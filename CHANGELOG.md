# Changelog

本文件遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)。

## [1.0.0] - 2026-10-25

首次发布。

- MCP 服务器(`wordpress-blog`):14 个工具与 1 个写作规范 prompt,mcp SDK 2.x。
- 文章与页面增删改查(草稿优先、回收站优先)、分类与标签查询、媒体上传(类型白名单)、Markdown 与 HTML 互转。
- install.sh:服务器侧安装(幂等)。自动探测 WordPress 与 PHP-FPM;创建最小权限用户与应用密码;生成回环 TLS 证书与独立无缓存 nginx 站点块;PHP 8.4 display_errors 池级加固;安装后运行两套测试。
- install.ps1 / install.bat:Windows 客户端接入(Claude Code 项目级配置、Codex config.toml)。幂等,含连通性验证。
- uninstall.sh:卸载,可选连 WordPress 用户一并删除。
- 测试:真实站点 CRUD 冒烟(9 项,非破坏)与 MCP stdio 协议握手。
- CI:Python 编译检查、shellcheck、JSON 校验。
