#!/bin/sh
# EC-CUBE container entrypoint
#   - Does not create .env; passes environment variables to PHP ($_SERVER) via Apache PassEnv
#   - Creates the schema and loads initial data if the DB is empty (no web installer needed)
set -eu

ECCUBE_ROOT=/var/www/html

log() { echo "[eccube-entrypoint] $*" >&2; }

console() {
    runuser -u www-data -- php "${ECCUBE_ROOT}/bin/console" --no-interaction "$@"
}

# ---- Required variables ----
: "${DATABASE_URL:?DATABASE_URL is required (e.g. mysql://user:pass@db:3306/eccube)}"
: "${ECCUBE_AUTH_MAGIC:?ECCUBE_AUTH_MAGIC is required (random string; must never change once set)}"

# Default to utf8mb4 for MySQL, same as the web installer
if [ -z "${DATABASE_CHARSET:-}" ]; then
    case "${DATABASE_URL}" in
        mysql*) DATABASE_CHARSET=utf8mb4 ;;
        *)      DATABASE_CHARSET=utf8 ;;
    esac
    export DATABASE_CHARSET
fi

# ---- Pass environment variables to PHP through Apache ----
# With mod_php, OS environment variables are not in $_SERVER, so index.php would load .env.install.
# Only variable names are listed with PassEnv; values are never written to a file.
env | sed -n 's/^\(\(APP\|DATABASE\|MAILER\|ECCUBE\|TRUSTED\)_[A-Za-z0-9_]*\)=.*/PassEnv \1/p' \
    > /etc/apache2/conf-enabled/zz-eccube-env.conf

# Discard the compiled container cache on startup so environment changes always take effect
rm -rf "${ECCUBE_ROOT}/var/cache/${APP_ENV}"

# ---- DB initialization ----
if [ "${ECCUBE_DB_INIT:-1}" = "1" ]; then
    tries="${ECCUBE_DB_WAIT:-60}"
    until console dbal:run-sql -q 'SELECT 1' >/dev/null 2>&1; do
        tries=$((tries - 1))
        if [ "${tries}" -le 0 ]; then
            log "Cannot connect to the database"
            console dbal:run-sql 'SELECT 1' || true
            exit 1
        fi
        log "Waiting for the database..."
        sleep 2
    done

    if console dbal:run-sql -q 'SELECT 1 FROM dtb_base_info' >/dev/null 2>&1; then
        log "Database is already initialized"
    else
        log "Initializing database"
        console doctrine:schema:create
        console eccube:fixtures:load
        log "Database initialized (default admin: admin / password - change it immediately)"
    fi
fi

exec docker-php-entrypoint "$@"
