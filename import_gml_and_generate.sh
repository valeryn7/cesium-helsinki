#!/bin/bash

set -e

echo "======================================"
echo " Importar CityGML exportado + generar 3D Tiles"
echo "======================================"
echo ""

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
DB_CONFIG_FILE="$PROJECT_DIR/db_config.sh"

GML_DIR="$PROJECT_DIR/gml"
BUILDINGS_GML="$GML_DIR/export.gml"
TERRAIN_GML="$GML_DIR/export_terrain.gml"
TEXTURES_DIR="$GML_DIR/citygml_textures"

CITYDB_TOOL_DIR="$PROJECT_DIR/citydb-tool-1.3.1"
CITYDB_TOOL="$CITYDB_TOOL_DIR/citydb"

GENERATE_TILES_SCRIPT="$PROJECT_DIR/generate_tiles.sh"

TILER_DIR="$PROJECT_DIR/citydb-3dtiler-0.9.2"
TILER_SHARED_DIR="$TILER_DIR/shared"
OUTPUT_DIR="$PROJECT_DIR/helsinki_tiles"

if [ ! -f "$DB_CONFIG_FILE" ]; then
  echo "ERROR: No se encontró el archivo de configuración de base de datos:"
  echo "$DB_CONFIG_FILE"
  exit 1
fi

# Carga DB_HOST, DB_PORT, DB_NAME, DB_SCHEMA, DB_USER, DB_PASSWORD
source "$DB_CONFIG_FILE"

export CITYDB_PASSWORD="$DB_PASSWORD"
export PGPASSWORD="$DB_PASSWORD"

echo "Proyecto: $PROJECT_DIR"
echo "Carpeta GML: $GML_DIR"
echo "Buildings GML: $BUILDINGS_GML"
echo "Terrain GML: $TERRAIN_GML"
echo "Texturas: $TEXTURES_DIR"
echo "citydb-tool: $CITYDB_TOOL"
echo "Base: $DB_NAME"
echo "Schema: $DB_SCHEMA"
echo "Usuario: $DB_USER"
echo ""

# -------------------------------------------------
# 1. Verificaciones
# -------------------------------------------------

if [ ! -d "$GML_DIR" ]; then
  echo "ERROR: No existe la carpeta:"
  echo "$GML_DIR"
  unset CITYDB_PASSWORD
  unset PGPASSWORD
  exit 1
fi

if [ ! -f "$BUILDINGS_GML" ]; then
  echo "ERROR: No se encontró el archivo principal de edificios:"
  echo "$BUILDINGS_GML"
  echo ""
  echo "La carpeta gml debe contener:"
  echo "gml/export.gml"
  unset CITYDB_PASSWORD
  unset PGPASSWORD
  exit 1
fi

if [ ! -f "$CITYDB_TOOL" ]; then
  echo "ERROR: No se encontró citydb-tool en:"
  echo "$CITYDB_TOOL"
  echo ""
  echo "Revisá que exista:"
  echo "citydb-tool-1.3.1/citydb"
  unset CITYDB_PASSWORD
  unset PGPASSWORD
  exit 1
fi

if [ ! -x "$CITYDB_TOOL" ]; then
  echo "citydb-tool no tiene permisos de ejecución. Agregando permisos..."
  chmod +x "$CITYDB_TOOL"
fi

if [ ! -f "$GENERATE_TILES_SCRIPT" ]; then
  echo "ERROR: No se encontró:"
  echo "$GENERATE_TILES_SCRIPT"
  unset CITYDB_PASSWORD
  unset PGPASSWORD
  exit 1
fi

if [ ! -x "$GENERATE_TILES_SCRIPT" ]; then
  echo "generate_tiles.sh no tiene permisos de ejecución. Agregando permisos..."
  chmod +x "$GENERATE_TILES_SCRIPT"
fi

echo "Archivos principales encontrados correctamente."

if [ -d "$TEXTURES_DIR" ]; then
  echo "Carpeta de texturas encontrada:"
  echo "$TEXTURES_DIR"
else
  echo "ADVERTENCIA: No se encontró citygml_textures/"
  echo "El GML se puede importar igual, pero las texturas podrían no estar disponibles."
fi

if [ -f "$TERRAIN_GML" ]; then
  echo "Archivo de terreno encontrado:"
  echo "$TERRAIN_GML"
else
  echo "ADVERTENCIA: No se encontró export_terrain.gml"
  echo "Se importarán solo los edificios."
fi

echo ""

# -------------------------------------------------
# 2. Verificar citydb-tool
# -------------------------------------------------

echo "======================================"
echo " Verificando citydb-tool"
echo "======================================"
echo ""

"$CITYDB_TOOL" --help > /dev/null

echo "citydb-tool funciona correctamente."
echo ""

# -------------------------------------------------
# 3. Limpiar tiles anteriores
# -------------------------------------------------

echo "======================================"
echo " Limpiando 3D Tiles anteriores"
echo "======================================"
echo ""

echo "Eliminando:"
echo "$OUTPUT_DIR"
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

echo "Eliminando salida interna anterior del tiler:"
echo "$TILER_SHARED_DIR"
rm -rf "$TILER_SHARED_DIR"
mkdir -p "$TILER_SHARED_DIR"

echo "Tiles anteriores eliminados."
echo ""

# -------------------------------------------------
# 4. Limpiar vistas/materialized views generadas por el tiler
# -------------------------------------------------

echo "======================================"
echo " Limpiando vistas viejas del tiler"
echo "======================================"
echo ""

psql \
  -h "$DB_HOST" \
  -p "$DB_PORT" \
  -U "$DB_USER" \
  -d "$DB_NAME" \
  -v ON_ERROR_STOP=1 \
  -c "DROP MATERIALIZED VIEW IF EXISTS $DB_SCHEMA.mv_geometries CASCADE;" \
  -c "DROP VIEW IF EXISTS $DB_SCHEMA.mv_geometries CASCADE;"

echo "Vistas viejas del tiler eliminadas."
echo ""

# -------------------------------------------------
# 5. Limpiar modelo anterior de 3DCityDB
# -------------------------------------------------

echo "======================================"
echo " Limpiando modelo anterior de 3DCityDB"
echo "======================================"
echo ""

yes | "$CITYDB_TOOL" delete \
  -H "$DB_HOST" \
  -P "$DB_PORT" \
  -d "$DB_NAME" \
  -S "$DB_SCHEMA" \
  -u "$DB_USER"

echo ""
echo "Modelo anterior eliminado."
echo ""

# -------------------------------------------------
# 6. Importar edificios
# -------------------------------------------------

echo "======================================"
echo " Importando edificios CityGML"
echo "======================================"
echo ""

"$CITYDB_TOOL" import citygml "$BUILDINGS_GML" \
  -H "$DB_HOST" \
  -P "$DB_PORT" \
  -d "$DB_NAME" \
  -S "$DB_SCHEMA" \
  -u "$DB_USER"

echo ""
echo "Edificios importados correctamente."
echo ""

# -------------------------------------------------
# 7. Importar terreno, si existe
# -------------------------------------------------

if [ -f "$TERRAIN_GML" ]; then
  echo "======================================"
  echo " Importando terreno CityGML"
  echo "======================================"
  echo ""

  "$CITYDB_TOOL" import citygml "$TERRAIN_GML" \
    -H "$DB_HOST" \
    -P "$DB_PORT" \
    -d "$DB_NAME" \
    -S "$DB_SCHEMA" \
    -u "$DB_USER"

  echo ""
  echo "Terreno importado correctamente."
  echo ""
else
  echo "No se importó terreno porque no existe export_terrain.gml."
  echo ""
fi

# -------------------------------------------------
# 8. Regenerar 3D Tiles
# -------------------------------------------------

echo "======================================"
echo " Generando 3D Tiles"
echo "======================================"
echo ""

"$GENERATE_TILES_SCRIPT"

unset CITYDB_PASSWORD
unset PGPASSWORD

echo ""
echo "======================================"
echo " Proceso terminado"
echo "======================================"
echo ""
echo "CityGML de edificios importado desde:"
echo "$BUILDINGS_GML"
echo ""

if [ -f "$TERRAIN_GML" ]; then
  echo "CityGML de terreno importado desde:"
  echo "$TERRAIN_GML"
  echo ""
fi

echo "3D Tiles actualizados en:"
echo "$PROJECT_DIR/helsinki_tiles"
echo ""
echo "Ahora podés levantar el visor con:"
echo "./start_server.sh"
echo ""
echo "Y abrir:"
echo "http://localhost:8002"