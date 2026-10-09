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

# Huella de todo lo que puede cambiar el resultado del build: resources entero
# (js, css y vistas Blade que Tailwind escanea), configs de vite/mix/tailwind/postcss
# y package.json con sus lockfiles. Solo ficheros TRACKEADOS (ls-files -s da el
# hash de cada blob): el propio build genera ficheros ignorados en resources/js
# (wayfinder) y con find la huella cambiaria despues de cada build.
assets_hash() {
  { git -C "$1" ls-files -s -- resources 'vite.config.*' \
      webpack.mix.js \
      'tailwind.config.*' 'postcss.config.*' package.json package-lock.json \
      pnpm-lock.yaml yarn.lock 2>/dev/null || true; } | cksum
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

# Init corre como root: todo lo que crea (rsync, vendor, logs de migrate...) es
# root y el app (usuario app) no podria escribirlo. Se llama desde el trap EXIT
# y no al final del init, para que un init fallido a medias tampoco deje
# ficheros root en los volumenes.
# El .env lo monta el host como :ro (lleva el PAT), asi que hay que saltarselo:
# un chown -R sobre /app moriria con "Read-only file system".
fix_perms() {
  find "$APP_DIR" -path "$APP_DIR/.env" -prune -o -print0 2>/dev/null | xargs -0 -r chown app:app
  chown -R app:app "$DATA_DIR"
}

# Salida del init: limpia FETCH_HEAD, arregla permisos y, si el despliegue
# fallo despues de poner la app en mantenimiento, la vuelve a levantar (con el
# codigo/vendor que haya quedado) en vez de dejar un 503 permanente.
# KEEP_DOWN_ON_FAIL=true conserva el mantenimiento a proposito (p. ej. si una
# migracion a medias hace inseguro servir trafico).
on_init_exit() {
  local rc=$?
  rm -f "$APP_DIR/.git/FETCH_HEAD"
  if [ "$rc" -ne 0 ] && [ "${DOWNED:-0}" = "1" ] && [ "${KEEP_DOWN_ON_FAIL:-false}" != "true" ]; then
    echo "==> init fallo (rc=$rc): levantando la app de nuevo" >&2
    (cd "$APP_DIR" && php artisan up) || true
  fi
  fix_perms || true
}

BIN_DIR="${BIN_DIR:-/opt/bin}"

# EXTRA_TOOLS="nombre|https://url|sha256,otro|https://url|sha256": binarios
# sueltos en el volumen app_bin, que app, queue y schedule montan :ro. Los
# instala root y siguen siendo de root: ni el proceso web ni yt-dlp -U pueden
# sustituirlos. Sin sha256 verificado no se instala nada.
install_tool() {
  local name="$1" url="$2" sha="$3" tmp
  # Marca por herramienta: sin cambio de hash no se vuelve a descargar.
  [ "$(cat "$BIN_DIR/.$name.sha256" 2>/dev/null)" = "$sha" ] && return 0
  echo "==> instalando $name"
  tmp="$(mktemp)"
  curl -fsSL --proto '=https' --tlsv1.2 -o "$tmp" "$url"
  if [ "$(sha256sum "$tmp" | cut -d' ' -f1)" != "$sha" ]; then
    echo "ERROR: sha256 de $name no coincide ($url)" >&2
    rm -f "$tmp"; return 1
  fi
  install -m 755 "$tmp" "$BIN_DIR/$name.new"
  rm -f "$tmp"
  mv -f "$BIN_DIR/$name.new" "$BIN_DIR/$name"
  printf '%s\n' "$sha" > "$BIN_DIR/.$name.sha256"
}

# YTDLP_VERSION (tag o latest) instala yt-dlp; el hash sale del SHA2-256SUMS de
# ese release. Cambiar la variable y redesplegar actualiza sin rebuild.
install_tools() {
  [ -n "${EXTRA_TOOLS:-}${YTDLP_VERSION:-}" ] || return 0
  mkdir -p "$BIN_DIR"
  local t name url sha base asset=yt-dlp_linux
  if [ -n "${YTDLP_VERSION:-}" ]; then
    base="https://github.com/yt-dlp/yt-dlp/releases"
    if [ "$YTDLP_VERSION" = latest ]; then base="$base/latest/download"; else base="$base/download/$YTDLP_VERSION"; fi
    [ "$(uname -m)" = aarch64 ] && asset=yt-dlp_linux_aarch64
    sha="$(curl -fsSL --proto '=https' --tlsv1.2 "$base/SHA2-256SUMS" | awk -v a="$asset" '$2==a{print $1}')"
    [ -n "$sha" ] || { echo "ERROR: sin sha256 de yt-dlp en $base" >&2; return 1; }
    install_tool yt-dlp "$base/$asset" "$sha"
  fi
  for t in $(printf '%s' "$EXTRA_TOOLS" | tr ',' ' '); do
    IFS='|' read -r name url sha <<< "$t"
    case "$name" in ''|*[!A-Za-z0-9._-]*|.*) echo "ERROR: nombre invalido en EXTRA_TOOLS: $t" >&2; return 1 ;; esac
    case "$url" in https://*) ;; *) echo "ERROR: EXTRA_TOOLS solo admite https: $t" >&2; return 1 ;; esac
    case "$sha" in *[!0-9a-f]*|'') echo "ERROR: EXTRA_TOOLS exige sha256 hex: $t" >&2; return 1 ;; esac
    [ "${#sha}" = 64 ] || { echo "ERROR: sha256 de $name no tiene 64 caracteres" >&2; return 1; }
    install_tool "$name" "$url" "$sha"
  done
}

do_init() {
  validate_env

  # El .git lo deja chown como app y este init corre como root: git lo trata
  # como propietario ajeno y se niega. Global (no -c) porque tambien lo usa
  # composer, que ejecuta git en /app para detectar la version del proyecto.
  git config --global --add safe.directory "$APP_DIR"

  local url branch clean
  url="$(repo_url "$GIT_REPO" "${GITHUB_PAT:-}")"
  branch="${GIT_BRANCH:-main}"
  # fresh ademas borra lo ignorado (vendor, node_modules, public/build y con
  # ellos public/build); update lo conserva. En ambos, .env (montado :ro)
  # y storage (volumen) quedan fuera.
  clean="-fd"
  [ "${REDEPLOY_STRATEGY:-update}" = "fresh" ] && clean="-fdx"

  # FETCH_HEAD apunta a la URL con el PAT, y APP_DIR es un volumen persistente.
  trap on_init_exit EXIT

  # Sin esto los workers siguen con el codigo viejo y los usuarios ven codigo
  # nuevo con vendor viejo mientras dura el despliegue. || true: en el primer
  # despliegue aun no hay app que poner en mantenimiento.
  if [ -f "$APP_DIR/artisan" ]; then
    (cd "$APP_DIR" && php artisan down --retry=60) && DOWNED=1 || true
  fi

  # /app es un volumen con .env y storage montados, asi que no se puede
  # clonar en ella: se inicializa el repo en sitio y se trae solo el commit
  # de la rama. reset --hard (no pull) para no tener merges ni conflictos, y
  # borra lo que el repo elimino.
  echo "==> sincronizando ${GIT_REPO} (${branch}) en ${APP_DIR}"
  mkdir -p "$APP_DIR"
  g() { git -C "$APP_DIR" "$@"; }
  [ -d "$APP_DIR/.git" ] || g init -q
  g fetch --depth 1 "$url" "$branch"
  g reset -q --hard FETCH_HEAD
  g clean -q $clean -e /.env -e /storage
  echo "==> commit $(g rev-parse --short HEAD)"

  # BUILD_ASSETS=auto compara la huella de las fuentes del build con la que se
  # guardo tras el ultimo build EXITOSO. Asi un build fallido se reintenta.
  # La marca vive en storage (volumen, fuera del clean) y no en public/build:
  # Mix no escribe ahi, y un fichero suelto en public lo borraria git clean.
  # Como fresh ya no se lleva la marca, fresh fuerza la recompilacion.
  marker="$APP_DIR/storage/.assets-hash"
  new_hash="$(assets_hash "$APP_DIR")"
  assets_changed=true
  if [ "${BUILD_ASSETS:-true}" = "auto" ] && [ "${REDEPLOY_STRATEGY:-update}" != "fresh" ] \
     && [ "$(cat "$marker" 2>/dev/null)" = "$new_hash" ]; then
    assets_changed=false
  fi

  mkdir -p "$APP_DIR"/storage/framework/{cache/data,sessions,views} \
           "$APP_DIR"/storage/logs "$APP_DIR"/storage/app/public \
           "$APP_DIR"/bootstrap/cache "$DATA_DIR"

  if [ "${DB_CONNECTION:-sqlite}" = "sqlite" ]; then
    touch "${DB_DATABASE:-$DATA_DIR/database.sqlite}"
  fi

  cd "$APP_DIR"

  # bootstrap/cache sobrevive al rsync (esta protegido) y trae config/rutas del
  # despliegue anterior: composer arrancaria la app con ellas en package:discover,
  # y fuera de production config.php viejo seguiria mandando sobre el .env.
  rm -f bootstrap/cache/*.php

  # Da el token a Composer para dependencias privadas de GitHub declaradas en
  # el composer.json del proyecto. Con ${GITHUB_PAT:-} y el guard de no-vacio:
  # sin el, set -u mata el init en cuanto la variable no esta definida, y con
  # un PAT vacio escribiriamos una credencial vacia en el auth.json.
  if [ -n "${GITHUB_PAT:-}" ]; then
    composer config --global --auth github-oauth.github.com "$GITHUB_PAT"
  fi

  install_tools

  echo "==> composer (APP_ENV=${APP_ENV:-production})"
  if [ "${APP_ENV:-production}" = "production" ]; then
    composer install --no-dev --optimize-autoloader --no-interaction --prefer-dist
  else
    composer install --no-interaction
  fi


  if [ "${BUILD_ASSETS:-true}" = "true" ] || { [ "${BUILD_ASSETS:-true}" = "auto" ] && [ "$assets_changed" = "true" ]; }; then
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
    printf '%s\n' "$new_hash" > "$marker"
  fi

  [ -L public/storage ] || php artisan storage:link || true

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

  # Los workers son procesos largos: sin esto siguen con el codigo viejo.
  # schedule:work no hace falta, lanza un schedule:run nuevo cada minuto.
  php artisan queue:restart || true
  if [ -f config/horizon.php ]; then
    php artisan horizon:terminate || true
  fi
  php artisan up || true

  echo "==> init completado"
}

main() {
  case "${1:-}" in
    init)
      do_init
      ;;
    app)
      cd "$APP_DIR"
      # WEB_SERVER lo fija la imagen (frankenphp | apache). Los comandos
      # init/schedule/queue/horizon son identicos en ambas.
      if [ "${WEB_SERVER:-frankenphp}" = "apache" ]; then
        exec apache2-foreground
      fi
      # FrankenPHP sirve Laravel directamente, sin Octane, con el Caddyfile
      # que la imagen trae en /etc/frankenphp (no en /app: ahi lo borraria el
      # init). SERVER_NAME por defecto a :3000 para que cuadren el puerto
      # publicado del compose y el healthcheck; el Caddyfile trae auto_https
      # off: el TLS lo pone el proxy de delante.
      export SERVER_NAME="${SERVER_NAME:-:3000}"
      # Mismo limite de subida que PHP (K/M/G de PHP son binarios: 16M -> 16MiB).
      if [ -z "${CADDY_MAX_SIZE:-}" ]; then
        case "${PHP_POST_MAX_SIZE:-16M}" in
          *[KkMmGg]) CADDY_MAX_SIZE="${PHP_POST_MAX_SIZE:-16M}iB" ;;
          *)         CADDY_MAX_SIZE="${PHP_POST_MAX_SIZE}" ;;
        esac
        export CADDY_MAX_SIZE
      fi
      exec frankenphp run --config /etc/frankenphp/Caddyfile
      ;;
    schedule)
      cd "$APP_DIR"
      exec php artisan schedule:work
      ;;
    horizon)
      cd "$APP_DIR"
      exec php artisan horizon
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
