@echo off
rem wordpress-mcp windows client setup (delegates to install.ps1)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
exit /b %errorlevel%
