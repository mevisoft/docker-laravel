# Imagen genérica de deploy para Laravel (FrankenPHP + Octane)

Fecha: 2026-09-14
Estado: aprobado, pendiente de plan de implementación

## Resumen

Una única imagen Docker, sin código de aplicación dentro, que al arrancar clona un
proyecto Laravel desde GitHub, instala dependencias y levanta uno de tres procesos
según el rol que se le pase: servidor Octane, planificador o worker de colas.

La misma imagen sirve para cualquier proyecto Laravel. Todo se configura por
variables de entorno: repositorio, rama, token de acceso, si compilar assets con
Vite, si correr migraciones y si instalar en modo producción.

## Decisiones tomadas

| Decisión | Elección | Motivo |
|---|---|---|
| Momento del clone | Runtime | Una imagen genérica reutilizable en vez de una imagen por proyecto |
| Código compartido | Volumen `app_code` + servicio `init` | Un solo clone y un solo build para los cuatro servicios; todos en el mismo commit |
| Re-deploy | `REDEPLOY_STRATEGY=update\|fresh` | El usuario decide entre arranque rápido y determinismo |
| Infraestructura | Ninguna | SQLite por defecto; otras bases de datos se configuran por `.env` apuntando a un host externo |
| Publicación | `build.sh` local | Sin dependencia de CI |
| HTTP | Plano en 8000 tras proxy | TLS lo resuelve Nginx/Traefik/Cloudflare delante |
| `.env` | Uno solo, montado read-only | Un único archivo que editar |
| Organización | `entrypoint.sh` con `case $1` | El bootstrap cabe en un archivo; partirlo sería abstracción especulativa |

## Arquitectura

```
LaravelDockerDeploy/
├── Dockerfile
├── entrypoint.sh       # case: init | app | schedule | queue
├── docker-compose.yml
├── build.sh
├── smoke-test.sh
├── .env.example
└── README.md
```

Cuatro servicios, la misma imagen, distinto `command`:

```
init ──(service_completed_successfully)──┬── app       php artisan octane:start
                                         ├── schedule  php artisan schedule:work
                                         └── queue     php artisan queue:work
```

Volúmenes:

| Volumen | Montaje | Contenido |
|---|---|---|
| `app_code` | `/app` | Código clonado, `vendor/`, `node_modules/`, assets compilados |
| `app_storage` | `/app/storage` | Uploads y logs; sobrevive a `fresh` |
| `app_data` | `/data` | `database.sqlite`; fuera del código a propósito |
| bind | `/app/.env` (ro) | El `.env` de la raíz del stack |

`app_storage` se monta sobre un subpath de `app_code`: el montaje más específico
gana, y por eso `rsync` excluye `/storage` y `init` recrea las subcarpetas.

## El clone y la sincronización

```sh
git clone --depth 1 --branch "$GIT_BRANCH" "$(repo_url)" /tmp/repo
[ "$REDEPLOY_STRATEGY" = fresh ] && DEL=--delete || DEL=
rsync -a $DEL --exclude=/.git --exclude=/storage --exclude=/.env /tmp/repo/ /app/
rm -rf /tmp/repo
```

Tres propiedades que salen de esta forma:

- `fresh` es exactamente `--delete`. Un solo camino de código para las dos
  estrategias, no dos ramas que probar por separado.
- `--exclude=/.git` mantiene el PAT fuera del volumen. El token vive solo en
  `/tmp/repo/.git/config`, borrado en el mismo script.
- `--exclude=/storage` preserva uploads y logs entre deploys.

`--depth 1` hace que clonar de nuevo cueste poco, así que no hace falta un camino
separado con `git fetch` para el modo `update`.

`repo_url` acepta `owner/repo` o una URL completa. Con `GITHUB_PAT` presente
construye `https://x-access-token:$GITHUB_PAT@github.com/owner/repo.git`; sin él,
la URL pública.

## Variables de entorno

Un solo `.env` en la raíz: el compose lo consume con `env_file` y lo monta
read-only en `/app/.env`.

### Bloque de deploy

| Variable | Default | Qué hace |
|---|---|---|
| `GIT_REPO` | obligatoria | `owner/repo` o URL completa |
| `GIT_BRANCH` | `main` | Rama o tag |
| `GITHUB_PAT` | vacío | Vacío = repositorio público |
| `REDEPLOY_STRATEGY` | `update` | `fresh` añade `--delete` al rsync |
| `BUILD_ASSETS` | `true` | `npm ci && npm run build` |
| `RUN_MIGRATIONS` | `false` | `php artisan migrate --force` |
| `APP_PORT` | `8000` | Puerto publicado en el host |
| `OCTANE_WORKERS` | `auto` | `--workers` de Octane |
| `OCTANE_MAX_REQUESTS` | `500` | Recicla workers para acotar fugas de memoria |
| `QUEUE_OPTS` | `--tries=3 --timeout=90` | Se pasa tal cual a `queue:work` |
| `IMAGE` | `ghcr.io/USUARIO/laravel-deploy:latest` | Imagen que usan los cuatro servicios |

### Bloque Laravel

El `.env` normal del proyecto: `APP_KEY`, `APP_ENV`, `APP_DEBUG`, `APP_URL`,
`DB_CONNECTION=sqlite`, `DB_DATABASE=/data/database.sqlite` y lo que la aplicación
necesite.

### Reglas

1. **`APP_ENV` decide el modo de Composer.** `production` instala con
   `--no-dev --optimize-autoloader --no-interaction --prefer-dist` y cachea
   config, rutas y vistas. Cualquier otro valor instala normal y no cachea. No se
   añade una variable nueva para algo que `APP_ENV` ya expresa.

2. **`APP_KEY` vacío aborta el `init`.** No se genera automáticamente: el `.env`
   está montado read-only, así que `key:generate` no podría persistirla y se
   generaría una clave distinta en cada arranque, invalidando sesiones y dejando
   ilegible todo lo cifrado. El README documenta
   `echo "base64:$(openssl rand -base64 32)"`, que es exactamente lo que
   `key:generate` produce. No se usa `artisan` porque la imagen no contiene
   Laravel hasta que `init` clona el proyecto.

3. **Sintaxis del `.env` compartido.** Compose y el dotenv de Laravel no parsean
   igual, y la regla correcta es más fina de lo que parece: nunca `#` a mitad de
   línea, y **los valores que contengan espacios van entrecomillados**. El dotenv
   de Laravel aborta ante un espacio sin comillas (`Failed to parse dotenv file.
   Encountered unexpected whitespace`), y ese parseo ocurre durante
   `composer install`, así que un `.env` mal formado tumba el `init` entero antes
   de que exista ningún worker. Compose retira las comillas antes de pasar la
   variable al contenedor — verificado: el valor que llega es idéntico con y sin
   ellas — así que entrecomillar es seguro por ambos lados. En este proyecto el
   único valor afectado es `QUEUE_OPTS`. Advertencia al principio de
   `.env.example`.

## Flujo del `init`

Corre como root (`user: "0:0"`) porque necesita `chown` sobre volúmenes recién
creados. Con `set -euo pipefail`, cualquier paso fallido corta el arranque.

1. Validar `GIT_REPO` y `APP_KEY`; abortar con mensaje accionable si faltan.
2. Clonar a `/tmp/repo` y sincronizar a `/app` con `rsync`.
3. Crear `storage/framework/{cache/data,sessions,views}`, `storage/logs`,
   `storage/app/public` y `bootstrap/cache`.
4. Si `DB_CONNECTION=sqlite`, `touch` del archivo en `$DB_DATABASE`.
5. `composer install`, en modo producción o normal según `APP_ENV`.
6. Si `BUILD_ASSETS=true`: `npm ci && npm run build`.
7. `php artisan storage:link` (tolerante a que ya exista).
8. Si `RUN_MIGRATIONS=true`: `php artisan migrate --force`.
9. Si `APP_ENV=production`: `config:cache`, `route:cache`, `view:cache`.
10. `chown -R app:app /app /data`.

Los otros tres roles son una línea cada uno:

```sh
app)      exec php artisan octane:start --server=frankenphp --host=0.0.0.0 --port=8000 \
            --workers="$OCTANE_WORKERS" --max-requests="$OCTANE_MAX_REQUESTS" ;;
schedule) exec php artisan schedule:work ;;
queue)    exec php artisan queue:work $QUEUE_OPTS ;;
```

## Dockerfile

Base `dunglas/frankenphp:php8.4`. Añade:

- Paquetes del sistema: `git`, `rsync`, `curl`, `unzip`.
- Extensiones PHP con `install-php-extensions` (incluido en la imagen base):
  `pcntl` (requerido por Octane y los workers), `pdo_sqlite`, `pdo_mysql`,
  `pdo_pgsql`, `bcmath`, `intl`, `zip`, `gd`, `opcache`.
- Node.js 22 LTS desde NodeSource, para Vite.
- Composer 2 copiado desde `composer/composer:2-bin`.
- Usuario `app` (uid 1000), `WORKDIR /app`, `COPY entrypoint.sh`,
  `ENTRYPOINT ["/entrypoint.sh"]`, `USER app`.

Octane y los workers corren como `app`, no como root. Como el puerto es 8000
(>1024) no hace falta `setcap`. Solo `init` se eleva a root desde el compose.

## docker-compose.yml

Una ancla YAML con la base común (imagen, `env_file`, volúmenes) y cuatro
servicios que cambian `command`:

- `init`: `user: "0:0"`, `restart: "no"`.
- `app`: publica `${APP_PORT:-8000}:8000`, `depends_on` con
  `condition: service_completed_successfully`, healthcheck sobre `/up` cada 30s,
  `restart: unless-stopped`.
- `schedule` y `queue`: mismo `depends_on` y `restart`. `queue` es escalable con
  `docker compose up --scale queue=3`.

## build.sh

Lee `REGISTRY`, `IMAGE_NAME`, `TAG` y `PLATFORMS` del mismo `.env` de la raíz
(las únicas variables del archivo que consume el build y no el runtime), hace
`docker login` si hace falta y ejecuta `docker buildx build --push`. Por defecto
`PLATFORMS` vale `linux/amd64`; admite multi-arquitectura si se amplía.
Funciona igual contra GHCR (`ghcr.io/usuario/imagen`) y Docker Hub
(`docker.io/usuario/imagen`); lo único que cambia es el registry en la
configuración.

## Manejo de errores

- `set -euo pipefail` en el entrypoint.
- `service_completed_successfully` impide que los tres servicios largos arranquen
  sobre un código a medio instalar: si falla el clone, Composer o el build de
  Vite, el stack no levanta y el log señala el paso.
- `restart: unless-stopped` en los servicios largos, `restart: "no"` en `init`
  para que no entre en bucle.
- Healthcheck de `app` sobre `/up`, la ruta de salud que Laravel trae de serie.

## Verificación

`smoke-test.sh`, un único script:

1. Levanta el stack apuntando a `laravel/laravel` (repositorio público, sin PAT).
2. Espera hasta 120 s a que `/up` responda 200.
3. Comprueba que `schedule` y `queue` siguen en `running`.
4. Derriba el stack y borra los volúmenes.

Falla si cualquier pieza del flujo se rompe. Sin frameworks de test.

## Fuera de alcance

Deliberadamente excluidos de esta versión:

- Horizon y Redis.
- Base de datos dentro del compose.
- TLS automático con Caddy.
- Pipeline de CI.
- Multi-arquitectura por defecto.

Añadir un rol nuevo (Horizon, Reverb) es una rama más en el `case` del entrypoint
y un servicio más en el compose.
