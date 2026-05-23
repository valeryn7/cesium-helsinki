#!/bin/bash

# Configuracion central de base de datos para scripts del proyecto.
# Se puede sobreescribir con variables de entorno antes de ejecutar.

: "${DB_HOST:=localhost}"
: "${DB_PORT:=5432}"
: "${DB_NAME:=citydb_test}"
: "${DB_SCHEMA:=citydb}"
: "${DB_USER:=valerynater}"
: "${DB_PASSWORD:=}"

export DB_HOST
export DB_PORT
export DB_NAME
export DB_SCHEMA
export DB_USER
export DB_PASSWORD
