#!/bin/bash

set -e

echo "======================================"
echo " Generando 3D Tiles de Helsinki"
echo "======================================"

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
TILER_DIR="$PROJECT_DIR/citydb-3dtiler-0.9.2"
OUTPUT_DIR="$PROJECT_DIR/helsinki_tiles"
VENV_DIR="$PROJECT_DIR/.venv"
PYTHON_BIN="$VENV_DIR/bin/python"
DB_CONFIG_FILE="$PROJECT_DIR/db_config.sh"

if [ ! -f "$DB_CONFIG_FILE" ]; then
  echo "ERROR: No se encontró el archivo de configuración de base de datos:"
  echo "$DB_CONFIG_FILE"
  exit 1
fi

# Carga DB_HOST, DB_PORT, DB_NAME, DB_SCHEMA, DB_USER, DB_PASSWORD
source "$DB_CONFIG_FILE"

echo "Proyecto: $PROJECT_DIR"
echo "Tiler: $TILER_DIR"
echo "Salida: $OUTPUT_DIR"
echo ""

if [ ! -d "$TILER_DIR" ]; then
  echo "ERROR: No existe la carpeta citydb-3dtiler-0.9.2"
  exit 1
fi

if [ ! -f "$TILER_DIR/citydb-3dtiler.py" ]; then
  echo "ERROR: No se encontró citydb-3dtiler.py dentro de citydb-3dtiler-0.9.2"
  exit 1
fi

if [ ! -f "$TILER_DIR/tiler_app/pg2b3dm" ]; then
  echo "ERROR: No se encontró tiler_app/pg2b3dm"
  echo "Debe estar en:"
  echo "$TILER_DIR/tiler_app/pg2b3dm"
  exit 1
fi

if [ ! -x "$TILER_DIR/tiler_app/pg2b3dm" ]; then
  echo "pg2b3dm no tiene permisos de ejecución. Agregando permisos..."
  chmod +x "$TILER_DIR/tiler_app/pg2b3dm"
fi

if [ ! -f "$PYTHON_BIN" ]; then
  echo "No existe el entorno virtual .venv. Creándolo..."
  python3 -m venv "$VENV_DIR"
fi

echo "Instalando/verificando dependencias Python..."
"$PYTHON_BIN" -m pip install --upgrade pip > /dev/null
"$PYTHON_BIN" -m pip install pyyaml psycopg2-binary > /dev/null

echo "Limpiando salida anterior..."
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

echo "Limpiando salida interna del tiler..."
rm -rf "$TILER_DIR/shared"
mkdir -p "$TILER_DIR/shared"

echo "Ejecutando citydb-3dtiler..."
cd "$TILER_DIR"

"$PYTHON_BIN" citydb-3dtiler.py \
  -H "$DB_HOST" \
  -P "$DB_PORT" \
  -d "$DB_NAME" \
  -S "$DB_SCHEMA" \
  -u "$DB_USER" \
  -p "$DB_PASSWORD" \
  --tiler-app pg2b3dm \
  tile

echo ""
echo "Copiando tiles generados..."

if [ -f "$TILER_DIR/shared/tileset.json" ]; then
  cp -R "$TILER_DIR/shared/"* "$OUTPUT_DIR/"
else
  echo "ERROR: No se encontró shared/tileset.json"
  echo "El tiler no generó los tiles correctamente."
  exit 1
fi

echo ""
echo "Listo. Los 3D Tiles quedaron en:"
echo "$OUTPUT_DIR"