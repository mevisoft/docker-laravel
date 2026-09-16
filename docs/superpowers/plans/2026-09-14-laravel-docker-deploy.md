# Imagen genérica de deploy para Laravel — Plan de Implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **NOTA (2026-09-15):** este plan se ejecutó y completó tal como está escrito,
> con Octane. Después, por decisión del usuario, **se eliminó Octane**: el rol
> `app` pasó a servir con `frankenphp php-server` directamente. Las referencias
> a Octane, `INSTALL_OCTANE`, `OCTANE_WORKERS` y `OCTANE_MAX_REQUESTS` que
> siguen más abajo describen el estado anterior y se conservan como registro de
> lo ejecutado. El diseño vigente está en el spec.

**Goal:** Construir una imagen Docker genérica que, al arrancar, clona un proyecto Laravel desde GitHub y levanta Octane, el planificador o un worker de colas según el rol que reciba.

**Architecture:** Un `entrypoint.sh` con un `case` de cuatro roles (`init`, `app`, `schedule`, `queue`) más un default que ejecuta cualquier comando. El rol `init` clona a `/tmp/repo` y sincroniza a `/app` con `rsync`, de modo que `REDEPLOY_STRATEGY=fresh` sea literalmente `--delete`. Un `docker-compose.yml` usa la misma imagen cuatro veces cambiando solo `command`.

**Tech Stack:** Bash, Docker, Docker Compose v2, `dunglas/frankenphp:php8.4`, PHP 8.4, Node.js 22, Composer 2, Laravel Octane.

## Global Constraints

- Spec de referencia: `docs/superpowers/specs/2026-09-14-laravel-docker-deploy-design.md`.
- Imagen base exacta: `dunglas/frankenphp:php8.4`.
- Todo script shell **de producción** (`entrypoint.sh`, `build.sh`, `smoke-test.sh`)
  empieza con `#!/usr/bin/env bash` y `set -euo pipefail`. Los tests y los stubs
  quedan exentos de `-e` a propósito, porque la suite necesita seguir corriendo
  cuando un assert falla; cada exención lleva un comentario que lo explica.
- El PAT de GitHub nunca puede escribirse en un volumen: solo existe en `/tmp/repo/.git/config`, borrado en el mismo script.
- Octane y los workers corren como el usuario `app` (uid 1000). Solo `init` se eleva a root.
- Sin Horizon, sin Redis, sin base de datos en el compose, sin TLS, sin CI. Están fuera de alcance.
- Sin frameworks de test. Los tests son scripts bash con `assert_eq`.
- El puerto interno es siempre `8000`. **(Obsoleto: hoy es `3000` y lo sirve
  FrankenPHP, no Octane. Ver la nota de cabecera y el spec.)**
- Los mensajes de commit terminan con las dos líneas de atribución mostradas en cada paso de commit.

---

## File Structure

| Archivo | Responsabilidad |
|---|---|
| `entrypoint.sh` | Funciones puras (`repo_url`, `rsync_flags`, `validate_env`), el rol `init` y el dispatch de roles |
| `tests/test_entrypoint.sh` | Único archivo de tests; cubre funciones puras y el flujo de `init` con stubs |
| `tests/stubs/` | Ejecutables falsos (`git`, `rsync`, `composer`, `npm`, `php`, `chown`) que registran sus argumentos |
| `Dockerfile` | Imagen base + extensiones PHP + Node + Composer + usuario `app` |
| `docker-compose.yml` | Los cuatro servicios y los tres volúmenes |
| `.env.example` | Todas las variables documentadas |
| `build.sh` | `docker buildx build --push` al registry configurado |
| `smoke-test.sh` | Verificación end-to-end contra `laravel/laravel` |
| `README.md` | Uso, generación de `APP_KEY`, advertencias del `.env` |

`entrypoint.sh` se mantiene sourceable: todo lo ejecutable vive en `main`, invocada solo cuando el script se ejecuta directamente. Eso es lo que permite testear sus funciones sin Docker.

---

### Task 1: Funciones puras del entrypoint

Establece el repositorio git y las tres funciones que deciden qué URL clonar, qué flags pasar a `rsync` y si la configuración es válida. Son puras: sin efectos secundarios, testeables sin Docker.

**Files:**
- Create: `entrypoint.sh`
- Create: `tests/test_entrypoint.sh`
- Create: `.gitignore`

**Interfaces:**
- Produces: `repo_url <repo> [pat]` → imprime la URL de clone en stdout. `rsync_flags <strategy>` → imprime `--delete` o cadena vacía. `validate_env` → retorna 0 o imprime error en stderr y retorna 1. Todas se sourcean con `ENTRYPOINT_SOURCED=1 . ./entrypoint.sh`.

- [ ] **Step 1: Inicializar el repositorio**

```bash
cd /Volumes/DiskData/Docker/LaravelDockerDeploy
git init
git branch -M main
printf '.env\n.env.smoke\n' > .gitignore
```

- [ ] **Step 2: Escribir el test que falla**

Crear `tests/test_entrypoint.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."

FAILED=0
assert_eq() {
  if [ "$2" = "$3" ]; then
    echo "  ok: $1"
  else
    echo "  FAIL: $1"
    echo "    esperado: [$2]"
    echo "    obtenido: [$3]"
    FAILED=1
  fi
}

# entrypoint.sh trae set -euo pipefail; al sourcearlo heredamos -e y
# cualquier grep que devuelva 1 a proposito abortaria la suite.
ENTRYPOINT_SOURCED=1 . ./entrypoint.sh
set +e

echo "repo_url:"
assert_eq "owner/repo publico" \
  "https://github.com/acme/shop.git" \
  "$(repo_url acme/shop)"
assert_eq "owner/repo privado inyecta el PAT" \
  "https://x-access-token:ghp_xxx@github.com/acme/shop.git" \
  "$(repo_url acme/shop ghp_xxx)"
assert_eq "URL completa de github con PAT" \
  "https://x-access-token:ghp_xxx@github.com/acme/shop.git" \
  "$(repo_url https://github.com/acme/shop.git ghp_xxx)"
assert_eq "URL ssh se respeta tal cual" \
  "git@github.com:acme/shop.git" \
  "$(repo_url git@github.com:acme/shop.git ghp_xxx)"
assert_eq "host no-github se respeta tal cual" \
  "https://gitlab.com/acme/shop.git" \
  "$(repo_url https://gitlab.com/acme/shop.git)"

echo "rsync_flags:"
assert_eq "fresh borra" "--delete" "$(rsync_flags fresh)"
assert_eq "update conserva" "" "$(rsync_flags update)"
assert_eq "default es update" "" "$(rsync_flags)"

echo "validate_env:"
( GIT_REPO="" APP_KEY=base64:x validate_env ) 2>/dev/null
assert_eq "sin GIT_REPO falla" "1" "$?"
( GIT_REPO=acme/shop APP_KEY="" validate_env ) 2>/dev/null
assert_eq "sin APP_KEY falla" "1" "$?"
( GIT_REPO=acme/shop APP_KEY=base64:x validate_env ) 2>/dev/null
assert_eq "con ambas pasa" "0" "$?"

exit $FAILED
```

```bash
chmod +x tests/test_entrypoint.sh
```

- [ ] **Step 3: Ejecutar el test para verificar que falla**

Run: `./tests/test_entrypoint.sh`
Expected: FAIL — `./entrypoint.sh: No such file or directory`

- [ ] **Step 4: Escribir la implementación mínima**

Crear `entrypoint.sh`:

```bash
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

if [ "${ENTRYPOINT_SOURCED:-}" != "1" ]; then
  echo "main aun no implementada" >&2
  exit 1
fi
```

```bash
chmod +x entrypoint.sh
```

- [ ] **Step 5: Ejecutar el test para verificar que pasa**

Run: `./tests/test_entrypoint.sh`
Expected: PASS — 11 líneas `ok:` y salida 0.

- [ ] **Step 6: Commit**

```bash
git add .gitignore entrypoint.sh tests/test_entrypoint.sh docs/
git commit -m "feat: funciones puras del entrypoint con sus tests

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01SQS88ADbKjzaf1dFqTEcY7"
```

---

### Task 2: Rol `init` y dispatch de roles

Completa `entrypoint.sh` con el bootstrap y el `case` de roles. Se testea sin Docker sustituyendo `git`, `rsync`, `composer`, `npm`, `php` y `chown` por stubs que registran sus argumentos.

Para que sea testeable, `init` no escribe en rutas fijas: usa `APP_DIR` y `DATA_DIR`, que por defecto valen `/app` y `/data`.

**Files:**
- Modify: `entrypoint.sh`
- Modify: `tests/test_entrypoint.sh`
- Create: `tests/stubs/git`, `tests/stubs/rsync`, `tests/stubs/composer`, `tests/stubs/npm`, `tests/stubs/php`, `tests/stubs/chown`

**Interfaces:**
- Consumes: `repo_url`, `rsync_flags`, `validate_env` de la Task 1.
- Produces: `main <rol> [args...]` con los roles `init`, `app`, `schedule`, `queue` y un default que hace `exec "$@"`. Variables `APP_DIR` (default `/app`) y `DATA_DIR` (default `/data`).

- [ ] **Step 1: Crear los stubs**

```bash
mkdir -p tests/stubs
for cmd in git rsync composer npm php chown; do
  cat > "tests/stubs/$cmd" <<STUB
#!/usr/bin/env bash
echo "$cmd \$*" >> "\$STUB_LOG"
exit 0
STUB
  chmod +x "tests/stubs/$cmd"
done
```

Verificar que quedaron bien:

Run: `cat tests/stubs/git`
Expected:
```
#!/usr/bin/env bash
echo "git $*" >> "$STUB_LOG"
exit 0
```

- [ ] **Step 2: Escribir el test que falla**

Añadir al final de `tests/test_entrypoint.sh`, **antes** de la línea `exit $FAILED`:

```bash
echo "init (produccion, fresh):"
WORK="$(mktemp -d)"
export STUB_LOG="$WORK/log"
: > "$STUB_LOG"
env PATH="$PWD/tests/stubs:$PATH" \
    APP_DIR="$WORK/app" DATA_DIR="$WORK/data" \
    GIT_REPO=acme/shop GIT_BRANCH=main GITHUB_PAT=ghp_xxx \
    APP_KEY=base64:x APP_ENV=production \
    REDEPLOY_STRATEGY=fresh BUILD_ASSETS=true RUN_MIGRATIONS=true \
    DB_CONNECTION=sqlite DB_DATABASE="$WORK/data/database.sqlite" \
    ./entrypoint.sh init >/dev/null 2>&1
assert_eq "init termina bien" "0" "$?"

LOG="$(cat "$STUB_LOG")"
grep -q -- "--branch main" <<< "$LOG"
assert_eq "clona la rama configurada" "0" "$?"
grep -q "x-access-token:ghp_xxx" <<< "$LOG"
assert_eq "el clone usa el PAT" "0" "$?"
grep -q -- "rsync .*--delete" <<< "$LOG"
assert_eq "fresh pasa --delete a rsync" "0" "$?"
grep -q -- "--exclude=/.git" <<< "$LOG"
assert_eq "rsync excluye .git" "0" "$?"
grep -q -- "--exclude=/storage" <<< "$LOG"
assert_eq "rsync excluye storage" "0" "$?"
grep -q -- "composer install --no-dev" <<< "$LOG"
assert_eq "produccion instala sin dev" "0" "$?"
grep -q "npm run build" <<< "$LOG"
assert_eq "compila los assets" "0" "$?"
grep -q "migrate --force" <<< "$LOG"
assert_eq "corre migraciones" "0" "$?"
grep -q "config:cache" <<< "$LOG"
assert_eq "produccion cachea config" "0" "$?"
assert_eq "crea storage/framework/views" "0" \
  "$([ -d "$WORK/app/storage/framework/views" ] && echo 0 || echo 1)"
assert_eq "crea el archivo sqlite" "0" \
  "$([ -f "$WORK/data/database.sqlite" ] && echo 0 || echo 1)"
assert_eq "el PAT no queda en app" "" \
  "$(grep -rl ghp_xxx "$WORK/app" 2>/dev/null)"

echo "init (local, update):"
: > "$STUB_LOG"
env PATH="$PWD/tests/stubs:$PATH" \
    APP_DIR="$WORK/app2" DATA_DIR="$WORK/data2" \
    GIT_REPO=acme/shop APP_KEY=base64:x APP_ENV=local \
    REDEPLOY_STRATEGY=update BUILD_ASSETS=false RUN_MIGRATIONS=false \
    ./entrypoint.sh init >/dev/null 2>&1
LOG="$(cat "$STUB_LOG")"
grep -q -- "--delete" <<< "$LOG"
assert_eq "update no borra" "1" "$?"
grep -q "npm run build" <<< "$LOG"
assert_eq "no compila si BUILD_ASSETS=false" "1" "$?"
grep -q "config:cache" <<< "$LOG"
assert_eq "local no cachea" "1" "$?"

echo "dispatch de roles:"
for role in app schedule queue; do
  : > "$STUB_LOG"
  env PATH="$PWD/tests/stubs:$PATH" APP_DIR="$WORK/app" \
      OCTANE_WORKERS=4 OCTANE_MAX_REQUESTS=500 QUEUE_OPTS="--tries=3" \
      ./entrypoint.sh "$role" >/dev/null 2>&1
  grep -q "php artisan" "$STUB_LOG"
  assert_eq "el rol $role lanza artisan" "0" "$?"
done
: > "$STUB_LOG"
env PATH="$PWD/tests/stubs:$PATH" ./entrypoint.sh php -v >/dev/null 2>&1
assert_eq "comando libre se ejecuta tal cual" "php -v" "$(cat "$STUB_LOG")"

rm -rf "$WORK"
```

- [ ] **Step 3: Ejecutar el test para verificar que falla**

Run: `./tests/test_entrypoint.sh`
Expected: FAIL — `main aun no implementada`, con los asserts de `init` y de roles en rojo.

- [ ] **Step 4: Implementar `init` y el dispatch**

En `entrypoint.sh`, reemplazar el bloque final:

```bash
if [ "${ENTRYPOINT_SOURCED:-}" != "1" ]; then
  echo "main aun no implementada" >&2
  exit 1
fi
```

por:

```bash
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
```

- [ ] **Step 5: Ejecutar el test para verificar que pasa**

Run: `./tests/test_entrypoint.sh`
Expected: PASS — todos los asserts en `ok:`, salida 0.

- [ ] **Step 6: Commit**

```bash
git add entrypoint.sh tests/
git commit -m "feat: rol init y dispatch de roles en el entrypoint

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01SQS88ADbKjzaf1dFqTEcY7"
```

---

### Task 3: Dockerfile

Construye la imagen: extensiones PHP, Node 22, Composer 2 y el usuario `app`.

**Files:**
- Create: `Dockerfile`
- Create: `.dockerignore`

**Interfaces:**
- Consumes: `entrypoint.sh` de la Task 2, copiado a `/entrypoint.sh`.
- Produces: imagen con `ENTRYPOINT ["/entrypoint.sh"]`, `WORKDIR /app`, `USER app` (uid 1000), y disponibles `php`, `composer`, `node`, `npm`, `git`, `rsync`, `curl`.

- [ ] **Step 1: Escribir el `.dockerignore`**

```bash
cat > .dockerignore <<'EOF'
.git
.env
.env.smoke
docs/
tests/
smoke-test.sh
build.sh
README.md
EOF
```

- [ ] **Step 2: Escribir el Dockerfile**

```dockerfile
FROM dunglas/frankenphp:php8.4

RUN install-php-extensions \
      pcntl pdo_sqlite pdo_mysql pdo_pgsql bcmath intl zip gd opcache

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git rsync curl unzip ca-certificates gnupg \
 && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/*

COPY --from=composer/composer:2-bin /composer /usr/bin/composer

RUN useradd -u 1000 -m -s /bin/bash app \
 && mkdir -p /app /data \
 && chown app:app /app /data

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /app
USER app
ENTRYPOINT ["/entrypoint.sh"]
```

- [ ] **Step 3: Construir la imagen**

Run: `docker build -t laravel-deploy:test .`
Expected: termina con `naming to docker.io/library/laravel-deploy:test done`.

- [ ] **Step 4: Verificar el contenido de la imagen**

Run:
```bash
docker run --rm laravel-deploy:test php -m | grep -iE '^(pcntl|pdo_sqlite|zend opcache)$'
docker run --rm laravel-deploy:test node --version
docker run --rm laravel-deploy:test composer --version
docker run --rm laravel-deploy:test id -u
docker run --rm laravel-deploy:test rsync --version | head -1
```
Expected: las tres extensiones listadas — OPcache aparece como `Zend OPcache`, que es como PHP nombra ese módulo en `php -m`, no como `opcache` — luego `v22.x.x`, `Composer version 2.x.x`, `1000`, y la versión de rsync. Que `php -m` responda confirma además que el caso default del `case` ejecuta comandos libres.

- [ ] **Step 5: Verificar que falta la configuración obligatoria**

Run: `docker run --rm laravel-deploy:test init`
Expected: FAIL con exit 1 y en stderr `ERROR: falta GIT_REPO` y `ERROR: falta APP_KEY`.

- [ ] **Step 6: Commit**

```bash
git add Dockerfile .dockerignore
git commit -m "feat: Dockerfile sobre frankenphp con node, composer y usuario app

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01SQS88ADbKjzaf1dFqTEcY7"
```

---

### Task 4: `.env.example` y `docker-compose.yml`

Define la configuración y los cuatro servicios. `ENV_FILE` existe para que `smoke-test.sh` pueda usar un `.env` alternativo sin tocar el del usuario.

**Files:**
- Create: `.env.example`
- Create: `docker-compose.yml`

**Interfaces:**
- Consumes: la imagen de la Task 3 y los roles de la Task 2.
- Produces: servicios `init`, `app`, `schedule`, `queue`; volúmenes `app_code`, `app_storage`, `app_data`; variable `ENV_FILE` (default `.env`).

- [ ] **Step 1: Escribir `.env.example`**

```bash
cat > .env.example <<'EOF'
# ---------------------------------------------------------------
# IMPORTANTE: este archivo lo leen Docker Compose y Laravel a la vez.
# No pongas # a mitad de linea. Los valores con espacios SI van
# entrecomillados: el dotenv de Laravel falla ante un espacio sin comillas,
# y Compose las retira antes de pasar la variable al contenedor.
# ---------------------------------------------------------------

# --- Deploy ---
GIT_REPO=acme/mi-proyecto
GIT_BRANCH=main
GITHUB_PAT=
REDEPLOY_STRATEGY=update
BUILD_ASSETS=true
RUN_MIGRATIONS=false
APP_PORT=8000
OCTANE_WORKERS=auto
OCTANE_MAX_REQUESTS=500
QUEUE_OPTS="--tries=3 --timeout=90"
ENV_FILE=.env

# --- Imagen y publicacion ---
IMAGE=ghcr.io/usuario/laravel-deploy:latest
REGISTRY=ghcr.io
IMAGE_NAME=usuario/laravel-deploy
TAG=latest
PLATFORMS=linux/amd64

# --- Laravel ---
# Genera la clave con: echo "base64:$(openssl rand -base64 32)"
APP_KEY=
APP_ENV=production
APP_DEBUG=false
APP_URL=http://localhost:8000
DB_CONNECTION=sqlite
DB_DATABASE=/data/database.sqlite
EOF
```

- [ ] **Step 2: Escribir `docker-compose.yml`**

```yaml
x-app: &app
  image: ${IMAGE}
  env_file: ${ENV_FILE:-.env}
  volumes:
    - app_code:/app
    - app_storage:/app/storage
    - app_data:/data
    - ./${ENV_FILE:-.env}:/app/.env:ro
  restart: unless-stopped

x-needs-init: &needs-init
  depends_on:
    init:
      condition: service_completed_successfully

services:
  init:
    <<: *app
    command: init
    user: "0:0"
    restart: "no"

  app:
    <<: [*app, *needs-init]
    command: app
    ports:
      - "${APP_PORT:-8000}:8000"
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://localhost:8000/up"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s

  schedule:
    <<: [*app, *needs-init]
    command: schedule

  queue:
    <<: [*app, *needs-init]
    command: queue

volumes:
  app_code:
  app_storage:
  app_data:
```

- [ ] **Step 3: Validar el compose**

Run:
```bash
cp .env.example .env
sed -i '' 's|^APP_KEY=|APP_KEY=base64:dGVzdA==|' .env
sed -i '' 's|^IMAGE=.*|IMAGE=laravel-deploy:test|' .env
docker compose config
```
Expected: imprime el YAML resuelto sin errores, con los cuatro servicios, `user: "0:0"` solo en `init`, el bind `/app/.env:ro` en los cuatro y los tres volúmenes declarados.

- [ ] **Step 4: Verificar el orden de arranque**

Run: `docker compose config --services && docker compose config | awk '/^services:/,/^volumes:/' | grep -c service_completed_successfully`
Expected: los cuatro nombres de servicio, y `3` (app, schedule y queue esperan a `init`).
El `awk` acota el conteo al bloque `services:` porque `docker compose config`
conserva los campos de extensión `x-*`, y sin él el ancla `x-needs-init` se
cuenta a sí misma y el total sale 4.

- [ ] **Step 5: Commit**

```bash
git add .env.example docker-compose.yml
git commit -m "feat: compose de cuatro servicios y env de ejemplo

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01SQS88ADbKjzaf1dFqTEcY7"
```

---

### Task 5: `build.sh`

Publica la imagen al registry configurado. Lee solo las cinco variables que necesita, con un parser línea a línea en vez de `source`, porque un valor de Laravel con espacios (`APP_NAME=Mi Tienda`) rompería un `source`.

**Files:**
- Create: `build.sh`

**Interfaces:**
- Consumes: `REGISTRY`, `IMAGE_NAME`, `TAG`, `PLATFORMS` del `.env` de la Task 4.
- Produces: `./build.sh [tag]`; el argumento opcional pisa `TAG`.

- [ ] **Step 1: Escribir `build.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

[ -f .env ] || { echo "ERROR: no existe .env (copia .env.example)" >&2; exit 1; }

read_env() {
  local val
  val="$(grep -E "^$1=" .env | tail -1 | cut -d= -f2-)"
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
```

```bash
chmod +x build.sh
```

- [ ] **Step 2: Verificar que falla sin configuración**

Run:
```bash
mv .env .env.bak && ./build.sh; echo "exit=$?"; mv .env.bak .env
```
Expected: `ERROR: no existe .env (copia .env.example)` y `exit=1`.

- [ ] **Step 3: Verificar el build local sin push**

Run: `PUSH=false ./build.sh v-test`
Expected: construye y termina con `==> construida en local: ghcr.io/usuario/laravel-deploy:v-test`.

- [ ] **Step 4: Verificar que el tag se aplicó**

Run: `docker images --format '{{.Repository}}:{{.Tag}}' | grep v-test`
Expected: `ghcr.io/usuario/laravel-deploy:v-test`

- [ ] **Step 5: Commit**

```bash
git add build.sh
git commit -m "feat: script de build y publicacion al registry

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01SQS88ADbKjzaf1dFqTEcY7"
```

---

### Task 6: `smoke-test.sh` y README

Verificación end-to-end contra `laravel/laravel`, un repositorio público, y la documentación de uso.

**Files:**
- Create: `smoke-test.sh`
- Create: `README.md`

**Interfaces:**
- Consumes: todo lo anterior. Usa `ENV_FILE` de la Task 4 para no tocar el `.env` del usuario.
- Produces: `./smoke-test.sh` con salida 0 si el stack levanta y responde.

- [ ] **Step 1: Escribir `smoke-test.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

PROJECT=laravel-smoke
ENVF=.env.smoke
PORT=8901

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
GIT_REPO=laravel/laravel
GIT_BRANCH=13.x   # rama por defecto real de laravel/laravel
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
    echo "==> /up responde 200 tras ${i}0s aprox"
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
```

```bash
chmod +x smoke-test.sh
```

- [ ] **Step 2: Ejecutar el smoke test**

Run: `./smoke-test.sh`
Expected: termina con `OK: smoke test superado` y salida 0. Tarda varios minutos: clona Laravel, corre `composer install`, `npm ci` y `npm run build`.

Si falla en el clone con `Remote branch 13.x not found`, la rama por defecto de
`laravel/laravel` cambió. Comprobar la actual con
`git ls-remote --symref https://github.com/laravel/laravel HEAD` y ajustar
`GIT_BRANCH` en `smoke-test.sh`.

- [ ] **Step 3: Escribir el README**

```bash
cat > README.md <<'EOF'
# Imagen genérica de deploy para Laravel

Una sola imagen Docker que clona tu proyecto Laravel desde GitHub al arrancar y
levanta Octane (FrankenPHP), el planificador y un worker de colas.

La imagen no contiene código de aplicación: sirve para cualquier proyecto Laravel.

## Uso

```bash
cp .env.example .env
echo "base64:$(openssl rand -base64 32)"   # pega el resultado en APP_KEY
# edita GIT_REPO, GITHUB_PAT (si es privado) e IMAGE
docker compose up -d
```

Servicios: `init` (clona e instala, corre una vez), `app` (Octane en `APP_PORT`),
`schedule` (`schedule:work`), `queue` (`queue:work`).

Escalar workers: `docker compose up -d --scale queue=3`

## Configuración

Todas las variables están documentadas en `.env.example`. Las principales:

| Variable | Qué hace |
|---|---|
| `GIT_REPO` | `owner/repo` o URL completa. Obligatoria |
| `GITHUB_PAT` | Solo para repositorios privados |
| `REDEPLOY_STRATEGY` | `update` (rápido) o `fresh` (borra y reinstala) |
| `BUILD_ASSETS` | `true` corre `npm ci && npm run build` |
| `RUN_MIGRATIONS` | `true` corre `php artisan migrate --force` |
| `APP_ENV` | `production` instala sin dev-dependencies y cachea config |

**El `.env` lo leen Compose y Laravel a la vez:** nunca pongas `#` a mitad de
línea, y entrecomilla los valores que tengan espacios — el dotenv de Laravel
falla ante un espacio sin comillas, y Compose las retira antes de pasar la
variable al contenedor.

## Base de datos

Por defecto SQLite en `/data/database.sqlite`, un volumen separado del código,
para que `REDEPLOY_STRATEGY=fresh` no se lleve tus datos por delante. Para usar
MySQL o PostgreSQL, cambia `DB_CONNECTION` y apunta `DB_HOST` a un servidor
externo: este compose no levanta bases de datos.

## HTTPS

Octane escucha HTTP plano en el puerto 8000. Pon Nginx, Traefik o Cloudflare
delante para el TLS, y configura `TrustProxies` en tu aplicación.

## Publicar la imagen

Configura `REGISTRY`, `IMAGE_NAME` y `TAG` en el `.env`, y:

```bash
./build.sh            # publica con el TAG del .env
./build.sh v1.2.0     # publica con un tag concreto
PUSH=false ./build.sh # solo construye en local
```

Funciona igual con GHCR (`REGISTRY=ghcr.io`) y Docker Hub
(`REGISTRY=docker.io`); haz `docker login` al registry antes.

## Tests

```bash
./tests/test_entrypoint.sh   # funciones del entrypoint, sin Docker, rápido
./smoke-test.sh              # end-to-end contra laravel/laravel, varios minutos
```
EOF
```

- [ ] **Step 4: Verificar que el README no miente sobre el `.env.example`**

Run: `for v in GIT_REPO GITHUB_PAT REDEPLOY_STRATEGY BUILD_ASSETS RUN_MIGRATIONS APP_ENV; do grep -q "^$v=" .env.example || echo "FALTA $v"; done; echo listo`
Expected: solo `listo`, sin líneas `FALTA`.

- [ ] **Step 5: Ejecutar la suite completa**

Run: `./tests/test_entrypoint.sh && ./smoke-test.sh`
Expected: los asserts en `ok:` y `OK: smoke test superado`.

- [ ] **Step 6: Commit**

```bash
git add smoke-test.sh README.md
git commit -m "feat: smoke test end-to-end y documentacion de uso

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01SQS88ADbKjzaf1dFqTEcY7"
```

---

## Cobertura del spec

| Requisito del spec | Tarea |
|---|---|
| `repo_url` con `owner/repo`, URL completa y PAT | 1 |
| `fresh` = `--delete`, un solo camino de código | 1, 2 |
| `--exclude=/.git`, `/storage`, `/.env` | 2 |
| Validación fail-fast de `GIT_REPO` y `APP_KEY` | 1, 3 |
| `APP_ENV` decide el modo de Composer y las cachés | 2 |
| `BUILD_ASSETS`, `RUN_MIGRATIONS` | 2 |
| Roles `app`, `schedule`, `queue` con sus comandos | 2 |
| Imagen base, extensiones, Node, Composer, usuario `app` | 3 |
| Cuatro servicios, tres volúmenes, `service_completed_successfully`, healthcheck `/up` | 4 |
| `init` como root vía `user: "0:0"` | 4 |
| SQLite en volumen `app_data` separado | 2, 4 |
| Advertencia de sintaxis del `.env` compartido | 4, 6 |
| `build.sh` a GHCR o Docker Hub | 5 |
| `smoke-test.sh` contra `laravel/laravel` | 6 |
| El PAT nunca toca un volumen | 2 (unit), 6 (e2e) |
