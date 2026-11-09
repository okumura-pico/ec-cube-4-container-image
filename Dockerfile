# syntax=docker/dockerfile:1
# EC-CUBE 4.3 supports PHP 8.1-8.3 (pinned explicitly; 8-apache would resolve to 8.4+)
ARG PHP=8.3-apache
ARG ECCUBE=4.3.1-p1
# Update this sha256 together with ECCUBE when changing the version
ARG ECCUBE_SHA256=5783ae3598a902a4bce1d59ea8592281f02f5306d253944dfb45c8cb58680ab4

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
# EC-CUBE build stage (download + composer install --no-dev)
#
FROM php-ext AS eccube

# ARGs declared before FROM are not visible inside a stage, so redeclare them
ARG ECCUBE
ARG ECCUBE_SHA256

COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer

ADD --checksum=sha256:${ECCUBE_SHA256} \
    https://github.com/EC-CUBE/ec-cube/releases/download/${ECCUBE}/eccube-${ECCUBE}.tar.gz \
    /tmp/eccube.tar.gz

# Bundled plugins (type: eccube-plugin, already extracted under app/Plugin from the tarball)
# cannot be installed by composer because ec-cube/plugin-installer refuses it.
# So generate vendor/composer/installed.json from composer.lock marking them as installed.
# plugin-installer itself must also be present beforehand so composer resolves app/Plugin paths.
COPY <<'EOF' /usr/local/bin/seed-installed.php
<?php
$lock = json_decode(file_get_contents('composer.lock'), true);
$packages = [];
foreach ($lock['packages'] as $p) {
    if ($p['type'] === 'eccube-plugin') {
        $p['install-path'] = '../../app/Plugin/' . $p['extra']['code'];
        $packages[] = $p;
    } elseif ($p['name'] === 'ec-cube/plugin-installer') {
        $p['install-path'] = '../ec-cube/plugin-installer';
        $packages[] = $p;
        echo $p['version'];
    }
}
@mkdir('vendor/composer', 0755, true);
file_put_contents('vendor/composer/installed.json', json_encode(
    ['packages' => $packages, 'dev' => false, 'dev-package-names' => []],
    JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES
));
EOF

WORKDIR /app
ENV COMPOSER_ALLOW_SUPERUSER=1
RUN set -eux; \
    tar xzf /tmp/eccube.tar.gz --strip-components=1 --no-same-owner --exclude='ec-cube/vendor'; \
    rm -rf .devcontainer dockerbuild gulp Dockerfile docker-compose*.yml .dockerignore \
           babel.config.json gulpfile.js webpack.config.js package.json package-lock.json \
           nginx.conf.sample web.config; \
    PI_VERSION="$(php /usr/local/bin/seed-installed.php)"; \
    mkdir /tmp/pi; echo '{}' > /tmp/pi/composer.json; \
    composer --working-dir=/tmp/pi require --no-plugins --no-scripts --no-interaction --no-progress "ec-cube/plugin-installer:${PI_VERSION}"; \
    mkdir -p vendor/ec-cube; \
    mv /tmp/pi/vendor/ec-cube/plugin-installer vendor/ec-cube/; \
    # Keep only the google/apiclient-services (~185MB) used by SiteKit42 (official google/apiclient cleanup)
    composer config extra.google/apiclient-services --json '["SiteVerification", "Webmasters"]'; \
    composer config scripts.pre-autoload-dump 'Google\Task\Composer::cleanup'; \
    composer install --no-dev --optimize-autoloader --no-interaction --no-progress; \
    # .env / sqlite DB created by post-install scripts are not needed.
    # Also remove .env.install / .env.dist so the web installer never starts if env vars are missing
    rm -rf .env .env.install .env.dist var/eccube.db var/cache/* var/log/* app/Plugin/.composer/cache/*

# -------------------------------------------
# Live stage
#
FROM php:${PHP}

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends libfreetype6 libjpeg62-turbo libpng16-16t64 libwebp7 libzip5 libicu76; \
    rm -rf /var/lib/apt/lists/*

COPY --from=php-ext /usr/local/lib/php/extensions/ /usr/local/lib/php/extensions/

RUN set -eux; \
    docker-php-ext-enable mysqli gd zip intl pdo_mysql opcache; \
    php -m

# access_compat (requires authn_core) and authz_host are needed because EC-CUBE's .htaccess uses Order/Allow/Deny
RUN set -eux; \
    a2enmod access_compat authz_host headers remoteip rewrite; \
    a2dismod -f auth_basic authn_file authz_user autoindex status; \
    a2disconf serve-cgi-bin

# Return 404 instead of 403 for non-public files/directories to hide their existence.
# Matching is by URL pattern only (not file existence), so existing and missing files are indistinguishable.
# (mod_alias runs before the .htaccess access control)
COPY <<'EOF' /etc/apache2/conf-available/hide-files.conf
# Dotfiles and dot-directories (.env, .env.*, .htaccess, .git, .maintenance, app/Plugin/.composer ...)
RedirectMatch 404 "/\.(?!well-known/)"
# EC-CUBE internal directories
RedirectMatch 404 "^/(app|bin|src|var|vendor|tests|node_modules|codeception|dockerbuild|gulp|zap)(/|$)"
# Internal files in the document root
RedirectMatch 404 "^/(composer\.(json|lock)|symfony\.lock|COPYING|maintenance\.php)$"
# Config/template extensions (same as those denied by EC-CUBE's bundled .htaccess)
RedirectMatch 404 "\.(ini|lock|dist|git|sh|bak|swp|env|twig|yml|yaml|dockerignore|sample)$"
# PHP files under html/
RedirectMatch 404 "^/html/.*\.php$"
EOF
RUN a2enconf hide-files

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

# COPY --chown avoids an extra layer for chown
COPY --from=eccube --chown=www-data:www-data /app /var/www/html

# Configured via environment variables instead of .env (DATABASE_URL and ECCUBE_AUTH_MAGIC are required at startup)
ENV APP_ENV=prod \
    APP_DEBUG=0

COPY --chmod=755 eccube-entrypoint.sh /usr/local/bin/eccube-entrypoint

EXPOSE 80
ENTRYPOINT ["eccube-entrypoint"]
CMD ["apache2-foreground"]
