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

echo "init (produccion, fresh):"
WORK="$(mktemp -d)"
export STUB_LOG="$WORK/log"
: > "$STUB_LOG"
mkdir -p "$WORK/app"
echo '{}' > "$WORK/app/package-lock.json"
touch "$WORK/app/.env"
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
grep -q "npm ci" <<< "$LOG"
assert_eq "con package-lock.json usa npm ci" "0" "$?"
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
grep "^chown" <<< "$LOG" | grep -q -- "$WORK/app/.env"
assert_eq "chown no toca el .env montado" "1" "$?"
grep "^chown" <<< "$LOG" | grep -q -- "$WORK/app/package-lock.json"
assert_eq "chown si toca otros archivos de app" "0" "$?"
echo "init (sin GITHUB_PAT definida, repo publico):"
: > "$STUB_LOG"
env PATH="$PWD/tests/stubs:$PATH" \
    APP_DIR="$WORK/app-nopat" DATA_DIR="$WORK/data-nopat" \
    GIT_REPO=acme/shop APP_KEY=base64:x APP_ENV=production \
    BUILD_ASSETS=false RUN_MIGRATIONS=false \
    ./entrypoint.sh init >/dev/null 2>&1
assert_eq "init no muere por set -u sin GITHUB_PAT" "0" "$?"
grep -q "composer config --global --auth" "$STUB_LOG"
assert_eq "sin PAT no escribe credencial vacia en el auth.json" "1" "$?"

echo "init (sin package-lock.json):"
: > "$STUB_LOG"
mkdir -p "$WORK/app-nolock"
env PATH="$PWD/tests/stubs:$PATH" \
    APP_DIR="$WORK/app-nolock" DATA_DIR="$WORK/data-nolock" \
    GIT_REPO=acme/shop APP_KEY=base64:x APP_ENV=production \
    BUILD_ASSETS=true RUN_MIGRATIONS=false \
    ./entrypoint.sh init >/dev/null 2>&1
LOG="$(cat "$STUB_LOG")"
grep -q "npm install" <<< "$LOG"
assert_eq "sin package-lock.json usa npm install" "0" "$?"
grep -q "npm ci" <<< "$LOG"
assert_eq "sin package-lock.json no usa npm ci" "1" "$?"

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

echo "init (git clone falla, no debe dejar el PAT en /tmp/repo):"
REPO_BACKUP=""
if [ -e /tmp/repo ]; then
  REPO_BACKUP="$(mktemp -d)"
  mv /tmp/repo "$REPO_BACKUP/repo"
fi
: > "$STUB_LOG"
env PATH="$PWD/tests/stubs-failgit:$PWD/tests/stubs:$PATH" \
    APP_DIR="$WORK/app3" DATA_DIR="$WORK/data3" \
    GIT_REPO=acme/shop GIT_BRANCH=main GITHUB_PAT=ghp_xxx \
    APP_KEY=base64:x \
    ./entrypoint.sh init >/dev/null 2>&1
assert_eq "init termina mal si git clone falla" "1" "$?"
assert_eq "/tmp/repo no sobrevive a un clone fallido" "1" \
  "$([ -e /tmp/repo ] && echo 0 || echo 1)"
if [ -n "$REPO_BACKUP" ]; then
  rm -rf /tmp/repo
  mv "$REPO_BACKUP/repo" /tmp/repo
  rm -rf "$REPO_BACKUP"
fi

echo "dispatch de roles:"
: > "$STUB_LOG"
env PATH="$PWD/tests/stubs:$PATH" APP_DIR="$WORK/app" \
    ./entrypoint.sh app >/dev/null 2>&1
assert_eq "el rol app sirve con frankenphp directamente" \
  "frankenphp php-server --root public --listen :8000 --access-log" \
  "$(cat "$STUB_LOG")"
grep -qi "octane" "$STUB_LOG"
assert_eq "el rol app no arranca octane" "1" "$?"

for role in schedule queue; do
  : > "$STUB_LOG"
  env PATH="$PWD/tests/stubs:$PATH" APP_DIR="$WORK/app" \
      QUEUE_OPTS="--tries=3" \
      ./entrypoint.sh "$role" >/dev/null 2>&1
  grep -q "php artisan" "$STUB_LOG"
  assert_eq "el rol $role lanza artisan" "0" "$?"
done
: > "$STUB_LOG"
env PATH="$PWD/tests/stubs:$PATH" ./entrypoint.sh php -v >/dev/null 2>&1
assert_eq "comando libre se ejecuta tal cual" "php -v" "$(cat "$STUB_LOG")"

rm -rf "$WORK"

exit $FAILED
