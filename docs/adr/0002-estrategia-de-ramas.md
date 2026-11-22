# ADR 0002: Estrategia de ramas: GitHub Flow

- **Estado:** aceptada
- **Fecha:** 2026-11-22
- **Relacionada con:** el requisito de control de versiones de la entrega (estrategia de ramas justificada, PRs con revisión entre integrantes y ramas protegidas) y la observación 5 de la auditoría: "no hay forma de saber qué versión se está ejecutando ni de repetir un despliegue de la misma manera dos veces".

## Contexto

- Somos dos personas y cada una lleva una parte distinta (aplicación y CI por un lado, infraestructura por el otro). Cada cambio lo revisa la otra persona.
- Entregamos de forma continua: cada bloque de trabajo es chico y entra a `main` en uno o dos días.
- Los ambientes Dev, Test y Prod no dependen de ramas. El pipeline construye las imágenes de cada commit de `main`, las etiqueta con su SHA y promueve esa misma imagen de Dev a Test y a Prod si pasa los controles.
- La letra pide una estrategia definida y justificada, al menos dos PRs con comentarios de revisión, y que ninguna rama se fusione sin la aprobación de alguien distinto al autor.
- Los PR #1, #2 y #3 ya se trabajaron así, pero la estrategia no estaba escrita.

## Decisión

Usamos **GitHub Flow**: una sola rama de larga vida, `main`, que siempre se puede desplegar, y ramas cortas por cambio que entran por pull request.

| Regla | Cómo se aplica |
|---|---|
| `main` protegida | PR obligatorio, 1 aprobación de alguien distinto al autor y todas las conversaciones resueltas. Cada push nuevo descarta la aprobación anterior. Sin force push ni borrado, también para administradores. |
| Una rama por bloque | Sale de `main` actualizada, vive pocos días y lleva un prefijo según el tipo de cambio (ver [CONTRIBUTING.md](../../CONTRIBUTING.md)). |
| Revisión real | Comentarios en líneas concretas. El autor responde y corrige con commits nuevos; después de pedir revisión no se reescribe la historia de la rama. |
| Merge commit | Se fusiona con "Create a merge commit": en `main` queda un commit "Merge pull request #N" por PR, con la historia de la rama. Así se ve qué entró en cada PR y se puede revertir un PR entero. |
| Versiones por SHA | Cada commit de `main` genera imágenes con su SHA como tag, y esa misma imagen se promueve entre ambientes. No hay ramas de release. |
| Arreglos urgentes | Igual que cualquier cambio: rama `fix/...` desde `main`, PR revisado y merge. Para volver atrás rápido se vuelve a desplegar el SHA anterior, y el arreglo entra después por PR (o con `git revert` del merge commit, también por PR). |
| Controles automáticos | Cuando el CI esté estable, sus jobs pasan a ser obligatorios en la protección de `main`. |

## Alternativas consideradas

- **Git Flow** (`main`, `develop`, `feature/*`, `release/*`, `hotfix/*`). Está pensado para versiones planificadas y varias líneas de desarrollo en paralelo. Con dos personas y entrega continua suma dos ramas de larga vida y merges dobles sin beneficio. Además, nuestras "versiones" ya son el SHA que se promueve entre ambientes.
- **Trunk-Based Development con feature flags.** Commits directos o ramas de horas contra `main`, con flags para esconder lo que no está terminado. Necesita una infraestructura de flags que Tero no tiene y deja menos lugar a la revisión por PR, que es justamente la evidencia que pide la letra.
- **Ramas por ambiente** (`dev`, `test`, `prod`). Mezclan el código con el estado de cada ambiente, obligan a hacer merges para promover y permiten que un ambiente corra un código distinto del que se revisó. Promover la misma imagen por SHA es más simple y se puede verificar.
- **Squash merge o rebase merge.** El squash deja un solo commit por PR y pierde los commits de la revisión (por ejemplo, las tres correcciones del PR #3) y quién hizo cada uno. El rebase reescribe los SHA de la rama. Preferimos el merge commit.

## Consecuencias

- `main` tiene que estar siempre desplegable: el CI corre en cada PR y frena el merge si falla.
- Cada cambio deja evidencia de revisión: el PR, los comentarios, las respuestas y la aprobación.
- Las ramas tienen que ser cortas. Si una vive mucho, aparecen conflictos; se resuelven con `git merge origin/main` dentro de la rama, sin rebase ni force push.
- Sin ramas de release, la versión que corre en cada ambiente se conoce por el SHA de la imagen desplegada.
- El botón "Revert" de GitHub crea una rama que deshace el PR: se usa solo a propósito, y también entra por PR.

## Evidencia

- Los PR #1 (credenciales), #2 (imágenes) y #3 (puertos) entraron con merge commit: `7557228`, `11e37c1` y `5f19eae`.
- El PR #3 tiene 9 comentarios de revisión en líneas con sus respuestas, 3 commits de corrección del revisor que el autor revisó y probó, y todas las conversaciones resueltas antes del merge.
- La protección de `main` se puede consultar con `gh api repos/ignaciocomp/tero-devops/branches/main/protection`.
- Diagrama: [docs/diagramas/ramas.md](../diagramas/ramas.md).
