#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

PROJECT=laravel-smoke
ENVF=.env.smoke
PORT=8901
# SMOKE_REPO/SMOKE_BRANCH por defecto apuntan al esqueleto oficial de Laravel
# (sin package-lock.json, ejercita la rama npm install de entrypoint.sh).
# Para ejercitar la rama npm ci contra un proyecto real con lockfiles:
#   SMOKE_REPO=LaravelDaily/Laravel-13-Teams-Demo SMOKE_BRANCH=main ./smoke-test.sh
SMOKE_REPO="${SMOKE_REPO:-laravel/laravel}"
SMOKE_BRANCH="${SMOKE_BRANCH:-13.x}"

cleanup() {
  docker compose --env-file "$ENVF" -p "$PROJECT" down -v --remove-orphans >/dev/null 2>&1 || true
  rm -f "$ENVF"
}
trap cleanup EXIT

echo "==> construyendo imagen de prueba"
docker build -t laravel-deploy:smoke .

cat > "$ENVF" <<EOF
ENV_FILE=$ENVF
IMAGE=laravel-deploy:smoke
GIT_REPO=$SMOKE_REPO
GIT_BRANCH=$SMOKE_BRANCH
GITHUB_PAT=
REDEPLOY_STRATEGY=fresh
BUILD_ASSETS=true
RUN_MIGRATIONS=true
APP_PORT=$PORT
OCTANE_WORKERS=2
OCTANE_MAX_REQUESTS=500
QUEUE_OPTS="--tries=1 --timeout=30"
APP_KEY=base64:$(openssl rand -base64 32)
APP_ENV=production
APP_DEBUG=false
APP_URL=http://localhost:$PORT
DB_CONNECTION=sqlite
DB_DATABASE=/data/database.sqlite
EOF

echo "==> levantando el stack"
docker compose --env-file "$ENVF" -p "$PROJECT" up -d

echo "==> esperando /up (max 180s)"
for i in $(seq 1 90); do
  if curl -fsS "http://localhost:$PORT/up" >/dev/null 2>&1; then
    echo "==> /up responde 200 tras $((i * 2))s aprox"
    break
  fi
  if [ "$i" = 90 ]; then
    echo "FAIL: /up nunca respondio" >&2
    docker compose --env-file "$ENVF" -p "$PROJECT" logs --tail=50 >&2
    exit 1
  fi
  sleep 2
done

echo "==> verificando servicios de fondo"
RUNNING="$(docker compose --env-file "$ENVF" -p "$PROJECT" ps --services --status running | sort | tr '\n' ' ')"
case "$RUNNING" in
  *app*) ;;
  *) echo "FAIL: app no esta running (running: $RUNNING)" >&2; exit 1 ;;
esac
case "$RUNNING" in
  *queue*) ;;
  *) echo "FAIL: queue no esta running (running: $RUNNING)" >&2; exit 1 ;;
esac
case "$RUNNING" in
  *schedule*) ;;
  *) echo "FAIL: schedule no esta running (running: $RUNNING)" >&2; exit 1 ;;
esac

echo "==> verificando que el PAT no quedo en el volumen"
if docker compose --env-file "$ENVF" -p "$PROJECT" run --rm --no-deps -T app test -d /app/.git; then
  echo "FAIL: /app/.git existe, el token podria haberse filtrado" >&2
  exit 1
fi

echo "OK: smoke test superado"
