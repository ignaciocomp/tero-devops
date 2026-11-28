# Informe de análisis estático

- **Fecha:** 2026-11-22
- **Herramienta:** Semgrep 1.186.0, en el job `sast` del pipeline (ver el [ADR 0003](../adr/0003-ci-y-quality-gates.md)).
- **Reglas:** packs del registry `p/default`, `p/golang`, `p/python`, `p/javascript`, `p/typescript`, `p/nodejs` y `p/dockerfile`.
- **Alcance:** los archivos versionados del repo (96 al 2026-11-22): código de los seis servicios, Dockerfiles, HTML y configuración.

## Umbrales (quality gate)

| Severidad | Límite | Qué pasa si se supera |
|---|---|---|
| ERROR, CRITICAL o HIGH | 0 | El pipeline falla (gate de seguridad) |
| WARNING o MEDIUM | 1, la línea base medida | El pipeline falla (quality gate). El umbral solo baja |
| INFO o LOW | sin límite | Solo se informa |

El umbral funciona como un trinquete: cualquier hallazgo nuevo de nivel WARNING o MEDIUM hace fallar el pipeline, y cuando se corrige el que queda, el límite baja a 0. Cambiarlo requiere un PR. Que el pipeline falle todavía no impide mergear: eso empieza cuando los checks sean obligatorios en la protección de `main` (issue #16).

## Resultados

| Hallazgo | Severidad | Dónde | Resolución |
|---|---|---|---|
| `missing-integrity` (recurso sin atributo `integrity`) | WARNING | `src/ui/public/index.html` y `src/admin/public/index.html` | Falso positivo: el favicon es un `data:` URI, no carga nada externo. Se silenció en esa línea con `nosemgrep`, nombrando la regla |
| `yarn-missing-minimal-age-gate` | MEDIUM | `src/checkout/.yarnrc.yml` | Recomendación real, pendiente: configurar en Yarn una edad mínima para instalar versiones recién publicadas |

No hubo hallazgos ERROR. Semgrep además avisó que no pudo analizar del todo 4 Dockerfiles (ui, admin, carts y checkout): no interpreta bien los `RUN` con continuaciones de línea y comentarios intercalados, así que las reglas de Dockerfile cubren esos archivos solo en parte.

## Riesgos aceptados

Hallazgos reales que responden a una decisión escrita en un ADR, silenciados con `nosemgrep` según el [ADR 0003](../adr/0003-ci-y-quality-gates.md#cómo-se-maneja-una-excepción). No cuentan para el umbral, así que cada uno queda listado acá con su fecha de revisión.

| Hallazgo | Severidad | Dónde | Por qué se acepta | Mejora prevista | Desde | Revisión |
|---|---|---|---|---|---|---|
| `bypass-tls-verification` (`rejectUnauthorized: false`) | WARNING | `src/admin/src/app.ts`, en `dbSsl` | `DB_SSLMODE=require` cifra la conexión a la base sin verificar el certificado, igual que `sslmode=require` en los otros tres servicios. Es el valor por defecto, para conectarse a RDS sin el bundle de su CA ([ADR 0004](../adr/0004-tls-y-credenciales-hacia-los-datos.md)) | `verify-full` con el bundle de CA de RDS (`NODE_EXTRA_CA_CERTS` en admin) | 2026-11-27 | 2026-12-31 |

## Interpretación

Que haya tan pocos hallazgos no significa que el código no tenga problemas. Significa que no usa los patrones inseguros que buscan las reglas de la comunidad: inyección, `eval`, criptografía débil, deserialización insegura, entre otros. Semgrep tampoco mide mantenibilidad (duplicación, complejidad, "code smells") ni detecta fallas de diseño. Los problemas más significativos de Tero aparecieron en la revisión manual y al operar el stack, no en el escaneo:

- `sslmode=disable` fijo y la contraseña sin escapar al armar la conexión en catalog y orders;
- una sola conexión a PostgreSQL en carts (`src/cart/app/postgres_service.py`), que no se reconecta si la base se reinicia;
- pools de `pg` sin manejador de errores en admin (`src/admin/src/app.ts`): un error de una conexión ociosa tira el proceso;
- endpoints de diagnóstico sin autenticación (`/chaos/*` en catalog) y endpoints que devuelven la ubicación de la base y de Redis;
- un único usuario de base de datos con privilegios de superusuario para todos los servicios.

Por eso el gate actual sirve para evitar regresiones, pero no alcanza como medida de calidad del código. El PR del #18 corrigió los tres primeros y los endpoints de `/topology` (ver el [ADR 0004](../adr/0004-tls-y-credenciales-hacia-los-datos.md)). Quedan `/chaos/*` y el usuario único.

## Recomendaciones

1. **Medir mantenibilidad con SonarQube Cloud** (issue #20), con su propio quality gate: 0 bugs y vulnerabilidades nuevas, duplicación menor a 3 % y un tope de code smells. Es gratis para repos públicos.
2. **Sumar linters por lenguaje al CI:** ESLint en ui, admin y checkout; `golangci-lint` en catalog y orders; `ruff` en carts. Detectan errores comunes que Semgrep no busca.
3. **Escribir reglas propias de Semgrep para lo que encontró la revisión manual**, por ejemplo un `sslmode=disable` literal o un `fmt.Sprintf` que arme un DSN con la contraseña. Así, si vuelven, el gate los frena.
4. **Fijar la versión de las reglas.** Hoy los packs se bajan del registry en cada corrida, así que el resultado puede cambiar sin cambios en el código. Exportarlas a un archivo versionado hace el gate repetible.
5. **Reordenar los `RUN` de los Dockerfiles**, o sumar `hadolint`, para que el análisis de Dockerfiles sea completo.
6. **Configurar `npmMinimalAgeGate` en Yarn** después de confirmar que la versión vendorizada (4.11) lo soporta y que no frena las instalaciones con `--immutable`. Con eso se resuelve el último hallazgo y el umbral baja a 0.
