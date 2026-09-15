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

  echo "==> composer (APP_ENV=${APP_ENV:-production})"
  if [ "${APP_ENV:-production}" = "production" ]; then
    composer install --no-dev --optimize-autoloader --no-interaction --prefer-dist
  else
    composer install --no-interaction
  fi

  if [ "${BUILD_ASSETS:-true}" = "true" ]; then
    echo "==> compilando assets"
    npm ci
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

  chown -R app:app "$APP_DIR" "$DATA_DIR"
  echo "==> init completado"
}

main() {
  case "${1:-}" in
    init)
      do_init
      ;;
    app)
      cd "$APP_DIR"
      exec php artisan octane:start --server=frankenphp \
        --host=0.0.0.0 --port=8000 \
        --workers="${OCTANE_WORKERS:-auto}" \
        --max-requests="${OCTANE_MAX_REQUESTS:-500}"
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
