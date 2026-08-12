# ENTREGABLE — Respaldo, retención y recuperación de PostgreSQL (CNPG 1.30 + Barman Cloud Plugin 0.14.0 + AWS S3)

**Alcance:** clusters `erp-db` en `erp-pdn` (servidor de producción) y `erp-dev` / `erp-qa` (servidor no productivo). Bucket `ingenia365-erp-backups`, región `us-east-1`.

## Estado verificado (2026-08-12)

**PostgreSQL producción — operativo y comprobado contra S3:**

| Comprobación | Resultado |
|---|---|
| `ContinuousArchiving` | `True` — "Continuous archiving is working" |
| Archivado de WAL | `last_archived_time` posterior a `last_failed_time` |
| Respaldo base | `base/20260812T160119/data.tar.gz` (4,9 MiB) + `backup.info` |
| Marcador `.backup` | presente: ancla el respaldo a su punto en el WAL (habilita PITR) |
| Etiquetas | `sistema`, `env=pdn`, `clasificacion=confidencial` |
| Object Lock | `GOVERNANCE` hasta 2026-09-21 (los 40 días configurados) |
| Cifrado | `AES256` |

**MongoDB — ciclo completo ensayado en DEV**, incluida la restauración: ver
[mongo-replica-set.md](mongo-replica-set.md).

> ⚠️ **Falta el ensayo de restauración de PostgreSQL.** Que el respaldo exista y
> esté bien etiquetado no prueba que sirva. Con MongoDB el ensayo de
> restauración destapó dos defectos; con PostgreSQL esa prueba está pendiente.

> ⚠️ **Producción no tiene monitoreo.** El fallo de archivado de hoy acumuló 102
> errores durante ~45 minutos sin que nada avisara — se detectó por observación
> directa. Prometheus corre en el servidor de nonprod y no vigila PDN. Con datos
> reales encima, eso significa creer que hay PITR cuando no lo hay.

### Lecciones del día de la puesta en marcha

1. **`s3:PutObjectTagging` faltaba en la política IAM.** El `ObjectStore` declara
   etiquetas y la política no permitía aplicarlas: cada WAL se subía y moría al
   etiquetar. Dos piezas del mismo diseño que no se cruzaron.
2. **`s3:PutBucketLifecycleConfiguration` no existe** — la acción real es
   `s3:PutLifecycleConfiguration`. Estaba en un bloque `Deny`, donde una acción
   inexistente no deniega nada: un hueco silencioso si AWS la hubiera aceptado.
3. **Object Lock no se puede habilitar en un bucket existente.** Por eso se creó
   uno dedicado en vez de reutilizar `polly-carteravirtual-pdn`.

## Decisiones que gobiernan todos los manifiestos

| # | Decisión | Valor | Por qué |
|---|---|---|---|
| D1 | Prefijo por ambiente **y** `serverName` explícito | `erp/pdn` + `erp-db-pdn`, etc. | Los tres clusters se llaman `erp-db`. `serverName` cae por defecto al nombre del cluster: sin separación, DEV pisaría el catálogo de PDN. Doble barrera (prefijo + serverName) por si alguien clona un `destinationPath`. |
| D2 | `serverName` **prohibido** en `ObjectStore.spec.configuration` | ausente | El campo existe solo por compatibilidad in-tree; se fija en `Cluster.spec.plugins[].parameters.serverName`. |
| D3 | `region` es un **secretKeyRef**, no un string | clave `AWS_REGION` en el Secret | El CRD lo define como `{name,key}` con ambos requeridos. `region: us-east-1` es rechazado por el API server. |
| D4 | `retentionPolicy` en `spec.retentionPolicy` | PDN `35d`, QA `14d`, DEV `7d` | El CRD lo pone fuera de `configuration` (la página `concepts.md` de la doc está equivocada). Patrón `^[1-9][0-9]*[dwm]$`; `m` = **meses**. 35d = ciclo contable mensual + 5 días de detección. |
| D5 | Compresión desde el día 1 | WAL `zstd`, data `gzip` | El plugin **no comprime por defecto**: con `archive_timeout=300s` serían 288 × 16 MiB = 4.6 GB/día de ceros (~$3.2/mes). Con `zstd` bajan a ~40 KB c/u. Una línea de YAML, factor ~400×. `zstd` es válido solo para WAL; `data` admite `gzip│bzip2│lz4│snappy`. |
| D6 | `archive_timeout` | PDN `300s`, QA `900s`, DEV `300s` (piloto) → `1800s` | RPO ≤ 5 min en PDN. Bajar a 60s multiplica ×5 los objetos y, sobre todo, ×5 la velocidad a la que `pg_wal` llena el PVC de 20 Gi si el archivado se cae — que es el modo de fallo que tumba producción. |
| D7 | Hora del backup de PDN | **06:30 UTC = 01:30 COT** | Después del cierre nocturno, antes de la jornada de las cooperativas, y fuera de la ventana de mantenimiento (dom 03:00–05:00 COT) documentada en `docs/operaciones/slo.md`. Cron de CNPG es de **6 campos** (incluye segundos). |
| D8 | `backupOwnerReference: cluster` en PDN | | Los objetos `Backup` sobreviven a editar/recrear el `ScheduledBackup`; solo mueren con el Cluster. Preserva el rastro para auditoría. En DEV/QA `self` (basura efímera). |
| D9 | Retención regulatoria SARLAFT **no** con backups físicos | dumps lógicos mensuales a bucket con Object Lock Compliance | Un PGDATA binario de PG 17.7 en 2031 es arqueología de contenedores. 5 años de backups físicos ≈ 3.6 TB ≈ $85/mes para restaurar cero veces. Ver §5.3. |

---

# 1. MANIFIESTOS

Todos verificados contra el CRD `barmancloud.cnpg.io_objectstores.yaml` del tag `v0.14.0` y los tipos de `cloudnative-pg/api` release-1.30. Aplicables tal cual.

## 1.0 Secret — añadir la región (previo obligatorio)

El Secret `s3-backup-creds` ya existe con `ACCESS_KEY_ID` / `ACCESS_SECRET_KEY`. Falta la región y la etiqueta de recarga:

```powershell
foreach ($ns in @('erp-pdn')) {                     # y 'erp-dev','erp-qa' en el otro clúster
  kubectl patch secret s3-backup-creds -n $ns --type=merge -p '{"stringData":{"AWS_REGION":"us-east-1"}}'
  kubectl label secret s3-backup-creds -n $ns cnpg.io/reload="" --overwrite
}
kubectl get secret s3-backup-creds -n erp-pdn -o jsonpath='{.data}' | ConvertFrom-Json | Get-Member -MemberType NoteProperty | Select-Object Name
```

Salida esperada: `ACCESS_KEY_ID`, `ACCESS_SECRET_KEY`, `AWS_REGION`.

> `stringData` funciona en un merge patch: el API server lo convierte a `data`. Sin la etiqueta `cnpg.io/reload`, un cambio posterior de credenciales no llega al sidecar hasta reiniciar el pod.

---

## 1.a ObjectStore — `erp-pdn`

**Archivo:** `k8s/backup/pdn/01-objectstore.yaml`

```yaml
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: erp-pdn-store
  namespace: erp-pdn
  labels:
    app.kubernetes.io/part-of: ingenia365erp
    ambiente: pdn
spec:
  # OJO: retentionPolicy va AQUI, no dentro de configuration.
  # Patron ^[1-9][0-9]*[dwm]$  ->  d=dias, w=semanas, m=MESES (no minutos).
  retentionPolicy: "35d"
  configuration:
    # Unico campo obligatorio de toda la configuracion.
    destinationPath: "s3://ingenia365-erp-backups/erp/pdn"
    # endpointURL: se OMITE para AWS S3 nativo (autodiscovery de boto3).
    #              Al migrar a MinIO: endpointURL: "https://minio.interno:9000"
    # serverName: PROHIBIDO aqui. Se fija en Cluster.spec.plugins[].parameters.serverName
    s3Credentials:
      accessKeyId:
        name: s3-backup-creds
        key: ACCESS_KEY_ID
      secretAccessKey:
        name: s3-backup-creds
        key: ACCESS_SECRET_KEY
      region:                    # es un secretKeyRef, NO un string literal
        name: s3-backup-creds
        key: AWS_REGION
    wal:
      compression: zstd          # WAL admite: bzip2|gzip|lz4|snappy|xz|zstd
      encryption: AES256         # SSE-S3 forzado en el PUT
      maxParallel: 8             # sube WAL en lote; tambien acelera el replay al restaurar
    data:
      compression: gzip          # data admite: bzip2|gzip|lz4|snappy  (NO zstd/xz)
      encryption: AES256
      jobs: 2
      immediateCheckpoint: false
    tags:
      env: "pdn"
      sistema: "ingenia365erp"
      clasificacion: "confidencial"
    historyTags:
      env: "pdn"
      tipo: "wal-history"
  instanceSidecarConfiguration:
    logLevel: info
    retentionPolicyIntervalSeconds: 1800
    # Descomentar SOLO al migrar a MinIO / S3-compatible (issue #393, x-amz-content-sha256):
    # env:
    #   - name: AWS_REQUEST_CHECKSUM_CALCULATION
    #     value: "when_required"
    #   - name: AWS_RESPONSE_CHECKSUM_VALIDATION
    #     value: "when_required"
    resources:
      requests: { cpu: "50m",  memory: "128Mi" }
      limits:   { cpu: "500m", memory: "512Mi" }
```

---

## 1.b Conectar el Cluster `erp-db` existente al plugin — `erp-pdn`

⚠️ **Esto provoca un rollout.** El plugin inyecta el sidecar `plugin-barman-cloud` en el PodSpec. Con `instances: 1` **es downtime real**, no un rolling update sin corte. Ventana obligatoria.

**Archivo:** `k8s/backup/pdn/02-cluster-patch.yaml` (aplicable con `kubectl patch --type=merge --patch-file`)

```yaml
spec:
  plugins:
    - name: barman-cloud.cloudnative-pg.io   # constante PluginName, literal exacto
      enabled: true
      isWALArchiver: true                    # maximo UN plugin puede tenerlo
      parameters:
        barmanObjectName: erp-pdn-store
        serverName: erp-db-pdn               # CRITICO: sin esto seria "erp-db" y colisionaria
  postgresql:
    parameters:
      archive_timeout: "300s"                # RPO <= 5 min
      wal_compression: "lz4"                 # comprime full-page images DENTRO del WAL (~40-50%)
      max_wal_size: "2GB"
      min_wal_size: "256MB"
      wal_keep_size: "1GB"
```

```powershell
# Verificar ANTES que no exista .spec.backup.barmanObjectStore (no puede coexistir con el plugin)
kubectl get cluster erp-db -n erp-pdn -o jsonpath='{.spec.backup}'      # esperado: vacio o sin barmanObjectStore

kubectl patch cluster erp-db -n erp-pdn --type=merge --patch-file k8s/backup/pdn/02-cluster-patch.yaml
```

Equivalente declarativo, si prefieres versionar el Cluster completo en Git (las secciones omitidas se conservan tal cual están hoy):

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: erp-db
  namespace: erp-pdn
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:17.7   # pin explicito: hace falta al restaurar
  storage:
    size: 20Gi
  plugins:
    - name: barman-cloud.cloudnative-pg.io
      enabled: true
      isWALArchiver: true
      parameters:
        barmanObjectName: erp-pdn-store
        serverName: erp-db-pdn
  postgresql:
    parameters:
      archive_timeout: "300s"
      wal_compression: "lz4"
      max_wal_size: "2GB"
      min_wal_size: "256MB"
      wal_keep_size: "1GB"
```

---

## 1.c ScheduledBackup diario — `erp-pdn`

**Archivo:** `k8s/backup/pdn/03-scheduledbackup.yaml`

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: erp-db-diario
  namespace: erp-pdn
spec:
  cluster:
    name: erp-db                 # INMUTABLE: para apuntar a otro cluster hay que recrear el recurso
  # CRON DE 6 CAMPOS (robfig/cron): segundos minutos horas dia-mes mes dia-semana
  # "0 30 6 * * *" = 06:30:00 UTC = 01:30 COT (Colombia es UTC-5 fijo, sin DST)
  schedule: "0 30 6 * * *"
  method: plugin                 # OBLIGATORIO: el default es barmanObjectStore (ruta in-tree deprecada)
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
  backupOwnerReference: cluster  # el default es "none"; "cluster" preserva el historico de auditoria
  target: primary
  immediate: true                # dispara uno al crear: valida la config sin esperar a mañana
  suspend: false
```

**Justificación de la hora (06:30 UTC / 01:30 COT):** las cooperativas operan 07:00–18:00 COT; el cierre nocturno de procesos batch termina antes de medianoche; la ventana de mantenimiento declarada es domingo 03:00–05:00 COT. 01:30 COT no colisiona con ninguna de las tres y deja 5.5 h de margen antes de la jornada para que un backup lento o un reintento terminen sin competir por I/O. Un fallo a las 01:30 se detecta a las 03:30 (alerta `CNPGUltimoBackupFallido`) con la jornada aún sin empezar.

> Trampa: `schedule: "30 6 * * *"` (5 campos, estilo crontab de Kubernetes) es sintácticamente aceptado y se interpreta corrido — el backup corre a una hora que no es la que crees. **Siempre 6 campos.**

---

## 1.d Equivalentes para `erp-dev` y `erp-qa`

**Archivo único:** `k8s/backup/nonprod/backup-nonprod.yaml` (aplicar en el clúster no productivo)

```yaml
# ─────────────────────────────── DEV ───────────────────────────────
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: erp-dev-store
  namespace: erp-dev
  labels: { ambiente: dev }
spec:
  retentionPolicy: "7d"
  configuration:
    destinationPath: "s3://ingenia365-erp-backups/erp/dev"
    s3Credentials:
      accessKeyId:     { name: s3-backup-creds, key: ACCESS_KEY_ID }
      secretAccessKey: { name: s3-backup-creds, key: ACCESS_SECRET_KEY }
      region:          { name: s3-backup-creds, key: AWS_REGION }
    wal:
      compression: zstd
      maxParallel: 4
    data:
      compression: gzip
      jobs: 1
    tags: { env: "dev", sistema: "ingenia365erp" }
  instanceSidecarConfiguration:
    logLevel: debug          # el piloto arranca aqui: queremos ver todo
---
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: erp-db-diario
  namespace: erp-dev
spec:
  cluster: { name: erp-db }
  schedule: "0 30 7 * * *"        # 07:30 UTC = 02:30 COT (escalonado respecto a QA)
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
  backupOwnerReference: self
  target: primary
  immediate: true
  suspend: false
---
# ─────────────────────────────── QA ────────────────────────────────
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: erp-qa-store
  namespace: erp-qa
  labels: { ambiente: qa }
spec:
  retentionPolicy: "14d"
  configuration:
    destinationPath: "s3://ingenia365-erp-backups/erp/qa"
    s3Credentials:
      accessKeyId:     { name: s3-backup-creds, key: ACCESS_KEY_ID }
      secretAccessKey: { name: s3-backup-creds, key: ACCESS_SECRET_KEY }
      region:          { name: s3-backup-creds, key: AWS_REGION }
    wal:
      compression: zstd
      maxParallel: 4
    data:
      compression: gzip
      jobs: 1
    tags: { env: "qa", sistema: "ingenia365erp" }
  instanceSidecarConfiguration:
    logLevel: info
---
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: erp-db-diario
  namespace: erp-qa
spec:
  cluster: { name: erp-db }
  schedule: "0 0 7 * * *"         # 07:00 UTC = 02:00 COT
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
  backupOwnerReference: self
  target: primary
  immediate: true
  suspend: false
```

**Patches de Cluster para no-prod** (`k8s/backup/nonprod/cluster-patch-dev.yaml` y `-qa.yaml`):

```yaml
# DEV
spec:
  plugins:
    - name: barman-cloud.cloudnative-pg.io
      enabled: true
      isWALArchiver: true
      parameters:
        barmanObjectName: erp-dev-store
        serverName: erp-db-dev
  postgresql:
    parameters:
      archive_timeout: "300s"   # durante el piloto; subir a 1800s cuando este validado
      wal_compression: "lz4"
```

```yaml
# QA
spec:
  plugins:
    - name: barman-cloud.cloudnative-pg.io
      enabled: true
      isWALArchiver: true
      parameters:
        barmanObjectName: erp-qa-store
        serverName: erp-db-qa
  postgresql:
    parameters:
      archive_timeout: "900s"
      wal_compression: "lz4"
```

**Justificación de la retención menor en no-prod:**
- **No hay obligación regulatoria** sobre datos no productivos: SARLAFT y la Supersolidaria aplican sobre información de asociados reales.
- **El valor de un backup de DEV es "volver a la sesión de trabajo de ayer"**, no reconstruir un ciclo contable. 7 días cubren un sprint corto.
- **QA con 14 días** cubre un ciclo completo de regresión: si una tanda de pruebas de la semana pasada corrompió los datos semilla, se puede volver atrás.
- **Costo:** los PVC son de 10 Gi; 7 y 14 días retenidos son ~$0.60/mes combinados frente a ~$2.30 de PDN. Igualarlos a 35 días triplicaría ese renglón sin comprar nada.
- **`archive_timeout` más laxo en QA (900s)** reduce a un tercio los objetos por hora ociosa; el RPO de 15 min es irrelevante en un ambiente que se puede resembrar.
- **DEV arranca en 300s deliberadamente:** el piloto se hace aquí, y con `archive_timeout` alto habría que esperar media hora a que aparezca el primer WAL para saber si la configuración es correcta. Subir a `1800s` después de validar.

---

## 1.e PrometheusRule

**Archivo:** `k8s/backup/pdn/04-prometheusrule.yaml`

⚠️ **Antes de nada:** con el plugin, las métricas in-core `cnpg_collector_last_available_backup_timestamp`, `cnpg_collector_last_failed_backup_timestamp` y `cnpg_collector_first_recoverability_point` quedan **en 0 permanentemente** (deprecadas desde CNPG 1.26, solo funcionan con backup in-tree o volume snapshots). Cualquier dashboard copiado de internet basado en ellas reportará "sin backups" para siempre. Las métricas correctas llevan el prefijo `barman_cloud_cloudnative_pg_io_` y las expone el mismo exportador del instance manager en el puerto 9187 — **los PodMonitor que ya tienes las recogen sin cambios**.

Idéntico aviso para `.status.firstRecoverabilityPoint` del Cluster: lleva `Deprecated: the field is not set for backup plugins`. La fuente de verdad es `.status.serverRecoveryWindow` del ObjectStore.

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: erp-backups-pdn
  namespace: erp-pdn
  labels:
    release: kube-prometheus-stack   # AJUSTAR al ruleSelector de tu Prometheus
spec:
  groups:
    - name: erp.backup.postgres
      rules:

        - alert: CNPGBackupNoCompletado
          expr: |
            time() - max by (namespace) (
              barman_cloud_cloudnative_pg_io_last_available_backup_timestamp{namespace="erp-pdn"}
            ) > 26 * 3600
          for: 15m
          labels: { severity: critical, ambiente: pdn, componente: backup }
          annotations:
            summary: "Sin backup completo de {{ $labels.namespace }} en mas de 26 h"
            description: "Ultimo backup disponible hace {{ $value | humanizeDuration }}. Nodo unico: el backup es la unica red de seguridad."
            runbook_url: "docs/operaciones/runbook-backups.md#backup-no-completado"

        - alert: CNPGBackupNuncaEjecutado
          expr: |
            max by (namespace) (
              barman_cloud_cloudnative_pg_io_last_available_backup_timestamp{namespace="erp-pdn"}
            ) == 0
          for: 1h
          labels: { severity: critical, ambiente: pdn, componente: backup }
          annotations:
            summary: "El cluster de {{ $labels.namespace }} nunca completo un backup"
            description: "Revisar ObjectStore erp-pdn-store, Secret s3-backup-creds y politica IAM."

        - alert: CNPGUltimoBackupFallido
          expr: |
            max by (namespace) (barman_cloud_cloudnative_pg_io_last_failed_backup_timestamp{namespace="erp-pdn"})
            >
            max by (namespace) (barman_cloud_cloudnative_pg_io_last_available_backup_timestamp{namespace="erp-pdn"})
          for: 10m
          labels: { severity: warning, ambiente: pdn, componente: backup }
          annotations:
            summary: "El ultimo intento de backup de {{ $labels.namespace }} fallo"
            description: "Revisar logs del sidecar plugin-barman-cloud. Si escala a 26 h se dispara CNPGBackupNoCompletado."

        # La ventana se ENCOGIO: first_recoverability_point demasiado reciente = perdimos historia.
        # Silenciar los primeros 10 dias de vida del cluster.
        - alert: CNPGVentanaRecuperacionDegradada
          expr: |
            max by (namespace) (barman_cloud_cloudnative_pg_io_first_recoverability_point{namespace="erp-pdn"}) > 0
            and
            (time() - max by (namespace) (barman_cloud_cloudnative_pg_io_first_recoverability_point{namespace="erp-pdn"})) < 7 * 86400
          for: 6h
          labels: { severity: critical, ambiente: pdn, componente: backup }
          annotations:
            summary: "La ventana de recuperacion de {{ $labels.namespace }} bajo de 7 dias"
            description: "Se esperan ~35 d y hay {{ $value | humanizeDuration }}. Causa probable: lifecycle de S3 borrando objetos que Barman cree vigentes, o retentionPolicy mal configurada."

        # La retencion NO poda: fuga de costos y sintoma de permisos S3 incompletos.
        - alert: CNPGRetencionNoPoda
          expr: |
            (time() - max by (namespace) (barman_cloud_cloudnative_pg_io_first_recoverability_point{namespace="erp-pdn"}))
            > 40 * 86400
          for: 12h
          labels: { severity: warning, ambiente: pdn, componente: backup }
          annotations:
            summary: "La retencion de 35 d no esta eliminando backups obsoletos"
            description: "Ventana real {{ $value | humanizeDuration }}. Verificar s3:DeleteObject del usuario IAM y que la bucket policy no lo deniegue."

    - name: erp.backup.wal
      rules:

        - alert: CNPGWalArchivingFallando
          expr: |
            (cnpg_pg_stat_archiver_last_failed_time{namespace="erp-pdn"}
             - cnpg_pg_stat_archiver_last_archived_time{namespace="erp-pdn"}) > 1
          for: 5m
          labels: { severity: critical, ambiente: pdn, componente: wal }
          annotations:
            summary: "Falla el archivado de WAL en {{ $labels.pod }}"
            description: "RPO comprometido AHORA. Si no se resuelve, pg_wal llena el PVC de 20 Gi y Postgres entra en PANIC."

        - alert: CNPGWalSinArchivar
          expr: cnpg_pg_stat_archiver_seconds_since_last_archival{namespace="erp-pdn"} > 900
          for: 5m
          labels: { severity: critical, ambiente: pdn, componente: wal }
          annotations:
            summary: "Sin WAL archivado hace {{ $value | humanizeDuration }} en {{ $labels.pod }}"
            description: "Con archive_timeout=300s deberia archivarse al menos cada 5 min."

        - alert: CNPGColaWalCreciendo
          expr: cnpg_collector_pg_wal_archive_status{namespace="erp-pdn", value="ready"} > 30
          for: 10m
          labels: { severity: warning, ambiente: pdn, componente: wal }
          annotations:
            summary: "{{ $value }} segmentos WAL esperando archivado en {{ $labels.pod }}"
            description: "30 segmentos = 480 MiB sin subir. Revisar latencia a S3 o subir wal.maxParallel."

        - alert: CNPGColaWalCritica
          expr: cnpg_collector_pg_wal_archive_status{namespace="erp-pdn", value="ready"} > 120
          for: 5m
          labels: { severity: critical, ambiente: pdn, componente: wal }
          annotations:
            summary: "{{ $value }} segmentos WAL en cola: riesgo de llenar el PVC"
            description: "120 x 16 MiB ~ 1.9 GiB (10% del PVC). Actuar antes del PANIC de Postgres."

    - name: erp.backup.espacio
      rules:

        - alert: CNPGPVCEspacioBajo
          expr: |
            kubelet_volume_stats_available_bytes{namespace="erp-pdn", persistentvolumeclaim=~"erp-db.*"}
            / kubelet_volume_stats_capacity_bytes{namespace="erp-pdn", persistentvolumeclaim=~"erp-db.*"}
            < 0.25
          for: 15m
          labels: { severity: warning, ambiente: pdn, componente: almacenamiento }
          annotations:
            summary: "PVC {{ $labels.persistentvolumeclaim }} con {{ $value | humanizePercentage }} libre"

        - alert: CNPGPVCEspacioCritico
          expr: |
            kubelet_volume_stats_available_bytes{namespace="erp-pdn", persistentvolumeclaim=~"erp-db.*"}
            / kubelet_volume_stats_capacity_bytes{namespace="erp-pdn", persistentvolumeclaim=~"erp-db.*"}
            < 0.12
          for: 5m
          labels: { severity: critical, ambiente: pdn, componente: almacenamiento }
          annotations:
            summary: "PVC {{ $labels.persistentvolumeclaim }} por debajo del 12% libre"
            description: "Postgres se detiene al llenarse el volumen. Ampliar PVC o purgar pg_wal atascado."

    - name: erp.backup.observabilidad
      rules:

        - alert: CNPGMetricasBackupAusentes
          expr: absent(barman_cloud_cloudnative_pg_io_last_available_backup_timestamp{namespace="erp-pdn"})
          for: 30m
          labels: { severity: critical, ambiente: pdn, componente: observabilidad }
          annotations:
            summary: "No llegan metricas de backup de erp-pdn"
            description: "O el PodMonitor dejo de raspar, o el plugin no esta cargado. Estamos ciegos sobre el respaldo."

        - alert: CNPGExporterCaido
          expr: cnpg_collector_up{namespace="erp-pdn"} == 0
          for: 5m
          labels: { severity: warning, ambiente: pdn, componente: observabilidad }
          annotations:
            summary: "El colector de metricas de {{ $labels.pod }} no responde"

        # La unica alerta que prueba que el backup SIRVE. Metrica publicada por el
        # job mensual de la seccion 4 via Pushgateway.
        - alert: RestauracionNoVerificada
          expr: |
            absent(erp_restore_verification_success_timestamp{ambiente="pdn"})
            or
            time() - max(erp_restore_verification_success_timestamp{ambiente="pdn"}) > 40 * 86400
          for: 1h
          labels: { severity: critical, ambiente: pdn, componente: backup }
          annotations:
            summary: "Hace mas de 40 dias que no se verifica una restauracion real"
            description: "Un backup que nunca se restauro es una hipotesis, no un respaldo."
```

**Variante no-prod** (`k8s/backup/nonprod/prometheusrule-nonprod.yaml`) — mismo esqueleto reemplazando `namespace="erp-pdn"` por `namespace=~"erp-dev|erp-qa"`, umbral de backup a `50*3600`, todas las severidades a `warning`, y sin `RestauracionNoVerificada`.

---

# 2. SECUENCIA DE APLICACIÓN

Cada paso incluye cómo verificar. **No avanzar sin la salida esperada.** El orden es: primero DEV (donde el downtime es gratis), luego QA, luego PDN.

### Paso 0 — Preflight

```powershell
kubectl get pods -n cnpg-system                                    # operator y plugin Running
kubectl get crd objectstores.barmancloud.cnpg.io                   # debe existir
kubectl get cluster erp-db -n erp-dev -o jsonpath='{.spec.backup}' # vacio (no puede coexistir con el plugin)
kubectl exec -n erp-dev erp-db-1 -c postgres -- df -h /var/lib/postgresql/data
```
✅ Esperado: pods `Running`; CRD listado; `.spec.backup` vacío o sin `barmanObjectStore`; ≥ 40 % libre en el PVC.

### Paso 1 — Bucket y IAM listos (§5)

```powershell
aws s3 ls s3://ingenia365-erp-backups/
aws s3api get-bucket-versioning --bucket ingenia365-erp-backups
```
✅ Esperado: el bucket lista sin error; `"Status": "Enabled"`.

Prueba de escritura **con las mismas credenciales que irán al Secret** (esto separa "credencial mala" de "YAML malo" antes de que sea un misterio dentro de un pod):
```powershell
"probe" | Out-File -Encoding ascii probe.txt
aws s3 cp probe.txt s3://ingenia365-erp-backups/erp/dev/probe.txt --sse AES256
aws s3 rm s3://ingenia365-erp-backups/erp/dev/probe.txt
```
✅ Esperado: `upload:` y `delete:` sin `AccessDenied`.

### Paso 2 — Secret con la región

Comando y verificación en §1.0. ✅ Tres claves listadas.

### Paso 3 — ObjectStore (no impacta al cluster todavía)

```powershell
kubectl apply -f k8s/backup/nonprod/backup-nonprod.yaml   # solo la parte de ObjectStore si prefieres separar
kubectl get objectstore -n erp-dev
kubectl describe objectstore erp-dev-store -n erp-dev
```
✅ Esperado: el recurso se crea sin error de validación del API server.
❌ Si aparece `spec.configuration.s3Credentials.region: Invalid value: "string"` → escribiste la región como literal en vez de secretKeyRef.

### Paso 4 — Conectar el Cluster al plugin ⚠️ **DOWNTIME**

```powershell
kubectl patch cluster erp-db -n erp-dev --type=merge --patch-file k8s/backup/nonprod/cluster-patch-dev.yaml
kubectl get pods -n erp-dev -w
```
✅ Esperado: el pod `erp-db-1` se recrea y arranca con **2 contenedores adicionales** visibles:
```powershell
kubectl get pod erp-db-1 -n erp-dev -o jsonpath='{.spec.containers[*].name}'
# postgres plugin-barman-cloud
```

Plugin registrado:
```powershell
kubectl cnpg status erp-db -n erp-dev | Select-String -Pattern "Plugins|barman"
```
✅ Esperado:
```
Name                            Version  Status  Reported Operator Capabilities
barman-cloud.cloudnative-pg.io  0.14.0   N/A     Reconciler Hooks, Lifecycle Service
```
❌ `requested plugin is not available: barman-cloud.cloudnative-pg.io` → el plugin no está en `cnpg-system` o los listening namespaces del operator no cubren `erp-dev`.

### Paso 5 — Verificar el archivado continuo de WAL

```powershell
kubectl get cluster erp-db -n erp-dev -o jsonpath='{range .status.conditions[?(@.type=="ContinuousArchiving")]}{.status}{"`t"}{.reason}{"`t"}{.message}{"`n"}{end}'
```
✅ Esperado: `True   ContinuousArchivingSuccess   Continuous archiving is working`
❌ `False  ContinuousArchivingFailing  <mensaje>` → el mensaje es el error literal de `barman-cloud-wal-archive`. Ver §7 de errores.

Forzar un WAL y comprobar que llega a S3:
```powershell
kubectl exec -n erp-dev erp-db-1 -c postgres -- psql -U postgres -c "SELECT pg_switch_wal();"
Start-Sleep 45
aws s3 ls s3://ingenia365-erp-backups/erp/dev/erp-db-dev/wals/ --recursive | Select-Object -Last 5

kubectl exec -n erp-dev erp-db-1 -c postgres -- psql -U postgres -c `
  "SELECT archived_count, failed_count, last_archived_wal, last_archived_time, last_failed_wal FROM pg_stat_archiver;"
```
✅ Esperado: objetos bajo `erp/dev/erp-db-dev/wals/…`; `failed_count = 0`; `last_failed_wal` vacío.
✅ **Comprobar que la ruta contiene `erp-db-dev`, no `erp-db`** — si dice `erp-db`, el `serverName` no se aplicó y estás a un paso de la colisión entre ambientes.

### Paso 6 — ScheduledBackup (con `immediate: true`)

```powershell
kubectl apply -f k8s/backup/nonprod/backup-nonprod.yaml
kubectl get backups.postgresql.cnpg.io -n erp-dev -o custom-columns='NAME:.metadata.name,ID:.status.backupId,PHASE:.status.phase,STOP:.status.stoppedAt,ERR:.status.error' -w
```
✅ Esperado: `PHASE: completed`, `ID` con formato `20260810T063001`, `ERR` vacío.
❌ `PHASE: failed` → `kubectl logs -n erp-dev erp-db-1 -c plugin-barman-cloud --tail=200`.

### Paso 7 — Confirmar el catálogo (fuente de verdad)

```powershell
kubectl get objectstore erp-dev-store -n erp-dev -o jsonpath='{.status.serverRecoveryWindow}'
```
✅ Esperado, mapa poblado: `{"erp-db-dev":{"firstRecoverabilityPoint":"2026-08-10T06:30:11Z","lastSuccessfulBackupTime":"2026-08-10T06:31:44Z"}}`
❌ Vacío → el backup no completó, o estás mirando el `serverName` equivocado.

```powershell
kubectl cnpg status erp-db -n erp-dev --verbose
```
✅ Sección **Continuous Backup status (Barman Cloud Plugin)** con `Working WAL archiving: OK`, `WALs waiting to be archived: 0`, `Last Failed WAL: -`.

### Paso 8 — Métricas y alertas

```powershell
kubectl exec -n erp-dev erp-db-1 -c postgres -- curl -s localhost:9187/metrics | Select-String "barman_cloud"
```
✅ Esperado: las tres métricas `barman_cloud_cloudnative_pg_io_{last_available_backup_timestamp,last_failed_backup_timestamp,first_recoverability_point}` con valores distintos de 0 (salvo `last_failed`).

```powershell
kubectl apply -f k8s/backup/pdn/04-prometheusrule.yaml
kubectl apply -f k8s/backup/nonprod/prometheusrule-nonprod.yaml
```
Verificar en Prometheus → Status → Rules que el grupo `erp.backup.*` aparece **sin errores de evaluación** y sin series vacías.

### Paso 9 — Descartar la regresión de barman-cli-cloud 3.19.x

```powershell
kubectl exec -n erp-dev erp-db-1 -c plugin-barman-cloud -- barman-cloud-backup --version
```
Si devuelve **3.19.0 o 3.19.1**, no habilites Object Lock en PDN todavía: esas versiones escriben `backup.info` dos veces y contra destinos con retención la segunda escritura puede ser rechazada — los tarballs suben pero el catálogo nunca marca `DONE` y **todos** los backups reportan `FAILED`. Piloto obligatorio en `erp-dev` contra un prefijo con Object Lock `retain-until` de 1 día, y 3 días seguidos de `last_available_backup_timestamp` avanzando antes de tocar PDN. 3.18.0 no está afectada.

### Paso 10 — Ensayo de restauración en DEV antes de declarar operativo

Ejecutar §4 completo. **No declarar el backup operativo sin un RTO medido.**

### Paso 11 — Replicar a QA, luego a PDN

Mismo orden 2→8. En PDN, **agendar ventana**: el paso 4 corta el servicio ~2–4 min.

### Paso 12 — Cerrar documentación

Actualizar `docs/operaciones/slo.md` con RPO/RTO (tabla §6) y cerrar M5 en `docs/operaciones/despliegue-infraestructura.md`, que hoy dice **Backblaze B2** y debe decir AWS S3 (§5.5).

---

# 3. RUNBOOK DE RESTAURACIÓN (condensado)

> **Reglas de hierro:** (1) la recuperación en CNPG **nunca es in-place**, siempre bootstrapea un Cluster nuevo; (2) `serverName` en `externalClusters` es **obligatorio de facto** — si se omite cae al nombre del cluster *nuevo* y falla con `no target backup found`; (3) `.spec.bootstrap.recovery.backup.name` **no funciona** con el plugin; (4) el `ObjectStore` es namespaced y **no puede ser cross-namespace**: hay que crear Secret + ObjectStore en el namespace destino.

### A. Restauración completa de producción al último WAL disponible

**1) Namespace, Secret y ObjectStore de origen (solo lectura)**

```powershell
kubectl create namespace erp-restore
kubectl create secret generic s3-backup-creds -n erp-restore `
  --from-literal=ACCESS_KEY_ID=$env:RESTORE_KEY `
  --from-literal=ACCESS_SECRET_KEY=$env:RESTORE_SECRET `
  --from-literal=AWS_REGION=us-east-1
```

```yaml
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: erp-pdn-source
  namespace: erp-restore
spec:
  # SIN retentionPolicy: este ObjectStore es de lectura, no debe podar nada.
  configuration:
    destinationPath: "s3://ingenia365-erp-backups/erp/pdn"
    s3Credentials:
      accessKeyId:     { name: s3-backup-creds, key: ACCESS_KEY_ID }
      secretAccessKey: { name: s3-backup-creds, key: ACCESS_SECRET_KEY }
      region:          { name: s3-backup-creds, key: AWS_REGION }
    wal:
      compression: zstd
      maxParallel: 8      # acelera MUCHO el replay: descarga WALs en paralelo
    data:
      compression: gzip
      jobs: 2
```

**2) Reponer los Secrets — el backup NO los contiene**

`barman-cloud` respalda PGDATA + WAL. Las contraseñas de superusuario y de la app viven en Secrets de Kubernetes que mueren con el nodo. Recuperarlos de SealedSecrets/SOPS en Git:

```powershell
kubectl apply -f secrets/erp-db-superuser.sealed.yaml -n erp-restore
kubectl apply -f secrets/erp-db-app-user.sealed.yaml  -n erp-restore
```

**3) Cluster de recuperación**

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: erp-db-restore
  namespace: erp-restore
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:17.7   # PIN OBLIGATORIO: no se restaura PG17 en PG18
  imagePullPolicy: IfNotPresent
  storage:
    size: 20Gi                                        # >= al PVC del origen
  enableSuperuserAccess: true
  superuserSecret: { name: erp-db-superuser }
  postgresql:
    parameters:                                       # replicar los del origen; ajustar DESPUES
      max_connections: "200"
      shared_buffers: "512MB"
  bootstrap:
    recovery:
      source: origin
      database: ingenia365erp                         # tus BDs no se llaman 'app': declararlas
      owner: ingenia365erp_app
      secret: { name: erp-db-app-user }
      # sin recoveryTarget => hasta el ultimo WAL disponible, timeline 'latest'
  externalClusters:
    - name: origin
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: erp-pdn-source
          serverName: erp-db-pdn      # NOMBRE DEL SERVIDOR ORIGEN. Sin esto: "no target backup found"
  # DELIBERADAMENTE SIN .spec.plugins: el cluster restaurado NO archiva WAL.
```

```powershell
kubectl apply -f erp-db-restore.yaml
kubectl get cluster erp-db-restore -n erp-restore -w
kubectl logs -n erp-restore job/erp-db-restore-1-full-recovery -c plugin-barman-cloud -f
kubectl logs -n erp-restore erp-db-restore-1 -c postgres -f | Select-String "recovery|redo|consistent|promot|FATAL"
kubectl cnpg psql -n erp-restore erp-db-restore -- -c "SELECT pg_is_in_recovery();"   # debe dar 'f'
```

**4) Promover a productivo (solo cuando esté validado)**

Al reactivar el archivado hay que **versionar el `serverName`**, o el cluster queda clavado en `Setting up primary` con `ERROR: WAL archive check failed... Expected empty archive`:

```yaml
spec:
  plugins:
    - name: barman-cloud.cloudnative-pg.io
      isWALArchiver: true
      parameters:
        barmanObjectName: erp-pdn-store   # ObjectStore read-write
        serverName: erp-db-pdn-v2         # VERSIONAR. Nunca reusar el del origen.
```

> **No** uses `cnpg.io/skipEmptyWalArchiveCheck: enabled`. La doc lo llama "strongly discouraged": mezcla timelines en el mismo archivo y puede causar pérdida de datos severa.

**Reapuntar la app:** el nombre del Cluster determina los Services (`erp-db-restore-rw`, `-ro`, `-r`). Los connection strings apuntan a `erp-db-rw.erp-pdn.svc`. Opciones: cambiar el connection string, o crear un Service `ExternalName` que mantenga el nombre viejo apuntando al nuevo.

### B. PITR a un momento exacto

Mismos Secret y ObjectStore de origen. Solo cambia `bootstrap.recovery`:

```yaml
  bootstrap:
    recovery:
      source: origin
      recoveryTarget:
        # Justo ANTES del DELETE/UPDATE sin WHERE.
        # Colombia es UTC-05:00 fijo. SIEMPRE con offset explicito.
        targetTime: "2026-08-09T14:29:55-05:00"
        exclusive: true          # parar ANTES del target (por defecto es inclusive)
        # targetTLI: "latest"
```

☠️ **`targetTime: "2026-08-09 14:29:55"` sin zona se lee como UTC** y te desplaza 5 horas en silencio. Formas válidas y equivalentes: `...T14:29:55-05:00` · `...T19:29:55Z` · `2026-08-09 14:29:55.00000-05`.

⚠️ PostgreSQL detiene el replay en la **primera transacción posterior** al target. Si no existe ninguna (ERP dormido de madrugada), **la recuperación falla**. Elige un target dentro de la ventana de actividad o usa `targetLSN`.

**Los cinco targets** (solo uno por `recoveryTarget`):

| Campo | Formato | ¿`backupID` obligatorio? | Uso |
|---|---|---|---|
| `targetTime` | RFC 3339 con TZ | No — el operador busca el backup anterior más cercano | El 95 % de los casos |
| `targetLSN` | `"0/2A000000"` | No | Preciso, sin ambigüedad de reloj |
| `targetXID` | `"1234567"` | **Sí** | Deshacer una transacción concreta |
| `targetName` | `"pre-migracion-004"` | **Sí** | Restore points creados a mano |
| `targetImmediate` | `true` | **Sí** | Estado consistente más temprano |

**Patrón recomendado antes de cada operación de riesgo** (migración EF Core, cierre contable, despliegue de esquema multi-tenant):

```powershell
kubectl cnpg psql -n erp-pdn erp-db -- -c "SELECT pg_create_restore_point('pre-migracion-004');"
kubectl cnpg backup -n erp-pdn erp-db --method=plugin --plugin-name=barman-cloud.cloudnative-pg.io
kubectl get backups.postgresql.cnpg.io -n erp-pdn -o jsonpath='{.items[-1:].status.backupId}'
```
Restauración con `backupID: "20260809T142236"` + `targetName: "pre-migracion-004"` + `exclusive: true`.

### C. Backup on-demand

```powershell
kubectl cnpg backup -n erp-pdn erp-db --method=plugin --plugin-name=barman-cloud.cloudnative-pg.io
```
`--method=barmanObjectStore` **deja de funcionar** tras migrar al plugin (issue #353).

### D. Si el nodo murió y no queda ningún CR: leer el catálogo directo de S3

```yaml
apiVersion: v1
kind: Pod
metadata: { name: barman-inspect, namespace: erp-restore }
spec:
  restartPolicy: Never
  containers:
    - name: barman
      image: ghcr.io/cloudnative-pg/plugin-barman-cloud-sidecar:0.14.0
      command: ["sleep", "3600"]
      env:
        - name: AWS_ACCESS_KEY_ID
          valueFrom: { secretKeyRef: { name: s3-backup-creds, key: ACCESS_KEY_ID } }
        - name: AWS_SECRET_ACCESS_KEY
          valueFrom: { secretKeyRef: { name: s3-backup-creds, key: ACCESS_SECRET_KEY } }
        - name: AWS_DEFAULT_REGION
          value: "us-east-1"
```

```powershell
kubectl exec -n erp-restore barman-inspect -- barman-cloud-backup-list s3://ingenia365-erp-backups/erp/pdn erp-db-pdn
kubectl exec -n erp-restore barman-inspect -- barman-cloud-backup-show --format=json s3://ingenia365-erp-backups/erp/pdn erp-db-pdn 20260809T142236
kubectl exec -n erp-restore barman-inspect -- barman-cloud-check-wal-archive s3://ingenia365-erp-backups/erp/pdn erp-db-pdn
```

### E. Errores frecuentes

| Mensaje | Causa | Corrección |
|---|---|---|
| `no target backup found` | `serverName` ausente en `externalClusters` | Poner el `serverName` del origen |
| `WAL archive check failed...: Expected empty archive` | El restaurado archiva al mismo destino+serverName del origen | `serverName` versionado (`-v2`) |
| `panic caught: assignment to entry in nil map` | ObjectStore mal configurado: Secret o `key` inexistente | `kubectl get secret s3-backup-creds -n <ns> -o jsonpath='{.data}'` y comparar claves |
| `AccessDenied` / `403` | IAM sin `PutObject`/`ListBucket` sobre el prefijo | Probar con `aws s3 cp` desde fuera |
| `NoSuchBucket` | `destinationPath` o `endpointURL` mal | Para AWS nativo, **omitir** `endpointURL` |
| `x-amz-content-sha256` | boto3 vs S3-compatible (issue #393) | `instanceSidecarConfiguration.env` con `AWS_*_CHECKSUM_*=when_required`. **Te golpeará con MinIO, no con AWS** |
| Replay atascado tras failover | WAL de redo cruza frontera de timeline (#10422) | Elegir un `backupID` posterior al failover |

Logs en orden: `job/<cluster>-1-full-recovery -c plugin-barman-cloud` → `<pod> -c postgres` → `deployment/barman-cloud` en `cnpg-system` → `kubectl get events --sort-by='.lastTimestamp'`.

---

# 4. PROCEDIMIENTO DE PRUEBA DE RESTAURACIÓN (mensual)

**Premisa:** "el backup existe" y "el backup restaura" son afirmaciones distintas. El pre-chequeo `ensureArchiveContainsLastCheckpointRedoWAL` del plugin — el que detecta un backup base sin su WAL de redo — **solo se ejecuta al restaurar**. Sin ensayo mensual, ese defecto permanece invisible hasta el desastre.

### Reglas de aislamiento (obligatorias)

1. **Namespace efímero dedicado**, destruido al terminar.
2. **NUNCA `.spec.plugins`** en el cluster de ensayo. Sin `isWALArchiver` no hay escritura al bucket: es la garantía *técnica* de que el ensayo no puede corromper el archivo de PDN.
3. **Credenciales S3 de solo lectura** (usuario `erp-restore-reader`, §5.2). Cinturón y tirantes.
4. **Ejecutar en el servidor NO productivo.** Restaurar consume CPU, I/O y 20 Gi de disco; con nodo único, hacerlo sobre PDN es exactamente lo que no quieres.
5. ⚖️ **Habeas data (Ley 1581/2012):** restaurar PDN implica datos reales de asociados. **No dejar el cluster de ensayo accesible.** NetworkPolicy `deny-all` de egreso, sin Ingress, acceso registrado, destrucción al terminar. Si necesitas usar esos datos en QA de forma persistente, debe pasar por anonimización.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: deny-all, namespace: erp-restore-drill }
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
  egress:
    - to: [{ ipBlock: { cidr: 0.0.0.0/0, except: ["10.0.0.0/8","172.16.0.0/12","192.168.0.0/16"] } }]
      ports: [{ protocol: TCP, port: 443 }]     # solo S3
    - to: [{ namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: kube-system } } }]
      ports: [{ protocol: UDP, port: 53 }]
```

### Qué restaurar (rotar cada mes)

- [ ] El backup **más antiguo dentro de la ventana de retención**, no el de anoche. El de anoche casi siempre funciona; el borde de la ventana es donde se rompen las cosas (lifecycle de S3 comiéndose objetos que Barman cree vigentes).
- [ ] **Además, un PITR** a un `targetTime` intermedio (p. ej. hace 3 días, 15:00 −05:00). Ejercita el replay de WAL, no solo el restore del base.

### Script

```powershell
$NS  = "erp-restore-drill"
$CL  = "erp-db-drill-$(Get-Date -Format yyyyMMdd)"
$T0  = Get-Date

kubectl create namespace $NS
kubectl apply -f drill/networkpolicy-deny-all.yaml
kubectl create secret generic s3-backup-creds -n $NS `
  --from-literal=ACCESS_KEY_ID=$env:DRILL_KEY `
  --from-literal=ACCESS_SECRET_KEY=$env:DRILL_SECRET `
  --from-literal=AWS_REGION=us-east-1
kubectl apply -f drill/objectstore-readonly.yaml
kubectl apply -f drill/cluster-drill.yaml

kubectl wait --for=condition=Ready cluster/$CL -n $NS --timeout=90m
$RTO = (Get-Date) - $T0
Write-Host "RTO medido: $([math]::Round($RTO.TotalMinutes,1)) minutos"
```

### Checklist de validación (no basta con "el pod está Ready")

```powershell
kubectl cnpg status -n $NS $CL --verbose
kubectl cnpg psql -n $NS $CL -- -c "SELECT pg_is_in_recovery();"                     # 'f'
kubectl cnpg psql -n $NS $CL -- -c "SELECT timeline_id, redo_lsn FROM pg_control_checkpoint();"
kubectl cnpg psql -n $NS $CL -- -c "SELECT datname, pg_size_pretty(pg_database_size(datname)) FROM pg_database WHERE datname LIKE 'ingenia365%';"

# Multi-tenancy: los schemas por tenant sobrevivieron
kubectl cnpg psql -n $NS $CL -d ingenia365erp -- -c "SELECT count(*) FROM information_schema.schemata WHERE schema_name NOT IN ('pg_catalog','information_schema','public');"

# Cuadre contable: LA prueba que de verdad importa en un ERP financiero
kubectl cnpg psql -n $NS $CL -d ingenia365erp -- -c "SELECT sum(debito) - sum(credito) AS descuadre FROM tenant_001.movimientos_contables;"

# Identidad central
kubectl cnpg psql -n $NS $CL -d ingenia365erp_admin -- -c "SELECT count(*) FROM usuarios;"

# Corrupcion fisica de indices
kubectl cnpg psql -n $NS $CL -d ingenia365erp -- -c "CREATE EXTENSION IF NOT EXISTS amcheck;"
kubectl cnpg psql -n $NS $CL -d ingenia365erp -- -c "SELECT c.relname, bt_index_check(c.oid, true) FROM pg_class c JOIN pg_index i ON i.indexrelid = c.oid WHERE c.relam = (SELECT oid FROM pg_am WHERE amname='btree') AND c.relpersistence='p';"

# Barrido completo de heaps (detecta bloques corruptos)
kubectl cnpg psql -n $NS $CL -d ingenia365erp -- -c "DO `$`$DECLARE r record; n bigint; BEGIN FOR r IN SELECT schemaname, tablename FROM pg_tables WHERE schemaname NOT LIKE 'pg\_%' LOOP EXECUTE format('SELECT count(*) FROM %I.%I', r.schemaname, r.tablename) INTO n; END LOOP; END`$`$;"
```

| ✔ | Criterio de aceptación |
|---|---|
| ☐ | `pg_is_in_recovery()` = `f` |
| ☐ | `ingenia365erp` y `ingenia365erp_admin` presentes, tamaño ±5 % del origen |
| ☐ | Conteo de schemas de tenant = conteo en producción |
| ☐ | `bt_index_check()` limpio sobre todos los índices btree persistentes |
| ☐ | Barrido de heaps sin error de bloque |
| ☐ | Descuadre contable = 0 |
| ☐ | `dotnet ef migrations list` contra el restaurado coincide con el historial esperado |
| ☐ | Smoke test de la API: login + un endpoint de reporte PDF |
| ☐ | **RTO medido y registrado** (`kubectl apply` → `condition=Ready`) |
| ☐ | RPO verificado: `SELECT max(fecha_creacion)` en el restaurado vs. el instante del backup |
| ☐ | El PITR a `ahora − 3 días` también funcionó |
| ☐ | Evidencia archivada: salida de comandos + fecha + operador (la Supersolidaria la pide) |

**Publicar la métrica y limpiar:**

```powershell
"erp_restore_verification_success_timestamp{ambiente=`"pdn`"} $([int][double]::Parse((Get-Date -UFormat %s)))" |
  curl.exe --data-binary '@-' http://pushgateway.monitoring:9091/metrics/job/erp_restore_drill
kubectl delete namespace $NS      # borra Cluster, PVCs, Secret y ObjectStore
```

### Nivel 4 — simulacro DR completo, trimestral

- [ ] Restaurar partiendo **solo** del bucket S3 + el repo Git. Sin acceso al nodo de producción.
- [ ] Verificar que los Secrets se pueden reconstruir desde SealedSecrets/SOPS — **este es el punto de fallo que más simulacros descubre**.
- [ ] Reapuntar un backend real al cluster restaurado y correr `docs/operaciones/manual-pruebas-funcional-remates-identidad.md` end-to-end.
- [ ] Cronometrar el RTO extremo a extremo **incluida la intervención humana**.
- [ ] Actualizar este runbook con lo aprendido.

**Antipatrón a evitar:** que el chequeo diario sea "existe un objeto nuevo en el bucket". Un archivo de 200 bytes corrupto también existe.

---

# 5. CONFIGURACIÓN EN AWS Y EN MONGODB

## 5.1 Bucket S3

> 🚨 **Object Lock solo puede habilitarse AL CREAR el bucket.** En buckets existentes requiere abrir caso con AWS Support. Créalo con Object Lock habilitado aunque configures el *default retention* después: habilitarlo no obliga a bloquear nada; **no habilitarlo es irreversible**.

```bash
aws s3api create-bucket --bucket ingenia365-erp-backups --region us-east-1 \
  --object-lock-enabled-for-bucket

aws s3api put-bucket-versioning --bucket ingenia365-erp-backups \
  --versioning-configuration Status=Enabled

aws s3api put-public-access-block --bucket ingenia365-erp-backups \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

aws s3api put-bucket-encryption --bucket ingenia365-erp-backups \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'
```

**Object Lock — `Governance`, 40 días** sobre este bucket (= ventana Barman de 35d + 5 de holgura):

```bash
aws s3api put-object-lock-configuration --bucket ingenia365-erp-backups \
  --object-lock-configuration \
  '{"ObjectLockEnabled":"Enabled","Rule":{"DefaultRetention":{"Mode":"GOVERNANCE","Days":40}}}'
```

**Governance y no Compliance en el bucket operativo:** protege contra el 99 % de los escenarios reales (ransomware con las credenciales del pod, `kubectl delete` equivocado, bug de retención de Barman) manteniendo una salida de emergencia si alguien configura mal la ventana. El rol break-glass con `s3:BypassGovernanceRetention` vive fuera del clúster, con MFA y alarma de CloudTrail en cada uso. Compliance es para el bucket de archivo (§5.3), donde la salida de emergencia *es* el riesgo.

⚠️ **Piloto obligatorio**: prueba Object Lock primero sobre el prefijo `erp/dev` con `retain-until` de **1 día** y confirma que los backups siguen marcando `completed` durante 3 días (regresión de barman 3.19.x, paso 9 de §2). Un error de escala en Compliance se paga completo durante 5 años.

**Lifecycle** — nótese lo que **no** está: ninguna `Expiration` sobre versiones actuales, ninguna `Transition` a IA/Glacier.

```json
{ "Rules": [
  { "ID": "abortar-multipart-huerfanos", "Status": "Enabled", "Filter": {},
    "AbortIncompleteMultipartUpload": { "DaysAfterInitiation": 7 } },
  { "ID": "expirar-versiones-no-actuales", "Status": "Enabled", "Filter": {},
    "NoncurrentVersionExpiration": { "NoncurrentDays": 1 } },
  { "ID": "limpiar-delete-markers", "Status": "Enabled", "Filter": {},
    "Expiration": { "ExpiredObjectDeleteMarker": true } },
  { "ID": "expirar-dumps-mongo-diarios", "Status": "Enabled",
    "Filter": { "Prefix": "mongo/diario/" },
    "Expiration": { "Days": 35 } }
] }
```

**El principio de diseño detrás de esto: una sola autoridad de borrado.**
> **Barman decide qué se borra. S3 Lifecycle solo limpia basura que Barman no puede ver. Object Lock solo pone un piso temporal.**

Son tres autoridades sobre los mismos objetos, y **S3 siempre gana en el borrado sin que Barman se entere**. Si una regla de lifecycle expira los tarballs pero deja `base/<id>/backup.info`, `barman-cloud-backup-list` sigue reportando el backup como `DONE` y **la falla se descubre durante la restauración, en plena crisis**. Si expira segmentos de WAL en medio de la ventana, se abre un hueco y el recovery se detiene ahí con `could not find WAL file` — fallo silencioso hasta el desastre.

`AbortIncompleteMultipartUpload` **no es opcional**: los multipart abortados por un pod que murió a mitad de subida son invisibles para Barman y se facturan indefinidamente. Y `NoncurrentVersionExpiration` es lo que impide que el versionado convierta la retención de Barman en un no-op de costos.

**El prefijo `wals/` jamás entra en una regla de transición.** Un WAL comprimido de 40 KB en Standard-IA/GIR **se factura como 128 KB** (mínimo facturable, 3.2× de sobrefacturación), y transicionar cuesta **$0.05 por 1.000 objetos** — con 8.640 objetos/mes se pagarían $0.43/mes en peticiones para ahorrar $0.007/mes de almacenamiento. Además, dentro de la ventana operativa de 35 días Glacier no tiene sentido en absoluto: el ahorro máximo teórico sobre 95 GB es ~$1.80/mes, y un PITR pasaría de minutos a **12 horas** de espera de restauración.

## 5.2 Bucket policy e IAM

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "DenegarTransporteNoCifrado", "Effect": "Deny", "Principal": "*", "Action": "s3:*",
      "Resource": ["arn:aws:s3:::ingenia365-erp-backups","arn:aws:s3:::ingenia365-erp-backups/*"],
      "Condition": { "Bool": { "aws:SecureTransport": "false" } } },
    { "Sid": "DenegarPutSinCifrado", "Effect": "Deny", "Principal": "*", "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::ingenia365-erp-backups/*",
      "Condition": { "StringNotEquals": { "s3:x-amz-server-side-encryption": ["AES256","aws:kms"] } } },
    { "Sid": "SoloBreakGlassDestruyeVersiones", "Effect": "Deny", "Principal": "*",
      "Action": ["s3:DeleteObjectVersion","s3:BypassGovernanceRetention","s3:PutBucketVersioning",
                 "s3:PutObjectLockConfiguration","s3:PutBucketPolicy","s3:PutLifecycleConfiguration","s3:DeleteBucket"],
      "Resource": ["arn:aws:s3:::ingenia365-erp-backups","arn:aws:s3:::ingenia365-erp-backups/*"],
      "Condition": { "ArnNotEquals": { "aws:PrincipalArn": "arn:aws:iam::<CUENTA>:role/erp-backup-break-glass" } } }
  ]
}
```

**Sobre "una política que impida el borrado":** el `Deny` cubre `DeleteObjectVersion` (destrucción real) pero **debe permitir `s3:DeleteObject`** — Barman lo necesita para que `retentionPolicy` funcione. En un bucket versionado ese `DeleteObject` solo crea un delete marker: **el dato no se destruye**. Esa asimetría es exactamente lo que hace funcionar el diseño. Un `Deny s3:Delete*` general rompería la retención y el bucket crecería sin límite.

**Cuatro identidades IAM, una por ambiente, jamás compartidas:**

| Principal | Permisos | Recurso |
|---|---|---|
| `erp-backup-writer-pdn` | `PutObject`, `GetObject`, `GetObjectVersion`, `ListBucket`, `AbortMultipartUpload`, `DeleteObject` | solo `…/erp/pdn/*` |
| `erp-backup-writer-dev` / `-qa` | idem | solo `…/erp/dev/*` / `…/erp/qa/*` |
| `erp-restore-reader` | `GetObject`, `GetObjectVersion`, `ListBucket`, `GetBucketLocation` | todo el bucket (para drills y DR) |
| `erp-backup-break-glass` | + `DeleteObjectVersion`, `BypassGovernanceRetention` | fuera del clúster, MFA obligatorio, alarma CloudTrail |

⚠️ El Secret se llama `s3-backup-creds` en los tres namespaces, pero **las credenciales dentro deben ser distintas**. Una credencial de DEV comprometida no debe poder ni *listar* el prefijo de PDN.

Política del reader para los drills:
```json
{ "Version":"2012-10-17","Statement":[{"Effect":"Allow",
  "Action":["s3:GetObject","s3:GetObjectVersion","s3:ListBucket","s3:GetBucketLocation"],
  "Resource":["arn:aws:s3:::ingenia365-erp-backups","arn:aws:s3:::ingenia365-erp-backups/*"]}]}
```

Activar **CloudTrail data events** sobre el bucket hacia un tercer bucket. Sin eso no hay forma de demostrar que la evidencia no fue manipulada. Alarmas sobre: uso del rol break-glass, `PutBucketPolicy`, `PutLifecycleConfiguration`, `PutObjectLockConfiguration`, `DeleteObjectVersion`.

## 5.3 Segundo bucket: archivo regulatorio (recomendado, aparte)

La tarea especifica un solo bucket, y para lo operativo con prefijos funciona. Pero **el *default retention* de Object Lock se configura por bucket, no por prefijo**: no puedes tener 40 días Governance para los backups operativos y 1830 días Compliance para la evidencia SARLAFT en el mismo bucket. Por eso:

```bash
aws s3api create-bucket --bucket ingenia365-erp-archive --region us-east-1 --object-lock-enabled-for-bucket
aws s3api put-bucket-versioning --bucket ingenia365-erp-archive --versioning-configuration Status=Enabled
aws s3api put-object-lock-configuration --bucket ingenia365-erp-archive \
  --object-lock-configuration '{"ObjectLockEnabled":"Enabled","Rule":{"DefaultRetention":{"Mode":"COMPLIANCE","Days":1830}}}'
```
Lifecycle: Standard → Glacier Instant Retrieval a 90 d → Deep Archive a 365 d. Cifrado **SSE-KMS con CMK** (aquí sí: ~60–120 objetos/año hacen que el costo por request sea cero, y cada acceso a la evidencia queda registrado en CloudTrail con el `keyId`; en el bucket operativo SSE-KMS costaría +$1.05/mes sobre un total de ~$3 sin comprar nada).

**Por qué la retención de 5 años NO va en backups físicos.** Cuatro razones, de más fuerte a menos:

1. **Un backup físico caduca tecnológicamente antes que legalmente.** Un basebackup de PG 17.7 solo lo lee un binario de PostgreSQL 17 con el mismo blocksize, arquitectura y versión de glibc/ICU. En 2031 correrás PG 22. Como evidencia ante un supervisor, es frágil hasta ser inútil.
2. **La cadena de WAL de 5 años no tiene consumidor.** Nadie hace PITR al minuto exacto del 14 de marzo de 2027 desde 2032. Y bastaría un segmento perdido en 1825 días para invalidar todo lo posterior.
3. **Costo lineal, beneficio cero:** 35 días ≈ 70 GB ≈ $1.60/mes; la misma política a 5 años ≈ 3.6 TB ≈ **$85/mes**, creciendo, para conservar 1.790 backups que jamás se restaurarán.
4. **El deber legal es sobre el contenido, no el medio.** El art. 28 de la Ley 962 de 2005 obliga a conservar libros y papeles 10 años y permite **cualquier medio que garantice reproducción exacta**. Un `pg_dump` con su diccionario de datos la garantiza; un PGDATA binario huérfano de su binario, no.

**Arquitectura de tres niveles:**
```
NIVEL 1  OPERATIVO      Postgres fisico + WAL     35 dias   Governance 40d   bucket -backups
NIVEL 2  LIBROS         pg_dump -Fc mensual       10 años   Compliance 3660d bucket -archive
NIVEL 3  SARLAFT        Mongo sellado mensual      5 años   Compliance 1830d bucket -archive
```

Nivel 2 — día 1 de cada mes, 09:00 UTC, tras el cierre. Y —la parte que casi todos omiten— **empaquetado con su contexto de interpretación**:
```
archivo/libros/2026/08/
├── erp_202608.dump  admin_202608.dump  globals_202608.sql
├── schema_202608.sql        # pg_dump --schema-only, legible en texto plano
├── diccionario-datos.md     # que significa cada tabla/columna
├── MANIFIESTO.json          # git SHA de la app, version PG, fecha, conteo de filas por tabla
└── SHA256SUMS               # + x-amz-checksum-sha256 nativo de S3
```
Sin el manifiesto y el diccionario, un dump de 2026 abierto en 2036 es un montón de tablas cuyo significado nadie recuerda: **no cumple "reproducción exacta"**. Volumen: ~2 GB × 12 × 10 años = 240 GB en Deep Archive ≈ **$0.24/mes**.

⚖️ Los plazos concretos (5 años SARLAFT, 10 años libros) deben confirmarse con la asesoría legal de la cooperativa contra la Circular Básica Jurídica vigente de la Supersolidaria y el art. 632 del Estatuto Tributario. La arquitectura no cambia si los números cambian; solo los `retain-until-date`.

**Costo total estimado:** PDN ~$2.30/mes + DEV/QA ~$0.60 + archivo ~$0.05 ≈ **$3/mes**. Modelo: `USD/mes ≈ (tamaño_BD ÷ 4.3 × (ventana_días + 1) + wal_GB_día ÷ 4 × ventana_días) × 1.17 × 0.023`. **No estimes el volumen de WAL: mídelo** con `rate(cnpg_collector_wal_bytes{namespace="erp-pdn"}[1d]) * 86400 / 1024^3` durante 7 días con carga representativa, y dimensiona con el **p95 diario**, no con el promedio (el cierre mensual genera picos de 3–5×).

## 5.4 MongoDB — auditoría SARLAFT

CNPG no cubre MongoDB, y hay un problema más profundo: **MongoDB no tiene WORM**. `AppendOnlyAuditWriter` impone append-only *a nivel de aplicación*; cualquiera con credenciales de admin ejecuta `db.auditLogs.deleteMany({})`. Para SARLAFT eso no es evidencia defendible. **La inmutabilidad regulatoria no la da MongoDB: la da S3 Object Lock en Compliance.**

**Paso 0 habilitante (~10 minutos, hacerlo YA, antes de que la base tenga volumen):** convertir el `mongod` a **replica set de un nodo** (`replication.replSetName: rs0` + `rs.initiate()`). No cambia topología ni consumo; el connection string solo gana `?replicaSet=rs0`. Desbloquea `mongodump --oplog` consistente, change streams, transacciones multi-documento y, cuando quieras, Percona Backup for MongoDB sin migración (**PBM no soporta standalone**: necesita oplog).

**Dos niveles, no uno.** El error a evitar es hacer un `mongodump` diario y bloquearlo 5 años: un evento de hoy aparecería en ~1.825 volcados, decenas de TB inmutables e incorregibles.

Nivel operativo — diario 07:15 UTC (después del backup de Postgres, para no competir por I/O):
```bash
# --oplog es INCOMPATIBLE con --db y --collection: exige un volcado de instancia
# completa. La instancia solo contiene las bases del ERP, así que no se pierde
# nada, y a cambio la copia queda consistente.
mongodump --uri "$MONGO_URI" --oplog --archive=/tmp/audit-$(date -u +%F).archive.gz --gzip
aws s3 cp /tmp/audit-$(date -u +%F).archive.gz \
  s3://ingenia365-erp-backups/mongo/diario/$(date -u +%Y/%m)/ --checksum-algorithm SHA256 --sse AES256
```

> 🔧 **Corrección aplicada (2026-08-11).** Este bloque especificaba
> `mongodump --db ... --oplog`, una combinación que MongoDB rechaza. Habría
> fallado en la primera ejecución. Se detectó al implementarlo, no al diseñarlo:
> **el diseño no es evidencia — solo la ejecución lo es.**
>
> Implementado en `infrastructure/pdn/backup-mongo.yaml` (producción) y
> `infrastructure/nonprod/backup-mongo.yaml` (banco de pruebas en DEV).
Hereda el Governance de 40 días del bucket; la regla `expirar-dumps-mongo-diarios` de §5.1 lo purga a los 35. Aquí sí es correcto usar `Expiration` de lifecycle: cada objeto es autocontenido, no hay catálogo tipo Barman que se pueda desincronizar.

Nivel regulatorio — día 2 de cada mes, 08:00 UTC, sella el mes anterior en **JSON + gzip** (no BSON: el archivo debe ser legible en 2031 sin herramientas de Mongo):
```bash
mongoexport --uri "$MONGO_URI" --db IngenIA365ERP_Audit --collection auditLogs --type json \
  --query "{\"timestamp\":{\"\$gte\":{\"\$date\":\"${MES}-01T00:00:00Z\"},\"\$lt\":{\"\$date\":\"${SIG}-01T00:00:00Z\"}}}" \
  --sort '{_id:1}' | gzip -9 > auditLogs-${MES}.json.gz
sha256sum *.gz > SHA256SUMS      # + MANIFIESTO.json (periodo, conteos, hashes, git SHA de la app)
aws s3api put-object --bucket ingenia365-erp-archive --key "audit/${MES}/auditLogs-${MES}.json.gz" \
  --body auditLogs-${MES}.json.gz --object-lock-mode COMPLIANCE \
  --object-lock-retain-until-date "$(date -u -d "${MES}-01 +1830 days" +%Y-%m-%dT00:00:00Z)" \
  --checksum-algorithm SHA256 --server-side-encryption aws:kms --ssekms-key-id "$KMS_KEY_ID"
```

🔴 **Hallazgo en el código, verificado:** `src/Infrastructure/IngenIA365ERP.Audit/Configuration/MongoDbSettings.cs:10` → `AccessLogRetentionDays = 90` (replicado en `src/Presentation/IngenIA365ERP.API/appsettings.json:46`, y aplicado como índice TTL en `MongoDbInitializer.cs:102`). Los registros de **quién consultó** información de asociados se borran a los 90 días. Si SARLAFT exige trazabilidad de acceso —y normalmente la exige—, el dato ya no existirá cuando lo pidan. Dos caminos: subir el TTL, o —mejor y más barato— **incluir `accessLogs` en el sellado mensual**, manteniendo la colección caliente pequeña y la evidencia en S3 por 5 años.

✅ Coherencia con el TTL: `RetentionDays = 1825` borra el documento a los 5 años del evento; el sellado ocurre hasta 32 días después y bloquea 1830 días más, así que el objeto en S3 queda protegido hasta ~evento + 1862 días. **El archivo sobrevive al TTL.** Correcto por construcción, pero no es obvio: documentarlo.

## 5.5 Discrepancia que hay que cerrar antes de crear el bucket

`docs/operaciones/despliegue-infraestructura.md:60` (hito **M5**) y las líneas 172, 181 y 210 especifican **Backblaze B2 con Object Lock**; esta configuración especifica **AWS S3 us-east-1**. Hay que cerrar la decisión antes de crear buckets, porque **Object Lock no se puede activar después sin abrir caso con soporte**. B2 es ~4× más barato en almacenamiento y sin cargos de egreso hasta 3× el almacenamiento (relevante en una restauración), tiene Object Lock equivalente, pero **no tiene clases Glacier** — a 11 GB de archivo da igual. Ambos requieren `endpointURL` (B2 sí, S3 no) y validar boto3 ≥ 1.36.

**Sobre MinIO self-hosted a futuro:** si MinIO corre en las mismas VPS, **deja de ser un respaldo** — comparte dominio de fallo con lo que respalda y viola el "1 copia offsite" de la regla 3-2-1-1-0. Con nodo único, el respaldo remoto es *toda* la red de seguridad. MinIO solo es aceptable en hardware distinto y sede distinta. Cuando llegue, hará falta `endpointURL`, `endpointCA` si hay CA privada, y las dos variables `AWS_*_CHECKSUM_*=when_required` (issue #393).

---

# 6. RIESGOS CON UN SOLO NODO, Y QUÉ CAMBIA CON EL SEGUNDO

## RPO y RTO reales de esta configuración

| Ambiente | RPO | RTO | Cómo se logra |
|---|---|---|---|
| **PDN (Postgres)** | **≤ 5–6 min** | **≤ 2 h** | WAL continuo `archive_timeout=300s` + full diario |
| PDN (auditoría Mongo) | ≤ 24 h | ≤ 4 h | dump diario (mejora a ≤ 5 min con replica set + PBM) |
| QA / DEV | ≤ 24 h | ≤ 4 h | full diario, sin compromiso contractual |

**El RPO no es cero y no puede serlo.** PostgreSQL archiva un segmento WAL cuando se llena (16 MiB) o vence `archive_timeout`. **El segmento parcial en curso NUNCA se archiva.** Si el nodo muere, todo lo commiteado en el segmento activo desde el último cierre se pierde. `RPO_real = archive_timeout + tiempo de subida a S3 + latencia de detección`.

## Riesgos específicos del nodo único

| # | Riesgo | Impacto | Mitigación en esta configuración |
|---|---|---|---|
| R1 | **El rollout del plugin es un corte de servicio** | 2–4 min de ERP caído | Ventana planificada. Con 2 instancias sería un rolling update sin corte. |
| R2 | **`pg_wal` llena el PVC y Postgres entra en PANIC** | **Caída total de producción** por un fallo de *backup* | Es el único modo de fallo del respaldo que además tumba la BD. Alertas `CNPGColaWalCreciendo`/`Critica` + `CNPGPVCEspacioCritico`. `archive_timeout=300s` da ~24 h de margen; `60s` daría 5×menos. **Por esto no bajamos a 60s.** |
| R3 | **Los Secrets no están en el backup** | Datos recuperables, contraseñas perdidas | `barman-cloud` respalda PGDATA + WAL, nada más. **SealedSecrets/SOPS en Git, obligatorio.** El simulacro trimestral existe sobre todo para probar esto. |
| R4 | **Si muere el nodo, muere etcd/sqlite de k3s** | Se pierden todos los manifiestos, no solo la BD | `k3s etcd-snapshot save` o backup de `/var/lib/rancher/k3s/server/db/state.db` fuera del nodo + `Cluster`/`ObjectStore` versionados en Git. |
| R5 | **Colisión de `serverName`** (los 3 clusters se llaman `erp-db`) | WALs de DEV pisando el archivo de PDN, pérdida total de capacidad de recuperación, invisible hasta el desastre | Prefijo por ambiente + `serverName` explícito. **Verificar en el paso 5 que la ruta S3 contiene `erp-db-pdn`, no `erp-db`.** |
| R6 | **El observador vive en NONPROD y vigila PDN** | Si NONPROD cae, no hay alertas sobre PDN y **el silencio parece normalidad** | Dos heartbeats: el `Watchdog` de Alertmanager hacia Healthchecks.io/Better Stack, **y** un CronJob *en PDN* que consulta `barman-cloud-backup-list` y hace ping externo solo si hay backup de <26 h. Este segundo camino no pasa por Prometheus ni por NONPROD: es el único que sobrevive a la caída del observador. |
| R7 | **El drill compite por recursos** | Restaurar 20 Gi en el nodo de PDN degrada el ERP | Ensayar siempre en el servidor no productivo (§4, regla 4). |
| R8 | **Métricas deprecadas** | Dashboard verde permanente sobre un backup roto | Usar `barman_cloud_cloudnative_pg_io_*`, no `cnpg_collector_*_backup_*`. No alertar sobre `.status.firstRecoverabilityPoint` del Cluster. |
| R9 | **`check-empty-wal-archive`** | Al restaurar sobre un prefijo ya usado, el archivado se niega a arrancar | Prefijos limpios, `serverName` versionado (`-v2`). **Nunca** `skipEmptyWalArchiveCheck`. |
| R10 | **Regresión barman 3.19.x** con destinos con retención | Todos los backups reportan `FAILED` aunque los tarballs estén en S3 | Paso 9 de §2 antes de habilitar Object Lock en PDN. |
| R11 | **Sin `data.compression`** el WAL vacío cuesta más que todo lo demás | ~$3.2/mes de ceros | `wal.compression: zstd` desde el día 1. Ya está en los manifiestos. |

## Qué se gana con el segundo nodo

| Se gana | Detalle |
|---|---|
| **RPO → ~0 con replicación síncrona** | `synchronous_replication` hace que un commit no retorne hasta estar en la réplica. Los 5 min de exposición del segmento WAL parcial **desaparecen**. Este es, con diferencia, el mayor salto. |
| **RTO → segundos en vez de horas** | Un failover automático de CNPG promueve la réplica en ~10–30 s. Hoy, perder el nodo significa restaurar de S3: **10–90 min** según cuánto WAL haya que reproducir. |
| **Fin del downtime en mantenimiento** | El rollout del plugin, las actualizaciones de imagen menor y los cambios de parámetros que requieren reinicio pasan a ser rolling updates sin corte (R1 desaparece). |
| **Backup desde el standby** | `target: prefer-standby` saca la carga de I/O del basebackup del primario. Ojo: al hacer backup desde un standby **no se fuerza un WAL switch en el primario**, lo que en despliegues de baja escritura produce resultados inesperados hasta que entra `archive_timeout` — con 300s el efecto queda acotado a 5 min. |
| **Margen para bajar `archive_timeout`** | Con réplica, saturar `pg_wal` deja de ser un evento de caída total (R2 se degrada de crítico a serio), y se puede considerar `60s`. |
| **El drill deja de competir** | Se puede restaurar contra el nodo secundario sin tocar al que sirve tráfico. |

**Lo que el segundo nodo NO reemplaza:** el backup offsite. Una réplica protege contra fallo de hardware, no contra `DROP TABLE`, corrupción lógica, ransomware ni error humano — todos se replican fielmente en milisegundos. La regla 3-2-1-1-0 sigue exigiendo la copia en S3 con Object Lock, y el ensayo mensual de §4 sigue siendo obligatorio.

**Prioridad, en el orden en que compran seguridad por peso:**
1. Terminar esta configuración de backup y **medir un RTO real** en el drill de DEV (paso 10). Un backup nunca restaurado es una hipótesis, no un respaldo.
2. Versionar los Secrets fuera del clúster (R3) — hoy, un fallo de nodo te deja con los datos recuperables y las contraseñas perdidas.
3. Alerta sobre WALs pendientes de archivar (R2) — el único fallo de respaldo que además tumba producción.
4. Heartbeat externo independiente de NONPROD (R6).
5. Segundo nodo.

---

## Índice de archivos a crear

| Ruta | Contenido |
|---|---|
| `k8s/backup/pdn/01-objectstore.yaml` | §1.a |
| `k8s/backup/pdn/02-cluster-patch.yaml` | §1.b |
| `k8s/backup/pdn/03-scheduledbackup.yaml` | §1.c |
| `k8s/backup/pdn/04-prometheusrule.yaml` | §1.e |
| `k8s/backup/nonprod/backup-nonprod.yaml` | §1.d (ObjectStores + ScheduledBackups de dev y qa) |
| `k8s/backup/nonprod/cluster-patch-dev.yaml`, `-qa.yaml` | §1.d |
| `k8s/backup/nonprod/prometheusrule-nonprod.yaml` | §1.e, variante |
| `k8s/backup/restore/objectstore-source.yaml`, `cluster-restore.yaml`, `cluster-pitr.yaml`, `barman-inspect-pod.yaml` | §3 |
| `k8s/backup/drill/networkpolicy-deny-all.yaml`, `objectstore-readonly.yaml`, `cluster-drill.yaml`, `drill.ps1` | §4 |
| `aws/bucket-policy.json`, `lifecycle.json`, `iam-*.json` | §5 |
| `docs/operaciones/runbook-backups.md` | §3 + §4 (referenciado por `runbook_url` en las alertas) |

Archivos existentes a actualizar: `docs/operaciones/slo.md` (RPO/RTO de §6) y `docs/operaciones/despliegue-infraestructura.md` (cerrar M5, líneas 60/172/181/210: B2 → AWS S3).