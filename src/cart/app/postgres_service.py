import logging
import threading
import time

import psycopg2
import psycopg2.extras
from app.models import Item, Cart
from app.service import CartService
from app.config import settings

log = logging.getLogger("carts")

# Los mismos tres valores que en los otros servicios con base. prefer y allow no se aceptan,
# porque pueden caer a texto plano.
SSL_MODES = ("disable", "require", "verify-full")
# Durante una caída de la base, un solo intento de reconexión cada tantos segundos.
RECONNECT_BACKOFF_S = 2


class PostgresCartService(CartService):
    """Una sola conexión, compartida por los threads en los que FastAPI corre los endpoints
    (psycopg2 lo permite).

    Si la base corta la conexión (un reinicio, un failover de RDS), la operación siguiente
    falla y la conexión queda rota: se abre otra y la operación se repite una vez. Si la
    conexión muere sin aviso (el servidor desaparece sin cerrarla), los keepalives y
    tcp_user_timeout hacen que falle en menos de un minuto, y sigue el mismo camino. Repetir
    no duplica datos, porque todas las operaciones son idempotentes: el upsert y el update
    guardan valores absolutos, y borrar dos veces deja lo mismo. Si la conexión sigue sana, el
    error es de la operación y se propaga como siempre."""

    def __init__(self):
        if settings.postgres_sslmode not in SSL_MODES:
            raise ValueError(
                f"unsupported CART_POSTGRES_SSLMODE {settings.postgres_sslmode!r}: "
                "use disable, require or verify-full"
            )
        self._lock = threading.Lock()
        self._last_failure = float("-inf")
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
            # Si la base deja de responder sin cerrar la conexión (puede pasar en un failover),
            # TCP lo detecta en menos de un minuto en lugar de unos 15: keepalives para la
            # conexión ociosa y tcp_user_timeout (ms) para la que espera una respuesta.
            keepalives=1,
            keepalives_idle=30,
            keepalives_interval=10,
            keepalives_count=3,
            tcp_user_timeout=30000,
            # Para ver en pg_stat_activity qué servicio tiene cada conexión.
            application_name="carts",
        )
        conn.autocommit = True
        return conn

    @staticmethod
    def _broken(conn) -> bool:
        # closed lo pone psycopg2 recién cuando el thread que detectó el corte procesa el error.
        # Mientras tanto, los otros threads ven closed == 0, pero libpq ya dejó la conexión en
        # CONNECTION_BAD: por eso se mira también info.status (0 es CONNECTION_OK).
        return conn.closed != 0 or conn.info.status != 0

    def _connection(self):
        # El lock evita que dos threads abran una conexión nueva a la vez.
        with self._lock:
            if self._broken(self._conn):
                # Si el último intento falló hace poco, se responde con error enseguida, en lugar
                # de que cada request espere en fila su propio intento (hasta 5 s cada uno).
                if time.monotonic() - self._last_failure < RECONNECT_BACKOFF_S:
                    raise psycopg2.OperationalError("database unavailable, waiting to reconnect")
                log.warning("reconnecting to the database")
                if not self._conn.closed:
                    # Rota pero no cerrada: se libera antes de abrir otra. Si falla al cerrarla,
                    # no importa, porque se descarta igual.
                    try:
                        self._conn.close()
                    except psycopg2.Error:
                        pass
                try:
                    self._conn = self._connect()
                except psycopg2.Error:
                    self._last_failure = time.monotonic()
                    raise
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
            except psycopg2.Error:
                # Se decide por el estado de la conexión, no por la clase de la excepción: con la
                # conexión rota, psycopg2 puede tirar más de una (OperationalError, InterfaceError
                # o DatabaseError).
                if attempt == 2 or not self._broken(conn):
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
