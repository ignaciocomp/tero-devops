# Imagen de checkout (NestJS sobre Node.js 22, con Yarn 4). Dos etapas: build compila, runtime solo ejecuta.
# Decisiones y justificación: docs/adr/0001-imagenes-de-contenedor.md

# ---- Etapa 1: build --------------------------------------------------------
FROM node:22-trixie-slim AS build
WORKDIR /app
# No ejecuta scripts de instalación de dependencias de terceros.
ENV YARN_ENABLE_SCRIPTS=false
# Primero solo los manifiestos y .yarn: el binario de Yarn 4 versionado y, si existen,
# plugins y patches (el .dockerignore deja afuera la caché). El yarn de la imagen base
# le delega a ese binario porque .yarnrc.yml lo indica en yarnPath.
COPY package.json yarn.lock .yarnrc.yml ./
COPY .yarn ./.yarn
# --immutable: falla si yarn.lock no coincide con package.json (instalación reproducible).
RUN yarn install --immutable
COPY . .
# Compila y después reinstala solo las dependencias de producción.
RUN yarn build && yarn workspaces focus --production

# ---- Etapa 2: runtime ------------------------------------------------------
# distroless/nodejs: solo el runtime de Node (sin npm ni yarn, sin shell, sin gestor de paquetes).
FROM gcr.io/distroless/nodejs22-debian13:nonroot
ENV NODE_ENV=production \
    PORT=8080
# Rutas absolutas y el WORKDIR después: así /app lo crea COPY como root y el proceso
# (UID 65532) puede leer su código, pero no crear ni modificar archivos ahí (por ejemplo,
# un .env que @nestjs/config leería en el próximo arranque).
COPY --from=build /app/node_modules /app/node_modules
COPY --from=build /app/dist /app/dist
WORKDIR /app
EXPOSE 8080
# UID 65532 = usuario "nonroot" de distroless. Numérico para poder verificar que no es root.
USER 65532:65532
# Sin tini: src/main.ts llama a app.enableShutdownHooks(), así que Nest maneja SIGTERM.
# --no-global-search-paths: Node no busca módulos en $HOME/.node_modules, donde el proceso
# sí puede escribir, así que no se le puede "plantar" código para el próximo arranque.
ENTRYPOINT ["/nodejs/bin/node", "--no-global-search-paths"]
CMD ["dist/main.js"]
