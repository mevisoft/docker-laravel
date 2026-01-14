#!/bin/sh
set -e

# Función para imprimir mensajes con fecha
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

log "🚀 Iniciando contenedor..."

exec "$@"
