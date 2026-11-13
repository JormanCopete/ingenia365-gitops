# Alertas: dónde se ven y cómo cambiarlas

Las alertas de DEV, QA y producción llegan al chat de Telegram **IngenIA365 Alertas**.
Cada mensaje dice qué pasa, en qué ambiente, qué tan grave es y qué hacer; abajo
va el detalle técnico para quien lo revise.

## Verlas y silenciarlas: Grafana

Entrar con Tailscale encendido a **https://erp-nonprod.tail72aebc.ts.net**
(usuario `admin`; la clave se saca como dice [accesos.md](accesos.md)).

- **Qué está sonando:** menú *Alerting → Alert rules*, filtrar por la etiqueta
  `origen=ingenia365`. Ahí aparecen las mismas alertas, con los mismos textos
  (título, qué pasa, qué hacer) que llegan a Telegram.
- **Callar un aviso un rato** (por ejemplo durante un mantenimiento): *Alerting →
  Silences → New silence*, elegir el Alertmanager, poner la etiqueta
  `alertname = <nombre de la alerta>` y la duración. Al vencer vuelve a avisar.

Desde Grafana **no** se pueden cambiar los textos ni las reglas: el Alertmanager
que usamos no lo permite (sólo silencios). Eso se cambia en GitHub:

## Cambiar un texto, un umbral o una espera: GitHub

Los textos viven en las reglas mismas, en dos archivos de este repositorio:

- `infrastructure/nonprod/alertas-explicadas.yaml`: servidor, discos, componentes,
  despliegues, tareas programadas, monitoreo de producción.
- `infrastructure/nonprod/alertas-backup.yaml`: copias de seguridad.

Pasos: abrir el archivo en github.com, botón del lápiz (*Edit*), cambiar el texto
de `titulo`, `que_pasa` o `que_hacer` de la alerta, y *Commit changes* en `main`.
En uno o dos minutos Argo lo aplica solo (aplicación `monitoreo-alertas`) y el
siguiente aviso ya sale con el texto nuevo, en Telegram y en Grafana.

Otros cambios en el mismo archivo:

- `for: 15m`: cuánto tiene que durar el problema antes de avisar.
- `severity: critical` o `warning`: 🔴 problema grave o 🟠 aviso.
- Una alerta deja de llegar si se le quita la línea `origen: ingenia365` de sus
  `labels` (sigue viéndose en Grafana).

Lo que **no** se edita desde GitHub: a qué chat llega y la forma del mensaje
(`alertas-telegram.yaml`), porque el chat no puede estar en este repositorio, que
es público. Eso se pide.
