#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

[ -f .env ] || { echo "ERROR: no existe .env (copia .env.example)" >&2; exit 1; }

read_env() {
  local val
  # tr/sed: un .env guardado en Windows deja un \r al final del valor, y el
  # guard de no-vacio no lo detecta: la referencia de imagen sale corrupta y
  # docker falla luego con un error que no apunta a la causa.
  val="$(grep -E "^$1=" .env | tail -1 | cut -d= -f2- | tr -d '\r' | sed 's/[[:space:]]*$//')"
  printf '%s\n' "${val:-${2:-}}"
}

REGISTRY="$(read_env REGISTRY)"
IMAGE_NAME="$(read_env IMAGE_NAME)"
TAG="${1:-$(read_env TAG latest)}"
PLATFORMS="$(read_env PLATFORMS linux/amd64)"

[ -n "$REGISTRY" ]   || { echo "ERROR: falta REGISTRY en .env" >&2; exit 1; }
[ -n "$IMAGE_NAME" ] || { echo "ERROR: falta IMAGE_NAME en .env" >&2; exit 1; }

REF="$REGISTRY/$IMAGE_NAME:$TAG"
echo "==> construyendo $REF ($PLATFORMS)"

if [ "${PUSH:-true}" = "true" ]; then
  docker buildx build --platform "$PLATFORMS" -t "$REF" --push .
  echo "==> publicada: $REF"
else
  docker buildx build --platform "$PLATFORMS" -t "$REF" --load .
  echo "==> construida en local: $REF"
fi
