#!/bin/bash

set -e

export PAGER=cat
export PSQL_PAGER=cat

echo "======================================"
echo " Helsinki: Green Spaces + FOS"
echo " SQL + GeoServer publish"
echo "======================================"
echo ""

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
DB_CONFIG_FILE="$PROJECT_DIR/db_config.sh"

if [ ! -f "$DB_CONFIG_FILE" ]; then
  echo "ERROR: No se encontró db_config.sh"
  echo "$DB_CONFIG_FILE"
  exit 1
fi

source "$DB_CONFIG_FILE"

export PGPASSWORD="$DB_PASSWORD"

GEOSERVER_URL="http://localhost:8080/geoserver"
GEOSERVER_USER="admin"
GEOSERVER_PASSWORD="geoserver"

WORKSPACE="helsinki"

# Datastore limpio para analysis. Evita conflictos con stores viejos.
DATASTORE="citydb_analysis"

SQL_FILES=(
  "$PROJECT_DIR/sql/green_spaces.sql"
  "$PROJECT_DIR/sql/parcel_fos.sql"
)

LAYERS=(
  "green_areas_near_model_mat"
  "building_height_points_mat"
  "buildings_near_green_points_mat"
  "high_buildings_near_green_points"
  "parcels_clean_mat"
  "building_parcel_coverage_mat"
  "parcel_fos_mat"
)

echo "Proyecto: $PROJECT_DIR"
echo "Base: $DB_NAME"
echo "Usuario DB: $DB_USER"
echo "GeoServer: $GEOSERVER_URL"
echo "Workspace: $WORKSPACE"
echo "Datastore: $DATASTORE"
echo ""

# -------------------------------------------------
# 1. Verificaciones
# -------------------------------------------------

echo "======================================"
echo " Verificando herramientas y tablas base"
echo "======================================"
echo ""

for CMD in psql curl; do
  if ! command -v "$CMD" >/dev/null 2>&1; then
    echo "ERROR: No se encontró $CMD"
    unset PGPASSWORD
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
  unset PGPASSWORD
  exit 1
fi

if [ "$PARCELS_EXISTS" != "analysis.parcels" ]; then
  echo "ERROR: Falta analysis.parcels."
  echo "Importala desde QGIS/WFS como analysis.parcels."
  unset PGPASSWORD
  exit 1
fi

psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
  -c "SELECT COUNT(*) AS green_areas FROM analysis.green_areas;" \
  -c "SELECT COUNT(*) AS parcels FROM analysis.parcels;"

echo ""

# -------------------------------------------------
# 2. Preparar urban_building_base_mat para FOS
# -------------------------------------------------

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

echo ""

# -------------------------------------------------
# 3. Ejecutar SQL de análisis
# -------------------------------------------------

echo "======================================"
echo " Ejecutando SQL"
echo "======================================"
echo ""

for SQL_FILE in "${SQL_FILES[@]}"; do
  if [ ! -f "$SQL_FILE" ]; then
    echo "ERROR: No existe $SQL_FILE"
    unset PGPASSWORD
    exit 1
  fi

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
# 4. Verificar vistas importantes
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
  -c "SELECT COUNT(*) AS parcels_clean FROM analysis.parcels_clean_mat;" \
  -c "SELECT COUNT(*) AS parcel_fos FROM analysis.parcel_fos_mat;" \
  -c "SELECT COUNT(*) AS building_parcel_coverage FROM analysis.building_parcel_coverage_mat;"

echo ""

# -------------------------------------------------
# 5. GeoServer workspace/datastore
# -------------------------------------------------

echo "======================================"
echo " Preparando GeoServer"
echo "======================================"
echo ""

if ! curl -s "$GEOSERVER_URL" > /dev/null; then
  echo "ERROR: GeoServer no está corriendo."
  echo "Levantalo con ./start_server.sh y corré este script de nuevo."
  unset PGPASSWORD
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
# 6. Publicar capas
# -------------------------------------------------

echo "======================================"
echo " Publicando capas"
echo "======================================"
echo ""

publish_layer() {
  local LAYER_NAME="$1"

  echo "Publicando: $LAYER_NAME"

  local RESPONSE
  RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}" \
    -u "$GEOSERVER_USER:$GEOSERVER_PASSWORD" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "{
      \"featureType\": {
        \"name\": \"$LAYER_NAME\",
        \"nativeName\": \"$LAYER_NAME\",
        \"title\": \"$LAYER_NAME\",
        \"srs\": \"EPSG:4326\",
        \"nativeCRS\": \"EPSG:4326\",
        \"enabled\": true
      }
    }" \
    "$GEOSERVER_URL/rest/workspaces/$WORKSPACE/datastores/$DATASTORE/featuretypes")

  echo "$RESPONSE"
  echo ""
}

for LAYER in "${LAYERS[@]}"; do
  publish_layer "$LAYER"
done

# -------------------------------------------------
# 7. Recargar y verificar WFS
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

unset PGPASSWORD

echo ""
echo "======================================"
echo " Proceso terminado"
echo "======================================"
echo ""
echo "Abrir visor:"
echo "http://localhost:8003"
