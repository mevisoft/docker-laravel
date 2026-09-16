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
