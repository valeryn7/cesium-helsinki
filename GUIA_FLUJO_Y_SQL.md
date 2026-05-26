# Guia completa: flujo + SQL del proyecto

Este documento resume todo el flujo actual del proyecto, con foco en:
- que hace cada script principal
- que hace cada SQL
- que tablas/vistas se crean en `analysis`
- que capas se publican en GeoServer y consume el visor

## 1. Flujo general (actual)

El flujo recomendado hoy es:

1. Importar/actualizar datos fuente WFS en PostGIS:
- `analysis.green_areas`
- `analysis.parcels`

Para esto seguir:
- `sql/INSTRUCCIONES_WFS.txt`

2. Ejecutar pipeline principal:

```bash
./import_gml_and_generate.sh
```

Ese script hace de punta a punta:
- valida herramientas y configuracion (`db_config.sh`)
- valida que existan `analysis.green_areas` y `analysis.parcels`
- limpia 3DCityDB
- importa edificios GML (`gml/export.gml`)
- genera tiles sin piso (`helsinki_tiles_no_floor`)
- importa terreno (`gml/export_terrain.gml`, si existe)
- genera tiles completos (`helsinki_tiles`)
- crea base de edificios para analisis (`analysis.urban_building_base_mat`)
- ejecuta SQL de analisis en este orden:
  1. `sql/green_spaces.sql`
  2. `sql/parcel_fos.sql`
  3. `sql/parcel_far.sql`
  4. `sql/shadow_green_risk.sql`
- publica capas en GeoServer workspace `helsinki`, datastore `citydb_analysis`
- verifica endpoints WFS

3. Levantar servicios web:

```bash
./start_server.sh
```

Visor:
- `http://localhost:8003`

GeoServer:
- `http://localhost:8080/geoserver`

## 2. SQL ejecutados por el pipeline

## 2.1 `sql/green_spaces.sql`

Objetivo:
- analisis de edificios y su cercania a espacios verdes

Entradas esperadas:
- geometria de edificios en CityDB (`citydb.mv_geometries`)
- `analysis.green_areas` (importada desde WFS)

Salidas principales:
- `analysis.building_height_points_mat`
  - punto por edificio + altura estimada + categoria (`bajo/medio/alto/muy_alto`)
- `analysis.green_areas_near_model_mat`
  - espacios verdes cercanos al area del modelo
- `analysis.buildings_near_green_points_mat`
  - cada edificio con su verde mas cercano y distancia
- `analysis.high_buildings_near_green_points`
  - filtro de edificios altos cerca de verde

Notas:
- geometria final en EPSG:4326
- distancias en EPSG:3879

## 2.2 `sql/parcel_fos.sql`

Objetivo:
- calcular FOS real (ocupacion del suelo) por parcela

Entradas esperadas:
- `analysis.urban_building_base_mat`
- `analysis.parcels` (importada desde WFS)

Salidas principales:
- `analysis.buildings_clean_mat`
- `analysis.parcels_clean_mat`
- `analysis.building_parcel_intersections_mat`
- `analysis.building_parcel_coverage_mat`
- `analysis.parcel_fos_mat`
- `analysis.parcel_fos_summary` (vista resumen)

Interpretacion:
- FOS = porcentaje de area de parcela ocupada por huella edificada

## 2.3 `sql/parcel_far.sql`

Objetivo:
- estimar densidad construida (FAR) por parcela

Entradas esperadas:
- `analysis.parcels_clean_mat`
- `analysis.building_parcel_intersections_mat`

Salidas principales:
- `analysis.building_far_estimate_mat`
- `analysis.parcel_far_mat`
- `analysis.parcel_far_summary` (vista resumen)

Interpretacion usada:
- pisos estimados ~= altura / 3.2
- area construida estimada = interseccion edificio-parcela * pisos estimados
- FAR = area construida estimada / area parcela

## 2.4 `sql/shadow_green_risk.sql`

Objetivo:
- estimar sombra proyectada sobre espacios verdes

Entradas esperadas:
- `analysis.urban_building_base_mat`
- `analysis.green_areas_near_model_mat`

Salidas principales:
- `analysis.shadow_risk_green_mat`
  - parches de sombra proyectada sobre verde
  - incluye score, nivel, area sombreada, parametros solares
- `analysis.high_shadow_risk_green_points`
  - filtro `HIGH` y `VERY_HIGH`
- `analysis.shadow_risk_green_summary`
  - resumen agregado

Modelo simplificado:
- escenario solar fijo
- azimut y elevacion solar constantes
- proyeccion 2D aproximada (no ray tracing horario completo)

Compatibilidad:
- la vista mantiene columna `distance_to_green_m` para no romper capas ya publicadas en GeoServer

## 3. Base de edificios para analisis

El pipeline crea antes de los SQL una vista base:
- `analysis.urban_building_base_mat`

Que contiene:
- id de edificio
- altura y categoria
- huella del edificio
- metrica de area

Esta vista es dependencia directa de:
- `sql/parcel_fos.sql`
- `sql/shadow_green_risk.sql`

## 4. Capas publicadas en GeoServer por el pipeline

El script publica estas capas en workspace `helsinki`:

1. `green_areas_near_model_mat`
2. `building_height_points_mat`
3. `buildings_near_green_points_mat`
4. `high_buildings_near_green_points`
5. `parcels_clean_mat`
6. `building_parcel_coverage_mat`
7. `parcel_fos_mat`
8. `parcel_far_mat`
9. `shadow_risk_green_mat`
10. `high_shadow_risk_green_points`

Endpoint base WFS:
- `http://localhost:8080/geoserver/helsinki/ows`

## 5. SQL existentes que NO son parte del pipeline actual

## 5.1 `sql/urban_rules_views.sql`

- genera capas de reglas urbanas aproximadas
- util para analisis extra y demos
- no se ejecuta automaticamente en `import_gml_and_generate.sh`

## 5.2 `sql/urban_rules_queries.sql`

- consultas exploratorias de reglas urbanas
- orientado a analisis manual
- no se ejecuta automaticamente en el pipeline principal

## 6. Orden recomendado de uso

1. Cargar WFS en PostGIS (`green_areas` y `parcels`)
2. Ejecutar `./import_gml_and_generate.sh`
3. Levantar `./start_server.sh`
4. Verificar visor y capas en `http://localhost:8003`

## 7. Comandos de chequeo rapido

Verificar objetos clave:

```sql
SELECT to_regclass('analysis.green_areas');
SELECT to_regclass('analysis.parcels');
SELECT to_regclass('analysis.urban_building_base_mat');
SELECT to_regclass('analysis.parcel_fos_mat');
SELECT to_regclass('analysis.parcel_far_mat');
SELECT to_regclass('analysis.shadow_risk_green_mat');
```

Probar WFS de una capa:

```bash
curl "http://localhost:8080/geoserver/helsinki/ows?service=WFS&version=1.0.0&request=GetFeature&typeName=helsinki:shadow_risk_green_mat&outputFormat=application/json"
```

Si devuelve XML en lugar de JSON:
- revisar mensaje de error del XML
- verificar que exista la vista en PostGIS
- recargar GeoServer (`/rest/reload`) si hubo cambios de esquema/columnas

## 8. Nota de mantenimiento

- `run_analysis_and_publish.sh` ya no se usa (fue retirado)
- toda la ejecucion integral esta consolidada en:

```bash
./import_gml_and_generate.sh
```
