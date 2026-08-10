# Accesos y credenciales

**Ninguna credencial vive en este repositorio.** Todas se generaron en los
servidores y viven solo dentro de Secrets de Kubernetes. Este documento explica
cómo recuperarlas, no cuáles son.

## Paneles (solo por Tailscale — no existen desde internet)

| Servicio | URL |
|---|---|
| Argo CD producción | https://erp-pdn.tail72aebc.ts.net |
| Argo CD DEV/QA | https://erp-nonprod.tail72aebc.ts.net:8443 |
| Grafana | https://erp-nonprod.tail72aebc.ts.net |

## Servidores

| Nombre | IP privada (Tailscale) | Rol |
|---|---|---|
| `erp-pdn` | 100.104.190.76 | Producción |
| `erp-nonprod` | 100.94.218.42 | DEV + QA + observabilidad |

Acceso: `ssh -i ~/.ssh/ingenia365_deploy root@<ip-privada>`.
El SSH público está cerrado en ambos: **sin Tailscale no hay acceso**.
Vía de rescate: consola web (VNC) del proveedor.

## Recuperar contraseñas

### Argo CD (usuario `admin`)

```bash
ssh -i ~/.ssh/ingenia365_deploy root@100.104.190.76 \
  "k3s kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo"
```

Cambiala al primer ingreso (*User Info → Update Password*) y luego borrá el
secreto inicial:
`k3s kubectl -n argocd delete secret argocd-initial-admin-secret`

### Grafana (usuario `admin`)

```bash
ssh -i ~/.ssh/ingenia365_deploy root@100.94.218.42 \
  "k3s kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo"
```

### Administrador master del ERP

Sembrado en el primer arranque de la API. Cambiar `erp-pdn` por `erp-dev` o
`erp-qa` según el ambiente:

```bash
ssh -i ~/.ssh/ingenia365_deploy root@100.104.190.76 \
  "k3s kubectl -n erp-pdn get secret erp-master-admin -o jsonpath='{.data.password}' | base64 -d; echo"
```

### PostgreSQL (usuario `ingenia`)

```bash
ssh -i ~/.ssh/ingenia365_deploy root@100.104.190.76 \
  "k3s kubectl -n erp-pdn get secret erp-db-app -o jsonpath='{.data.password}' | base64 -d; echo"
```

Para una sesión `psql`:
`k3s kubectl exec -it -n erp-pdn erp-db-1 -- psql -d ingenia365erp`

## Claves de firma de tokens (RS256)

| Ambiente | Tamaño | Secret |
|---|---|---|
| Producción | 4096 bits | `erp-jwt-keys` en `erp-pdn` |
| DEV / QA | 2048 bits | `erp-jwt-keys` en `erp-dev` / `erp-qa` |

Son **distintas por ambiente a propósito**: un token emitido en DEV no puede
validarse en producción.

> ⚠️ **Rotación**: al rotar estas claves se invalidan todas las sesiones activas.
> El feature 002 exige conservar las claves públicas históricas 5 años para poder
> verificar tokens antiguos durante una auditoría. Guardar la clave retirada en
> un lugar seguro antes de reemplazarla.

## Descarga de imágenes (GHCR)

Las imágenes del ERP se publican como paquetes **privados**: contienen el código
compilado del producto. Cada namespace necesita el Secret `ghcr-pull`, o los pods
quedan en `ImagePullBackOff` con `unauthorized` aunque la imagen exista.

Se crea con `tools/scripts/crear-secreto-ghcr.ps1` (en el repo de la aplicación).
El token es un **PAT classic con un único permiso: `read:packages`** — vive dentro
de los servidores, así que no debe poder escribir nada.

```bash
ssh -i ~/.ssh/ingenia365_deploy root@100.94.218.42 \
  "k3s kubectl get secret ghcr-pull -n erp-dev"
```

> Alternativa descartada: hacer públicos los paquetes evitaría el token, pero
> expondría el código compilado del ERP a cualquiera. Para un producto financiero
> no compensa el ahorro de una credencial.

## Llaves SSH

| Llave | Uso |
|---|---|
| `~/.ssh/ingenia365_deploy` | Administración de los servidores (equipo de trabajo) |
| `/root/.ssh/gitops_deploy` (en cada servidor) | Lectura del repo GitOps por Argo CD. **Solo lectura**, registrada como deploy key |

## Pendiente de custodia

Estas credenciales solo existen dentro de los clústeres. **Si se pierde un
servidor, se pierden.** Falta definir dónde se resguardan (gestor de
contraseñas del equipo o sobre sellado) — especialmente:

- La contraseña del administrador master de producción
- Las claves privadas RS256 (necesarias para verificar tokens históricos)
- La llave de acceso `ingenia365_deploy`
