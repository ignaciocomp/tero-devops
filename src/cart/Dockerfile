# Imagen de carts (Python 3.12 + FastAPI). Dos etapas: build instala dependencias, runtime solo ejecuta.
# Decisiones y justificación: docs/adr/0001-imagenes-de-contenedor.md

# ---- Etapa 1: build --------------------------------------------------------
# Instala las dependencias en un entorno virtual que después se copia entero.
FROM python:3.12-slim-trixie AS build
# PIP_ONLY_BINARY: solo wheels ya compilados, así pip no ejecuta código de build de
# terceros (el equivalente a --ignore-scripts de npm).
ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_ONLY_BINARY=:all:
WORKDIR /build
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
COPY requirements.txt .
RUN pip install -r requirements.txt

# ---- Etapa 2: runtime ------------------------------------------------------
# Misma base slim (distroless no tiene Python 3.12): solo el venv y el código.
FROM python:3.12-slim-trixie
ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    CART_PERSISTENCE_PROVIDER=in-memory \
    PORT=8080
# Usuario sin privilegios con un UID fijo y alto (10001, para no chocar con usuarios del
# sistema), sin home ni shell de login. Además, a los binarios de la base que tienen el
# bit setuid/setgid (su, mount, passwd...) se les quita: el proceso no los necesita.
# Antes, se aplican los parches de seguridad de Debian que la imagen base todavía no trae
# (por ejemplo zlib1g, CVE-2026-85091): el escaneo de la imagen bloquea las CRITICAL/HIGH con fix.
RUN apt-get update \
 && apt-get upgrade -y --no-install-recommends \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --gid 10001 app \
 && useradd --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app \
 && find / -xdev -perm /6000 -type f -exec chmod a-s {} +
WORKDIR /app
COPY --from=build /opt/venv /opt/venv
COPY app ./app
EXPOSE 8080
USER 10001:10001
# exec: uvicorn reemplaza al shell y queda como PID 1, así recibe SIGTERM y se apaga limpio.
CMD ["sh", "-c", "exec uvicorn app.main:app --host 0.0.0.0 --port \"$PORT\""]
