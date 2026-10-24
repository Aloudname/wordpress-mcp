# wordpress-mcp

让 **Claude Code** 与 **Codex** 获得 WordPress 博客的编辑与排版能力:文章/页面增删改查、分类标签、媒体上传、Markdown 排版转换,全部通过标准的 MCP(stdio)协议。

- 🔒 **安全默认**:创建即草稿、删除进回收站、媒体类型白名单、最小权限专用用户、密钥不出服务器
- 📦 **一键安装**:树莓派跑 `install.sh`,Windows 跑 `install.ps1`,幂等可重复执行
- 🧪 **自带测试**:安装后自动对真实站点跑两套非破坏性测试

## 架构

```
Claude Code / Codex (Windows)
   │ stdio JSON-RPC over SSH(复用已有 SSH 密钥,客户端零凭据)
   ▼
WordPress 主机(如树莓派)/home/pi/wordpress-mcp
   │ 按需进程: venv/bin/python -m wordpress_mcp
   ▼
https://127.0.0.1:8443(nginx 回环自签 TLS,独立无缓存站点块)
   │ Basic Auth: 专用用户 mcp_agent(editor 角色)的应用密码
   ▼
WordPress REST API(wp/v2)
```

设计要点:

- **传输**:stdio 走 SSH,客户端不保存任何 WordPress 凭据;应用密码只存在服务器 `config.env`(0600)
- **安全模型**:回环 HTTPS 满足 WordPress「应用密码仅限 HTTPS」的核心要求,不修改 `wp-config.php`、不弱化任何安全控制
- **无缓存**:MCP 入口刻意不接主站点的 fastcgi 缓存,保证编辑后读到的永远是最新内容
- **按需进程**:无常驻守护,每个客户端会话拉起一个实例,配置错误启动即失败(stderr 可见)

## 快速开始

### 1. 服务器侧(WordPress 主机,Debian 系)

```bash
git clone https://github.com/<你>/wordpress-mcp.git
cd wordpress-mcp
bash install.sh          # 幂等;自动探测 WordPress 与 PHP-FPM
```

或管道安装(需指定仓库地址):

```bash
curl -fsSL https://raw.githubusercontent.com/<你>/wordpress-mcp/main/install.sh \
  | REPO_URL=https://github.com/<你>/wordpress-mcp bash
```

前置要求:Python ≥ 3.9、PHP CLI、nginx、openssl、curl;当前用户可 sudo。
安装器会自动:创建 venv 并锁定依赖(默认清华镜像)→ 创建 `mcp_agent` 用户(editor)+ 应用密码 → 生成回环自签证书 → 写入独立 nginx 块(127.0.0.1:8443)→ PHP 8.4 display_errors 加固 → 跑两套测试。

常用参数:`--wp-root` `--php-socket` `--port` `--server-dir` `--mirror` `--regen-password` `--no-harden-php` `--skip-tests`(见 `install.sh -h`)

### 2. 客户端侧(Windows)

```bat
install.bat
:: 或 powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -PiHost pi@mypi
```

自动完成:连通性验证(服务器侧跑完整 MCP 协议测试)→ Claude Code 项目级 `.mcp.json`(或 `-ClaudeScope user` 走 `claude mcp add`)→ Codex `~/.codex/config.toml` 追加(带哨兵标记,幂等)。

参数:`-PiHost` `-ServerDir` `-ClaudeScope project|user|skip` `-SkipCodex` `-Force` `-SkipVerify`

完成后重启 Claude Code / Codex 会话,工具以 `wp_` 前缀出现。

## 工具清单(14 个)

| 类别 | 工具 |
|---|---|
| 文章 | `wp_list_posts` `wp_get_post` `wp_create_post` `wp_update_post` `wp_delete_post` |
| 页面 | `wp_list_pages` `wp_get_page` `wp_update_page` |
| 分类/标签 | `wp_list_categories` `wp_list_tags` |
| 媒体 | `wp_list_media` `wp_upload_media` |
| 排版 | `markdown_to_html` `html_to_markdown` |

附 `blog_writing_guide` prompt:向 Agent 注入写作排版约定(草稿先行、标题层级、中英文空格等)。

### 已知行为约定

- **草稿无 slug**:WordPress 发布时才生成 slug,草稿请用 ID 查询
- **草稿 + 显式 slug**:会触发 WP 7.1 核心告警(未定义属性),依赖第 8 步的 display_errors 加固隐藏,不影响功能
- 分类/标签接受「名称或 ID」,不存在时报错;不自动新建分类

## 测试

在服务器安装目录运行(非破坏:只建草稿并在结束前清理,永不发布):

```bash
./venv/bin/python tests/test_wp_client.py      # 9 项真实站点 CRUD 冒烟
./venv/bin/python tests/test_mcp_handshake.py  # MCP stdio 协议握手 + 工具调用
```

## 卸载

```bash
bash uninstall.sh --server-dir /home/pi/wordpress-mcp   # 保留 WP 用户
bash uninstall.sh --with-wp-user                        # 连用户一起删
```

客户端:Claude Code 删 `.mcp.json` 中条目(或 `claude mcp remove wordpress-blog`);Codex 删 `config.toml` 中 `[wordpress-mcp-plugin]` 标记块。

## 密钥轮换

`install.sh --regen-password` 重新签发应用密码并更新 `config.env`;旧密码在 WP 后台「用户 → mcp_agent → 应用程序密码」撤销。

## 开发

- 代码在 `wordpress_mcp/`;`deploy.sh` 幂等部署到服务器(开发迭代用,不写密钥)
- 依赖锁定在 `requirements.txt`;`pyproject.toml` 提供打包元数据
- CI:语法编译 + shellcheck + JSON 校验(见 `.github/workflows/ci.yml`)
- 新增工具:在 `wp_client.py` 加客户端方法、在 `server.py` 加 `@mcp.tool()` 装饰的函数,同步更新两套测试的期望工具集

## 路线图

- 主题外观设置(Theme Mods)工具(需自建 WP 插件端点)
- 评论管理、批量导入导出
- 接入生图服务做配图工作流

## License

MIT
