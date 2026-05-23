#Requires -Version 5.1
# setup.ps1 - Claude Code x Obsidian Memory System Installer
# Run: powershell -ExecutionPolicy Bypass -File setup.ps1

param(
    [string]$VaultPath = "C:\Users\$env:USERNAME\OneDrive\ObsidianVault\ClaudeCode",
    [string]$ClaudeDir = "$env:USERPROFILE\.claude"
)

$ErrorActionPreference = 'Stop'
$utf8    = New-Object System.Text.UTF8Encoding $false
$utf8bom = New-Object System.Text.UTF8Encoding $true
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host ""
Write-Host "Claude Code x Obsidian Memory System - Setup" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

# ---- Step 1: Vault directory structure ------------------------------------
Write-Host "[1/5] Creating Obsidian Vault structure..." -ForegroundColor Yellow

$dirs = @(
    $VaultPath,
    "$VaultPath\_Global\Sessions",
    "$VaultPath\Projects"
)
foreach ($d in $dirs) {
    if (-not (Test-Path $d)) {
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        Write-Host "  Created: $d"
    } else {
        Write-Host "  Exists:  $d"
    }
}

# Init _Global/Index.md if missing
$globalIndex = "$VaultPath\_Global\Index.md"
if (-not (Test-Path $globalIndex)) {
    $template = [System.IO.File]::ReadAllText("$scriptDir\templates\Global-Index.md", $utf8)
    $template = $template -replace 'YYYY-MM-DD', (Get-Date -Format 'yyyy-MM-dd')
    [System.IO.File]::WriteAllText($globalIndex, $template, $utf8)
    Write-Host "  Created: $globalIndex"
}

# Init master Index.md if missing
$masterIndex = "$VaultPath\Index.md"
if (-not (Test-Path $masterIndex)) {
    $masterContent = @(
        '---',
        'title: Claude Code メモリ マスターインデックス',
        'tags: [claude-code, index, master]',
        "updated: $(Get-Date -Format 'yyyy-MM-dd')",
        '---',
        '',
        '# Claude Code メモリ マスターインデックス',
        '',
        '> Stop Hook により自動更新されます。',
        '> - グローバル知識 → [[_Global/Index]]',
        '> - プロジェクト別知識 → [[Projects/<プロジェクト名>/Index]]',
        '',
        '## グローバル知識',
        '',
        '→ **[[_Global/Index]]** を参照',
        '',
        '## プロジェクト別知識',
        '',
        '<!-- PROJECTS_START -->',
        '<!-- PROJECTS_END -->'
    ) -join "`n"
    [System.IO.File]::WriteAllText($masterIndex, $masterContent, $utf8)
    Write-Host "  Created: $masterIndex"
}

Write-Host "  Done." -ForegroundColor Green

# ---- Step 2: Install PS1 script ------------------------------------------
Write-Host ""
Write-Host "[2/5] Installing save-session-notes.ps1..." -ForegroundColor Yellow

$destPs1 = "$ClaudeDir\save-session-notes.ps1"
$srcPs1  = "$scriptDir\scripts\save-session-notes.ps1"

# Read and patch vault path to match the user's actual vault path
$ps1Content = [System.IO.File]::ReadAllText($srcPs1, $utf8)
$ps1Content = $ps1Content -replace [regex]::Escape("C:\Users\USERNAME\OneDrive\ObsidianVault\ClaudeCode"), $VaultPath

# Write with BOM (required for PS5.1 to read UTF-8 correctly)
[System.IO.File]::WriteAllText($destPs1, $ps1Content, $utf8bom)
Write-Host "  Installed (UTF-8 BOM): $destPs1"
Write-Host "  Done." -ForegroundColor Green

# ---- Step 3: Install rules file ------------------------------------------
Write-Host ""
Write-Host "[3/5] Installing obsidian_memory.md rules..." -ForegroundColor Yellow

$rulesDir = "$ClaudeDir\rules"
if (-not (Test-Path $rulesDir)) {
    New-Item -ItemType Directory -Force -Path $rulesDir | Out-Null
}
$rulesContent = [System.IO.File]::ReadAllText("$scriptDir\rules\obsidian_memory.md", $utf8)
$rulesContent = $rulesContent -replace [regex]::Escape("C:\Users\USERNAME\OneDrive\ObsidianVault\ClaudeCode"), $VaultPath
[System.IO.File]::WriteAllText("$rulesDir\obsidian_memory.md", $rulesContent, $utf8)
Write-Host "  Installed: $rulesDir\obsidian_memory.md"
Write-Host "  Done." -ForegroundColor Green

# ---- Step 4: Update settings.json ----------------------------------------
Write-Host ""
Write-Host "[4/5] Updating ~/.claude/settings.json..." -ForegroundColor Yellow

$settingsPath = "$ClaudeDir\settings.json"
$hookCommand  = "powershell -ExecutionPolicy Bypass -NonInteractive -NoProfile -File `"$ClaudeDir\save-session-notes.ps1`""

if (Test-Path $settingsPath) {
    $settingsRaw = [System.IO.File]::ReadAllText($settingsPath, $utf8)
    $settings    = $settingsRaw | ConvertFrom-Json
} else {
    $settings = [PSCustomObject]@{}
}

# Check if Stop hook already exists
$stopHookExists = $false
if ($settings.hooks -and $settings.hooks.Stop) {
    foreach ($group in $settings.hooks.Stop) {
        foreach ($h in $group.hooks) {
            if ($h.command -like "*save-session-notes*") {
                $stopHookExists = $true
            }
        }
    }
}

if ($stopHookExists) {
    Write-Host "  Stop Hook already registered - skipping."
} else {
    # Build new hook object via raw JSON merge to avoid PS5.1 object limitations
    $newHookJson = @"
{
  "type": "command",
  "command": "$($hookCommand -replace '\\','\\\\' -replace '"','\"')",
  "timeout": 60,
  "async": true,
  "statusMessage": "Obsidian にセッションノートを保存中..."
}
"@
    if (-not $settings.PSObject.Properties['hooks']) {
        Add-Member -InputObject $settings -NotePropertyName 'hooks' -NotePropertyValue ([PSCustomObject]@{})
    }
    if (-not $settings.hooks.PSObject.Properties['Stop']) {
        Add-Member -InputObject $settings.hooks -NotePropertyName 'Stop' -NotePropertyValue @()
    }
    $newGroup = [PSCustomObject]@{ hooks = @($newHookJson | ConvertFrom-Json) }
    $settings.hooks.Stop = @($settings.hooks.Stop) + $newGroup
    $newSettingsJson = $settings | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($settingsPath, $newSettingsJson, $utf8)
    Write-Host "  Stop Hook added to settings.json"
}
Write-Host "  Done." -ForegroundColor Green

# ---- Step 5: Verify claude.exe -------------------------------------------
Write-Host ""
Write-Host "[5/5] Checking claude.exe..." -ForegroundColor Yellow

$claudeBin = "$env:USERPROFILE\.local\bin\claude.exe"
if (Test-Path $claudeBin) {
    Write-Host "  Found: $claudeBin" -ForegroundColor Green
} else {
    Write-Host "  WARNING: claude.exe not found at $claudeBin" -ForegroundColor Red
    Write-Host "  AI summary will not work. Install Claude Code CLI first."
    Write-Host "  https://claude.ai/download"
}

# ---- Summary -------------------------------------------------------------
Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "Setup complete!" -ForegroundColor Green
Write-Host ""
Write-Host "Vault:   $VaultPath"
Write-Host "Script:  $destPs1"
Write-Host "Rules:   $rulesDir\obsidian_memory.md"
Write-Host ""
Write-Host "Next: End a Claude Code session and check"
Write-Host "  $VaultPath\_Global\Index.md"
Write-Host "  $VaultPath\Projects\<repo-name>\Index.md"
Write-Host ""
