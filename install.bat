@echo off
rem wordpress-mcp Windows 客户端接入(转发到 install.ps1)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
exit /b %errorlevel%
