#!/bin/sh
# Crea los buckets de custodia con Object Lock (WORM) y versionado (ADR-002, Parte IV.1: conservación 5 años).
# Modo governance en desarrollo; compliance en producción (MINIO_LOCK_MODE).
set -eu

MODE="${MINIO_LOCK_MODE:-governance}"
DAYS="${MINIO_RETENTION_DAYS:-2190}"

until mc alias set local "${MINIO_ENDPOINT:-http://minio:9000}" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1; do
  echo "[minio-init] esperando a MinIO..."
  sleep 2
done

# Un bucket por familia de artefacto; el prefijo por tenant se aplica dentro (tenants/<uuid>/...).
for bucket in conecta-documents conecta-dian-responses conecta-renderings; do
  if mc ls "local/$bucket" >/dev/null 2>&1; then
    echo "[minio-init] bucket $bucket ya existe"
  else
    mc mb --with-lock "local/$bucket"
    echo "[minio-init] bucket $bucket creado con Object Lock"
  fi
  mc version enable "local/$bucket" >/dev/null
  mc retention set --default "$MODE" "${DAYS}d" "local/$bucket" >/dev/null
  echo "[minio-init] retención por defecto en $bucket: $MODE ${DAYS}d"
done

# Bucket de trabajo sin WORM para artefactos temporales (ZIP de envío, PDF en proceso).
mc mb --ignore-existing local/conecta-scratch >/dev/null
mc ilm rule add --expire-days 7 local/conecta-scratch >/dev/null 2>&1 || true

# Usuario de la API y los workers: lee, escribe y fija la retención de cada objeto. No borra ni puede acortarla,
# porque no tiene s3:BypassGovernanceRetention.
# El SDK comprueba que el bucket exista antes de cada operación, y eso exige s3:ListBucket.
# Con versionado, un borrado sin versión deja un marcador que oculta el objeto, y el bloqueo no lo impide.
APP_POLICY=conecta-app-custody
cat > /tmp/conecta-app-policy.json <<'POLICY'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:PutObjectRetention"],
      "Resource": [
        "arn:aws:s3:::conecta-documents/*",
        "arn:aws:s3:::conecta-dian-responses/*",
        "arn:aws:s3:::conecta-renderings/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::conecta-documents",
        "arn:aws:s3:::conecta-dian-responses",
        "arn:aws:s3:::conecta-renderings"
      ]
    }
  ]
}
POLICY
mc admin user add local "$MINIO_APP_ACCESS_KEY" "$MINIO_APP_SECRET_KEY" >/dev/null
mc admin policy create local "$APP_POLICY" /tmp/conecta-app-policy.json >/dev/null
# Repetir la asignación falla; lo que importa es que la política quede asignada.
mc admin policy attach local "$APP_POLICY" --user "$MINIO_APP_ACCESS_KEY" >/dev/null 2>&1 || true
case "$(mc admin user info local "$MINIO_APP_ACCESS_KEY")" in
  *"$APP_POLICY"*) echo "[minio-init] usuario $MINIO_APP_ACCESS_KEY con política $APP_POLICY" ;;
  *) echo "[minio-init] el usuario $MINIO_APP_ACCESS_KEY quedó sin política" >&2; exit 1 ;;
esac

echo "[minio-init] listo"
