# Changelog

本文件遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)。

## [Unreleased]

- 部署配置外部化：新增 `.env.example`；`install.ps1` 与 `deploy.sh` 从 `.env` 读取 `MCP_SSH_HOST`/`MCP_SERVER_DIR`，优先级为命令行 > 环境变量 > `.env`。
- `install.sh` / `uninstall.sh` 默认安装目录改为 `$HOME/wordpress-mcp`；支持 `.env`、`MCP_SERVER_DIR` 与 `--server-dir`。卸载增加安装目录标记校验与 `--force`。
- `install.ps1` 的 `-PiHost` 更名为 `-SshHost`（保留 `-PiHost` 别名）；示例、入口注释与架构图去除 `pi@mypi` 硬编码。
- 修复 `wp_update_post`/`wp_update_page` 无法用空字符串清空正文或摘要的问题；查询参数与 JSON body 使用不同的清理规则。
- 网络超时、连接失败、非 JSON 响应统一翻译为结构化 `WordpressAPIError`；`httpx` 忽略代理环境变量，避免回环凭据被代理截获。
- 配置启动校验：`WP_URL` 协议/凭据/查询串、`WP_TIMEOUT`、`WP_VERIFY_SSL`；`config.env` 权限过宽时告警。
- 分类/标签自动翻页，不再受 REST API 单页 100 条限制；`per_page`/`page` 增加范围校验。
- 媒体上传清洗文件名、限制 32 MiB，并对非 ASCII 文件名使用 RFC 5987 回退；SVG 风险在文档中标注。
- `install.sh` 幂等性修复：nginx 配置每次重新渲染；`--port` 变化时同步更新 `config.env` 的 `WP_URL`；多 WordPress/PHP-FPM 候选时要求显式指定；现有 `mcp_agent` 用户必须是 editor。
- Python 最低版本提高到 3.10（`mcp` 2.3 要求）；安装器校验改为正确的版本比较。
- 新增 `tests/unit/`（`httpx.MockTransport`，无需真实站点），CI 运行 pytest；服务器安装/`deploy.sh` 只部署只读握手测试。
- 14 个 MCP 工具增加 read-only/additive/overwrite/destructive 注解；进程退出时显式关闭 HTTP 客户端。

## [1.0.0] - 2026-10-25

首次发布。

- MCP 服务器（`wordpress-blog`）：14 个工具与 1 个写作规范 prompt，mcp SDK 2.x。
- 文章与页面增删改查（草稿优先、回收站优先）、分类与标签查询、媒体上传（类型白名单）、Markdown 与 HTML 互转。
- `install.sh`：幂等的服务器侧安装。自动探测 WordPress 与 PHP-FPM；创建最小权限用户与应用密码；生成回环 TLS 证书与独立无缓存 nginx 站点块；PHP 8.4 display_errors 池级加固；安装后运行两套测试。
- `install.ps1` / `install.bat`：Windows 客户端接入。幂等，含连通性验证。
- `uninstall.sh`：卸载,可选连 WordPress 用户一并删除。
- 测试：真实站点的 9 项非破坏 CRUD 冒烟测试、MCP stdio 协议握手。
- CI：Python 编译检查、shellcheck、JSON 校验。
