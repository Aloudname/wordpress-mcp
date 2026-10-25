# wordpress-mcp windows client setup (claude code + codex)
#
# copy .env.example to .env and fill MCP_SSH_HOST / MCP_SERVER_DIR, then:
#   powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
#
# config precedence: parameters > environment variables > .env next to this script.
# idempotent: existing configs are skipped (-Force overwrites). files are
# written as utf-8 without bom.

[CmdletBinding()]
param(
    [Alias("PiHost")]
    [string]$SshHost = "",
    [string]$ServerDir = "",
    [string]$ProjectDir = "",
    [ValidateSet("project", "user", "skip")]
    [string]$ClaudeScope = "project",
    [switch]$SkipCodex,
    [switch]$Force,
    [switch]$SkipVerify,
    [string]$EnvFile = "",
    [switch]$Help
)

$ErrorActionPreference = "Stop"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-Step([string]$Msg) { Write-Host "==> $Msg" }
function Write-Err([string]$Msg) { Write-Host "错误: $Msg" -ForegroundColor Red }

if ($Help) {
    @'
usage: install.ps1 [-SshHost USER@HOST] [-ServerDir DIR] [options]

config precedence: parameters > environment variables > .env

  -SshHost USER@HOST   ssh target (alias -PiHost; env MCP_SSH_HOST)
  -ServerDir DIR       absolute install dir on the server (env MCP_SERVER_DIR)
  -EnvFile PATH        env file (default: .env next to this script)
  -ProjectDir DIR      claude code project dir (default: current dir)
  -ClaudeScope MODE    project (default) | user | skip
  -SkipCodex           do not touch the codex config
  -Force               overwrite existing configs
  -SkipVerify          skip the connectivity check
'@
    exit 0
}

# config: parameters > environment variables > .env
function Read-DotEnv([string]$Path) {
    $values = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $values }
    foreach ($raw in [System.IO.File]::ReadAllLines($Path)) {
        $line = $raw.Trim()
        if ($line.Length -eq 0 -or $line.StartsWith("#")) { continue }
        $eq = $line.IndexOf("=")
        if ($eq -lt 1) { continue }
        $key = $line.Substring(0, $eq).Trim()
        $value = $line.Substring($eq + 1).Trim()
        if ($value.Length -ge 2) {
            $first = $value[0]
            $last = $value[$value.Length - 1]
            if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) {
                $value = $value.Substring(1, $value.Length - 2)
            }
        }
        $values[$key] = $value
    }
    return $values
}

$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }
$envFileExplicit = -not [string]::IsNullOrWhiteSpace($EnvFile)
if (-not $envFileExplicit) { $EnvFile = Join-Path $scriptDir ".env" }
if ($envFileExplicit -and -not (Test-Path -LiteralPath $EnvFile)) {
    Write-Err "env 文件不存在: $EnvFile"
    exit 1
}
$dotenv = Read-DotEnv $EnvFile

if ([string]::IsNullOrWhiteSpace($SshHost) -and -not [string]::IsNullOrWhiteSpace($env:MCP_SSH_HOST)) {
    $SshHost = $env:MCP_SSH_HOST
}
if ([string]::IsNullOrWhiteSpace($SshHost) -and $dotenv.ContainsKey("MCP_SSH_HOST")) {
    $SshHost = $dotenv["MCP_SSH_HOST"]
}
if ([string]::IsNullOrWhiteSpace($ServerDir) -and -not [string]::IsNullOrWhiteSpace($env:MCP_SERVER_DIR)) {
    $ServerDir = $env:MCP_SERVER_DIR
}
if ([string]::IsNullOrWhiteSpace($ServerDir) -and $dotenv.ContainsKey("MCP_SERVER_DIR")) {
    $ServerDir = $dotenv["MCP_SERVER_DIR"]
}

if ([string]::IsNullOrWhiteSpace($SshHost)) {
    Write-Err "未配置 SSH 目标。请复制 .env.example 为 .env 并填写 MCP_SSH_HOST,或使用 -SshHost 指定"
    exit 1
}
if ([string]::IsNullOrWhiteSpace($ServerDir)) {
    Write-Err "未配置服务器安装目录。请复制 .env.example 为 .env 并填写 MCP_SERVER_DIR,或使用 -ServerDir 指定"
    exit 1
}
if ($SshHost.StartsWith("-") -or $SshHost -notmatch '^[A-Za-z0-9._@:\[\]-]+$') {
    Write-Err "SSH 目标格式无效(仅允许字母、数字、. _ @ : [ ] -): $SshHost"
    exit 1
}
$ServerDir = $ServerDir.TrimEnd([char]'/')
if ($ServerDir -notmatch '^/[A-Za-z0-9._/-]+$' -or $ServerDir.StartsWith('//') -or $ServerDir -match '(^|/)\.\.(/|$)') {
    Write-Err "服务器安装目录格式无效(须为绝对路径,仅允许字母、数字、. _ / -): $ServerDir"
    exit 1
}

Write-Host "目标: ${SshHost}:$ServerDir"

# pre-requirements
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
    Write-Step "验证与服务器的连通..."
    & $sshExe -o BatchMode=yes -o ConnectTimeout=8 -q $SshHost "cd $ServerDir && ./venv/bin/python tests/test_mcp_handshake.py" 2>&1 | Select-Object -Last 4
    if ($LASTEXITCODE -ne 0) {
        Write-Err "服务器侧验证失败(exit=$LASTEXITCODE)。请先在服务器上运行 install.sh,并确认 SSH 免密登录已配置"
        exit 1
    }
    Write-Host "服务器验证通过 ✓"
}

$entryArgs = @("-o", "BatchMode=yes", "-q", $SshHost, "$ServerDir/bin/mcp-server")

# claude code
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
        Write-Host "已注册到用户配置 ✓"
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

# codex
if (-not $SkipCodex) {
    Write-Step "Codex: ~/.codex/config.toml"
    $codexCfg = Join-Path $env:USERPROFILE ".codex\config.toml"
    $block = @"
# [wordpress-mcp-plugin] managed by install.ps1, do not edit
[mcp_servers.wordpress-blog]
command = '$sshExe'
args = ["-o", "BatchMode=yes", "-q", "$SshHost", "$ServerDir/bin/mcp-server"]
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
Write-Host " 接入完成。重启 Claude Code / Codex 会话后即可使用"
Write-Host " 工具前缀 wp_,共 14 个;写作规范见 blog_writing_guide prompt"
