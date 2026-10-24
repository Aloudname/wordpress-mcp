# wordpress-mcp

为 Claude Code 与 Codex 提供 WordPress 编辑接口的 MCP 服务器(stdio 传输)。

支持文章与页面的增删改查、分类与标签查询、媒体上传、Markdown 与 HTML 互转。WordPress 调用全部在服务器本机回环完成,凭据不离开服务器。

## 架构

```
Claude Code / Codex (Windows)
  stdio JSON-RPC over SSH
  ↓
WordPress 主机(如树莓派)/home/pi/wordpress-mcp
  按需进程:venv/bin/python -m wordpress_mcp
  ↓
https://127.0.0.1:8443(nginx 回环自签 TLS,独立站点块,无缓存)
  Basic Auth:专用用户 mcp_agent(editor 角色)的应用密码
  ↓
WordPress REST API(wp/v2)
```

## 安全模型

- 应用密码只存于服务器 `config.env`(0600);客户端仅持有 SSH 密钥。
- 回环 HTTPS 满足 WordPress 对应用密码的强制要求,不改 `wp-config.php`。
- MCP 入口不接主站点 fastcgi 缓存,编辑后读取不会返回过期内容。
- 新建文章默认草稿,删除默认进回收站;媒体上传有类型白名单。
- 服务器无常驻进程,客户端会话按需拉起;配置错误启动即失败。

## 安装

### 服务器侧(Debian 系)

前提:Python ≥ 3.9、PHP CLI、nginx、openssl、curl,当前用户可 sudo。

```bash
git clone https://github.com/Aloudname/wordpress-mcp.git
cd wordpress-mcp
bash install.sh
```

安装器依次完成:自动探测 WordPress 根目录与 PHP-FPM 套接字;创建 venv 并安装锁定版本依赖;创建 `mcp_agent` 用户(editor)并签发应用密码;生成回环自签证书;写入独立 nginx 站点块(127.0.0.1:8443);PHP 8.4 display_errors 池级加固;运行两套测试。重复执行幂等。

可选参数:`--wp-root`、`--php-socket`、`--port`、`--server-dir`、`--mirror`、`--regen-password`、`--no-harden-php`、`--skip-tests`。

### 客户端侧(Windows)

```bat
install.bat
```

或:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -PiHost pi@mypi
```

安装器先经 SSH 在服务器侧运行完整 MCP 协议测试以验证连通性,再向 Claude Code(项目级 `.mcp.json`)与 Codex(`~/.codex/config.toml`)写入配置;已有配置则跳过。

参数:`-PiHost`、`-ServerDir`、`-ClaudeScope project|user|skip`、`-SkipCodex`、`-Force`、`-SkipVerify`。

## 工具

共 14 个,前缀 `wp_`。

| 类别 | 工具 |
| --- | --- |
| 文章 | `wp_list_posts` `wp_get_post` `wp_create_post` `wp_update_post` `wp_delete_post` |
| 页面 | `wp_list_pages` `wp_get_page` `wp_update_page` |
| 分类与标签 | `wp_list_categories` `wp_list_tags` |
| 媒体 | `wp_list_media` `wp_upload_media` |
| 排版 | `markdown_to_html` `html_to_markdown` |

另有 `blog_writing_guide` prompt,向 Agent 注入写作与排版约定。

## 行为约定

- WordPress 对草稿不生成 slug,草稿以 ID 查询;slug 查询仅对已发布文章有效。
- 为草稿显式指定 slug 会触发 WP 7.1 核心未定义属性告警,由 PHP 8.4 加固步骤隐藏,不影响功能。
- 分类与标签参数接受名称或 ID;不存在时报错,不自动新建。

## 测试

```bash
./venv/bin/python tests/test_wp_client.py      # 真实站点 CRUD 冒烟,非破坏
./venv/bin/python tests/test_mcp_handshake.py  # MCP stdio 协议握手与工具调用
```

## 卸载

```bash
bash uninstall.sh --server-dir /home/pi/wordpress-mcp   # 保留 WP 用户
bash uninstall.sh --with-wp-user                        # 同时删除用户
```

客户端:删除 `.mcp.json` 中 `wordpress-blog` 条目(或 `claude mcp remove wordpress-blog`);删除 Codex `config.toml` 中 `[wordpress-mcp-plugin]` 标记块。

## 密钥轮换

`install.sh --regen-password` 重新签发应用密码并更新 `config.env`;旧密码在 WP 后台「用户 → mcp_agent → 应用程序密码」撤销。

## 开发

- `deploy.sh` 幂等部署到服务器(开发迭代用,不写密钥)。
- 依赖锁定于 `requirements.txt`;`pyproject.toml` 为打包元数据。
- CI 检查:Python 编译、shellcheck、JSON 校验。
- 新增工具:在 `wp_client.py` 添加客户端方法,在 `server.py` 添加 `@mcp.tool()` 函数,并同步更新两套测试的工具集合断言。

## License

MIT
