#!/bin/sh
# deploy wordpress-mcp source to the server and (re)install pinned deps.
# idempotent. requires install.sh to have run once (config.env exists).
# config.env (secrets) lives only on the server, never deployed.
# config precedence: --host/--server-dir > MCP_* environment > .env > error.
# shellcheck disable=SC2029  # remote command vars intentionally expand locally
set -eu

# shellcheck disable=SC1007  # CDPATH= prefix is the posix-safe cd idiom; the space is intentional
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
ENV_FILE_ARG=""
SSH_HOST_ARG=""
SERVER_DIR_ARG=""
MIRROR="https://pypi.tuna.tsinghua.edu.cn/simple"

log() { echo "==> $*"; }
fail() { echo "错误: $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
usage: ./deploy.sh [options]

deploy source to the wordpress host and refresh pinned dependencies.
settings are read from flags, then MCP_SSH_HOST/MCP_SERVER_DIR, then .env.

options:
  --host USER@HOST     ssh target (env MCP_SSH_HOST)
  --server-dir DIR     absolute install dir on the host (env MCP_SERVER_DIR)
  --env-file FILE      env file to read (default: .env next to this script)
  --mirror URL         pip mirror (default tsinghua)
  -h, --help           show help
EOF
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --host)       SSH_HOST_ARG="$2"; shift 2 ;;
        --server-dir) SERVER_DIR_ARG="$2"; shift 2 ;;
        --env-file)   ENV_FILE_ARG="$2"; shift 2 ;;
        --mirror)     MIRROR="$2"; shift 2 ;;
        -h|--help)    usage ;;
        *)            fail "未知参数: $1(见 -h)" ;;
    esac
done

if [ -n "$ENV_FILE_ARG" ]; then
    ENV_FILE=$ENV_FILE_ARG
    [ -f "$ENV_FILE" ] || fail "--env-file 不存在: $ENV_FILE"
fi

# parse .env as data, not shell code. only the two deployment keys are read.
ENV_SSH_HOST=""
ENV_SERVER_DIR=""
if [ -f "$ENV_FILE" ]; then
    while IFS='=' read -r key value || [ -n "$key" ]; do
        key=$(printf '%s' "$key" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        value=$(printf '%s' "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        case "$value" in
            \"*\") value=${value#\"}; value=${value%\"} ;;
            \'*\') value=${value#\'}; value=${value%\'} ;;
        esac
        case "$key" in
            MCP_SSH_HOST)   ENV_SSH_HOST=$value ;;
            MCP_SERVER_DIR) ENV_SERVER_DIR=$value ;;
        esac
    done < "$ENV_FILE"
fi

if [ -z "$SSH_HOST_ARG" ] && [ -z "${MCP_SSH_HOST:-}" ] && [ -n "${PI_HOST:-}" ]; then
    log "警告: PI_HOST 已弃用,请改用 MCP_SSH_HOST"
fi
SSH_HOST="${SSH_HOST_ARG:-${MCP_SSH_HOST:-${PI_HOST:-$ENV_SSH_HOST}}}"
SERVER_DIR="${SERVER_DIR_ARG:-${MCP_SERVER_DIR:-$ENV_SERVER_DIR}}"

[ -n "$SSH_HOST" ] || fail "未配置 SSH 目标: 复制 .env.example 为 .env 并填写 MCP_SSH_HOST,或使用 --host"
[ -n "$SERVER_DIR" ] || fail "未配置安装目录: 填写 MCP_SERVER_DIR,或使用 --server-dir"

case "$SSH_HOST" in
    -*)              fail "SSH 目标不能以 '-' 开头: $SSH_HOST" ;;
    *[[:space:]]*)   fail "SSH 目标不能包含空白字符: $SSH_HOST" ;;
esac
printf '%s' "$SSH_HOST" | grep -Eq '^[]A-Za-z0-9._@:[-]+$' \
    || fail "SSH 目标格式无效(仅允许字母、数字、. _ @ : [ ] -): $SSH_HOST"

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
case "$MIRROR" in
    http://*|https://*) ;;
    *) fail "--mirror 必须是 http(s) URL: $MIRROR" ;;
esac
case "$MIRROR" in
    *"'"*|*[[:space:]]*) fail "--mirror 不能包含引号或空白字符" ;;
esac

log "目标: $SSH_HOST:$SERVER_DIR"
cd "$SCRIPT_DIR"

REMOTE="'$SERVER_DIR'"
ssh "$SSH_HOST" "test -f $REMOTE/config.env" \
    || fail "远程 $SERVER_DIR 未安装 wordpress-mcp(缺少 config.env),请先在服务器运行 install.sh"

ssh "$SSH_HOST" "mkdir -p $REMOTE/wordpress_mcp $REMOTE/tests $REMOTE/bin"
scp -q wordpress_mcp/*.py "$SSH_HOST:$SERVER_DIR/wordpress_mcp/"
# only the handshake test is needed by install.ps1; unit/live tests stay local
scp -q tests/test_mcp_handshake.py "$SSH_HOST:$SERVER_DIR/tests/"
scp -q bin/mcp-server "$SSH_HOST:$SERVER_DIR/bin/"
scp -q requirements.txt "$SSH_HOST:$SERVER_DIR/"

ssh "$SSH_HOST" "chmod +x $REMOTE/bin/mcp-server && \
  if [ ! -d $REMOTE/venv ]; then python3 -m venv $REMOTE/venv; fi && \
  $REMOTE/venv/bin/pip install -q -i '$MIRROR' -r $REMOTE/requirements.txt && \
  echo DEPLOY_OK"

log "部署完成"
