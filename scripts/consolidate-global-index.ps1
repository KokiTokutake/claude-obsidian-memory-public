# consolidate-global-index.ps1 - Merge _Global/Inbox.md into the curated _Global/Index.md
#
# Runs weekly from Task Scheduler (or manually). The Stop hook
# (save-session-notes.ps1) only appends raw insights to Inbox.md; this script
# folds them into the small curated Index.md that every session reads at start.
#
# Safety: single-instance mutex, hard timeout on the nested claude call,
# output validation (never writes a broken/huge index), backups of the previous
# curated index, and the inbox is trimmed under the hook's own mutex so a
# concurrently appended entry is never lost.

param(
    [int]$MinEntries = 5,
    [int]$MaxLines   = 260,
    [switch]$Force
)

$vaultBase   = 'C:\Users\USERNAME\OneDrive\ObsidianVault\ClaudeCode'
$globalDir   = Join-Path $vaultBase '_Global'
$indexPath   = Join-Path $globalDir 'Index.md'
$inboxPath   = Join-Path $globalDir 'Inbox.md'
$archiveDir  = Join-Path $globalDir 'archive'
$logPath     = Join-Path $archiveDir 'consolidate.log'
$claudeBin   = "$env:USERPROFILE\.local\bin\claude.exe"
$utf8        = New-Object System.Text.UTF8Encoding $false
$stamp       = Get-Date -Format 'yyyyMMdd-HHmm'
$today       = Get-Date -Format 'yyyy-MM-dd'

function Write-Log([string]$msg) {
    try {
        if (-not (Test-Path $archiveDir)) { New-Item -ItemType Directory -Force -Path $archiveDir | Out-Null }
        [System.IO.File]::AppendAllText($logPath, "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg`n", $utf8)
    } catch {}
}

function Get-SectionLines([string]$text, [string]$startMarker, [string]$endMarker) {
    $pattern = '(?s)' + [regex]::Escape($startMarker) + '(.*?)' + [regex]::Escape($endMarker)
    $m = [regex]::Match($text, $pattern)
    if (-not $m.Success) { return @() }
    return @($m.Groups[1].Value -split "`n" | ForEach-Object { $_.TrimEnd("`r") } | Where-Object { $_ -match '^\s*-\s' })
}

$mutex = New-Object System.Threading.Mutex($false, 'Global\ClaudeConsolidateGlobalIndexMutex')
$acquired = $false
try { $acquired = $mutex.WaitOne(1000) } catch { $acquired = $false }
if (-not $acquired) { exit 0 }

try {
    if (-not (Test-Path $inboxPath) -or -not (Test-Path $indexPath)) { Write-Log 'skip: inbox or index missing'; exit 0 }

    $inboxText = [System.IO.File]::ReadAllText($inboxPath, $utf8)
    $newPatterns = Get-SectionLines $inboxText '<!-- PATTERNS_START -->' '<!-- PATTERNS_END -->'
    $newMistakes = Get-SectionLines $inboxText '<!-- MISTAKES_START -->' '<!-- MISTAKES_END -->'
    $processed   = @($newPatterns) + @($newMistakes)
    if ($processed.Count -eq 0 -or ($processed.Count -lt $MinEntries -and -not $Force)) {
        Write-Log "skip: inbox has $($processed.Count) entries (min $MinEntries)"
        exit 0
    }

    $indexText = [System.IO.File]::ReadAllText($indexPath, $utf8)

    $rules = @(
        'あなたは Claude Code の「全プロジェクト共通の知見インデックス」の編集者です。',
        '現在のインデックス（CURRENT）に、新しく集まった知見（INBOX）を統合し、更新後のインデックス全文を出力してください。',
        '',
        '編集ルール:',
        '- 形式・見出し・HTMLコメントのマーカー（<!-- PATTERNS_START --> 等）・front matter はそのまま保つ。front matter の updated は ' + $today + ' にする。',
        '- INBOX の各行は「- (日付) [プロジェクト名] 内容」。全プロジェクトで行動に移せる、具体的で当たり前でない知見だけを採用する。一般論・特定プロジェクト固有の事柄は捨てる。',
        '- 既存項目と同じ趣旨なら新しい行を足さず、既存行の [支持: N] を加算し、最新日付を更新する。',
        '- 新規採用は該当カテゴリに「- 内容（1文、80字以内） [支持: N, 最新: YYYY-MM-DD]」で追加する。',
        '- パターン・注意点はそれぞれ最大60行。超える場合は支持が少なく古い行から削る。',
        '- 全体で ' + $MaxLines + ' 行以内。',
        '- 出力は ===BEGIN=== の行と ===END=== の行の間にインデックス全文だけを書く。それ以外は何も書かない。',
        '',
        '===CURRENT===',
        $indexText,
        '',
        '===INBOX===',
        ($processed -join "`n")
    ) -join "`n"

    if (-not (Test-Path $claudeBin)) { Write-Log 'skip: claude.exe not found'; exit 0 }
    $neutralCwd = Join-Path $env:TEMP 'claude-hook-neutral-cwd'
    if (-not (Test-Path $neutralCwd)) { New-Item -ItemType Directory -Force -Path $neutralCwd | Out-Null }

    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $claudeBin
    $psi.Arguments = '--print --model sonnet'
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.WorkingDirectory = $neutralCwd
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    $stdinWriter = New-Object System.IO.StreamWriter($proc.StandardInput.BaseStream, $utf8)
    $stdinWriter.Write($rules)
    $stdinWriter.Close()
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit(300000)) {
        try { $proc.Kill() } catch {}
        Write-Log 'fail: claude timed out'
        exit 0
    }
    [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask), 5000) | Out-Null
    $raw = $stdoutTask.Result

    $m = [regex]::Match($raw, '(?s)===BEGIN===\s*\r?\n(.*?)\r?\n\s*===END===')
    if (-not $m.Success) { Write-Log 'fail: no BEGIN/END block in output'; exit 0 }
    $newIndex = $m.Groups[1].Value.Trim() + "`n"

    # ---- Validate before writing ----------------------------------------------
    $lineCount = ($newIndex -split "`n").Count
    $markersOk = ($newIndex.Contains('<!-- PATTERNS_START -->') -and $newIndex.Contains('<!-- PATTERNS_END -->') -and
                  $newIndex.Contains('<!-- MISTAKES_START -->') -and $newIndex.Contains('<!-- MISTAKES_END -->'))
    $oldItems = (Get-SectionLines $indexText '<!-- PATTERNS_START -->' '<!-- PATTERNS_END -->').Count +
                (Get-SectionLines $indexText '<!-- MISTAKES_START -->' '<!-- MISTAKES_END -->').Count
    $newItems = (Get-SectionLines $newIndex '<!-- PATTERNS_START -->' '<!-- PATTERNS_END -->').Count +
                (Get-SectionLines $newIndex '<!-- MISTAKES_START -->' '<!-- MISTAKES_END -->').Count
    if (-not $markersOk)            { Write-Log 'fail: markers missing in output'; exit 0 }
    if ($lineCount -gt $MaxLines)   { Write-Log "fail: output too long ($lineCount lines)"; exit 0 }
    if ($newItems -lt [math]::Floor($oldItems * 0.7)) { Write-Log "fail: output dropped too many items ($oldItems -> $newItems)"; exit 0 }

    # ---- Backup current curated index (keep the latest 8) -----------------------
    if (-not (Test-Path $archiveDir)) { New-Item -ItemType Directory -Force -Path $archiveDir | Out-Null }
    Copy-Item $indexPath (Join-Path $archiveDir "Index_curated_$stamp.md") -Force
    Get-ChildItem $archiveDir -Filter 'Index_curated_*.md' | Sort-Object Name -Descending | Select-Object -Skip 8 | Remove-Item -Force -ErrorAction SilentlyContinue

    [System.IO.File]::WriteAllText($indexPath, $newIndex, $utf8)

    # ---- Move processed inbox lines to the monthly archive (under the hook's mutex) ----
    $hookMutex = New-Object System.Threading.Mutex($false, 'Global\ClaudeSaveSessionNotesMutex')
    $gotHook = $false
    try { $gotHook = $hookMutex.WaitOne(60000) } catch { $gotHook = $false }
    if ($gotHook) {
        try {
            $current = [System.IO.File]::ReadAllText($inboxPath, $utf8)
            foreach ($line in $processed) {
                $current = $current.Replace("$line`n", '').Replace("$line`r`n", '')
            }
            [System.IO.File]::WriteAllText($inboxPath, $current, $utf8)
            $monthly = Join-Path $archiveDir ("Inbox_" + (Get-Date -Format 'yyyy-MM') + '.md')
            [System.IO.File]::AppendAllText($monthly, ("## consolidated $today`n" + ($processed -join "`n") + "`n`n"), $utf8)
        } finally {
            try { $hookMutex.ReleaseMutex() } catch {}
            $hookMutex.Dispose()
        }
    } else {
        Write-Log 'warn: could not lock inbox; processed lines left in inbox (will be re-merged next run)'
    }

    Write-Log "ok: merged $($processed.Count) inbox entries; items $oldItems -> $newItems; $lineCount lines"
}
finally {
    try { $mutex.ReleaseMutex() } catch {}
    $mutex.Dispose()
}
