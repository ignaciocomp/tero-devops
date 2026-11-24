# Imagen de orders (Go). Dos etapas: build compila, runtime solo ejecuta.
# Decisiones y justificación: docs/adr/0001-imagenes-de-contenedor.md

# ---- Etapa 1: build --------------------------------------------------------
# Imagen completa de Go: trae el compilador, pero no llega a la imagen final.
FROM golang:1.27-trixie AS build
WORKDIR /src
# Primero solo los manifiestos: si no cambian, Docker reutiliza la capa de dependencias.
COPY go.mod go.sum ./
RUN go mod download
COPY . .
# CGO_ENABLED=0: binario estático, no necesita libc en la imagen final.
# -trimpath y -ldflags "-s -w": sin rutas locales ni símbolos de depuración.
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/orders .

# ---- Etapa 2: runtime ------------------------------------------------------
# distroless/static: sin shell ni gestor de paquetes; trae certificados CA y zonas horarias.
FROM gcr.io/distroless/static-debian13:nonroot
COPY --from=build /out/orders /app/orders
WORKDIR /app
# Gin en modo release aunque el orquestador no pase la variable (compose también la pasa).
ENV GIN_MODE=release
EXPOSE 8080
# UID 65532 = usuario "nonroot" de distroless. Numérico para poder verificar que no es root.
USER 65532:65532
ENTRYPOINT ["/app/orders"]
