# Estrategia de ramas

Usamos GitHub Flow: `main` siempre desplegable y una rama corta por cambio, que entra por PR revisado. La justificación está en el [ADR 0002](../adr/0002-estrategia-de-ramas.md) y las reglas prácticas en [CONTRIBUTING.md](../../CONTRIBUTING.md).

## Historia real de `main`

Cada PR entra con un merge commit. En el PR #3 se ven también los commits que agregó el revisor durante la revisión.

```mermaid
gitGraph
  commit id: "56fd8cb inicial"
  branch fix/credenciales-hardcodeadas
  checkout fix/credenciales-hardcodeadas
  commit id: "8a25c88"
  checkout main
  merge fix/credenciales-hardcodeadas id: "PR #1"
  branch build/imagenes-docker
  checkout build/imagenes-docker
  commit id: "42ffac2"
  checkout main
  merge build/imagenes-docker id: "PR #2"
  branch fix/exposicion-puertos
  checkout fix/exposicion-puertos
  commit id: "78ce8f4"
  commit id: "4315144 revisión"
  commit id: "debe715 revisión"
  commit id: "55875d4 revisión"
  checkout main
  merge fix/exposicion-puertos id: "PR #3"
```

## Ciclo de vida de una rama

```mermaid
flowchart LR
  A["git switch -c tipo/descripcion<br/>desde main actualizada"] --> B["Commits<br/>(Conventional Commits)"]
  B --> C["Push y PR<br/>con la plantilla"]
  C --> D{"Revisión de la<br/>otra persona"}
  D -- "comentarios" --> E["Respuestas y<br/>commits nuevos"]
  E --> D
  D -- "aprobado, CI en verde y<br/>conversaciones resueltas" --> F["Create a merge commit"]
  F --> G["Delete branch"]
  F --> H["CI de main: imágenes<br/>con tag = SHA"]
  H --> I["Se promueve el mismo SHA:<br/>Dev, Test, Prod"]
```
