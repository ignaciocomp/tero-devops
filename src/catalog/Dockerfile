# Imagen de catalog (Go). Dos etapas: build compila, runtime solo ejecuta.
# Decisiones y justificación: docs/adr/0001-imagenes-de-contenedor.md

# ---- Etapa 1: build --------------------------------------------------------
# Imagen completa de Go: trae el compilador y gcc, pero no llega a la imagen final.
FROM golang:1.27-trixie AS build
WORKDIR /src
# Primero solo los manifiestos: si no cambian, Docker reutiliza la capa de dependencias.
COPY go.mod go.sum ./
RUN go mod download
COPY . .
# CGO_ENABLED=1: el modo in-memory usa SQLite (gorm.io/driver/sqlite -> go-sqlite3),
# que está escrito en C y necesita cgo y glibc. Sin cgo, ese modo falla al ejecutarse.
# -trimpath y -ldflags "-s -w": sin rutas locales ni símbolos de depuración.
RUN CGO_ENABLED=1 go build -trimpath -ldflags="-s -w" -o /out/catalog .

# ---- Etapa 2: runtime ------------------------------------------------------
# distroless/base-nossl: trae la glibc que necesita el binario (por cgo) y no trae
# OpenSSL, que el binario no usa. Es Debian 13, como la etapa de build: la misma glibc 2.41
# (el runtime puede traer una revisión de seguridad más nueva, que es la dirección segura).
FROM gcr.io/distroless/base-nossl-debian13:nonroot
COPY --from=build /out/catalog /app/catalog
WORKDIR /app
# Gin en modo release aunque el orquestador no pase la variable (compose también la pasa).
ENV GIN_MODE=release
EXPOSE 8080
# UID 65532 = usuario "nonroot" de distroless. Numérico para poder verificar que no es root.
USER 65532:65532
ENTRYPOINT ["/app/catalog"]
