# Cómo trabajamos en Tero

Usamos GitHub Flow. La justificación está en el [ADR 0002](docs/adr/0002-estrategia-de-ramas.md) y el diagrama en [docs/diagramas/ramas.md](docs/diagramas/ramas.md). Acá van las reglas prácticas.

## Ramas

Cada cambio va en una rama nueva, que sale de `main` actualizada:

```bash
git switch main
git pull --ff-only
git switch -c <tipo>/<descripcion-corta>
```

| Prefijo | Para qué |
|---|---|
| `feat/` | Funcionalidad nueva |
| `fix/` | Corrección |
| `build/` | Imágenes y builds |
| `ci/` | Pipelines de CI/CD |
| `infra/` | Terraform e infraestructura |
| `test/` | Pruebas |
| `obs/` | Observabilidad |
| `docs/` | Documentación |

Las ramas son cortas: un bloque de trabajo, de uno a tres días.

## Commits

- Conventional Commits en español: `tipo(alcance): descripción`. Por ejemplo, `fix(security): no publicar db ni redis en puertos del host`.
- Título de hasta 72 caracteres. En el cuerpo va el porqué, con líneas de hasta 72.
- `git add` con los archivos explícitos, nunca `git add .`. Ni `.env` ni secretos, en ningún caso.
- Identidad de git asociada a tu cuenta de GitHub. Como el repo es público, conviene usar el email "noreply" (GitHub → Settings → Emails): `git config user.email "<id>+<usuario>@users.noreply.github.com"`.

## Pull requests

- Usá la plantilla: qué cambia, por qué, cómo probarlo, evidencia y lo que queda fuera de alcance.
- Revisa la otra persona del equipo. Nadie aprueba su propio PR: GitHub no lo deja y la protección de `main` pide una aprobación.
- La revisión se hace con comentarios en líneas concretas: preguntas de verdad o pedidos con una propuesta. Una aprobación sin comentarios no sirve como evidencia de revisión.
- El autor contesta cada comentario. Los arreglos van en commits nuevos y se responde "Corregido en <hash>". Después de pedir revisión, nada de `--amend` ni `push --force`.
- Las conversaciones se resuelven antes del merge (la protección lo exige). Cada push nuevo descarta la aprobación anterior.
- Si hay conflictos con `main`: `git fetch origin` y después `git merge --no-edit origin/main` dentro de la rama. Sin rebase.
- Para fusionar: "Create a merge commit", después "Delete branch". El botón "Revert" que aparece después crea una rama que deshace todo el PR: solo se usa a propósito.

## Antes de pedir revisión

- Si el cambio toca la aplicación o compose: `bash scripts/smoke-test.sh` (ver el [README](README.md)).
- Cuando el CI esté activo, que la ejecución del PR esté en verde.
