#!/bin/bash

set -e

export PAGER=cat
export PSQL_PAGER=cat

echo "======================================"
echo " Helsinki: importar GML + tiles + análisis"
echo " Completo + sin piso + Green Spaces + FOS + FAR + sombra"
echo "======================================"
echo ""

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
DB_CONFIG_FILE="$PROJECT_DIR/db_config.sh"

SKIP_GEOSERVER=0
if [ "${1:-}" = "--skip-geoserver" ]; then
  SKIP_GEOSERVER=1
elif [ -n "${1:-}" ]; then
  echo "Uso: $0 [--skip-geoserver]"
  exit 1
fi

if [ ! -f "$DB_CONFIG_FILE" ]; then
  echo "ERROR: No se encontró db_config.sh"
  echo "$DB_CONFIG_FILE"
  exit 1
fi

source "$DB_CONFIG_FILE"

export PGPASSWORD="$DB_PASSWORD"
export CITYDB_PASSWORD="${DB_PASSWORD:-}"

CITYDB_TOOL="$PROJECT_DIR/citydb-tool-1.3.1/citydb"

GML_DIR="$PROJECT_DIR/gml"
BUILDINGS_GML="$GML_DIR/export.gml"
TERRAIN_GML="$GML_DIR/export_terrain.gml"

FULL_TILES_DIR="$PROJECT_DIR/helsinki_tiles"
NO_FLOOR_TILES_DIR="$PROJECT_DIR/helsinki_tiles_no_floor"

GEOSERVER_URL="http://localhost:8080/geoserver"
GEOSERVER_USER="admin"
GEOSERVER_PASSWORD="geoserver"

WORKSPACE="helsinki"
DATASTORE="citydb_analysis"

SQL_FILES=(
  "$PROJECT_DIR/sql/green_spaces.sql"
  "$PROJECT_DIR/sql/parcel_fos.sql"
  "$PROJECT_DIR/sql/parcel_far.sql"
  "$PROJECT_DIR/sql/shadow_green_risk.sql"
)

LAYERS=(
  "green_areas_near_model_mat"
  "building_height_points_mat"
  "buildings_near_green_points_mat"
  "high_buildings_near_green_points"
  "parcels_clean_mat"
  "building_parcel_coverage_mat"
  "parcel_fos_mat"
  "parcel_far_mat"
  "shadow_risk_green_mat"
  "high_shadow_risk_green_points"
)

echo "Proyecto: $PROJECT_DIR"
echo "Base: $DB_NAME"
echo "Schema CityDB: $DB_SCHEMA"
echo "Usuario DB: $DB_USER"
echo "Buildings GML: $BUILDINGS_GML"
echo "Terrain GML: $TERRAIN_GML"
echo "Tiles completo: $FULL_TILES_DIR"
echo "Tiles sin piso: $NO_FLOOR_TILES_DIR"
if [ "$SKIP_GEOSERVER" = "1" ]; then
  echo "GeoServer: se omite publicacion (--skip-geoserver)"
fi
echo ""

# -------------------------------------------------
# 1. Verificaciones
# -------------------------------------------------

echo "======================================"
echo " Verificando herramientas y archivos"
echo "======================================"
echo ""

for CMD in psql curl; do
  if ! command -v "$CMD" >/dev/null 2>&1; then
    echo "ERROR: No se encontró $CMD"
    unset PGPASSWORD CITYDB_PASSWORD
    exit 1
  fi
done

if [ ! -f "$CITYDB_TOOL" ]; then
  echo "ERROR: No se encontró citydb-tool:"
  echo "$CITYDB_TOOL"
  unset PGPASSWORD CITYDB_PASSWORD
  exit 1
fi

if [ ! -x "$CITYDB_TOOL" ]; then
  chmod +x "$CITYDB_TOOL"
fi

if [ ! -f "$BUILDINGS_GML" ]; then
  echo "ERROR: No se encontró:"
  echo "$BUILDINGS_GML"
  echo "Debe existir gml/export.gml"
  unset PGPASSWORD CITYDB_PASSWORD
  exit 1
fi

if [ ! -f "$PROJECT_DIR/generate_tiles.sh" ]; then
  echo "ERROR: No se encontró generate_tiles.sh"
  unset PGPASSWORD CITYDB_PASSWORD
  exit 1
fi

if [ ! -x "$PROJECT_DIR/generate_tiles.sh" ]; then
  chmod +x "$PROJECT_DIR/generate_tiles.sh"
fi

for SQL_FILE in "${SQL_FILES[@]}"; do
  if [ ! -f "$SQL_FILE" ]; then
    echo "ERROR: No existe $SQL_FILE"
    unset PGPASSWORD CITYDB_PASSWORD
    exit 1
  fi
done

psql \
  -h "$DB_HOST" \
  -p "$DB_PORT" \
  -U "$DB_USER" \
  -d "$DB_NAME" \
  -v ON_ERROR_STOP=1 \
  -c "CREATE SCHEMA IF NOT EXISTS analysis;" \
  -c "SELECT 'PostgreSQL OK' AS status;"

GREEN_EXISTS=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT to_regclass('analysis.green_areas');")
PARCELS_EXISTS=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT to_regclass('analysis.parcels');")

if [ "$GREEN_EXISTS" != "analysis.green_areas" ]; then
  echo "ERROR: Falta analysis.green_areas."
  echo "Importala desde QGIS/WFS como analysis.green_areas."
  unset PGPASSWORD CITYDB_PASSWORD
  exit 1
fi

if [ "$PARCELS_EXISTS" != "analysis.parcels" ]; then
  echo "ERROR: Falta analysis.parcels."
  echo "Importala desde QGIS/WFS como analysis.parcels."
  unset PGPASSWORD CITYDB_PASSWORD
  exit 1
fi

psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
  -c "SELECT COUNT(*) AS green_areas FROM analysis.green_areas;" \
  -c "SELECT COUNT(*) AS parcels FROM analysis.parcels;"

echo ""

# -------------------------------------------------
# 2. Limpiar base CityDB e importar solo edificios
# -------------------------------------------------

echo "======================================"
echo " Limpiando 3DCityDB"
echo "======================================"
echo ""

yes | "$CITYDB_TOOL" delete \
  -H "$DB_HOST" \
  -P "$DB_PORT" \
  -d "$DB_NAME" \
  -S "$DB_SCHEMA" \
  -u "$DB_USER"

# citydb delete no siempre elimina dem:TINRelief por defecto.
# Lo borramos siempre antes del tileset "sin piso".
# Es idempotente: si no hay terreno activo, no borra nada y sigue.
echo "Asegurando limpieza de terreno (dem:TINRelief) para tiles sin piso..."
yes | "$CITYDB_TOOL" delete \
  -H "$DB_HOST" \
  -P "$DB_PORT" \
  -d "$DB_NAME" \
  -S "$DB_SCHEMA" \
  -u "$DB_USER" \
  -t dem:TINRelief

echo ""
echo "======================================"
echo " Importando edificios"
echo "======================================"
echo ""

"$CITYDB_TOOL" import citygml "$BUILDINGS_GML" \
  -H "$DB_HOST" \
  -P "$DB_PORT" \
  -d "$DB_NAME" \
  -S "$DB_SCHEMA" \
  -u "$DB_USER"

echo ""
echo "======================================"
echo " Generando tiles SIN PISO"
echo "======================================"
echo ""

"$PROJECT_DIR/generate_tiles.sh" "$NO_FLOOR_TILES_DIR"

# -------------------------------------------------
# 3. Importar terreno y generar tiles completos
# -------------------------------------------------

if [ -f "$TERRAIN_GML" ]; then
  echo ""
  echo "======================================"
  echo " Importando terreno"
  echo "======================================"
  echo ""

  "$CITYDB_TOOL" import citygml "$TERRAIN_GML" -H "$DB_HOST" -P "$DB_PORT" -d "$DB_NAME" -S "$DB_SCHEMA" -u "$DB_USER"
else
  echo ""
  echo "ADVERTENCIA: No se encontró export_terrain.gml."
  echo "Se generará el tileset completo solo con edificios."
fi

echo ""
echo "======================================"
echo " Generando tiles COMPLETOS"
echo "======================================"
echo ""

"$PROJECT_DIR/generate_tiles.sh" "$FULL_TILES_DIR"

# -------------------------------------------------
# 4. Preparar urban_building_base_mat para FOS
# -------------------------------------------------

echo ""
echo "======================================"
echo " Preparando base de edificios para FOS"
echo "======================================"
echo ""

psql \
  -h "$DB_HOST" \
  -p "$DB_PORT" \
  -U "$DB_USER" \
  -d "$DB_NAME" \
  -v ON_ERROR_STOP=1 <<'SQL'
CREATE SCHEMA IF NOT EXISTS analysis;

DROP MATERIALIZED VIEW IF EXISTS analysis.urban_building_base_mat CASCADE;

CREATE MATERIALIZED VIEW analysis.urban_building_base_mat AS
WITH ground_surfaces AS (
  SELECT
    b.id AS building_id,
    b.objectid AS building_gml_id,
    ST_ZMin(b.envelope) AS ground_elevation,
    ST_ZMax(b.envelope) AS roof_elevation,
    ST_ZMax(b.envelope) - ST_ZMin(b.envelope) AS height_m,
    ST_Multi(
      ST_CollectionExtract(
        ST_MakeValid(
          ST_Force2D(
            ST_CurveToLine(
              ST_UnaryUnion(
                ST_Collect(gd.geometry)
              )
            )
          )
        ),
        3
      )
    )::geometry(MultiPolygon, 4326) AS geom
  FROM citydb.feature b
  JOIN citydb.objectclass oc_b
    ON oc_b.id = b.objectclass_id
   AND oc_b.classname = 'Building'
  JOIN citydb.property p_bound
    ON p_bound.feature_id = b.id
   AND p_bound.name = 'boundary'
  JOIN citydb.feature gs
    ON gs.id = p_bound.val_feature_id
  JOIN citydb.objectclass oc_gs
    ON oc_gs.id = gs.objectclass_id
   AND oc_gs.classname = 'GroundSurface'
  JOIN citydb.property p_geom
    ON p_geom.feature_id = gs.id
   AND p_geom.val_geometry_id IS NOT NULL
  JOIN citydb.geometry_data gd
    ON gd.id = p_geom.val_geometry_id
  GROUP BY b.id, b.objectid, b.envelope
),
metrics AS (
  SELECT
    building_id,
    building_gml_id,
    ground_elevation,
    roof_elevation,
    height_m,
    geom,
    ST_Area(ST_Transform(geom, 3879)) AS footprint_area_m2
  FROM ground_surfaces
  WHERE geom IS NOT NULL
    AND NOT ST_IsEmpty(geom)
)
SELECT
  row_number() OVER (ORDER BY building_id)::integer AS gid,
  building_id,
  building_gml_id,
  ROUND(ground_elevation::numeric, 2) AS ground_elevation_m,
  ROUND(roof_elevation::numeric, 2) AS roof_elevation_m,
  ROUND(height_m::numeric, 2) AS height_m,
  CASE
    WHEN height_m >= 40 THEN 'muy_alto'
    WHEN height_m >= 25 THEN 'alto'
    WHEN height_m >= 12 THEN 'medio'
    ELSE 'bajo'
  END AS height_category,
  ROUND(footprint_area_m2::numeric, 2) AS footprint_area_m2,
  geom
FROM metrics;

CREATE UNIQUE INDEX urban_building_base_mat_gid_idx
ON analysis.urban_building_base_mat (gid);

CREATE INDEX urban_building_base_mat_geom_idx
ON analysis.urban_building_base_mat
USING gist (geom);

CREATE INDEX urban_building_base_mat_geom_3879_idx
ON analysis.urban_building_base_mat
USING gist (ST_Transform(geom, 3879));

SELECT COUNT(*) AS urban_buildings
FROM analysis.urban_building_base_mat;
SQL

# -------------------------------------------------
# 5. Ejecutar SQL de análisis
# -------------------------------------------------

echo ""
echo "======================================"
echo " Ejecutando SQL de análisis"
echo "======================================"
echo ""

for SQL_FILE in "${SQL_FILES[@]}"; do
  echo "Ejecutando:"
  echo "$SQL_FILE"
  echo ""

  psql \
    -h "$DB_HOST" \
    -p "$DB_PORT" \
    -U "$DB_USER" \
    -d "$DB_NAME" \
    -v ON_ERROR_STOP=1 \
    -f "$SQL_FILE"

  echo ""
  echo "OK: $SQL_FILE"
  echo ""
done

# -------------------------------------------------
# 6. Verificar resultados
# -------------------------------------------------

echo "======================================"
echo " Verificando resultados"
echo "======================================"
echo ""

psql \
  -h "$DB_HOST" \
  -p "$DB_PORT" \
  -U "$DB_USER" \
  -d "$DB_NAME" \
  -c "SELECT COUNT(*) AS high_buildings_near_green FROM analysis.high_buildings_near_green_points;" \
  -c "SELECT * FROM analysis.parcel_fos_summary;" \
  -c "SELECT * FROM analysis.parcel_far_summary;" \
  -c "SELECT COUNT(*) AS parcels_clean FROM analysis.parcels_clean_mat;" \
  -c "SELECT COUNT(*) AS parcel_fos FROM analysis.parcel_fos_mat;" \
  -c "SELECT COUNT(*) AS parcel_far FROM analysis.parcel_far_mat;" \
  -c "SELECT COUNT(*) AS building_parcel_coverage FROM analysis.building_parcel_coverage_mat;" \
  -c "SELECT * FROM analysis.shadow_risk_green_summary;" \
  -c "SELECT COUNT(*) AS shadow_risk_green FROM analysis.shadow_risk_green_mat;" \
  -c "SELECT COUNT(*) AS high_shadow_risk_green FROM analysis.high_shadow_risk_green_points;"

echo ""

# -------------------------------------------------
# 7. GeoServer
# -------------------------------------------------

if [ "$SKIP_GEOSERVER" = "1" ]; then
  echo "======================================"
  echo " GeoServer omitido"
  echo "======================================"
  echo ""
  echo "Se omitieron la publicacion de capas y la verificacion WFS."
  unset PGPASSWORD CITYDB_PASSWORD
  echo ""
  echo "======================================"
  echo " Proceso terminado"
  echo "======================================"
  echo ""
  echo "Tiles:"
  echo "- Completo: $FULL_TILES_DIR"
  echo "- Sin piso: $NO_FLOOR_TILES_DIR"
  echo ""
  echo "Abrir visor:"
  echo "http://localhost:8003"
  exit 0
fi

echo "======================================"
echo " Preparando GeoServer"
echo "======================================"
echo ""

if ! curl -s "$GEOSERVER_URL" > /dev/null; then
  echo "ERROR: GeoServer no está corriendo."
  echo "Levantalo con ./start_server.sh y corré este script de nuevo."
  unset PGPASSWORD CITYDB_PASSWORD
  exit 1
fi

WORKSPACE_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  -u "$GEOSERVER_USER:$GEOSERVER_PASSWORD" \
  "$GEOSERVER_URL/rest/workspaces/$WORKSPACE.json")

if [ "$WORKSPACE_STATUS" != "200" ]; then
  echo "Creando workspace $WORKSPACE..."
  curl -s -u "$GEOSERVER_USER:$GEOSERVER_PASSWORD" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "{\"workspace\":{\"name\":\"$WORKSPACE\"}}" \
    "$GEOSERVER_URL/rest/workspaces" >/dev/null
fi

DATASTORE_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  -u "$GEOSERVER_USER:$GEOSERVER_PASSWORD" \
  "$GEOSERVER_URL/rest/workspaces/$WORKSPACE/datastores/$DATASTORE.json")

if [ "$DATASTORE_STATUS" = "200" ]; then
  echo "Eliminando datastore anterior $DATASTORE..."
  curl -s -u "$GEOSERVER_USER:$GEOSERVER_PASSWORD" \
    -X DELETE \
    "$GEOSERVER_URL/rest/workspaces/$WORKSPACE/datastores/$DATASTORE?recurse=true" >/dev/null
fi

echo "Creando datastore $DATASTORE apuntando a schema analysis..."

cat > /tmp/geoserver_datastore_payload.json <<JSON
{
  "dataStore": {
    "name": "$DATASTORE",
    "enabled": true,
    "connectionParameters": {
      "entry": [
        {"@key": "host", "$": "$DB_HOST"},
        {"@key": "port", "$": "$DB_PORT"},
        {"@key": "database", "$": "$DB_NAME"},
        {"@key": "user", "$": "$DB_USER"},
        {"@key": "passwd", "$": "$DB_PASSWORD"},
        {"@key": "dbtype", "$": "postgis"},
        {"@key": "schema", "$": "analysis"},
        {"@key": "Expose primary keys", "$": "true"}
      ]
    }
  }
}
JSON

curl -s -u "$GEOSERVER_USER:$GEOSERVER_PASSWORD" \
  -X POST \
  -H "Content-Type: application/json" \
  -d @/tmp/geoserver_datastore_payload.json \
  "$GEOSERVER_URL/rest/workspaces/$WORKSPACE/datastores" >/dev/null

echo ""

# -------------------------------------------------
# 8. Publicar capas
# -------------------------------------------------

echo "======================================"
echo " Publicando capas"
echo "======================================"
echo ""

delete_layer_everywhere() {
  local LAYER_NAME="$1"

  echo "Limpiando publicación vieja de: $LAYER_NAME"

  # Borra la capa publicada si existe.
  curl -s -u "$GEOSERVER_USER:$GEOSERVER_PASSWORD" \
    -X DELETE \
    "$GEOSERVER_URL/rest/layers/$WORKSPACE:$LAYER_NAME?recurse=true" >/dev/null || true

  # Borra featuretype del datastore nuevo si existe.
  curl -s -u "$GEOSERVER_USER:$GEOSERVER_PASSWORD" \
    -X DELETE \
    "$GEOSERVER_URL/rest/workspaces/$WORKSPACE/datastores/$DATASTORE/featuretypes/$LAYER_NAME?recurse=true" >/dev/null || true

  # Borra featuretype de datastores viejos comunes, por si quedó apuntando mal.
  curl -s -u "$GEOSERVER_USER:$GEOSERVER_PASSWORD" \
    -X DELETE \
    "$GEOSERVER_URL/rest/workspaces/$WORKSPACE/datastores/citydb_test/featuretypes/$LAYER_NAME?recurse=true" >/dev/null || true

  curl -s -u "$GEOSERVER_USER:$GEOSERVER_PASSWORD" \
    -X DELETE \
    "$GEOSERVER_URL/rest/workspaces/$WORKSPACE/datastores/citydb_analysis/featuretypes/$LAYER_NAME?recurse=true" >/dev/null || true
}

publish_layer() {
  local LAYER_NAME="$1"

  delete_layer_everywhere "$LAYER_NAME"

  echo "Publicando: $LAYER_NAME"

  local RESPONSE
  RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}" \
    -u "$GEOSERVER_USER:$GEOSERVER_PASSWORD" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "{
      \"featureType\": {
        \"name\": \"$LAYER_NAME\",
        \"title\": \"$LAYER_NAME\",
        \"srs\": \"EPSG:4326\",
        \"enabled\": true
      }
    }" \
    "$GEOSERVER_URL/rest/workspaces/$WORKSPACE/datastores/$DATASTORE/featuretypes")

  echo "$RESPONSE"
  echo ""

  if ! echo "$RESPONSE" | grep -q "HTTP_STATUS:201"; then
    echo "ADVERTENCIA: GeoServer no respondió 201 al publicar $LAYER_NAME."
    echo "Si ya existía una capa vieja, fue eliminada arriba; revisá el mensaje anterior."
  fi
}

for LAYER in "${LAYERS[@]}"; do
  publish_layer "$LAYER"
done

# -------------------------------------------------
# 9. Recargar y verificar WFS
# -------------------------------------------------

echo "======================================"
echo " Recargando y verificando WFS"
echo "======================================"
echo ""

curl -s -u "$GEOSERVER_USER:$GEOSERVER_PASSWORD" \
  -X POST \
  "$GEOSERVER_URL/rest/reload" >/dev/null

for LAYER in "${LAYERS[@]}"; do
  WFS_URL="$GEOSERVER_URL/$WORKSPACE/ows?service=WFS&version=1.0.0&request=GetFeature&typeName=$WORKSPACE:$LAYER&outputFormat=application/json"
  WFS_RESPONSE_FILE="$(mktemp)"
  WFS_STATUS=$(curl -s -o "$WFS_RESPONSE_FILE" -w "%{http_code}" "$WFS_URL")

  if grep -q "FeatureCollection" "$WFS_RESPONSE_FILE"; then
    echo "OK WFS: $LAYER"
  else
    echo "ERROR WFS: $LAYER"
    echo "HTTP status: $WFS_STATUS"
    cat "$WFS_RESPONSE_FILE"
    echo ""
  fi

  rm -f "$WFS_RESPONSE_FILE"
done

unset PGPASSWORD CITYDB_PASSWORD

echo ""
echo "======================================"
echo " Proceso terminado"
echo "======================================"
echo ""
echo "Tiles:"
echo "- Completo: $FULL_TILES_DIR"
echo "- Sin piso: $NO_FLOOR_TILES_DIR"
echo ""
echo "Abrir visor:"
echo "http://localhost:8003"
