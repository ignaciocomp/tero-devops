import logging
import threading

import psycopg2
import psycopg2.extras
from app.models import Item, Cart
from app.service import CartService
from app.config import settings

log = logging.getLogger("carts")


class PostgresCartService(CartService):
    """Una sola conexión, compartida por los threads en los que FastAPI corre los endpoints
    (psycopg2 lo permite).

    Si la base corta la conexión (un reinicio, un failover de RDS), la operación siguiente
    falla y psycopg2 marca la conexión como cerrada: se abre otra y la operación se repite una
    vez. Repetir no duplica datos, porque todas las operaciones son idempotentes: el upsert y
    el update guardan valores absolutos, y borrar dos veces deja lo mismo. Si la conexión
    sigue abierta, el error es de la operación y se propaga como siempre."""

    def __init__(self):
        self._lock = threading.Lock()
        self._conn = self._connect()

    def _connect(self):
        conn = psycopg2.connect(
            host=settings.postgres_host,
            port=settings.postgres_port,
            dbname=settings.postgres_db,
            user=settings.postgres_user,
            password=settings.postgres_password,
            sslmode=settings.postgres_sslmode,
            connect_timeout=5,
        )
        conn.autocommit = True
        return conn

    def _connection(self):
        # El lock evita que dos threads abran una conexión nueva a la vez.
        with self._lock:
            if self._conn.closed:
                log.warning("reconnecting to the database")
                self._conn = self._connect()
            return self._conn

    def _execute(self, sql: str, params: tuple, fetch: str | None = None):
        """Ejecuta una sentencia. Con fetch="one" o "all" devuelve las filas como
        diccionarios; sin fetch, la cantidad de filas afectadas."""
        for attempt in (1, 2):
            conn = self._connection()
            try:
                with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
                    cur.execute(sql, params)
                    if fetch == "one":
                        return cur.fetchone()
                    if fetch == "all":
                        return cur.fetchall()
                    return cur.rowcount
            except (psycopg2.OperationalError, psycopg2.InterfaceError):
                if attempt == 2 or not conn.closed:
                    raise

    def get(self, customer_id: str) -> Cart:
        return Cart(customerId=customer_id, items=self.get_items(customer_id))

    def delete(self, customer_id: str) -> None:
        self._execute("DELETE FROM cart_items WHERE customer_id = %s", (customer_id,))

    def merge(self, customer_id: str, session_id: str) -> None:
        for item in self.get_items(session_id):
            self.add_item(customer_id, item)
        self.delete(session_id)

    def get_items(self, customer_id: str) -> list[Item]:
        rows = self._execute(
            "SELECT item_id, quantity, unit_price FROM cart_items WHERE customer_id = %s",
            (customer_id,),
            fetch="all",
        )
        return [
            Item(itemId=r["item_id"], quantity=r["quantity"], unitPrice=r["unit_price"])
            for r in rows
        ]

    def add_item(self, customer_id: str, item: Item) -> Item:
        self._execute(
            """
            INSERT INTO cart_items (customer_id, item_id, quantity, unit_price)
            VALUES (%s, %s, %s, %s)
            ON CONFLICT (customer_id, item_id)
            DO UPDATE SET quantity = EXCLUDED.quantity, unit_price = EXCLUDED.unit_price
            """,
            (customer_id, item.itemId, item.quantity, item.unitPrice),
        )
        return item

    def update_item(self, customer_id: str, item: Item) -> Item | None:
        updated = self._execute(
            """
            UPDATE cart_items SET quantity = %s, unit_price = %s
            WHERE customer_id = %s AND item_id = %s
            """,
            (item.quantity, item.unitPrice, customer_id, item.itemId),
        )
        return item if updated > 0 else None

    def get_item(self, customer_id: str, item_id: str) -> Item | None:
        r = self._execute(
            "SELECT item_id, quantity, unit_price FROM cart_items WHERE customer_id = %s AND item_id = %s",
            (customer_id, item_id),
            fetch="one",
        )
        return Item(itemId=r["item_id"], quantity=r["quantity"], unitPrice=r["unit_price"]) if r else None

    def delete_item(self, customer_id: str, item_id: str) -> None:
        self._execute(
            "DELETE FROM cart_items WHERE customer_id = %s AND item_id = %s",
            (customer_id, item_id),
        )
