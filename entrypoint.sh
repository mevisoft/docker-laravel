#!/usr/bin/env bash
set -euo pipefail

repo_url() {
  local repo="$1" pat="${2:-}" path
  case "$repo" in
    git@*)                 printf '%s\n' "$repo"; return 0 ;;
    https://github.com/*)  path="${repo#https://github.com/}" ;;
    https://*|http://*)    printf '%s\n' "$repo"; return 0 ;;
    *)                     path="$repo" ;;
  esac
  path="${path%.git}"
  if [ -n "$pat" ]; then
    printf 'https://x-access-token:%s@github.com/%s.git\n' "$pat" "$path"
  else
    printf 'https://github.com/%s.git\n' "$path"
  fi
}

rsync_flags() {
  case "${1:-update}" in
    fresh) printf '%s\n' "--delete" ;;
    *)     printf '' ;;
  esac
}

validate_env() {
  local ok=0
  if [ -z "${GIT_REPO:-}" ]; then
    echo "ERROR: falta GIT_REPO (owner/repo o URL completa)" >&2
    ok=1
  fi
  if [ -z "${APP_KEY:-}" ]; then
    echo "ERROR: falta APP_KEY. Genera una con:" >&2
    echo '       echo "base64:$(openssl rand -base64 32)"' >&2
    ok=1
  fi
  return $ok
}

APP_DIR="${APP_DIR:-/app}"
DATA_DIR="${DATA_DIR:-/data}"

do_init() {
  validate_env

  local url flags tmp
  url="$(repo_url "$GIT_REPO" "${GITHUB_PAT:-}")"
  flags="$(rsync_flags "${REDEPLOY_STRATEGY:-update}")"
  tmp=/tmp/repo

  echo "==> clonando ${GIT_REPO} (${GIT_BRANCH:-main})"
  rm -rf "$tmp"
  trap 'rm -rf /tmp/repo' EXIT
  git clone --depth 1 --branch "${GIT_BRANCH:-main}" "$url" "$tmp"

  echo "==> sincronizando a ${APP_DIR}"
  mkdir -p "$APP_DIR"
  rsync -a $flags --exclude=/.git --exclude=/storage --exclude=/.env "$tmp/" "$APP_DIR/"
  rm -rf "$tmp"

  mkdir -p "$APP_DIR"/storage/framework/{cache/data,sessions,views} \
           "$APP_DIR"/storage/logs "$APP_DIR"/storage/app/public \
           "$APP_DIR"/bootstrap/cache "$DATA_DIR"

  if [ "${DB_CONNECTION:-sqlite}" = "sqlite" ]; then
    touch "${DB_DATABASE:-$DATA_DIR/database.sqlite}"
  fi

  cd "$APP_DIR"

  # Da el token a Composer para dependencias privadas de GitHub declaradas en
  # el composer.json del proyecto. Con ${GITHUB_PAT:-} y el guard de no-vacio:
  # sin el, set -u mata el init en cuanto la variable no esta definida, y con
  # un PAT vacio escribiriamos una credencial vacia en el auth.json.
  if [ -n "${GITHUB_PAT:-}" ]; then
    composer config --global --auth github-oauth.github.com "$GITHUB_PAT"
  fi

  echo "==> composer (APP_ENV=${APP_ENV:-production})"
  if [ "${APP_ENV:-production}" = "production" ]; then
    composer install --no-dev --optimize-autoloader --no-interaction --prefer-dist
  else
    composer install --no-interaction
  fi


  if [ "${BUILD_ASSETS:-true}" = "true" ]; then
    echo "==> compilando assets"
    # El esqueleto oficial de laravel/laravel no comitea package-lock.json,
    # y npm ci exige que exista. Sin este condicional, init moriria en
    # cualquier repo Laravel que no comitee su lockfile. No lo simplifiques
    # de vuelta a un npm ci unico.
    if [ -f package-lock.json ]; then
      npm ci
    else
      npm install
    fi
    npm run build
  fi

  php artisan storage:link || true

  if [ "${RUN_MIGRATIONS:-false}" = "true" ]; then
    echo "==> migraciones"
    php artisan migrate --force
  fi

  if [ "${APP_ENV:-production}" = "production" ]; then
    echo "==> cacheando configuracion"
    php artisan config:cache
    php artisan route:cache
    php artisan view:cache
  fi

  # El .env lo monta el host como :ro (lleva el PAT), asi que hay que
  # saltarselo: un chown -R sobre /app moriria con "Read-only file system".
  find "$APP_DIR" -path "$APP_DIR/.env" -prune -o -print0 | xargs -0 -r chown app:app
  chown -R app:app "$DATA_DIR"
  echo "==> init completado"
}

main() {
  case "${1:-}" in
    init)
      do_init
      ;;
    app)
      cd "$APP_DIR"
      # FrankenPHP sirve Laravel directamente, sin Octane: php-server usa la
      # directiva php_server de Caddy, que ya resuelve el front controller
      # (try_files hacia public/index.php). Una peticion = un arranque de
      # Laravel, como con FPM pero sin FPM.
      exec frankenphp php-server --root public --listen :8000 --access-log
      ;;
    schedule)
      cd "$APP_DIR"
      exec php artisan schedule:work
      ;;
    queue)
      cd "$APP_DIR"
      exec php artisan queue:work ${QUEUE_OPTS:---tries=3 --timeout=90}
      ;;
    *)
      exec "$@"
      ;;
  esac
}

if [ "${ENTRYPOINT_SOURCED:-}" != "1" ]; then
  main "$@"
fi
