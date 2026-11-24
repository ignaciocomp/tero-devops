"""Logs en JSON, una línea por evento, con los mismos campos en los seis servicios:
time (UTC), level (info, warn, error), service y msg. Los requests suman method, path,
status y duration_ms. Así CloudWatch Logs Insights filtra por campo.

Se configura al importar app.main, que uvicorn hace después de aplicar su propia
configuración de logging: así se reemplazan sus formatos de texto.
"""

import json
import logging
import logging.config
from datetime import datetime, timezone

SERVICE = "carts"

_LEVELS = {"WARNING": "warn", "CRITICAL": "error"}
# Atributos que trae todo LogRecord: el resto son campos agregados con extra=...
# color_message lo agrega uvicorn: es el mismo mensaje con códigos de color.
_STANDARD = set(vars(logging.LogRecord("", 0, "", 0, "", (), None))) | {
    "message",
    "asctime",
    "color_message",
}


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        entry = {
            "time": datetime.fromtimestamp(record.created, timezone.utc)
            .isoformat(timespec="milliseconds")
            .replace("+00:00", "Z"),
            "level": _LEVELS.get(record.levelname, record.levelname.lower()),
            "service": SERVICE,
            "msg": record.getMessage(),
            "logger": record.name,
        }
        for key, value in vars(record).items():
            if key not in _STANDARD and not key.startswith("_"):
                entry[key] = value
        if record.exc_info:
            entry["error"] = self.formatException(record.exc_info)
        # Sin espacios entre clave y valor, igual que los otros cinco servicios
        return json.dumps(entry, default=str, ensure_ascii=False, separators=(",", ":"))


LOGGING = {
    "version": 1,
    "disable_existing_loggers": False,
    "formatters": {"json": {"()": JsonFormatter}},
    "handlers": {
        "stdout": {
            "class": "logging.StreamHandler",
            "formatter": "json",
            "stream": "ext://sys.stdout",
        }
    },
    "root": {"handlers": ["stdout"], "level": "INFO"},
    "loggers": {
        # Los loggers de uvicorn pasan a usar el handler JSON de root.
        "uvicorn": {"handlers": [], "propagate": True},
        "uvicorn.error": {"handlers": [], "propagate": True},
        # El log de acceso de uvicorn es texto e incluye la IP del cliente: se apaga, y el
        # middleware de app.main registra cada request con campos.
        "uvicorn.access": {"handlers": [], "propagate": False, "level": "WARNING"},
    },
}


def configure_logging() -> None:
    logging.config.dictConfig(LOGGING)
    logging.captureWarnings(True)
