# Runbook: alarma `tero-<ambiente>-alb-5xx`

## Qué mide y cuándo se dispara

Es el porcentaje de requests a la tienda (el ALB público, puerto 80) que terminan en 5xx. Suma los 5xx que devuelve un servicio (`HTTPCode_Target_5XX_Count`) y los que devuelve el propio ALB (`HTTPCode_ELB_5XX_Count`), por ejemplo un 503 cuando no hay tareas sanas.

- Se dispara si pasa el 5 % (`alarm_5xx_percent`) en **3 de los últimos 5 minutos**.
- Solo cuenta los minutos con al menos 20 requests (`alarm_min_requests`). Con menos tráfico, un solo error sería el 100 %.
- Sin tráfico no se dispara.
- Avisa por mail (tópico `tero-<ambiente>-alarmas`) al dispararse y al volver a OK.

Está definida en `infra/observability.tf`.

## Impacto

Los clientes ven errores en la tienda: no cargan los productos, el carrito o el checkout fallan. Si el 5xx es del ALB, puede estar caída toda la tienda.

## Primeros 5 minutos

1. **Abrí el dashboard** del ambiente (`terraform output dashboard_url`) y fijate en la fila de la tienda:
   - **¿Los 5xx son de los servicios o del ALB?** Si son del ALB, no hay tareas sanas detrás de ui (503) o tardan demasiado (504): seguí en el paso 3. Si son de los servicios, seguí en el paso 2.
   - **¿Empezó justo después de un despliegue?** `terraform output image_tag` da el SHA desplegado. Comparalo con el último merge a `main`.
2. **Buscá qué servicio falla.** El panel "Requests con 5xx por servicio" lo muestra. Para ver el detalle, en CloudWatch → Logs Insights, elegí los grupos `/tero/<ambiente>/*` y corré:

   ```text
   fields @timestamp, service, method, path, status, error
   | filter level = "error"
   | sort @timestamp desc
   | limit 50
   ```

   Los 5xx de ui suelen venir de un backend, y el servicio que falla es el del path: `/api/orders` es orders. Con el ALB interno (Learner Lab), un backend sin tareas sanas no deja un `proxy error`. El ALB interno responde 503, y ui lo reenvía como un request con `status` 503. Se ve también en la fila "Llamados entre servicios" del dashboard, como 5xx del ALB. Un `proxy error` (`ECONNREFUSED`, `ETIMEDOUT`) aparece cuando ui no llega ni al ALB interno.
3. **Mirá el estado del servicio en ECS:**

   ```bash
   aws ecs describe-services --cluster tero-<ambiente> --services <servicio> \
     --query 'services[0].{deseadas:desiredCount,corriendo:runningCount,eventos:events[0:5].message}'
   ```

   Los eventos dicen si las tareas no arrancan (imagen que no baja, secreto que no se puede leer), si no pasan el health check o si el circuit breaker volvió atrás un despliegue.

## Causas frecuentes y qué hacer

| Lo que ves | Causa probable | Qué hacer |
|---|---|---|
| Empezó con un despliegue y los logs muestran errores nuevos | Un cambio en la aplicación | Volver al SHA anterior: `terraform apply -var-file=envs/<ambiente>.tfvars -var="image_tag=<SHA anterior>"` (ver el README de `infra/`). Después, abrir un issue con los logs |
| Requests de ui con 503 hacia un servicio (o `proxy error`), y ese servicio con 0 tareas corriendo | Las tareas no arrancan o se caen | Leer los eventos del paso 3 y los logs del servicio. Si es memoria, ver el [runbook de memoria](alarma-memoria.md) |
| Errores de la base en catalog, carts, orders o admin (`connection refused`, `password authentication failed`) | La base se reinicia o está caída, o la clave cambió sin redesplegar | Mirar la base en el dashboard y en la consola de RDS. Si se rotó la clave, aplicar de nuevo para que se redespliegue (README, "Rotar una clave"). Los servicios se reconectan solos cuando la base vuelve |
| Errores de Redis en checkout | Redis caído o la clave cambió | Lo mismo, con ElastiCache y `redis_password_version` |
| 503 del ALB y ninguna tarea sana en ui | ui no arranca o no pasa `/health` | Eventos de ui en ECS. Si no hay un despliegue reciente, forzar uno: `aws ecs update-service --cluster tero-<ambiente> --service ui --force-new-deployment` |

## Cómo probarla

**Solo el aviso, sin romper nada.** Pone la alarma en ALARM por un ratito. Tiene que llegar el mail, y en el próximo minuto, con métricas normales, vuelve sola a OK:

```bash
aws cloudwatch set-alarm-state --alarm-name tero-<ambiente>-alb-5xx \
  --state-value ALARM --state-reason "Prueba del runbook"
```

**De punta a punta, en Dev o Test, nunca en Prod.** Se deja orders sin tareas y se le pega a la tienda:

```bash
aws ecs update-service --cluster tero-dev --service orders --desired-count 0
URL="$(terraform output -raw ui_url)"
# 30 requests por minuto durante 6 minutos: el ALB interno responde 503, y ui lo reenvía
for i in $(seq 1 180); do curl -s -o /dev/null "$URL/api/orders"; sleep 2; done
aws ecs update-service --cluster tero-dev --service orders --desired-count 1
```

A los 3 o 4 minutos la alarma pasa a ALARM y llega el mail. Unos minutos después de volver orders, pasa a OK y llega el segundo mail.

## Al cerrar

- Confirmá que la alarma volvió a OK y que el panel de 5xx bajó a cero.
- Si hubo un rollback, abrí un issue con la causa, los logs y el SHA que falló, para arreglarlo antes de volver a desplegarlo.
