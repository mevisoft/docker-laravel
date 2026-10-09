# Imagen genérica de deploy para Laravel

Una sola imagen Docker que clona tu proyecto Laravel desde GitHub al arrancar y
lo sirve con FrankenPHP, más el planificador y un worker de colas.

La imagen no contiene código de aplicación: sirve para cualquier proyecto
Laravel.

## Uso

```bash
cp .env.example .env
echo "base64:$(openssl rand -base64 32)"   # pega el resultado en APP_KEY
# edita GIT_REPO, GITHUB_PAT (si es privado) e IMAGE
docker compose up -d
```

Servicios: `init` (clona e instala, corre una vez), `app` (FrankenPHP en `APP_PORT`),
`schedule` (`schedule:work`), `queue` (`queue:work`).

Escalar workers: `docker compose up -d --scale queue=3`

## Configuración

Todas las variables están documentadas en `.env.example`. Las principales:

| Variable | Qué hace |
|---|---|
| `GIT_REPO` | `owner/repo` o URL completa. Obligatoria |
| `GITHUB_PAT` | Repositorios privados, y también dependencias privadas de Composer y de GitHub Packages (npm/pnpm/yarn) |
| `REDEPLOY_STRATEGY` | `update` actualiza `/app` con `git fetch` + `reset --hard` (borra lo eliminado del repo y conserva `vendor`, `node_modules` y `public/build`); `fresh` borra además todo lo ignorado y reinstala |
| `BUILD_ASSETS` | `true` compila los assets con el gestor que indique tu lockfile (pnpm, yarn o npm) |
| `RUN_MIGRATIONS` | `true` corre `php artisan migrate --force` |
| `APP_ENV` | `production` instala sin dev-dependencies y cachea config |

**El `.env` lo leen Compose y Laravel a la vez:** sin comillas por defecto, y
nunca `#` a mitad de línea. Un valor que contenga espacios (como `QUEUE_OPTS`)
sí debe ir entrecomillado: el parser dotenv de Laravel rechaza espacios sin
comillas, y Compose las retira antes de pasar la variable al contenedor.

### Producción: comportamiento a tener en cuenta

- **Init fallido:** si el despliegue falla tras poner la app en mantenimiento, el
  init la vuelve a levantar. `KEEP_DOWN_ON_FAIL=true` la deja en mantenimiento.
- **`GITHUB_PAT` solo llega al servicio `init`**; `app`, `queue` y `schedule` lo
  reciben vacío.
- **Límite de subida:** `PHP_POST_MAX_SIZE` fija también el `max_size` de Caddy
  (salvo que definas `CADDY_MAX_SIZE`); sube `PHP_UPLOAD_MAX_FILESIZE` y
  `PHP_POST_MAX_SIZE` juntos.
- **Apache:** `APACHE_MAX_REQUEST_WORKERS` (25) limita los procesos prefork;
  calcúlalo como RAM disponible / `PHP_MEMORY_LIMIT`.
- **Queue:** `stop_grace_period` (120s) debe ser mayor que el `--timeout` de `QUEUE_OPTS`.
- **OPcache** mantiene `validate_timestamps=1`: el init cambia el código sin
  reiniciar `app`. No lo pongas a 0 sin reiniciar `app` tras cada despliegue.
- **Node:** `--build-arg NODE_MAJOR=24` cambia la versión (22 por defecto).
- **ffmpeg, ffprobe y node** vienen en la imagen (ffmpeg fijado por digest).
- **yt-dlp:** `YTDLP_VERSION=2026.08.19` (o `latest`) en el `.env` lo instala el
  `init` en el volumen `app_bin`; cambiar la variable y redesplegar lo actualiza
  sin rebuild. El hash se verifica contra el `SHA2-256SUMS` de ese release. Vacio,
  no se instala. La imagen ya trae `/etc/yt-dlp.conf` con `--js-runtimes node`.
- **Binarios extra:** `EXTRA_TOOLS="nombre|https://url|sha256,..."` los descarga
  el `init` al volumen `app_bin`, que `app`, `queue` y `schedule` montan de solo
  lectura y va en el `PATH`. El sha256 es obligatorio y un hash que no coincide
  aborta el init; solo HTTPS.
- Las URLs `git@...` no funcionan (la imagen no trae cliente SSH ni claves): usa HTTPS + PAT.

## Base de datos

Por defecto SQLite en `/data/database.sqlite`, un volumen separado del código,
para que `REDEPLOY_STRATEGY=fresh` no se lleve tus datos por delante. Para usar
MySQL o PostgreSQL, cambia `DB_CONNECTION` y apunta `DB_HOST` a un servidor
externo: este compose no levanta bases de datos.

## HTTPS

FrankenPHP escucha HTTP plano en el puerto 3000. Pon Nginx, Traefik o Cloudflare
delante para el TLS, y configura `TrustProxies` en tu aplicación.

La configuración del servidor vive en el `Caddyfile` del repositorio, que se
copia a `/etc/frankenphp/Caddyfile` dentro de la imagen: trae compresión
(zstd/br/gzip), un límite de tamaño de petición ajustable con `CADDY_MAX_SIZE`
y `auto_https off`, porque el TLS lo resuelve el proxy de delante. `SERVER_NAME`
vale `:3000` por defecto; si lo cambias, ajusta también el puerto del compose.

## Publicar la imagen

Configura `REGISTRY`, `IMAGE_NAME` y `TAG` en el `.env`, y:

```bash
./build.sh                    # construye en local con el TAG del .env
./build.sh v1.2.0             # construye en local con un tag concreto
PUSH=true ./build.sh v1.2.0   # publica, preguntando antes
PUSH=true YES=1 ./build.sh    # publica sin preguntar (scripts, CI)
```

**Publicar no es el comportamiento por defecto.** Subir una imagen a un registry
es irreversible en la práctica, así que hay que pedirlo con `PUSH=true` y
confirmarlo. Sin terminal donde preguntar, el script aborta salvo que pases
`YES=1`.

Funciona igual con GHCR (`REGISTRY=ghcr.io`) y Docker Hub
(`REGISTRY=docker.io`); haz `docker login` al registry antes.

## Publicar desde GitHub Actions

El workflow manual `.github/workflows/build-publish.yml` (Actions → *Build & publish image* → Run workflow) construye y publica en `ghcr.io/<owner>/<repo>`:

| Input | Valores |
|---|---|
| `tag` | obligatorio, p. ej. `v1.2.0` (con `apache` queda `v1.2.0-apache`) |
| `variant` | `frankenphp` / `apache` |
| `php_version` | `8.3` / `8.4` / `8.5` |
| `node_major` | `22` / `24` |
| `platforms` | `linux/amd64`, `linux/arm64` o `both` |

Con `both` cada arquitectura se construye en su runner nativo (amd64 y arm64, sin QEMU) y un job final une ambas en un único tag multi-arch. Los runners arm64 son gratuitos solo en repos públicos. Desde la CLI:

```bash
gh workflow run build-publish.yml -f tag=v1.2.0 -f variant=apache -f php_version=8.4 -f node_major=22 -f platforms=both
```

Localmente, `build.sh` acepta `PHP_VERSION` y `NODE_MAJOR` como variables de entorno.

## Tests

```bash
./tests/test_entrypoint.sh   # funciones del entrypoint, sin Docker, rápido
./smoke-test.sh              # end-to-end contra laravel/laravel, varios minutos
```

`smoke-test.sh` acepta `SMOKE_REPO` y `SMOKE_BRANCH` para apuntar a otro
proyecto en lugar del esqueleto oficial:

```bash
SMOKE_REPO=LaravelDaily/Laravel-13-Teams-Demo SMOKE_BRANCH=main ./smoke-test.sh
```

Por defecto usa `laravel/laravel` (rama `13.x`), que no trae
`package-lock.json` ni `composer.lock` y ejercita la rama `npm install` del
`init`. `LaravelDaily/Laravel-13-Teams-Demo` es un proyecto real que sí
comitea ambos lockfiles y ejercita la rama `npm ci`.
