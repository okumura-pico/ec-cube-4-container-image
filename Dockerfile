# syntax=docker/dockerfile:1
# EC-CUBE 4.3 は PHP 8.1〜8.3 をサポート (8-apache だと 8.4 以降になるため明示)
ARG PHP=8.3-apache
ARG ECCUBE=4.3.1-p1
# ECCUBE を変更した場合は tar.gz の sha256 も合わせて変更すること
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

# FROM より前の ARG はステージ内では使えないので再宣言
ARG ECCUBE
ARG ECCUBE_SHA256

COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer

ADD --checksum=sha256:${ECCUBE_SHA256} \
    https://github.com/EC-CUBE/ec-cube/releases/download/${ECCUBE}/eccube-${ECCUBE}.tar.gz \
    /tmp/eccube.tar.gz

# 同梱プラグイン (type: eccube-plugin, tar ball の app/Plugin 配下に展開済み) は
# ec-cube/plugin-installer が composer からのインストールを拒否するため、
# composer.lock から「インストール済み」として vendor/composer/installed.json を作っておく。
# plugin-installer 自体も先に入れておかないと app/Plugin 配下を認識できない。
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
    # google/apiclient-services (約 185MB) は SiteKit42 が使うサービスだけ残す (google/apiclient 公式の cleanup 機能)
    composer config extra.google/apiclient-services --json '["SiteVerification", "Webmasters"]'; \
    composer config scripts.pre-autoload-dump 'Google\Task\Composer::cleanup'; \
    composer install --no-dev --optimize-autoloader --no-interaction --no-progress; \
    # post-install スクリプトが作る .env / sqlite DB は不要。
    # .env.install / .env.dist も消し、環境変数の渡し忘れ時にインストーラが起動しないようにする
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

# EC-CUBE 同梱の .htaccess が Order/Allow/Deny を使うため access_compat (依存: authn_core) と authz_host は有効化する
RUN set -eux; \
    a2enmod access_compat authz_host headers remoteip rewrite; \
    a2dismod -f auth_basic authn_file authz_user autoindex status; \
    a2disconf serve-cgi-bin

# 公開不要なファイル・ディレクトリは 403 ではなく 404 を返して存在を隠す。
# ファイルの有無ではなく URL パターンだけで判定するため、実在するかどうか区別できない。
# (mod_alias は .htaccess のアクセス制御より前に処理される)
COPY <<'EOF' /etc/apache2/conf-available/hide-files.conf
# ドットファイル・ドットディレクトリ (.env, .env.*, .htaccess, .git, .maintenance, app/Plugin/.composer ...)
RedirectMatch 404 "/\.(?!well-known/)"
# EC-CUBE の内部ディレクトリ
RedirectMatch 404 "^/(app|bin|src|var|vendor|tests|node_modules|codeception|dockerbuild|gulp|zap)(/|$)"
# ルート直下の内部ファイル
RedirectMatch 404 "^/(composer\.(json|lock)|symfony\.lock|COPYING|maintenance\.php)$"
# 設定ファイル・テンプレート等の拡張子 (EC-CUBE 同梱 .htaccess の拒否対象と同じ)
RedirectMatch 404 "\.(ini|lock|dist|git|sh|bak|swp|env|twig|yml|yaml|dockerignore|sample)$"
# html/ 配下の PHP
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

# --chown 付き COPY なら chown 用の追加レイヤーが発生しない
COPY --from=eccube --chown=www-data:www-data /app /var/www/html

# .env は使わず環境変数で設定する (DATABASE_URL, ECCUBE_AUTH_MAGIC は起動時に必須)
ENV APP_ENV=prod \
    APP_DEBUG=0

COPY --chmod=755 eccube-entrypoint.sh /usr/local/bin/eccube-entrypoint

EXPOSE 80
ENTRYPOINT ["eccube-entrypoint"]
CMD ["apache2-foreground"]
