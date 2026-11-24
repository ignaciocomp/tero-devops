## Qué cambia

<!-- Lista corta de los cambios. -->

## Por qué

<!-- Qué observación del auditor o qué requisito de la letra atiende. -->

## Cómo probarlo

```bash
# Comandos para que el revisor lo pruebe en su máquina.
```

## Evidencia

<!-- Salidas, capturas o el link a la ejecución del CI. Sin secretos. -->

## Fuera de alcance

<!-- Lo que se vio pero queda para otro PR. -->

## Checklist

- [ ] La rama sale de `main` actualizada y su nombre sigue [CONTRIBUTING.md](../CONTRIBUTING.md).
- [ ] Los commits siguen Conventional Commits, en español.
- [ ] El diff no tiene secretos ni archivos `.env`.
- [ ] Si toca la aplicación o compose, `bash scripts/smoke-test.sh` pasa.
- [ ] Si cambia cómo se usa o se opera algo, actualicé el README, el ADR o la documentación.
- [ ] Le pedí la revisión a la otra persona del equipo.
