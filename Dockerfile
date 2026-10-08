# VARIANT=frankenphp (default) | apache. BuildKit solo construye la etapa elegida.
# Ambas comparten todo desde "common": mismo entrypoint, mismos comandos.
ARG VARIANT=frankenphp
ARG NODE_MAJOR=22

FROM dunglas/frankenphp:php8.4 AS base-frankenphp
RUN install-php-extensions \
    pdo_mysql \
    pdo_pgsql \
    pdo_sqlite \
    pgsql \
    intl \
    zip \
    bcmath \
    soap \
    pcntl \
    redis \
    gd \
    opcache \
    exif \
    ldap \
    imagick
COPY Caddyfile /etc/frankenphp/Caddyfile
ENV WEB_SERVER=frankenphp

FROM php:8.4-apache AS base-apache
COPY --from=mlocati/php-extension-installer /usr/bin/install-php-extensions /usr/local/bin/
RUN install-php-extensions \
    pdo_mysql \
    pdo_pgsql \
    pdo_sqlite \
    pgsql \
    intl \
    zip \
    bcmath \
    soap \
    pcntl \
    redis \
    gd \
    opcache \
    exif \
    ldap \
    imagick
# Puerto 3000 y front controller en /app/public, igual que el Caddyfile. Corre
# como app (uid 1000): Apache necesita poder escribir pid, locks y logs.
RUN a2enmod rewrite headers remoteip \
 && sed -ri 's/Listen 80/Listen 3000/' /etc/apache2/ports.conf \
 && sed -ri 's/<VirtualHost \*:80>/<VirtualHost *:3000>/; s#/var/www/html#${SERVER_ROOT}#' /etc/apache2/sites-available/000-default.conf \
 && printf '<Directory ${SERVER_ROOT}>\n  AllowOverride All\n  Require all granted\n</Directory>\n' > /etc/apache2/conf-available/app.conf \
 && a2enconf app
# Hardening y proxy: sin version en cabeceras, IP real tras el proxy (solo
# redes privadas se consideran proxy de confianza) y techo de procesos prefork
# acorde a memory_limit (APACHE_MAX_REQUEST_WORKERS, 150 por defecto de Apache
# agotaria la RAM con 256M por proceso).
RUN printf '%s\n' \
  'ServerName localhost' \
  'ServerTokens Prod' \
  'ServerSignature Off' \
  'TraceEnable Off' \
  'RemoteIPHeader X-Forwarded-For' \
  'RemoteIPInternalProxy 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16' \
  '<IfModule mpm_prefork_module>' \
  '  MaxRequestWorkers ${APACHE_MAX_REQUEST_WORKERS}' \
  '  ServerLimit ${APACHE_MAX_REQUEST_WORKERS}' \
  '</IfModule>' \
  > /etc/apache2/conf-available/zz-hardening.conf \
 && a2enconf zz-hardening
ENV WEB_SERVER=apache \
    APACHE_MAX_REQUEST_WORKERS=25 \
    SERVER_ROOT=/app/public \
    APACHE_RUN_USER=app APACHE_RUN_GROUP=app \
    APACHE_PID_FILE=/tmp/apache2.pid

FROM base-${VARIANT} AS common
ARG NODE_MAJOR

# php.ini de produccion en ambas bases: la de FrankenPHP no activa ninguno.
RUN mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"

# Limites de PHP configurables por .env (sintaxis ${VAR:-defecto} del php.ini,
# PHP >= 8.3). Valen igual para web, queue y artisan, en ambas variantes.
RUN printf '%s\n' \
  'memory_limit = ${PHP_MEMORY_LIMIT:-256M}' \
  'upload_max_filesize = ${PHP_UPLOAD_MAX_FILESIZE:-16M}' \
  'post_max_size = ${PHP_POST_MAX_SIZE:-16M}' \
  'max_execution_time = ${PHP_MAX_EXECUTION_TIME:-30}' \
  'max_input_vars = ${PHP_MAX_INPUT_VARS:-1000}' \
  'date.timezone = ${PHP_TIMEZONE:-UTC}' \
  'display_errors = ${PHP_DISPLAY_ERRORS:-Off}' \
  'opcache.validate_timestamps = ${PHP_OPCACHE_VALIDATE_TIMESTAMPS:-1}' \
  'opcache.memory_consumption = ${PHP_OPCACHE_MEMORY:-128}' \
  'opcache.max_accelerated_files = ${PHP_OPCACHE_MAX_FILES:-20000}' \
  'opcache.interned_strings_buffer = ${PHP_OPCACHE_INTERNED:-16}' \
  > "$PHP_INI_DIR/conf.d/zz-app.ini"

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git curl unzip ca-certificates gnupg dnsutils procps \
 && curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/*

# corepack deja disponibles pnpm y yarn: el entrypoint elige segun el lockfile
# del proyecto clonado, que no conocemos hasta el arranque.
RUN corepack enable
# Comprobado que sin TTY corepack no se queda esperando, pero si anuncia cada
# descarga; esto deja los logs de despliegue limpios. La version de pnpm/yarn
# se resuelve al vuelo para respetar el campo packageManager del proyecto.
ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0

COPY --from=composer/composer:2-bin /composer /usr/bin/composer

RUN useradd -u 1000 -m -s /bin/bash app \
 && mkdir -p /app/storage /app/bootstrap/cache /data \
 && chown -R app:app /app /data \
 && if [ "$WEB_SERVER" = apache ]; then chown -R app:app /var/run/apache2 /var/lock/apache2 /var/log/apache2; fi

COPY --chmod=755 entrypoint.sh /entrypoint.sh

LABEL org.opencontainers.image.title="laravel-deploy" \
      org.opencontainers.image.description="Laravel runtime (FrankenPHP o Apache) que despliega desde git"

WORKDIR /app
USER app
ENTRYPOINT ["/entrypoint.sh"]
