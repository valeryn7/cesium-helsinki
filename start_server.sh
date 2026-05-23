#!/bin/bash

set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
CESIUM_PORT=8003
GEOSERVER_DIR="$PROJECT_DIR/geoserver-2.28.3-bin"
GEOSERVER_URL="http://localhost:8080/geoserver"
GEOSERVER_PID=""

cleanup() {
  echo ""
  echo "======================================"
  echo " Cerrando servidores"
  echo "======================================"

  if [ -n "$GEOSERVER_PID" ]; then
    echo "Cerrando GeoServer iniciado por este script..."
    kill "$GEOSERVER_PID" 2>/dev/null || true
  else
    echo "GeoServer ya estaba corriendo antes o no fue iniciado por este script."
  fi

  echo "Cerrando visor Cesium..."
  echo "Listo."
  exit 0
}

trap cleanup INT TERM

cd "$PROJECT_DIR"

echo "======================================"
echo " Levantando proyecto Helsinki 3D"
echo "======================================"
echo ""

echo "Carpeta del proyecto:"
echo "$PROJECT_DIR"
echo ""

# -------------------------------------------------
# 1. Verificar si GeoServer ya está corriendo
# -------------------------------------------------

echo "Verificando GeoServer..."

if curl -s "$GEOSERVER_URL" > /dev/null; then
  echo "GeoServer ya está corriendo en:"
  echo "$GEOSERVER_URL"
  echo ""
  echo "IMPORTANTE: Como GeoServer ya estaba corriendo antes,"
  echo "este script no lo va a cerrar al salir."
else
  echo "GeoServer no está corriendo. Intentando levantarlo..."

  if [ ! -d "$GEOSERVER_DIR" ]; then
    echo "ERROR: No existe la carpeta:"
    echo "$GEOSERVER_DIR"
    exit 1
  fi

  if [ ! -f "$GEOSERVER_DIR/bin/startup.sh" ]; then
    echo "ERROR: No se encontró:"
    echo "$GEOSERVER_DIR/bin/startup.sh"
    exit 1
  fi

  echo "Levantando GeoServer desde:"
  echo "$GEOSERVER_DIR"

  cd "$GEOSERVER_DIR"

  ./bin/startup.sh > "$PROJECT_DIR/geoserver.log" 2>&1 &
  GEOSERVER_PID=$!

  echo "GeoServer PID: $GEOSERVER_PID"
  echo "Esperando que GeoServer inicie..."

  for i in {1..30}; do
    if curl -s "$GEOSERVER_URL" > /dev/null; then
      echo "GeoServer levantado correctamente:"
      echo "$GEOSERVER_URL"
      break
    fi

    echo "Esperando GeoServer... ($i/30)"
    sleep 2
  done

  if ! curl -s "$GEOSERVER_URL" > /dev/null; then
    echo "ERROR: GeoServer no respondió después de esperar."
    echo "Revisá el log:"
    echo "$PROJECT_DIR/geoserver.log"

    if [ -n "$GEOSERVER_PID" ]; then
      kill "$GEOSERVER_PID" 2>/dev/null || true
    fi

    exit 1
  fi
fi

echo ""

# -------------------------------------------------
# 2. Verificar tiles
# -------------------------------------------------

cd "$PROJECT_DIR"

echo "Verificando 3D Tiles..."

if [ ! -f "$PROJECT_DIR/helsinki_tiles/tileset.json" ]; then
  echo "ADVERTENCIA: No se encontró helsinki_tiles/tileset.json"
  echo "Si no aparece el modelo 3D, ejecutá:"
  echo "./generate_tiles.sh"
  echo ""
else
  echo "3D Tiles encontrados:"
  echo "$PROJECT_DIR/helsinki_tiles/tileset.json"
fi

echo ""

# -------------------------------------------------
# 3. Levantar servidor Cesium
# -------------------------------------------------

echo "======================================"
echo " Levantando visor Cesium"
echo "======================================"
echo ""
echo "URL del visor:"
echo "http://localhost:$CESIUM_PORT"
echo ""
echo "GeoServer:"
echo "$GEOSERVER_URL"
echo ""
echo "Para cerrar todo: Ctrl + C"
echo ""

cd "$PROJECT_DIR"
python3 -m http.server "$CESIUM_PORT"