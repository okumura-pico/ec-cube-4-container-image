# syntax=docker/dockerfile:1
# EC-CUBE 4.3 は PHP 8.1〜8.3 をサポート (8-apache だと 8.4 以降になるため明示)
ARG PHP=8.3-apache
ARG ECCUBE=4.3.1-p1

# -------------------------------------------
# PHP extension build stage
#
FROM php:${PHP} AS php-ext

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends libfreetype6-dev libjpeg-dev libpng-dev libwebp-dev libzip-dev libicu-dev; \
    docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp; \
    docker-php-ext-install -j"$(nproc)" mysqli gd zip intl pdo_mysql opcache

# -------------------------------------------
# Live stage
#
FROM php:${PHP}

# FROM より前の ARG はステージ内では使えないので再宣言
ARG ECCUBE

RUN set -eux; \
    apt-get update; \
    apt-get upgrade -y; \
    apt-get install -y --no-install-recommends libfreetype6 libjpeg62-turbo libpng16-16t64 libwebp7 libzip5 libicu76; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

COPY --from=php-ext /usr/local/lib/php/extensions/ /usr/local/lib/php/extensions/

RUN set -eux; \
    docker-php-ext-enable mysqli gd zip intl pdo_mysql opcache; \
    php -m

# EC-CUBE 同梱の .htaccess が Order/Allow/Deny を使うため access_compat (依存: authn_core) と authz_host は有効化する
RUN set -eux; \
    a2enmod access_compat authz_host headers remoteip rewrite; \
    a2dismod -f auth_basic authn_file authz_user autoindex status; \
    a2disconf serve-cgi-bin

# Set recommended production PHP.ini
RUN cp "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"

# Configure Apache
RUN set -eux; \
    echo 'LogFormat "%{X-Forwarded-For}i %l %u %t \"%r\" %>s %b \"%{Referer}i\" \"%{User-Agent}i\" %P %X %D" xff_combined' > /etc/apache2/conf-available/xff_logformat.conf; \
    a2enconf xff_logformat; \
    sed -i 's|\(CustomLog .*\) combined|\1 xff_combined|' /etc/apache2/sites-available/000-default.conf

RUN set -eux; \
    { \
      echo 'ServerSignature Off'; \
      echo 'TraceEnable Off'; \
      echo 'ServerTokens Prod'; \
    } > /etc/apache2/conf-available/newsecurity.conf; \
    a2disconf security; \
    a2enconf newsecurity

# Configure PHP.ini settings
RUN set -eux; \
    echo 'error_log=/dev/stderr' > "$PHP_INI_DIR/conf.d/error_log.ini"; \
    sed -i \
      -e 's|^expose_php = .*|expose_php = Off|' \
      -e 's|^memory_limit = .*|memory_limit = 256M|' \
      -e 's|^upload_max_filesize = .*|upload_max_filesize = 50M|' \
      -e 's|^post_max_size = .*|post_max_size = 50M|' \
      -e 's|^max_execution_time = .*|max_execution_time = 120|' \
      "$PHP_INI_DIR/php.ini"

# Extract EC-CUBE (tarball has vendor/ bundled, so composer install is not needed)
#   ビルドコンテキストの eccube-${ECCUBE}.tar.gz を使用
WORKDIR /var/www/html
RUN --mount=type=bind,source=eccube-${ECCUBE}.tar.gz,target=/tmp/eccube.tar.gz \
    set -eux; \
    tar xzf /tmp/eccube.tar.gz --strip-components=1 --no-same-owner; \
    rm -rf .devcontainer dockerbuild gulp Dockerfile docker-compose*.yml \
           babel.config.json gulpfile.js webpack.config.js package.json package-lock.json \
           nginx.conf.sample web.config; \
    chown -R www-data:www-data /var/www/html

EXPOSE 80
