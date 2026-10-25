#!/bin/sh
# wordpress-mcp uninstaller
#
# removes by default: the nginx loopback block, the tls certificate,
# the php hardening line, and the install dir.
# keeps by default: the wordpress user and its application passwords
# (pass --with-wp-user to delete them too).
#
# config precedence: --server-dir > MCP_SERVER_DIR > .env > $HOME/wordpress-mcp.
set -eu

# shellcheck disable=SC1007  # CDPATH= prefix is the posix-safe cd idiom; the space is intentional
SRC_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ENV_FILE="$SRC_DIR/.env"
ENV_SERVER_DIR=""

if [ -f "$ENV_FILE" ]; then
    while IFS='=' read -r key value || [ -n "$key" ]; do
        key=$(printf '%s' "$key" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        case "$key" in
            MCP_SERVER_DIR)
                value=$(printf '%s' "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
                case "$value" in
                    \"*\") value=${value#\"}; value=${value%\"} ;;
                    \'*\') value=${value#\'}; value=${value%\'} ;;
                esac
                ENV_SERVER_DIR=$value
                ;;
        esac
    done < "$ENV_FILE"
fi

SERVER_DIR="${MCP_SERVER_DIR:-${ENV_SERVER_DIR:-$HOME/wordpress-mcp}}"
WP_ROOT=""
KEEP_HARDENING=0
WITH_WP_USER=0
NO_RELOAD=0
FORCE=0

SUDO=""
[ "$(id -u)" = "0" ] || SUDO="sudo"

fail() { echo "错误: $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
usage: bash uninstall.sh [options]

options:
  --server-dir DIR     install dir (default: $HOME/wordpress-mcp)
  --wp-root DIR        wordpress root (needed only with --with-wp-user, default: auto-detect)
  --keep-hardening     keep the php display_errors hardening line
  --with-wp-user       also delete the wordpress user and all its app passwords
  --no-reload          do not reload nginx / restart fpm
  --force              remove --server-dir even if it lacks install markers
  -h, --help           show help

config precedence: --server-dir > MCP_SERVER_DIR > .env > $HOME/wordpress-mcp
EOF
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --server-dir)    SERVER_DIR="$2"; shift 2 ;;
        --wp-root)       WP_ROOT="$2"; shift 2 ;;
        --keep-hardening) KEEP_HARDENING=1; shift ;;
        --with-wp-user)  WITH_WP_USER=1; shift ;;
        --no-reload)     NO_RELOAD=1; shift ;;
        --force)         FORCE=1; shift ;;
        -h|--help)       usage ;;
        *)               fail "未知参数: $1(见 -h)" ;;
    esac
done

# validate config before touching anything
SERVER_DIR=${SERVER_DIR%/}
case "$SERVER_DIR" in
    ""|/)            fail "安装目录不能是根目录" ;;
    /*)              ;;
    *)               fail "安装目录必须是绝对路径: $SERVER_DIR" ;;
esac
case "$SERVER_DIR" in
    */../*|*/..)     fail "安装目录不能包含 '..': $SERVER_DIR" ;;
    *[[:space:]]*)   fail "安装目录不能包含空白字符: $SERVER_DIR" ;;
esac
if printf '%s' "$SERVER_DIR" | grep -q '[^A-Za-z0-9._/-]'; then
    fail "安装目录包含不支持的字符(仅允许字母、数字、. _ / -): $SERVER_DIR"
fi
if [ -d "$SERVER_DIR" ] && [ "$FORCE" = "0" ] \
   && [ ! -e "$SERVER_DIR/bin/mcp-server" ] && [ ! -e "$SERVER_DIR/config.env" ]; then
    fail "目录中未找到 wordpress-mcp 安装痕迹(缺 bin/mcp-server 与 config.env): $SERVER_DIR。确认后可用 --force"
fi

echo "将移除以下内容:"
echo "  - nginx 回环块 wordpress-mcp-loopback.conf 及其启用链接"
echo "  - TLS 证书 /etc/nginx/ssl/loopback.{crt,key}(目录为空则删除)"
[ "$KEEP_HARDENING" = "1" ] || echo "  - PHP 池中的 [wordpress-mcp] display_errors 加固行"
echo "  - 安装目录 $SERVER_DIR"
[ "$WITH_WP_USER" = "1" ] && echo "  - WordPress 用户 mcp_agent 及其全部应用密码"

# 1. nginx
NGX_CONF="/etc/nginx/sites-available/wordpress-mcp-loopback.conf"
$SUDO rm -f "$NGX_CONF" /etc/nginx/sites-enabled/wordpress-mcp-loopback.conf
if [ "$NO_RELOAD" = "0" ]; then
    $SUDO nginx -t >/dev/null 2>&1 && $SUDO systemctl reload nginx
fi
echo "[ok] nginx 回环块已移除"

# 2. tls certificate
$SUDO rm -f /etc/nginx/ssl/loopback.crt /etc/nginx/ssl/loopback.key
$SUDO rmdir /etc/nginx/ssl 2>/dev/null || true
echo "[ok] TLS 证书已移除"

# 3. php hardening line
if [ "$KEEP_HARDENING" = "0" ]; then
    POOL_FILES=$(grep -l '\[wordpress-mcp\]' /etc/php/*/fpm/pool.d/*.conf 2>/dev/null || true)
    for f in $POOL_FILES; do
        $SUDO sed -i '/; \[wordpress-mcp\]/,+1d' "$f"
    done
    if [ "$NO_RELOAD" = "0" ]; then
        FPM_SVC=$(systemctl list-units 'php*-fpm.service' --no-pager --no-legend 2>/dev/null | awk '{print $1}' | head -1)
        [ -n "$FPM_SVC" ] && $SUDO systemctl restart "$FPM_SVC"
    fi
    echo "[ok] PHP 加固行已移除"
fi

# 4. wordpress user
if [ "$WITH_WP_USER" = "1" ]; then
    [ -z "$WP_ROOT" ] && WP_ROOT=$(find /var/www -maxdepth 3 -name wp-load.php 2>/dev/null | head -1 | sed 's|/wp-load.php||')
    [ -n "$WP_ROOT" ] || { echo "[跳过] 未找到 wp-load.php,无法删除用户" >&2; }
    if [ -n "$WP_ROOT" ]; then
        cat > /tmp/del-wp-user.php <<PHPEOF
<?php
require '$WP_ROOT/wp-load.php';
\$u = get_user_by('login', 'mcp_agent');
if (!\$u) { echo "user_absent\n"; exit(0); }
WP_Application_Passwords::delete_all_application_passwords(\$u->ID);
if (!wp_delete_user(\$u->ID)) { fwrite(STDERR, "delete failed\n"); exit(1); }
echo "user_deleted\n";
PHPEOF
        $SUDO chmod 644 /tmp/del-wp-user.php
        $SUDO -u www-data php /tmp/del-wp-user.php
        $SUDO rm -f /tmp/del-wp-user.php
        echo "[ok] WordPress 用户已删除"
    fi
fi

# 5. install dir
if [ -d "$SERVER_DIR" ]; then
    $SUDO rm -rf -- "$SERVER_DIR"
    echo "[ok] 安装目录已移除: $SERVER_DIR"
else
    echo "[跳过] 安装目录不存在: $SERVER_DIR"
fi

echo ""
echo "卸载完成。客户端(Windows)上的 MCP 配置如需移除:"
echo "  Claude Code: 删除项目 .mcp.json 中的 wordpress-blog 或 claude mcp remove wordpress-blog"
echo "  Codex:       删除 ~/.codex/config.toml 中 [mcp_servers.wordpress-blog] 段"
