# MongoDB como replica set de un nodo

## Por qué

MongoDB guarda la auditoría SARLAFT, con retención obligatoria de 5 años. Un
`mongodump` **sin oplog no es una copia consistente**: mezcla escrituras de
distintos instantes, y eso no es evidencia defendible ante una revisión. El
oplog solo existe si el `mongod` corre como replica set, aunque sea de un nodo.

De paso habilita transacciones multidocumento, change streams y —cuando haga
falta— Percona Backup for MongoDB, que **no soporta standalone**.

No cambia la topología ni el consumo. El único efecto visible en la aplicación
es el `?replicaSet=rs0` de la cadena de conexión.

## La trampa del arranque (leer antes de tocar nada)

`mongod` resuelve el nombre de su miembro del replica set **al arrancar** y
decide en ese momento si se reconoce como parte del conjunto. **No lo reevalúa
nunca más.**

Al recrear el pod cambia su IP. CoreDNS puede seguir devolviendo la anterior
hasta 30 segundos por su caché, mientras `mongod` arranca en ~2. Si eso pasa,
concluye que no es miembro y queda así de forma permanente:

```
InvalidReplicaSetConfig: Our replica set config is invalid or we are not a
member of it
```

El resultado es una base que **responde consultas pero no genera oplog**: sin
respaldo consistente posible, y sin ninguna señal evidente de que algo esté mal.

**La solución está en el initContainer `esperar-dns`**, que bloquea el arranque
de `mongod` hasta que `erp-mongo-0.erp-mongo` apunte a la IP de ese pod. Medido
en DEV: la convergencia tarda unos 8 segundos. Si no converge en 180, el
initContainer falla a propósito y el pod queda en `Init` — un estado
recuperable, en vez de una base rota.

También es necesario `publishNotReadyAddresses: true` en el Service: sin eso el
registro DNS del pod solo se publica cuando está `Ready`, pero estar `Ready`
exige ser `PRIMARY`, que exige la iniciación que necesita ese DNS. Ciclo cerrado.

## La otra trampa: el StatefulSet no se actualiza solo

Un StatefulSet **no ejecuta su actualización mientras su pod está `not Ready`**.
Si MongoDB queda roto, el arreglo publicado en Git **no llega**: Argo reporta
`Synced` y el pod sigue con la definición vieja.

Hay que forzar el reemplazo a mano:

```bash
k3s kubectl delete pod erp-mongo-0 -n erp-dev
```

El PVC no se toca: el pod se recrea sobre el mismo disco.

## Reparar un nodo que quedó fuera de su propio replica set

Síntoma: `rs.status()` devuelve `InvalidReplicaSetConfig` y el pod nunca alcanza
`Ready`. La configuración está en disco (`local.system.replset` tiene 1
documento) pero `mongod` no se reconoce en ella.

```bash
k3s kubectl exec -n erp-dev erp-mongo-0 -c mongo -- mongosh --quiet local --eval \
  'var c = db.system.replset.findOne(); c.version = c.version + 1; rs.reconfig(c, {force:true})'
```

Con el DNS ya correcto, el nodo se reconoce y pasa a `PRIMARY` en segundos.

> Si en cambio el error es `NotYetInitialized`, el replica set nunca se creó: el
> hook `postStart` se encarga solo al recrear el pod. `reconfig` no aplica ahí.

## Comprobaciones rápidas

```bash
# Estado (1 = PRIMARY, que es lo esperado)
k3s kubectl exec -n erp-dev erp-mongo-0 -c mongo -- mongosh --quiet --eval \
  'var s = rs.status(); print(s.set + " estado=" + s.myState)'

# Qué hizo el arranque
k3s kubectl logs -n erp-dev erp-mongo-0 -c esperar-dns
k3s kubectl logs -n erp-dev erp-mongo-0 -c mongo | grep rs-init
```

La sonda de disponibilidad exige `myState === 1` a propósito: convierte "está
standalone y nadie se enteró" en un fallo visible. El costo es que un MongoDB
roto deja a la API fuera de servicio — que es el comportamiento correcto para un
producto donde la auditoría es obligatoria, no opcional.

## Ensayo verificado (2026-08-12, DEV)

Ciclo completo probado con datos reales, no simulado:

| Paso | Evidencia |
|---|---|
| Volcado consistente | `dumped 1 oplog entry` — sin replica set esta línea no existe |
| Subida a S3 | `head-object` devolvió 10.726 bytes: se comprueba el objeto en destino, no el código de salida del `cp` |
| Descarga desde S3 | 10,5 KiB recuperados |
| Restauración | `132 document(s) restored successfully. 0 failed`, índices incluidos (entre ellos el TTL de 90 días de `accessLogs`) |
| Comparación | original 132 = restaurado 132 |

El ensayo restaura a `prueba_restauracion` con `--nsFrom/--nsTo` y borra esa base
al terminar: es inocuo sobre los datos vivos y puede repetirse cuando se quiera.

> Conviene repetirlo cada vez que cambie la versión de MongoDB o el formato del
> volcado. Un respaldo que dejó de restaurarse hace un año es una suposición.

## Historial

Esta configuración costó cinco iteraciones en DEV (2026-08-11/12). Las cuatro
primeras atacaron síntomas — DNS no publicado, el StatefulSet que no rotaba, una
ventana de espera fija, reintentos de iniciación — porque se dio por supuesta la
causa en vez de leer el error exacto de `rs.status()`. Ese error señalaba
directamente el problema real desde el principio.
