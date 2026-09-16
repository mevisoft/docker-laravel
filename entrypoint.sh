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
    # Credenciales para paquetes privados de GitHub Packages (@scope/x con
    # registry npm.pkg.github.com). Sin esto el install muere con 401.
    #
    # Va en $HOME/.npmrc (init corre como root, o sea /root) y NUNCA en
    # /app/.npmrc: /app es un volumen y ahi el token persistiria, que es justo
    # lo que el diseno prohibe. El contenedor init es efimero, asi que el
    # fichero se va con el. npm, pnpm y yarn classic leen todos ~/.npmrc.
    if [ -n "${GITHUB_PAT:-}" ]; then
      printf '//npm.pkg.github.com/:_authToken=%s\n' "$GITHUB_PAT" >> "${HOME:-/root}/.npmrc"
      # yarn 2+ (berry) ignora ~/.npmrc: su equivalente es ~/.yarnrc.yml. Va en
      # el HOME por el mismo motivo, nunca en el .yarnrc.yml del proyecto, que
      # vive en el volumen.
      printf 'npmRegistries:\n  "//npm.pkg.github.com":\n    npmAuthToken: "%s"\n' \
        "$GITHUB_PAT" > "${HOME:-/root}/.yarnrc.yml"
    fi

    # El gestor lo decide el lockfile del proyecto: un Laravel con pnpm o yarn
    # es tan valido como uno con npm, y la imagen dice servir para cualquiera.
    # Ojo con npm ci: exige package-lock.json y aborta sin el, y el esqueleto
    # oficial de laravel/laravel no lo comitea. Por eso el ultimo caso es
    # npm install y no npm ci.
    if [ -f pnpm-lock.yaml ]; then
      pnpm install --frozen-lockfile
      pnpm run build
    elif [ -f yarn.lock ]; then
      # yarn 2+ (berry, reconocible por .yarnrc.yml) renombro --frozen-lockfile
      # a --immutable; yarn classic solo entiende el viejo.
      if [ -f .yarnrc.yml ]; then
        yarn install --immutable
      else
        yarn install --frozen-lockfile
      fi
      yarn run build
    elif [ -f package-lock.json ]; then
      npm ci
      npm run build
    else
      npm install
      npm run build
    fi
  fi

  php artisan storage:link || true

  if [ "${RUN_MIGRATIONS:-false}" = "true" ]; then
    echo "==> migraciones"
    php artisan migrate --force
  fi

  if [ "${APP_ENV:-production}" = "production" ]; then
    echo "==> cacheando configuracion"
    # optimize hace config:cache, route:cache, view:cache y ademas event:cache,
    # asi que llamar a los tres por separado era hacer menos en mas lineas.
    php artisan optimize
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
      # FrankenPHP sirve Laravel directamente, sin Octane, con el Caddyfile
      # que la imagen trae en /etc/frankenphp (no en /app: ahi lo borraria el
      # rsync del init). El Caddyfile resuelve el front controller con
      # php_server + try_files, y anade compresion y limite de tamano de
      # peticion.
      #
      # SERVER_NAME por defecto a :3000 para que cuadren el puerto publicado
      # del compose y el healthcheck. Se puede sobreescribir por .env, pero
      # el Caddyfile trae auto_https off: el TLS lo pone el proxy de delante.
      export SERVER_NAME="${SERVER_NAME:-:3000}"
      exec frankenphp run --config /etc/frankenphp/Caddyfile
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
