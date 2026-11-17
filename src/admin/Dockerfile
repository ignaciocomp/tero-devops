# Imagen de admin (Node.js 22 + TypeScript). Dos etapas: build compila, runtime solo ejecuta.
# Decisiones y justificación: docs/adr/0001-imagenes-de-contenedor.md

# ---- Etapa 1: build --------------------------------------------------------
FROM node:22-trixie-slim AS build
# tini: init mínimo que después se copia a la imagen final (ver la etapa runtime).
RUN apt-get update \
 && apt-get install -y --no-install-recommends tini \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
# Primero solo los manifiestos: si no cambian, Docker reutiliza la capa de dependencias.
COPY package.json package-lock.json ./
# npm ci instala exactamente lo que dice el lockfile.
# --ignore-scripts: no ejecuta scripts de instalación de dependencias de terceros.
RUN npm ci --ignore-scripts
COPY . .
# Compila TypeScript y después deja en node_modules solo las dependencias de producción.
RUN npm run build && npm prune --omit=dev --ignore-scripts

# ---- Etapa 2: runtime ------------------------------------------------------
# distroless/nodejs: solo el runtime de Node (sin npm, sin shell, sin gestor de paquetes).
FROM gcr.io/distroless/nodejs22-debian13:nonroot
ENV NODE_ENV=production \
    PORT=8080
# Rutas absolutas y el WORKDIR después: así /app lo crea COPY como root y el proceso
# (UID 65532) puede leer su código, pero no crear ni modificar archivos ahí.
COPY --from=build /app/node_modules /app/node_modules
COPY --from=build /app/dist /app/dist
COPY --from=build /app/public /app/public
# tini queda como PID 1 y le reenvía las señales a Node. Sin esto, Node como PID 1 ignora
# SIGTERM (no instala un manejador) y Docker o ECS terminan matándolo con SIGKILL.
COPY --from=build /usr/bin/tini-static /tini
WORKDIR /app
EXPOSE 8080
# UID 65532 = usuario "nonroot" de distroless. Numérico para poder verificar que no es root.
USER 65532:65532
# -s: tini funciona igual (y sin advertencias) si el orquestador agrega su propio init.
# --no-global-search-paths: Node no busca módulos en $HOME/.node_modules, donde el proceso
# sí puede escribir, así que no se le puede "plantar" código para el próximo arranque.
ENTRYPOINT ["/tini", "-s", "--", "/nodejs/bin/node", "--no-global-search-paths"]
CMD ["dist/app.js"]
