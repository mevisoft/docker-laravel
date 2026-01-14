FROM php:8.3-apache

ENV APACHE_DOCUMENT_ROOT="/var/www/html"

# Install additional dependencies
RUN apt-get update && \
    apt-get install -y \
        git \
        zip \
        unzip \
        curl \
        libfreetype-dev \
        libjpeg62-turbo-dev \
        libpng-dev \
        libzip-dev \
        libicu-dev \
        libonig-dev \
        libxml2-dev \
        libpq-dev \
        libldap2-dev \
        libmagickwand-dev \
      && docker-php-ext-configure ldap --with-libdir="lib/$(gcc -dumpmachine)" \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j$(nproc) pdo_mysql gd ldap zip intl bcmath mbstring pcntl xml \
        opcache \
        exif \
    && pecl install redis imagick  && \
    docker-php-ext-enable redis imagick && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* \
    && a2enmod rewrite \
    && a2enmod alias \
    && a2enmod headers \
    && a2enmod negotiation \
    && a2enmod authz_core \
    && sed -ri -e 's!/var/www/html!${APACHE_DOCUMENT_ROOT}!g' /etc/apache2/sites-available/*.conf \
    && sed -ri -e 's!/var/www/!${APACHE_DOCUMENT_ROOT}!g' /etc/apache2/apache2.conf /etc/apache2/conf-available/*.conf \
    && mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini" \
    && sed -i 's/memory_limit = 128M/memory_limit = 256M/g' "$PHP_INI_DIR/php.ini"

# Instalar Composer
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

COPY ./bin/run-app /usr/local/bin
RUN chmod +x /usr/local/bin/run-app
# Establecer directorio de trabajo
WORKDIR /var/www/html

# Copy application code with correct ownership
#COPY --chown=1000:1000 . /var/www/html

# Copy entrypoint script
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

#RUN composer prod && \
#    chown -R www-data:www-data /var/www/html && \
#    chmod -R 755 /var/www/html/storage /var/www/html/bootstrap/cache

# Exponer puerto 80
EXPOSE 80

# Punto de entrada
ENTRYPOINT ["docker-entrypoint.sh"]

# Comando por defecto: iniciar Apache
CMD ["/usr/sbin/apache2ctl", "-D", "FOREGROUND"]
