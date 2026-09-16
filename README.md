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
| `GITHUB_PAT` | Solo para repositorios privados |
| `REDEPLOY_STRATEGY` | `update` (rápido) o `fresh` (borra y reinstala) |
| `BUILD_ASSETS` | `true` corre `npm ci && npm run build` |
| `RUN_MIGRATIONS` | `true` corre `php artisan migrate --force` |
| `APP_ENV` | `production` instala sin dev-dependencies y cachea config |

**El `.env` lo leen Compose y Laravel a la vez:** sin comillas por defecto, y
nunca `#` a mitad de línea. Un valor que contenga espacios (como `QUEUE_OPTS`)
sí debe ir entrecomillado: el parser dotenv de Laravel rechaza espacios sin
comillas, y Compose las retira antes de pasar la variable al contenedor.

## Base de datos

Por defecto SQLite en `/data/database.sqlite`, un volumen separado del código,
para que `REDEPLOY_STRATEGY=fresh` no se lleve tus datos por delante. Para usar
MySQL o PostgreSQL, cambia `DB_CONNECTION` y apunta `DB_HOST` a un servidor
externo: este compose no levanta bases de datos.

## HTTPS

FrankenPHP escucha HTTP plano en el puerto 8000. Pon Nginx, Traefik o Cloudflare
delante para el TLS, y configura `TrustProxies` en tu aplicación.

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
