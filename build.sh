#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

[ -f .env ] || { echo "ERROR: no existe .env (copia .env.example)" >&2; exit 1; }

read_env() {
  local val
  # tr/sed: un .env guardado en Windows deja un \r al final del valor, y el
  # guard de no-vacio no lo detecta: la referencia de imagen sale corrupta y
  # docker falla luego con un error que no apunta a la causa.
  val="$(grep -E "^$1=" .env | tail -1 | cut -d= -f2- | tr -d '\r' | sed -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/")"
  printf '%s\n' "${val:-${2:-}}"
}

REGISTRY="$(read_env REGISTRY)"
IMAGE_NAME="$(read_env IMAGE_NAME)"
TAG="${1:-$(read_env TAG latest)}"
PLATFORMS="$(read_env PLATFORMS linux/amd64)"

[ -n "$REGISTRY" ]   || { echo "ERROR: falta REGISTRY en .env" >&2; exit 1; }
[ -n "$IMAGE_NAME" ] || { echo "ERROR: falta IMAGE_NAME en .env" >&2; exit 1; }

# VARIANT=apache ./build.sh -> imagen php:apache, etiquetada <tag>-apache.
VARIANT="${VARIANT:-frankenphp}"
[ "$VARIANT" = "frankenphp" ] && SUFFIX="" || SUFFIX="-$VARIANT"
# PHP_VERSION / NODE_MAJOR opcionales, p. ej. PHP_VERSION=8.3 NODE_MAJOR=24 ./build.sh
BUILD_ARGS=""
[ -n "${PHP_VERSION:-}" ] && BUILD_ARGS="$BUILD_ARGS --build-arg PHP_VERSION=$PHP_VERSION"
[ -n "${NODE_MAJOR:-}" ] && BUILD_ARGS="$BUILD_ARGS --build-arg NODE_MAJOR=$NODE_MAJOR"
REF="$REGISTRY/$IMAGE_NAME:$TAG$SUFFIX"
echo "==> construyendo $REF ($PLATFORMS)"

# Publicar NO es el default: subir una imagen a un registry es irreversible en la
# practica (queda cacheada y replicada aunque luego la borres), asi que tiene que
# pedirse a proposito. Sin PUSH=true esto solo construye en local.
if [ "${PUSH:-false}" = "true" ]; then
  if [ "${YES:-}" != "1" ]; then
    if [ -t 0 ]; then
      printf '==> se va a PUBLICAR %s en %s. Continuar? [y/N] ' "$REF" "$REGISTRY"
      read -r respuesta
      case "$respuesta" in
        y|Y|s|S) ;;
        *) echo "cancelado, no se ha publicado nada" >&2; exit 1 ;;
      esac
    else
      # Sin terminal no hay a quien preguntar: abortar antes que publicar a ciegas.
      echo "ERROR: publicar sin terminal requiere YES=1 (PUSH=true YES=1 ./build.sh)" >&2
      exit 1
    fi
  fi
  docker buildx build --pull --platform "$PLATFORMS" --build-arg VARIANT="$VARIANT" $BUILD_ARGS \
    --provenance=mode=max --sbom=true -t "$REF" --push .
  echo "==> publicada: $REF"
else
  # --load solo admite una plataforma: con varias hay que publicar.
  case "$PLATFORMS" in
    *,*) echo "ERROR: PLATFORMS multiple ($PLATFORMS) no se puede cargar en local; usa PUSH=true o una sola plataforma" >&2; exit 1 ;;
  esac
  docker buildx build --pull --platform "$PLATFORMS" --build-arg VARIANT="$VARIANT" $BUILD_ARGS -t "$REF" --load .
  echo "==> construida en local: $REF"
fi
