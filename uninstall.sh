#!/bin/sh
# =============================================================================
# wordpress-mcp 卸载
#
# 用法: bash uninstall.sh [选项]
#   默认移除: nginx 回环块、TLS 证书、PHP 加固行、安装目录
#   默认保留: WordPress 用户与应用密码(如需删除加 --with-wp-user)
#
# 选项:
#   --server-dir DIR     安装目录(默认 /home/pi/wordpress-mcp)
#   --wp-root DIR        WordPress 根目录(仅 --with-wp-user 时需要,默认自动探测)
#   --keep-hardening     保留 PHP display_errors 加固行
#   --with-wp-user       同时删除 WordPress 用户及其全部应用密码
#   --no-reload          不重载 nginx / 不重启 FPM(由你自行处理)
#   -h, --help           帮助
# =============================================================================
set -eu

SERVER_DIR="/home/pi/wordpress-mcp"
WP_ROOT=""
KEEP_HARDENING=0
WITH_WP_USER=0
NO_RELOAD=0

SUDO=""
[ "$(id -u)" = "0" ] || SUDO="sudo"

usage() {
    sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
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

# 2. 证书
$SUDO rm -f /etc/nginx/ssl/loopback.crt /etc/nginx/ssl/loopback.key
$SUDO rmdir /etc/nginx/ssl 2>/dev/null || true
echo "[ok] TLS 证书已移除"

# 3. PHP 加固行
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

# 4. WordPress 用户
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

# 5. 安装目录
$SUDO rm -rf "$SERVER_DIR"
echo "[ok] 安装目录已移除: $SERVER_DIR"

echo ""
echo "卸载完成。客户端(Windows)上的 MCP 配置如需移除:"
echo "  Claude Code: 删除项目 .mcp.json 中的 wordpress-blog 或 claude mcp remove wordpress-blog"
echo "  Codex:       删除 ~/.codex/config.toml 中 [mcp_servers.wordpress-blog] 段"
