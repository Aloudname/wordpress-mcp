#!/bin/sh
# =============================================================================
# wordpress-mcp 一键安装(树莓派 / Debian 系)
#
# 用法:
#   从仓库运行:  bash install.sh [选项]
#   管道安装:    curl -fsSL <raw-install.sh-url> | REPO_URL=https://github.com/you/wordpress-mcp bash
#
# 幂等:重复执行会跳过已完成的步骤。全程不修改 wp-config.php。
#
# 选项:
#   --wp-root DIR        WordPress 根目录(默认自动探测 /var/www)
#   --php-socket SOCK    PHP-FPM 套接字(默认自动探测)
#   --port PORT          回环 HTTPS 端口(默认 8443)
#   --server-dir DIR     安装目录(默认 /home/pi/wordpress-mcp)
#   --mirror URL         pip 镜像(默认清华源)
#   --regen-password     强制重新签发应用密码
#   --no-harden-php      跳过 display_errors 加固(PHP 8.4 下会导致 JSON 被警告污染)
#   --skip-tests         跳过安装后的测试
#   --repo URL           管道安装时的仓库地址(或环境变量 REPO_URL)
#   --ref BRANCH         管道安装时的分支/标签(默认 main)
#   -h, --help           帮助
# =============================================================================
set -eu

# ---- 默认值 ---------------------------------------------------------------
SERVER_DIR="/home/pi/wordpress-mcp"
WP_ROOT=""
PHP_SOCKET=""
PORT="8443"
MIRROR="https://pypi.tuna.tsinghua.edu.cn/simple"
WP_USER="mcp_agent"
APP_NAME="wordpress-mcp"
HARDEN_PHP=1
REGEN_PASSWORD=0
SKIP_TESTS=0
REPO_URL="${REPO_URL:-}"
REF="main"
SRC_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
LOG="/tmp/wordpress-mcp-install.log"
: > "$LOG"

log() { echo "$*" | tee -a "$LOG"; }
fail() { echo "错误: $*" | tee -a "$LOG" >&2; exit 1; }
step() { log ""; log "==> $*"; }

SUDO=""
[ "$(id -u)" = "0" ] || SUDO="sudo"

usage() {
    sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

# ---- 参数解析 -------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --wp-root)       WP_ROOT="$2"; shift 2 ;;
        --php-socket)    PHP_SOCKET="$2"; shift 2 ;;
        --port)          PORT="$2"; shift 2 ;;
        --server-dir)    SERVER_DIR="$2"; shift 2 ;;
        --mirror)        MIRROR="$2"; shift 2 ;;
        --regen-password) REGEN_PASSWORD=1; shift ;;
        --no-harden-php) HARDEN_PHP=0; shift ;;
        --skip-tests)    SKIP_TESTS=1; shift ;;
        --repo)          REPO_URL="$2"; shift 2 ;;
        --ref)           REF="$2"; shift 2 ;;
        -h|--help)       usage ;;
        *)               fail "未知参数: $1(见 -h)" ;;
    esac
done

# ---- 0. 环境检查 ----------------------------------------------------------
step "检查环境"
command -v python3 >/dev/null 2>&1 || fail "缺少 python3"
command -v php    >/dev/null 2>&1 || fail "缺少 php CLI"
command -v nginx  >/dev/null 2>&1 || fail "缺少 nginx"
command -v openssl >/dev/null 2>&1 || fail "缺少 openssl"
command -v curl   >/dev/null 2>&1 || fail "缺少 curl"
command -v dpkg   >/dev/null 2>&1 || fail "仅支持 Debian 系(未找到 dpkg)"
PY_MAJOR=$(python3 -c 'import sys; print(sys.version_info[0])')
PY_MINOR=$(python3 -c 'import sys; print(sys.version_info[1])')
{ [ "$PY_MAJOR" -ge 3 ] && [ "$PY_MINOR" -ge 9 ]; } || fail "需要 Python >= 3.9(当前 $PY_MAJOR.$PY_MINOR)"
log "Python $PY_MAJOR.$PY_MINOR OK"

# ---- 1. 获取源码 ----------------------------------------------------------
step "获取源码"
if [ ! -f "$SRC_DIR/wordpress_mcp/server.py" ]; then
    [ -n "$REPO_URL" ] || fail "本地未找到源码。管道安装请设置 REPO_URL=https://github.com/<you>/<repo>"
    TMP_SRC="$(mktemp -d)"
    trap 'rm -rf "$TMP_SRC"' EXIT
    log "下载 $REPO_URL/archive/refs/heads/$REF.tar.gz ..."
    curl -fsSL "$REPO_URL/archive/refs/heads/$REF.tar.gz" -o "$TMP_SRC/src.tar.gz" \
        || fail "下载失败,检查 --repo/--ref 与网络"
    mkdir -p "$TMP_SRC/src"
    tar -xzf "$TMP_SRC/src.tar.gz" -C "$TMP_SRC/src" --strip-components=1 \
        || fail "解压失败"
    SRC_DIR="$TMP_SRC/src"
fi
[ -f "$SRC_DIR/wordpress_mcp/server.py" ] || fail "源码不完整:缺少 wordpress_mcp/server.py"
log "源码: $SRC_DIR"

# ---- 2. 部署到安装目录 ----------------------------------------------------
step "部署源码到 $SERVER_DIR"
$SUDO mkdir -p "$SERVER_DIR/wordpress_mcp" "$SERVER_DIR/bin" "$SERVER_DIR/tests" "$SERVER_DIR/setup"
for f in wordpress_mcp/*.py; do $SUDO cp "$f" "$SERVER_DIR/wordpress_mcp/"; done
$SUDO cp "$SRC_DIR/bin/mcp-server" "$SERVER_DIR/bin/mcp-server"
$SUDO chmod +x "$SERVER_DIR/bin/mcp-server"
$SUDO cp "$SRC_DIR/tests/"*.py "$SERVER_DIR/tests/"
$SUDO cp "$SRC_DIR/setup/"* "$SERVER_DIR/setup/"
$SUDO cp "$SRC_DIR/requirements.txt" "$SRC_DIR/pyproject.toml" "$SRC_DIR/README.md" "$SERVER_DIR/"
log "已复制(覆盖)到 $SERVER_DIR"

# ---- 3. 探测 WordPress 与 PHP-FPM -----------------------------------------
step "探测 WordPress 与 PHP-FPM"
if [ -z "$WP_ROOT" ]; then
    WP_ROOT=$(find /var/www -maxdepth 3 -name wp-load.php 2>/dev/null | head -1 | sed 's|/wp-load.php||')
    [ -n "$WP_ROOT" ] || fail "未找到 WordPress,请用 --wp-root 指定"
fi
[ -f "$WP_ROOT/wp-load.php" ] || fail "--wp-root 无效: $WP_ROOT 下没有 wp-load.php"
log "WordPress: $WP_ROOT"

if [ -z "$PHP_SOCKET" ]; then
    PHP_SOCKET=$(grep -rhoE '^listen *= *[^;]+\.sock' /etc/php/*/fpm/pool.d/*.conf 2>/dev/null \
        | head -1 | awk -F'= ' '{print $2}' | tr -d '[:space:]')
    [ -z "$PHP_SOCKET" ] && PHP_SOCKET=$(ls /run/php/*.sock 2>/dev/null | head -1)
fi
[ -n "$PHP_SOCKET" ] || fail "未找到 PHP-FPM 套接字,请用 --php-socket 指定"
log "PHP-FPM 套接字: $PHP_SOCKET"

# ---- 4. 创建 venv 并安装依赖 ----------------------------------------------
step "Python 虚拟环境与依赖"
if [ ! -x "$SERVER_DIR/venv/bin/python" ]; then
    python3 -m venv "$SERVER_DIR/venv" 2>/dev/null \
        || fail "venv 创建失败,Debian 需先安装: sudo apt install python3-venv"
fi
if ! "$SERVER_DIR/venv/bin/python" -c "import mcp, httpx, markdownify, markdown" 2>/dev/null; then
    "$SERVER_DIR/venv/bin/pip" install -q -i "$MIRROR" -r "$SERVER_DIR/requirements.txt" \
        || fail "依赖安装失败,可换 --mirror 后重试"
fi
log "依赖就绪(mcp/httpx/markdownify/markdown 已锁定版本)"

# ---- 5. 创建/复用 WordPress 用户并签发应用密码 ------------------------------
step "WordPress 专用用户与应用密码"
if [ -f "$SERVER_DIR/config.env" ] && [ "$REGEN_PASSWORD" = "0" ]; then
    log "config.env 已存在,跳过(如需重新签发: --regen-password)"
else
    TMP_PHP="/tmp/setup-wp-user.php"
    $SUDO cp "$SERVER_DIR/setup/setup-wp-user.php" "$TMP_PHP"
    $SUDO chmod 644 "$TMP_PHP"
    PHP_OUT=$($SUDO -u www-data php "$TMP_PHP" "$WP_USER" "$APP_NAME" "$WP_ROOT/wp-load.php") \
        || fail "创建用户/应用密码失败: $PHP_OUT"
    $SUDO rm -f "$TMP_PHP"
    APP_PW=$(printf '%s\n' "$PHP_OUT" | sed -n 's/^app_password=//p')
    [ -n "$APP_PW" ] || fail "未能解析应用密码(输出: $PHP_OUT)"
    printf 'WP_URL=https://127.0.0.1:%s\nWP_USER=%s\nWP_APP_PASSWORD=%s\nWP_TIMEOUT=15\nWP_VERIFY_SSL=false\n' \
        "$PORT" "$WP_USER" "$APP_PW" | $SUDO tee "$SERVER_DIR/config.env" >/dev/null
    $SUDO chmod 600 "$SERVER_DIR/config.env"
    $SUDO chown "${SUDO_USER:-root}" "$SERVER_DIR/config.env" 2>/dev/null || true
    log "config.env 已写入(0600)。旧应用密码可在 WP 后台撤销"
fi

# ---- 6. 回环 TLS 证书 ------------------------------------------------------
step "回环 TLS 证书(自签名)"
if [ -f /etc/nginx/ssl/loopback.crt ] && [ -f /etc/nginx/ssl/loopback.key ]; then
    log "证书已存在,跳过"
else
    $SUDO mkdir -p /etc/nginx/ssl
    $SUDO openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout /etc/nginx/ssl/loopback.key -out /etc/nginx/ssl/loopback.crt \
        -subj "/CN=127.0.0.1" >/dev/null 2>&1 || fail "证书生成失败"
    $SUDO chmod 600 /etc/nginx/ssl/loopback.key
    log "已生成 /etc/nginx/ssl/loopback.{crt,key}(有效期 10 年)"
fi

# ---- 7. nginx 回环块 --------------------------------------------------------
step "nginx 回环入口(独立、无缓存)"
NGX_CONF="/etc/nginx/sites-available/wordpress-mcp-loopback.conf"
if [ -f "$NGX_CONF" ]; then
    log "$NGX_CONF 已存在,跳过"
else
    $SUDO sed -e "s|{{PORT}}|$PORT|g" -e "s|{{WP_ROOT}}|$WP_ROOT|g" \
        -e "s|{{PHP_SOCKET}}|$PHP_SOCKET|g" \
        "$SERVER_DIR/setup/nginx-loopback.conf.template" > /tmp/nginx-loopback.conf
    $SUDO install -m 644 /tmp/nginx-loopback.conf "$NGX_CONF"
    rm -f /tmp/nginx-loopback.conf
fi
$SUDO ln -sf "$NGX_CONF" /etc/nginx/sites-enabled/wordpress-mcp-loopback.conf
$SUDO nginx -t >/dev/null 2>&1 || fail "nginx 配置校验失败,请检查 $NGX_CONF"
$SUDO systemctl reload nginx
log "nginx 已启用 $NGX_CONF(仅监听 127.0.0.1:$PORT)"

# ---- 8. PHP 8.4 display_errors 加固 ---------------------------------------
if [ "$HARDEN_PHP" = "1" ]; then
    step "PHP display_errors 加固(PHP 8.4 下 ini 文件赋值失效)"
    if grep -q "php_admin_value\[display_errors\]" /etc/php/*/fpm/pool.d/*.conf 2>/dev/null; then
        log "池配置已含 display_errors,跳过"
    else
        POOL_FILE=$(grep -l "listen *= *$PHP_SOCKET" /etc/php/*/fpm/pool.d/*.conf 2>/dev/null | head -1)
        if [ -n "$POOL_FILE" ]; then
            printf '\n; [wordpress-mcp] PHP 8.4 下 php.ini 的 display_errors 赋值被忽略,池级覆盖才生效\nphp_admin_value[display_errors] = 0\n' \
                | $SUDO tee -a "$POOL_FILE" >/dev/null
            FPM_SVC=$(systemctl list-units 'php*-fpm.service' --no-pager --no-legend 2>/dev/null | awk '{print $1}' | head -1)
            [ -n "$FPM_SVC" ] && $SUDO systemctl restart "$FPM_SVC"
            log "已写入 $POOL_FILE 并重启 FPM(跳过: --no-harden-php)"
        else
            log "警告: 未找到套接字所属的池文件,跳过加固。PHP 8.4 下创建带 slug 的草稿会污染 JSON,可手动在池配置加 php_admin_value[display_errors] = 0"
        fi
    fi
fi

# ---- 9. 测试 ---------------------------------------------------------------
if [ "$SKIP_TESTS" = "1" ]; then
    step "已跳过测试(--skip-tests)"
else
    step "运行测试(对真实站点,非破坏)"
    cd "$SERVER_DIR"
    ./venv/bin/python tests/test_wp_client.py || fail "CRUD 冒烟测试失败,详见上方输出"
    ./venv/bin/python tests/test_mcp_handshake.py || fail "MCP 协议测试失败,详见上方输出"
fi

# ---- 完成 -----------------------------------------------------------------
log ""
log "======================================================"
log " wordpress-mcp 安装完成 ✓"
log " 服务器: $SERVER_DIR"
log " 回环入口: https://127.0.0.1:$PORT(仅本机,无缓存)"
log " 日志: $LOG"
log ""
log " Windows 客户端接入: 运行本仓库的 install.ps1(或 install.bat)"
log " 卸载: bash uninstall.sh --server-dir $SERVER_DIR"
log "======================================================"
