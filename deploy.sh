#!/bin/sh
# deploy wordpress-mcp source to the pi and (re)install pinned deps.
# idempotent. config.env (secrets) lives only on the pi, never deployed.
# shellcheck disable=SC2029  # $REMOTE etc. intentionally expand on the dev machine
set -eu

PI_HOST="${PI_HOST:-pi@mypi}"
REMOTE=/home/pi/wordpress-mcp
MIRROR=https://pypi.tuna.tsinghua.edu.cn/simple

ssh "$PI_HOST" "mkdir -p $REMOTE/wordpress_mcp $REMOTE/tests $REMOTE/bin"
scp -q wordpress_mcp/*.py "$PI_HOST:$REMOTE/wordpress_mcp/"
scp -q tests/*.py "$PI_HOST:$REMOTE/tests/"
scp -q bin/mcp-server "$PI_HOST:$REMOTE/bin/"
scp -q requirements.txt "$PI_HOST:$REMOTE/"

ssh "$PI_HOST" "chmod +x $REMOTE/bin/mcp-server && \
  if [ ! -d $REMOTE/venv ]; then python3 -m venv $REMOTE/venv; fi && \
  $REMOTE/venv/bin/pip install -q -i $MIRROR -r $REMOTE/requirements.txt && \
  echo DEPLOY_OK"
