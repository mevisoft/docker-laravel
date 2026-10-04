FROM dunglas/frankenphp:php8.4

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
    exif

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git curl unzip ca-certificates gnupg dnsutils \
 && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
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
 && mkdir -p /app /data \
 && chown app:app /app /data

COPY Caddyfile /etc/frankenphp/Caddyfile
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /app
USER app
ENTRYPOINT ["/entrypoint.sh"]
