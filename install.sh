#!/bin/sh
# wordpress-mcp installer for debian-based wordpress hosts (e.g. raspberry pi)
#
# idempotent: rerunning skips completed steps. never touches wp-config.php.
# run with -h for options and config precedence.
set -eu

# non-interactive ssh shells may lack /usr/sbin in path (nginx lives there)
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
export PATH

# defaults
# shellcheck disable=SC1007  # CDPATH= prefix is the posix-safe cd idiom; the space is intentional
SRC_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ENV_FILE="$SRC_DIR/.env"

# install dir precedence: --server-dir > MCP_SERVER_DIR > .env > $HOME/wordpress-mcp.
# .env is parsed as data, never sourced. piped installs have no checkout, so there
# only the environment variable and the flag apply.
ENV_SERVER_DIR=""
if [ -f "$SRC_DIR/wordpress_mcp/server.py" ] && [ -f "$ENV_FILE" ]; then
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
LOG="/tmp/wordpress-mcp-install.log"
: > "$LOG"

log() { echo "$*" | tee -a "$LOG"; }
fail() { echo "错误: $*" | tee -a "$LOG" >&2; exit 1; }
step() { log ""; log "==> $*"; }

SUDO=""
[ "$(id -u)" = "0" ] || SUDO="sudo"

usage() {
    cat <<'EOF'
usage:
  from a checkout:  bash install.sh [options]
  piped:            curl -fsSL <raw-install.sh-url> | REPO_URL=https://github.com/you/wordpress-mcp bash

idempotent: rerunning skips completed steps. never touches wp-config.php.

options:
  --wp-root DIR        wordpress root (default: auto-detect under /var/www)
  --php-socket SOCK    php-fpm socket (default: auto-detect)
  --port PORT          loopback https port (default 8443)
  --server-dir DIR     install dir (default: $HOME/wordpress-mcp)
  --mirror URL         pip mirror (default tsinghua)
  --regen-password     force a new application password
  --no-harden-php      skip display_errors hardening (php 8.4: warnings pollute json)
  --skip-tests         skip the post-install MCP handshake test
  --repo URL           repo url for piped install (or env REPO_URL)
  --ref BRANCH         branch/tag for piped install (default main)
  -h, --help           show help

config precedence: --server-dir > MCP_SERVER_DIR > .env > $HOME/wordpress-mcp
EOF
    exit 0
}

# parse args
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

# validate config
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
case "$PORT" in
    ''|*[!0-9]*) fail "--port 必须是 1-65535 的整数: $PORT" ;;
esac
if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    fail "--port 必须是 1-65535 的整数: $PORT"
fi

# check environment
step "检查环境"
command -v python3 >/dev/null 2>&1 || fail "缺少 python3"
command -v php    >/dev/null 2>&1 || fail "缺少 php CLI"
command -v nginx  >/dev/null 2>&1 || fail "缺少 nginx"
command -v openssl >/dev/null 2>&1 || fail "缺少 openssl"
command -v curl   >/dev/null 2>&1 || fail "缺少 curl"
command -v dpkg   >/dev/null 2>&1 || fail "仅支持 Debian 系(未找到 dpkg)"
PY_MAJOR=$(python3 -c 'import sys; print(sys.version_info[0])')
PY_MINOR=$(python3 -c 'import sys; print(sys.version_info[1])')
if [ "$PY_MAJOR" -lt 3 ] || { [ "$PY_MAJOR" -eq 3 ] && [ "$PY_MINOR" -lt 10 ]; }; then
    fail "需要 Python >= 3.10(当前 $PY_MAJOR.$PY_MINOR;mcp 2.3 要求)"
fi
log "Python $PY_MAJOR.$PY_MINOR OK"

# fetch source
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
[ -f "$SRC_DIR/tests/test_mcp_handshake.py" ] || fail "源码不完整:缺少 tests/test_mcp_handshake.py"
log "源码: $SRC_DIR"

# deploy to server dir
step "部署源码到 $SERVER_DIR"
$SUDO mkdir -p "$SERVER_DIR/wordpress_mcp" "$SERVER_DIR/bin" "$SERVER_DIR/tests" "$SERVER_DIR/setup"
for f in "$SRC_DIR"/wordpress_mcp/*.py; do $SUDO cp "$f" "$SERVER_DIR/wordpress_mcp/"; done
$SUDO cp "$SRC_DIR/bin/mcp-server" "$SERVER_DIR/bin/mcp-server"
$SUDO chmod +x "$SERVER_DIR/bin/mcp-server"
# only the handshake test is deployed; unit/live tests stay in the source repo
$SUDO cp "$SRC_DIR/tests/test_mcp_handshake.py" "$SERVER_DIR/tests/"
$SUDO cp "$SRC_DIR/setup/"* "$SERVER_DIR/setup/"
$SUDO cp "$SRC_DIR/requirements.txt" "$SERVER_DIR/"
if [ -n "$SUDO" ]; then
    # keep the install writable by the invoking user so venv/deploy work
    # without sudo after the privileged copy step
    $SUDO chown -R "$(id -u):$(id -g)" "$SERVER_DIR"
fi
log "已复制(覆盖)到 $SERVER_DIR"

# detect wordpress and php-fpm. multiple matches are ambiguous: list
# them and ask for an explicit flag instead of silently picking one.
step "探测 WordPress 与 PHP-FPM"
if [ -z "$WP_ROOT" ]; then
    WP_CANDIDATES=$(mktemp)
    find /var/www -maxdepth 3 -name wp-load.php 2>/dev/null \
        | sed 's|/wp-load.php$||' | sort -u > "$WP_CANDIDATES"
    WP_COUNT=$(wc -l < "$WP_CANDIDATES" | tr -d '[:space:]')
    if [ "$WP_COUNT" -eq 0 ]; then
        rm -f "$WP_CANDIDATES"
        fail "未找到 WordPress,请用 --wp-root 指定"
    fi
    if [ "$WP_COUNT" -gt 1 ]; then
        log "发现多个 WordPress 根目录:"
        sed 's/^/  - /' "$WP_CANDIDATES" | while IFS= read -r line; do log "$line"; done
        rm -f "$WP_CANDIDATES"
        fail "请用 --wp-root 指定要使用的目录"
    fi
    WP_ROOT=$(cat "$WP_CANDIDATES")
    rm -f "$WP_CANDIDATES"
fi
WP_ROOT=${WP_ROOT%/}
case "$WP_ROOT" in
    ""|/)            fail "WordPress 根目录不能是根目录" ;;
    /*)              ;;
    *)               fail "--wp-root 必须是绝对路径: $WP_ROOT" ;;
esac
case "$WP_ROOT" in
    *[[:space:]]*)   fail "--wp-root 不能包含空白字符: $WP_ROOT" ;;
esac
if printf '%s' "$WP_ROOT" | grep -q '[^A-Za-z0-9._/-]'; then
    fail "--wp-root 包含不支持的字符(仅允许字母、数字、. _ / -): $WP_ROOT"
fi
[ -f "$WP_ROOT/wp-load.php" ] || fail "--wp-root 无效: $WP_ROOT 下没有 wp-load.php"
log "WordPress: $WP_ROOT"

if [ -z "$PHP_SOCKET" ]; then
    SOCK_CANDIDATES=$(mktemp)
    grep -rhoE '^listen *= *[^;]+\.sock' /etc/php/*/fpm/pool.d/*.conf 2>/dev/null \
        | sed -E 's/^listen *= *//' | tr -d '[:space:]' | sort -u > "$SOCK_CANDIDATES"
    if [ ! -s "$SOCK_CANDIDATES" ]; then
        find /run/php -maxdepth 1 -name '*.sock' -print 2>/dev/null \
            | sort -u > "$SOCK_CANDIDATES"
    fi
    SOCK_COUNT=$(wc -l < "$SOCK_CANDIDATES" | tr -d '[:space:]')
    if [ "$SOCK_COUNT" -eq 0 ]; then
        rm -f "$SOCK_CANDIDATES"
        fail "未找到 PHP-FPM 套接字,请用 --php-socket 指定"
    fi
    if [ "$SOCK_COUNT" -gt 1 ]; then
        log "发现多个 PHP-FPM 套接字:"
        sed 's/^/  - /' "$SOCK_CANDIDATES" | while IFS= read -r line; do log "$line"; done
        rm -f "$SOCK_CANDIDATES"
        fail "请用 --php-socket 指定要使用的套接字"
    fi
    PHP_SOCKET=$(cat "$SOCK_CANDIDATES")
    rm -f "$SOCK_CANDIDATES"
fi
case "$PHP_SOCKET" in
    ""|/)            fail "PHP-FPM 套接字路径无效" ;;
    /*)              ;;
    *)               fail "--php-socket 必须是绝对路径: $PHP_SOCKET" ;;
esac
case "$PHP_SOCKET" in
    *[[:space:]]*)   fail "--php-socket 不能包含空白字符: $PHP_SOCKET" ;;
esac
if printf '%s' "$PHP_SOCKET" | grep -q '[^A-Za-z0-9._/-]'; then
    fail "--php-socket 包含不支持的字符(仅允许字母、数字、. _ / -): $PHP_SOCKET"
fi
[ -S "$PHP_SOCKET" ] || fail "--php-socket 不存在或不是套接字: $PHP_SOCKET"
log "PHP-FPM 套接字: $PHP_SOCKET"

# venv and dependencies
step "Python 虚拟环境与依赖"
if [ ! -x "$SERVER_DIR/venv/bin/python" ]; then
    python3 -m venv "$SERVER_DIR/venv" 2>/dev/null \
        || fail "venv 创建失败,Debian 需先安装: sudo apt install python3-venv"
fi
REQ_FILE="$SERVER_DIR/requirements.txt"
REQ_STAMP="$SERVER_DIR/venv/.requirements.sha256"
REQ_HASH=$(sha256sum "$REQ_FILE" | awk '{print $1}')
NEED_DEPS=0
"$SERVER_DIR/venv/bin/python" -c "import mcp, httpx, markdownify, markdown" 2>/dev/null \
    || NEED_DEPS=1
if [ ! -f "$REQ_STAMP" ] || [ "$(cat "$REQ_STAMP" 2>/dev/null)" != "$REQ_HASH" ]; then
    NEED_DEPS=1
fi
if [ "$NEED_DEPS" = "1" ]; then
    "$SERVER_DIR/venv/bin/pip" install -q --disable-pip-version-check \
        -i "$MIRROR" -r "$REQ_FILE" \
        || fail "依赖安装失败,可换 --mirror 后重试"
    printf '%s\n' "$REQ_HASH" > "$REQ_STAMP"
fi
log "依赖就绪(mcp/httpx/markdownify/markdown 已锁定版本)"

# wordpress user and application password
step "WordPress 用户与应用密码"
if [ -f "$SERVER_DIR/config.env" ] && [ "$REGEN_PASSWORD" = "0" ]; then
    log "config.env 已存在,复用现有凭据(如需重新签发: --regen-password)"
    MISSING_KEYS=""
    for key in WP_URL WP_USER WP_APP_PASSWORD; do
        grep -q "^$key=." "$SERVER_DIR/config.env" || MISSING_KEYS="$MISSING_KEYS $key"
    done
    [ -z "$MISSING_KEYS" ] || fail "config.env 缺少配置:$MISSING_KEYS。可用 --regen-password 重新生成"
    CURRENT_URL=$(sed -n 's/^WP_URL=//p' "$SERVER_DIR/config.env" | head -1)
    EXPECTED_URL="https://127.0.0.1:$PORT"
    if [ "$CURRENT_URL" != "$EXPECTED_URL" ]; then
        $SUDO sed -i "s|^WP_URL=.*|WP_URL=$EXPECTED_URL|" "$SERVER_DIR/config.env"
        log "config.env 的 WP_URL 已更新为 $EXPECTED_URL"
    fi
    $SUDO chmod 600 "$SERVER_DIR/config.env"
    $SUDO chown "$(id -u):$(id -g)" "$SERVER_DIR/config.env" 2>/dev/null || true
else
    TMP_PHP="/tmp/setup-wp-user.php"
    $SUDO cp "$SERVER_DIR/setup/setup-wp-user.php" "$TMP_PHP"
    $SUDO chmod 644 "$TMP_PHP"
    PHP_OUT=$($SUDO -u www-data php "$TMP_PHP" "$WP_USER" "$APP_NAME" "$WP_ROOT/wp-load.php" 2>&1) \
        || fail "创建用户/应用密码失败: $PHP_OUT"
    $SUDO rm -f "$TMP_PHP"
    APP_PW=$(printf '%s\n' "$PHP_OUT" | sed -n 's/^app_password=//p')
    [ -n "$APP_PW" ] || fail "未能解析应用密码(输出: $PHP_OUT)"
    printf 'WP_URL=https://127.0.0.1:%s\nWP_USER=%s\nWP_APP_PASSWORD=%s\nWP_TIMEOUT=15\nWP_VERIFY_SSL=false\n' \
        "$PORT" "$WP_USER" "$APP_PW" | $SUDO tee "$SERVER_DIR/config.env" >/dev/null
    $SUDO chmod 600 "$SERVER_DIR/config.env"
    $SUDO chown "$(id -u):$(id -g)" "$SERVER_DIR/config.env" 2>/dev/null || true
    log "config.env 已写入(0600)。旧应用密码可在 WP 后台撤销"
fi

# loopback tls certificate
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

# nginx loopback site block. this file is generated, so always render
# it again: changing --port/--wp-root/--php-socket must take effect.
step "nginx 回环入口(独立、无缓存)"
NGX_CONF="/etc/nginx/sites-available/wordpress-mcp-loopback.conf"
TMP_NGX=$(mktemp)
sed -e "s|{{PORT}}|$PORT|g" -e "s|{{WP_ROOT}}|$WP_ROOT|g" \
    -e "s|{{PHP_SOCKET}}|$PHP_SOCKET|g" \
    "$SERVER_DIR/setup/nginx-loopback.conf.template" > "$TMP_NGX" \
    || { rm -f "$TMP_NGX"; fail "nginx 模板渲染失败"; }
$SUDO install -m 644 "$TMP_NGX" "$NGX_CONF"
rm -f "$TMP_NGX"
$SUDO ln -sf "$NGX_CONF" /etc/nginx/sites-enabled/wordpress-mcp-loopback.conf
$SUDO nginx -t >/dev/null 2>&1 || fail "nginx 配置校验失败,请检查 $NGX_CONF"
$SUDO systemctl reload nginx
log "nginx 已启用 $NGX_CONF(仅监听 127.0.0.1:$PORT)"

# php 8.4 display_errors hardening
if [ "$HARDEN_PHP" = "1" ]; then
    step "PHP display_errors 加固(PHP 8.4 下 ini 文件赋值失效)"
    if grep -q "php_admin_value\[display_errors\]" /etc/php/*/fpm/pool.d/*.conf 2>/dev/null; then
        log "池配置已含 display_errors,跳过"
    else
        POOL_FILE=$(grep -l "listen *= *$PHP_SOCKET" /etc/php/*/fpm/pool.d/*.conf 2>/dev/null | head -1)
        if [ -n "$POOL_FILE" ]; then
            printf '\n; [wordpress-mcp] php 8.4 ignores php.ini display_errors; pool-level override takes effect\nphp_admin_value[display_errors] = 0\n' \
                | $SUDO tee -a "$POOL_FILE" >/dev/null
            FPM_SVC=$(systemctl list-units 'php*-fpm.service' --no-pager --no-legend 2>/dev/null | awk '{print $1}' | head -1)
            [ -n "$FPM_SVC" ] && $SUDO systemctl restart "$FPM_SVC"
            log "已写入 $POOL_FILE 并重启 FPM(跳过: --no-harden-php)"
        else
            log "警告: 未找到套接字所属的池文件,跳过加固。PHP 8.4 下创建带 slug 的草稿会污染 JSON,可手动在池配置加 php_admin_value[display_errors] = 0"
        fi
    fi
fi

# tests: the deployed handshake test is read-only and proves the stdio
# protocol plus the loopback api path. the live CRUD test stays in the
# source repo and is not part of the server install.
if [ "$SKIP_TESTS" = "1" ]; then
    step "已跳过测试(--skip-tests)"
else
    step "运行 MCP 握手测试(对真实站点,只读)"
    cd "$SERVER_DIR"
    ./venv/bin/python tests/test_mcp_handshake.py || fail "MCP 协议测试失败,详见上方输出"
fi

# done
log ""
log " wordpress-mcp 安装完成"
log " 服务器: $SERVER_DIR"
log " 回环入口: https://127.0.0.1:$PORT(仅本机,无缓存)"
log " 日志: $LOG"
log ""
log " Windows 客户端接入: 运行本仓库的 install.ps1(或 install.bat)"
log " 卸载: bash uninstall.sh --server-dir $SERVER_DIR"
