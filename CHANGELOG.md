# Changelog

本项目遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)。

## [1.0.0] - 2026-10-25

### 新增

- MCP 服务器(`wordpress-blog`):14 个工具 + 1 个写作规范 prompt,基于 mcp SDK 2.x
- 文章/页面 CRUD(草稿优先、回收站优先的安全默认)、分类/标签查询、媒体上传(类型白名单)、Markdown ↔ HTML 排版工具
- `install.sh`:树莓派/Debian 系一键安装(幂等),自动探测 WordPress 与 PHP-FPM 套接字、创建最小权限用户与应用密码、生成回环 TLS 证书与独立无缓存 nginx 块、可选 PHP 8.4 display_errors 加固、安装后自动跑两套测试
- `install.ps1` / `install.bat`:Windows 客户端一键接入(Claude Code 项目级 + Codex),幂等、可验证
- `uninstall.sh`:完整卸载
- 测试套件:真实站点 CRUD 冒烟(9 项,非破坏)+ MCP stdio 协议握手
- CI:语法编译检查 + shellcheck
