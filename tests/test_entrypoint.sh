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
