# Runbook: alarmas `tero-<ambiente>-<servicio>-memoria`

## Qué mide y cuándo se dispara

Hay una alarma por servicio: ui, catalog, carts, orders, checkout y admin. Cada una mide el máximo de `MemoryUtilization` (AWS/ECS) entre las tareas del servicio, como porcentaje de la memoria reservada en su task definition (`memory` en `services` del `.tfvars`).

- Se dispara si pasa el 85 % (`alarm_memory_percent`) en **3 minutos seguidos**.
- Sin datos no se dispara: un servicio sin tareas lo detecta la [alarma de 5xx](alarma-5xx.md).
- Avisa por mail (tópico `tero-<ambiente>-alarmas`) al dispararse y al volver a OK.

Está definida en `infra/observability.tf`.

## Impacto

Todavía ninguno: es un aviso previo. Si la memoria llega al 100 %, ECS mata la tarea (`OutOfMemoryError`) y arranca otra. Mientras tanto:

- **Con una sola tarea** (Dev y Test), el servicio queda caído unos segundos y la tienda devuelve 5xx.
- **Con dos** (Prod), atiende la otra.

Si vuelve a pasar en cada tarea nueva, el servicio entra en un ciclo de reinicios.

## Primeros 5 minutos

1. **Abrí el dashboard** (`terraform output dashboard_url`), panel "Memoria por servicio":
   - **¿Sube de a poco y no baja?** Es probable una pérdida de memoria (leak): con el tiempo va a llegar al 100 %.
   - **¿Saltó de golpe?** Puede ser un pico de tráfico (mirá "Requests por minuto") o un request puntual muy pesado.
   - **¿Empezó con un despliegue?** Compará `terraform output image_tag` con el último merge a `main`.
2. **¿ECS ya mató alguna tarea?**

   ```bash
   aws ecs list-tasks --cluster tero-<ambiente> --service-name <servicio> --desired-status STOPPED
   aws ecs describe-tasks --cluster tero-<ambiente> --tasks <arn> \
     --query 'tasks[0].{motivo:stoppedReason,contenedor:containers[0].reason}'
   ```

   `OutOfMemoryError: Container killed due to memory usage` confirma que llegó al límite.
3. **Mirá los logs del servicio** en Logs Insights (grupo `/tero/<ambiente>/<servicio>`), justo antes de la subida: requests muy lentos, errores repetidos o el mismo `path` muchas veces.

## Qué hacer

| Lo que ves | Qué hacer |
|---|---|
| Empezó con un despliegue | Volver al SHA anterior: `terraform apply -var-file=envs/<ambiente>.tfvars -var="image_tag=<SHA anterior>"`. Después, abrir un issue para buscar la causa |
| Sube de a poco, sin despliegue reciente (leak) | Ganar tiempo con tareas nuevas: `aws ecs update-service --cluster tero-<ambiente> --service <servicio> --force-new-deployment`. Abrir un issue para buscar la causa en el código |
| Pico de tráfico, o la reserva quedó chica | Subir `memory` (o `desired_count`) del servicio en `envs/<ambiente>.tfvars`, por PR, y aplicar. Las combinaciones válidas de Fargate son, por ejemplo, 256 de CPU con 512, 1024 o 2048 de memoria |

No conviene subir `alarm_memory_percent` para que deje de sonar: el límite de la tarea sigue siendo el mismo.

## Cómo probarla

**Solo el aviso, sin romper nada.** Tiene que llegar el mail, y en el próximo minuto, con métricas normales, vuelve sola a OK:

```bash
aws cloudwatch set-alarm-state --alarm-name tero-<ambiente>-catalog-memoria \
  --state-value ALARM --state-reason "Prueba del runbook"
```

**Con la métrica real, en Dev o Test.** Se baja el umbral por debajo de lo que usan los servicios. Todas las alarmas de memoria pasan a ALARM en 3 o 4 minutos, y vuelven a OK al aplicar de nuevo con el valor normal:

```bash
terraform apply -var-file=envs/dev.tfvars -var="image_tag=<SHA desplegado>" -var="alarm_memory_percent=1"
# esperar el mail de cada servicio
terraform apply -var-file=envs/dev.tfvars -var="image_tag=<SHA desplegado>"
```

## Al cerrar

- Confirmá que la alarma volvió a OK y que la memoria se estabilizó por debajo del umbral.
- Si cambiaste la reserva de memoria, que quede en el `.tfvars` por PR y no solo aplicada a mano.
