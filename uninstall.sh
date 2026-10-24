#!/bin/sh
# wordpress-mcp uninstaller
#
# usage: bash uninstall.sh [options]
#   removes by default: the nginx loopback block, the tls certificate,
#   the php hardening line, and the install dir.
#   keeps by default: the wordpress user and its application passwords
#   (pass --with-wp-user to delete them too).
#
# options:
#   --server-dir DIR     install dir (default /home/pi/wordpress-mcp)
#   --wp-root DIR        wordpress root (needed only with --with-wp-user, default: auto-detect)
#   --keep-hardening     keep the php display_errors hardening line
#   --with-wp-user       also delete the wordpress user and all its app passwords
#   --no-reload          do not reload nginx / restart fpm
#   -h, --help           show help
set -eu

SERVER_DIR="/home/pi/wordpress-mcp"
WP_ROOT=""
KEEP_HARDENING=0
WITH_WP_USER=0
NO_RELOAD=0

SUDO=""
[ "$(id -u)" = "0" ] || SUDO="sudo"

usage() {
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --server-dir)    SERVER_DIR="$2"; shift 2 ;;
        --wp-root)       WP_ROOT="$2"; shift 2 ;;
        --keep-hardening) KEEP_HARDENING=1; shift ;;
        --with-wp-user)  WITH_WP_USER=1; shift ;;
        --no-reload)     NO_RELOAD=1; shift ;;
        -h|--help)       usage ;;
        *)               echo "未知参数: $1(见 -h)" >&2; exit 1 ;;
    esac
done

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
$SUDO rm -rf "$SERVER_DIR"
echo "[ok] 安装目录已移除: $SERVER_DIR"

echo ""
echo "卸载完成。客户端(Windows)上的 MCP 配置如需移除:"
echo "  Claude Code: 删除项目 .mcp.json 中的 wordpress-blog 或 claude mcp remove wordpress-blog"
echo "  Codex:       删除 ~/.codex/config.toml 中 [mcp_servers.wordpress-blog] 段"
