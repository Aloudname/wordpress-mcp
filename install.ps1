# =============================================================================
# wordpress-mcp Windows 客户端接入(Claude Code + Codex)
#
# 用法:
#   powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -PiHost pi@mypi -ClaudeScope user
#
# 幂等:已存在的配置会跳过(-Force 覆盖)。写文件用 UTF-8 无 BOM。
#
# 参数:
#   -PiHost        SSH 目标(默认 pi@mypi)
#   -ServerDir     服务器上的安装目录(默认 /home/pi/wordpress-mcp)
#   -ProjectDir    Claude Code 项目目录(默认当前目录,仅 -ClaudeScope project 时用)
#   -ClaudeScope   project(默认,写入 <ProjectDir>\.mcp.json)|user(调用 claude mcp add)|skip
#   -SkipCodex     不修改 Codex 配置
#   -Force         覆盖已有配置
#   -SkipVerify    跳过连通性验证
#   -Help          帮助
# =============================================================================
[CmdletBinding()]
param(
    [string]$PiHost = "pi@mypi",
    [string]$ServerDir = "/home/pi/wordpress-mcp",
    [string]$ProjectDir = "",
    [ValidateSet("project", "user", "skip")]
    [string]$ClaudeScope = "project",
    [switch]$SkipCodex,
    [switch]$Force,
    [switch]$SkipVerify,
    [switch]$Help
)

$ErrorActionPreference = "Stop"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-Step([string]$Msg) { Write-Host "==> $Msg" }
function Write-Err([string]$Msg) { Write-Host "错误: $Msg" -ForegroundColor Red }

if ($Help) {
    Get-Help -Detailed $MyInvocation.MyCommand.Path
    exit 0
}

# ---- 0. 前置检查 ----------------------------------------------------------
$sshExe = "$env:WINDIR\System32\OpenSSH\ssh.exe"
if (-not (Test-Path $sshExe)) {
    $sshExe = (Get-Command ssh -ErrorAction SilentlyContinue).Source
}
if (-not $sshExe) {
    Write-Err "未找到 OpenSSH 客户端。请先在「设置 -> 可选功能」安装 OpenSSH 客户端"
    exit 1
}
Write-Step "使用 SSH: $sshExe"

if (-not $SkipVerify) {
    Write-Step "验证与树莓派的连通性(约 10 秒)..."
    & $sshExe -o BatchMode=yes -o ConnectTimeout=8 -q $PiHost "cd $ServerDir && ./venv/bin/python tests/test_mcp_handshake.py" 2>&1 | Select-Object -Last 4
    if ($LASTEXITCODE -ne 0) {
        Write-Err "服务器侧验证失败(exit=$LASTEXITCODE)。请先在树莓派上运行 install.sh,并确认 SSH 免密登录已配置"
        exit 1
    }
    Write-Host "服务器验证通过 ✓"
}

$entryArgs = @("-o", "BatchMode=yes", "-q", $PiHost, "$ServerDir/bin/mcp-server")

# ---- 1. Claude Code --------------------------------------------------------
if ($ClaudeScope -ne "skip") {
    if ($ClaudeScope -eq "user") {
        Write-Step "Claude Code(user 级): 调用 claude mcp add"
        $claude = Get-Command claude -ErrorAction SilentlyContinue
        if (-not $claude) {
            Write-Err "未找到 claude CLI。请安装 Claude Code,或改用 -ClaudeScope project"
            exit 1
        }
        & claude mcp remove wordpress-blog 2>$null | Out-Null
        & claude mcp add wordpress-blog -s user -- @entryArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Err "claude mcp add 失败(exit=$LASTEXITCODE)"
            exit 1
        }
        Write-Host "已注册到用户级配置 ✓"
    } else {
        Write-Step "Claude Code(项目级): $ProjectDir.mcp.json"
        if ([string]::IsNullOrWhiteSpace($ProjectDir)) { $ProjectDir = (Get-Location).Path }
        $mcpJson = Join-Path $ProjectDir ".mcp.json"
        $config = @{ mcpServers = @{} }
        if (Test-Path $mcpJson) {
            try {
                $existing = Get-Content -Raw $mcpJson | ConvertFrom-Json
                if ($existing.mcpServers) { $config.mcpServers = $existing.mcpServers }
            } catch {
                Write-Err ".mcp.json 解析失败: $($_.Exception.Message)"
                exit 1
            }
        }
        $existingEntry = $config.mcpServers.PSObject.Properties | Where-Object { $_.Name -eq "wordpress-blog" }
        if ($existingEntry -and -not $Force) {
            Write-Host "已存在 wordpress-blog 配置,跳过(覆盖请加 -Force)"
        } else {
            $entry = [ordered]@{
                type = "stdio"
                command = $sshExe
                args = $entryArgs
            }
            $config.mcpServers | Add-Member -NotePropertyName "wordpress-blog" -NotePropertyValue $entry -Force
            $json = $config | ConvertTo-Json -Depth 10
            [System.IO.File]::WriteAllText($mcpJson, $json + "`n", $utf8NoBom)
            Write-Host "已写入 $mcpJson ✓(Claude Code 中会提示批准该 MCP 服务器)"
        }
    }
}

# ---- 2. Codex --------------------------------------------------------------
if (-not $SkipCodex) {
    Write-Step "Codex: ~/.codex/config.toml"
    $codexCfg = Join-Path $env:USERPROFILE ".codex\config.toml"
    $block = @"
# [wordpress-mcp-plugin] 以下由 install.ps1 管理,勿手改(卸载/更新请重跑本脚本)
[mcp_servers.wordpress-blog]
command = '$sshExe'
args = ["-o", "BatchMode=yes", "-q", "$PiHost", "$ServerDir/bin/mcp-server"]
# [/wordpress-mcp-plugin]
"@
    $content = ""
    if (Test-Path $codexCfg) {
        $content = [System.IO.File]::ReadAllText($codexCfg)
        if ($content -match "\[mcp_servers\.wordpress-blog\]") {
            if (-not $Force) {
                Write-Host "Codex 配置中已存在 wordpress-blog,跳过(覆盖请加 -Force)"
            } else {
                $content = $content -replace "(?ms)# \[wordpress-mcp-plugin\].*# \[/wordpress-mcp-plugin\]\r?\n?", ""
                $content = $content -replace "(?ms)\[mcp_servers\.wordpress-blog\]\r?\n(?:.*\r?\n)*?(?=\r?\n\[|$)", ""
                $content = $content.TrimEnd() + "`n`n" + $block
                [System.IO.File]::WriteAllText($codexCfg, $content, $utf8NoBom)
                Write-Host "已更新 Codex 配置 ✓"
            }
        } else {
            $content = $content.TrimEnd() + "`n`n" + $block
            [System.IO.File]::WriteAllText($codexCfg, $content, $utf8NoBom)
            Write-Host "已写入 Codex 配置 ✓"
        }
    } else {
        New-Item -ItemType Directory -Force (Split-Path $codexCfg) | Out-Null
        [System.IO.File]::WriteAllText($codexCfg, $block, $utf8NoBom)
        Write-Host "已创建 Codex 配置 ✓(注意: 目录中未发现已有 config.toml,请确认 Codex 已安装)"
    }
}

Write-Host ""
Write-Host "======================================================"
Write-Host " 接入完成。重启 Claude Code / Codex 会话后即可使用"
Write-Host " 工具前缀 wp_,共 14 个;写作规范见 blog_writing_guide prompt"
Write-Host "======================================================"
