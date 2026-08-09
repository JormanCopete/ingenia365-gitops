# ingenia365-gitops

Manifiestos de despliegue de **IngenIA365ERP**. Argo CD observa este repositorio
y sincroniza el estado de los clústeres: **nadie despliega por SSH**.

> Repositorio **privado** a propósito: el repo de la aplicación es público, pero
> la topología de la infraestructura no debe serlo.

## Estructura

```
apps/                      Applications de Argo CD (qué observa cada clúster)
  pdn/                       -> clúster de producción
  nonprod/                   -> clúster de DEV + QA
workloads/
  erp/
    base/                    manifiestos comunes a los 3 ambientes
    overlays/{dev,qa,pdn}/   lo que cambia por ambiente
  panel/                     panel.ingenia365.com (migrado desde Docker)
infrastructure/
  {pdn,nonprod}/             backups (ObjectStore, ScheduledBackup), alertas
docs/                        runbooks
```

## Cómo se despliega

| Ambiente | Disparador | Sincronización |
|---|---|---|
| **DEV** | merge a `main` de este repo | Automática, con `selfHeal` |
| **QA** | merge a `main` | Automática, sin `selfHeal` (permite congelar durante certificación) |
| **PDN** | merge a `main` | **Manual**: alguien aprueba en Argo CD. El control de cambios que exige un producto regulado |

El flujo completo: código → CI construye y publica a GHCR → se actualiza la
etiqueta de imagen en este repo → Argo CD sincroniza.

## Decisiones que conviene entender antes de tocar

**Entrada única.** Un solo host sirve la Web y la API bajo `/api`. No es
estética: elimina CORS, permite que una sola imagen WASM sirva los 3 ambientes,
y refuerza FR-007 del feature 002 (el tenant sale del claim `active_tenant_id`,
nunca del subdominio). **Nunca crear subdominios por cooperativa.**

**Producción no se auto-migra.** `Database__AutoMigrate=false`: la API se niega
a arrancar si hay migraciones pendientes. Las aplica el Job `erp-db-migrate`
como *PreSync hook* antes de rotar los pods. Si ese Job falla, Argo aborta la
sincronización y los pods viejos siguen sirviendo: no hay ventana en la que el
código nuevo hable con un esquema viejo.

**Todo en UTC.** Los contenedores corren en UTC y la conversión a
`America/Bogota` ocurre solo en presentación. Un cierre contable corrido 5 horas
es un hallazgo de auditoría.

**MongoDB no está cubierto por los backups de PostgreSQL.** Ahí vive la
auditoría SARLAFT con retención de 5 años y necesita su propio respaldo
inmutable — ver `docs/backups.md`.

## Verificar antes de commitear

```bash
kubectl kustomize workloads/erp/overlays/dev
kubectl kustomize workloads/erp/overlays/qa
kubectl kustomize workloads/erp/overlays/pdn
```

Si alguno falla, no lo subas: Argo CD lo marcará como degradado.

## Secretos

**Nunca en este repo en claro.** Se crean fuera de Git:

| Secreto | Namespace | Origen |
|---|---|---|
| `erp-db-app` | erp-* | Lo genera CloudNativePG |
| `s3-backup-creds` | erp-* | `tools/scripts/crear-secreto-s3.ps1` del repo del ERP |
| `erp-jwt-keys` | erp-* | Claves RS256 generadas en el servidor |
| `erp-master-admin` | erp-* | Bootstrap del administrador master |
