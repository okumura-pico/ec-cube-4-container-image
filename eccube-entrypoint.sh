#!/bin/sh
# EC-CUBE コンテナ起動スクリプト
#   - .env は作らず、環境変数を Apache の PassEnv で PHP ($_SERVER) に渡す
#   - DB が未初期化ならスキーマ作成と初期データ投入を行う (インストーラ不要)
set -eu

ECCUBE_ROOT=/var/www/html

log() { echo "[eccube-entrypoint] $*" >&2; }

console() {
    runuser -u www-data -- php "${ECCUBE_ROOT}/bin/console" --no-interaction "$@"
}

# ---- 必須の環境変数 ----
: "${DATABASE_URL:?DATABASE_URL を指定してください (例: mysql://user:pass@db:3306/eccube)}"
: "${ECCUBE_AUTH_MAGIC:?ECCUBE_AUTH_MAGIC を指定してください (一度決めたら変更不可のランダム文字列)}"

# MySQL の場合はインストーラと同じく utf8mb4 を既定にする
if [ -z "${DATABASE_CHARSET:-}" ]; then
    case "${DATABASE_URL}" in
        mysql*) DATABASE_CHARSET=utf8mb4 ;;
        *)      DATABASE_CHARSET=utf8 ;;
    esac
    export DATABASE_CHARSET
fi

# ---- 環境変数を Apache 経由で PHP に渡す ----
# mod_php では OS の環境変数が $_SERVER に入らず、index.php が .env.install を読んでしまうため。
# 値はファイルに書かず、変数名だけを PassEnv で列挙する。
env | sed -n 's/^\(\(APP\|DATABASE\|MAILER\|ECCUBE\|TRUSTED\)_[A-Za-z0-9_]*\)=.*/PassEnv \1/p' \
    > /etc/apache2/conf-enabled/zz-eccube-env.conf

# 環境変数の変更を確実に反映させるため、コンパイル済みキャッシュは起動時に破棄する
rm -rf "${ECCUBE_ROOT}/var/cache/${APP_ENV}"

# ---- DB 初期化 ----
if [ "${ECCUBE_DB_INIT:-1}" = "1" ]; then
    tries="${ECCUBE_DB_WAIT:-60}"
    until console dbal:run-sql -q 'SELECT 1' >/dev/null 2>&1; do
        tries=$((tries - 1))
        if [ "${tries}" -le 0 ]; then
            log "DB に接続できません"
            console dbal:run-sql 'SELECT 1' || true
            exit 1
        fi
        log "DB の起動を待っています..."
        sleep 2
    done

    if console dbal:run-sql -q 'SELECT 1 FROM dtb_base_info' >/dev/null 2>&1; then
        log "DB は初期化済みです"
    else
        log "DB を初期化します"
        console doctrine:schema:create
        console eccube:fixtures:load
        log "DB の初期化が完了しました (初期管理者: admin / password → 必ず変更してください)"
    fi
fi

exec docker-php-entrypoint "$@"
