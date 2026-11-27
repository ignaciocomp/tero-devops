import logging
import time

from fastapi import FastAPI, Request
from fastapi.responses import PlainTextResponse
from prometheus_fastapi_instrumentator import Instrumentator
from app.config import settings
from app.logging_config import configure_logging
from app.router import router

configure_logging()
log = logging.getLogger("carts")

app = FastAPI(title="Cart Service")


@app.middleware("http")
async def log_requests(request: Request, call_next):
    """Un log por request, con campos. Solo la ruta, sin la query string ni la IP, para no
    dejar datos de los usuarios. El health check no se registra: en la nube lo consulta el
    balanceador cada pocos segundos."""
    start = time.perf_counter()
    path = request.url.path
    fields = {"method": request.method, "path": path}
    try:
        response = await call_next(request)
    except Exception:
        fields.update(status=500, duration_ms=round((time.perf_counter() - start) * 1000, 3))
        log.exception("request", extra=fields)
        # Se responde el 500 acá en lugar de relanzar: si se relanza, uvicorn vuelve a
        # registrar la misma excepción ("Exception in ASGI application") y cada error queda
        # dos veces. Es la misma respuesta que da Starlette.
        return PlainTextResponse("Internal Server Error", status_code=500)
    if path != "/health":
        status = response.status_code
        level = logging.ERROR if status >= 500 else logging.WARNING if status >= 400 else logging.INFO
        fields.update(status=status, duration_ms=round((time.perf_counter() - start) * 1000, 3))
        log.log(level, "request", extra=fields)
    return response


@app.on_event("startup")
def startup():
    if settings.cart_persistence_provider == "postgres":
        from app.postgres_service import PostgresCartService
        app.state.cart_service = PostgresCartService()
    else:
        from app.service import InMemoryCartService
        app.state.cart_service = InMemoryCartService()


@app.get("/topology")
def topology():
    return {"provider": settings.cart_persistence_provider}


@app.get("/health")
def health():
    return {"status": "UP"}


app.include_router(router)
Instrumentator().instrument(app).expose(app, endpoint="/metrics")
