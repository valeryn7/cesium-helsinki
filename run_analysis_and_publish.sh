#!/bin/bash

set -e

export PAGER=cat
export PSQL_PAGER=cat

echo "======================================"
echo " Ejecutar análisis + publicar capas"
echo " Helsinki 3D / PostGIS / GeoServer"
echo "======================================"
echo ""

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Carga configuracion central de base de datos.
# Permite override por entorno gracias a db_config.sh.
DB_CONFIG_FILE="$PROJECT_DIR/db_config.sh"
if [ ! -f "$DB_CONFIG_FILE" ]; then
  echo "ERROR: No existe el archivo de configuracion de BD:"
  echo "$DB_CONFIG_FILE"
  exit 1
fi
source "$DB_CONFIG_FILE"

export PGPASSWORD="$DB_PASSWORD"

SQL_FILES=(
  "$PROJECT_DIR/sql/green_spaces.sql"
  "$PROJECT_DIR/sql/urban_rules_views.sql"
)

GEOSERVER_URL="http://localhost:8080/geoserver"
GEOSERVER_USER="admin"
GEOSERVER_PASSWORD="geoserver"

WORKSPACE="helsinki"
DATASTORE="citydb_analysis"

GREEN_LAYERS=(
  "building_height_points_mat"
  "green_areas_near_model_mat"
  "buildings_near_green_points_mat"
  "high_buildings_near_green_points"
)

URBAN_RULES_LAYERS=(
  "urban_building_base_mat"
  "rule1_building_spacing_mat"
  "rule2_height_ratio_mat"
  "rule3_coverage_mat"
  "rule4_min_height_mat"
  "rule5_max_height_mat"
  "rule6_far_mat"
  "combined_urban_rules_mat"
)

ALL_LAYERS=("${GREEN_LAYERS[@]}" "${URBAN_RULES_LAYERS[@]}")

echo "Proyecto: $PROJECT_DIR"
echo "Base de datos: $DB_NAME"
echo "GeoServer: $GEOSERVER_URL"
echo "Workspace: $WORKSPACE"
echo "Datastore: $DATASTORE"
echo ""

echo "======================================"
echo " Verificando herramientas"
echo "======================================"

for CMD in psql curl; do
  if ! command -v "$CMD" >/dev/null 2>&1; then
    echo "ERROR: No se encontró $CMD"
    unset PGPASSWORD
    exit 1
  fi
done

echo "Herramientas OK."
echo ""

echo "======================================"
echo " Verificando PostgreSQL"
echo "======================================"

psql \
  -h "$DB_HOST" \
  -p "$DB_PORT" \
  -U "$DB_USER" \
  -d "$DB_NAME" \
  -v ON_ERROR_STOP=1 \
  -c "CREATE SCHEMA IF NOT EXISTS analysis;" \
  -c "SELECT 'PostgreSQL OK' AS status;"

echo ""
echo "Verificando que exista analysis.green_areas..."

GREEN_EXISTS=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT to_regclass('analysis.green_areas');")

if [ "$GREEN_EXISTS" != "analysis.green_areas" ]; then
  echo "ERROR: No existe analysis.green_areas."
  echo ""
  echo "Primero importá la capa WFS YLRE_Viheralue_alue desde QGIS como:"
  echo "schema: analysis"
  echo "table: green_areas"
  echo "geometry column: geom"
  echo "target SRID: EPSG:4326"
  echo ""
  unset PGPASSWORD
  exit 1
fi

psql \
  -h "$DB_HOST" \
  -p "$DB_PORT" \
  -U "$DB_USER" \
  -d "$DB_NAME" \
  -c "SELECT COUNT(*) AS green_areas FROM analysis.green_areas;"

echo ""

echo "======================================"
echo " Ejecutando SQL"
echo "======================================"

for SQL_FILE in "${SQL_FILES[@]}"; do
  if [ ! -f "$SQL_FILE" ]; then
    echo "ERROR: No existe el archivo:"
    echo "$SQL_FILE"
    unset PGPASSWORD
    exit 1
  fi

  echo ""
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
done

echo ""

echo "======================================"
echo " Verificando vistas creadas"
echo "======================================"

psql \
  -h "$DB_HOST" \
  -p "$DB_PORT" \
  -U "$DB_USER" \
  -d "$DB_NAME" \
  -c "
    SELECT table_schema, table_name
    FROM information_schema.tables
    WHERE table_schema = 'analysis'
    ORDER BY table_name;
  "

echo ""
echo "Resumen espacios verdes + edificios altos:"

psql \
  -h "$DB_HOST" \
  -p "$DB_PORT" \
  -U "$DB_USER" \
  -d "$DB_NAME" \
  -c "
    SELECT
      COUNT(*) AS high_buildings_near_green,
      ROUND(AVG(height_m)::numeric, 2) AS avg_height_m,
      ROUND(AVG(distance_to_green_m)::numeric, 2) AS avg_distance_to_green_m
    FROM analysis.high_buildings_near_green_points;
  "

echo ""
echo "Resumen reglas urbanas:"

psql \
  -h "$DB_HOST" \
  -p "$DB_PORT" \
  -U "$DB_USER" \
  -d "$DB_NAME" \
  -c "SELECT * FROM analysis.urban_rules_summary;"

echo ""

echo "======================================"
echo " Verificando GeoServer"
echo "======================================"

if ! curl -s "$GEOSERVER_URL" > /dev/null; then
  echo "ERROR: GeoServer no está corriendo en:"
  echo "$GEOSERVER_URL"
  echo ""
  echo "Levantalo con:"
  echo "./start_server.sh"
  echo ""
  unset PGPASSWORD
  exit 1
fi

echo "GeoServer está corriendo."
echo ""

echo "======================================"
echo " Verificando workspace"
echo "======================================"

WORKSPACE_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  -u "$GEOSERVER_USER:$GEOSERVER_PASSWORD" \
  "$GEOSERVER_URL/rest/workspaces/$WORKSPACE.json")

if [ "$WORKSPACE_STATUS" = "200" ]; then
  echo "Workspace '$WORKSPACE' existe."
else
  echo "Workspace '$WORKSPACE' no existe. Creándolo..."

  curl -s -u "$GEOSERVER_USER:$GEOSERVER_PASSWORD" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "{\"workspace\":{\"name\":\"$WORKSPACE\"}}" \
    "$GEOSERVER_URL/rest/workspaces"

  echo "Workspace creado."
fi

echo ""

echo "======================================"
echo " Verificando datastore"
echo "======================================"

DATASTORE_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  -u "$GEOSERVER_USER:$GEOSERVER_PASSWORD" \
  "$GEOSERVER_URL/rest/workspaces/$WORKSPACE/datastores/$DATASTORE.json")

if [ "$DATASTORE_STATUS" != "200" ]; then
  echo "ERROR: No existe el datastore '$DATASTORE' en GeoServer."
  echo ""
  echo "Crealo una vez manualmente:"
  echo "GeoServer → Stores → Add new Store → PostGIS"
  echo ""
  echo "Config:"
  echo "Workspace: $WORKSPACE"
  echo "Data Store Name: $DATASTORE"
  echo "host: $DB_HOST"
  echo "port: $DB_PORT"
  echo "database: $DB_NAME"
  echo "schema: analysis"
  echo "user: $DB_USER"
  echo "password: vacío si no tenés"
  echo ""
  echo "Después volvés a ejecutar este script."
  unset PGPASSWORD
  exit 1
fi

echo "Datastore '$DATASTORE' existe."
echo ""

echo "======================================"
echo " Publicando capas"
echo "======================================"

publish_layer() {
  local LAYER_NAME="$1"

  echo "Procesando capa: $LAYER_NAME"

  LAYER_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -u "$GEOSERVER_USER:$GEOSERVER_PASSWORD" \
    "$GEOSERVER_URL/rest/workspaces/$WORKSPACE/datastores/$DATASTORE/featuretypes/$LAYER_NAME.json")

  if [ "$LAYER_STATUS" = "200" ]; then
    echo "  Ya publicada. Se saltea."
    echo ""
    return
  fi

  curl -s -u "$GEOSERVER_USER:$GEOSERVER_PASSWORD" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "{
      \"featureType\": {
        \"name\": \"$LAYER_NAME\",
        \"nativeName\": \"$LAYER_NAME\",
        \"title\": \"$LAYER_NAME\",
        \"srs\": \"EPSG:4326\",
        \"enabled\": true
      }
    }" \
    "$GEOSERVER_URL/rest/workspaces/$WORKSPACE/datastores/$DATASTORE/featuretypes" >/dev/null

  echo "  Publicada."
  echo ""
}

for LAYER in "${ALL_LAYERS[@]}"; do
  publish_layer "$LAYER"
done

echo "======================================"
echo " Recargando GeoServer"
echo "======================================"

curl -s -u "$GEOSERVER_USER:$GEOSERVER_PASSWORD" \
  -X POST \
  "$GEOSERVER_URL/rest/reload" >/dev/null

unset PGPASSWORD

echo ""
echo "======================================"
echo " Proceso terminado"
echo "======================================"
echo ""
echo "Capas publicadas."
echo ""
echo "Probá:"
echo "$GEOSERVER_URL/$WORKSPACE/ows?service=WFS&version=1.0.0&request=GetFeature&typeName=$WORKSPACE:high_buildings_near_green_points&outputFormat=application/json"
echo ""
echo "$GEOSERVER_URL/$WORKSPACE/ows?service=WFS&version=1.0.0&request=GetFeature&typeName=$WORKSPACE:combined_urban_rules_mat&outputFormat=application/json"
echo ""
echo "Visor:"
echo "http://localhost:8002"