# save-session-notes.ps1 - Save Claude Code session insights to Obsidian Vault
# Structure: _Global/ for cross-project knowledge, Projects/<repo>/ for project-specific
#
# IMPORTANT: This hook intentionally runs for EVERY project/session on this machine
# (that's the point — it's the cross-project Obsidian memory system). It fires on
# every Stop event of every Claude Code session, so it MUST stay cheap and guarded:
# stop_hook_active check, single-instance mutex, and a per-session debounce. Missing
# these guards caused a CPU-100% hang on 2026-09-11 (recursive/overlapping spawns of
# this script plus a nested claude.exe subprocess, with no throttling).

param()

# ---- Config ---------------------------------------------------------------
$vaultBase    = 'C:\Users\USERNAME\OneDrive\ObsidianVault\ClaudeCode'
$globalDir    = Join-Path $vaultBase '_Global'
$globalIndex  = Join-Path $globalDir 'Index.md'   # curated (read at session start; rewritten only by consolidate-global-index.ps1)
$globalInbox  = Join-Path $globalDir 'Inbox.md'   # raw new global insights (appended here; consolidated weekly)
$globalSessDir = Join-Path $globalDir 'Sessions'
$projectsBase = Join-Path $vaultBase 'Projects'
$masterIndex  = Join-Path $vaultBase 'Index.md'
$projectsDir  = "$env:USERPROFILE\.claude\projects"
$claudeBin    = "$env:USERPROFILE\.local\bin\claude.exe"
$date         = Get-Date -Format 'yyyy-MM-dd'
$time         = Get-Date -Format 'HH-mm'

# ---- Read hook input from stdin --------------------------------------------
$stdinJson = ''
try { $stdinJson = [Console]::In.ReadToEnd() } catch {}
$sessionData = $null
try { $sessionData = $stdinJson | ConvertFrom-Json } catch {}
$sessionId = if ($sessionData -and $sessionData.session_id) { $sessionData.session_id } else { '' }

# ---- Guard: never re-fire on a Stop caused by our own previous hook output ----
if ($sessionData -and $sessionData.stop_hook_active) { exit 0 }

# ---- Guard: require a session_id (no expensive "most recent file" fallback) ----
if (-not $sessionId) { exit 0 }

# ---- Guard: only one instance of this script may run at a time machine-wide ----
# (Waits briefly so parallel sessions in different projects still get their note
# saved instead of silently dropping it; still bounds worst-case concurrency to 1.)
$mutex = New-Object System.Threading.Mutex($false, 'Global\ClaudeSaveSessionNotesMutex')
$acquired = $false
try { $acquired = $mutex.WaitOne(5000) } catch { $acquired = $false }
if (-not $acquired) { exit 0 }

try {
    # ---- Guard: debounce per session_id (skip if we already ran recently) ----
    $lockDir = Join-Path $env:TEMP 'claude-stop-hook-locks'
    if (-not (Test-Path $lockDir)) { New-Item -ItemType Directory -Force -Path $lockDir | Out-Null }
    $lockFile = Join-Path $lockDir "$sessionId.lock"
    $debounceMinutes = 3
    if (Test-Path $lockFile) {
        $lastRun = (Get-Item $lockFile).LastWriteTime
        if (((Get-Date) - $lastRun).TotalMinutes -lt $debounceMinutes) { exit 0 }
    }
    # Claim the slot immediately (before the heavy work) so overlapping triggers skip.
    try { [System.IO.File]::WriteAllText($lockFile, (Get-Date).ToString('o')) } catch {}

    # ---- Find transcript file (exact session_id match only; no repo-wide fallback) ----
    $transcriptPath = $null
    if (Test-Path $projectsDir) {
        $f = Get-ChildItem -Path $projectsDir -Recurse -Filter "$sessionId.jsonl" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($f) { $transcriptPath = $f.FullName }
    }
    if (-not $transcriptPath) { exit 0 }

    # ---- Extract conversation text --------------------------------------------
    $conversationParts = @()
    $cwd = ''
    try {
        foreach ($line in (Get-Content $transcriptPath -Encoding UTF8 -ErrorAction SilentlyContinue)) {
            if (-not $line) { continue }
            try {
                $obj = $line | ConvertFrom-Json
                if ($obj.cwd -and -not $cwd) { $cwd = $obj.cwd }
                if ($obj.type -in @('user','assistant') -and -not $obj.isMeta) {
                    $role    = $obj.message.role
                    $content = $obj.message.content
                    $text = ''
                    if ($content -is [string]) { $text = $content }
                    elseif ($null -ne $content) {
                        $parts = @($content) | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }
                        $text = $parts -join ' '
                    }
                    $text = $text.Trim()
                    if ($text.Length -gt 20) {
                        $t = if ($text.Length -gt 600) { $text.Substring(0, 600) + '...' } else { $text }
                        $conversationParts += "${role}: $t"
                    }
                }
            } catch {}
        }
    } catch {}

    $conversationText = $conversationParts -join "`n`n"

    # Skip entirely if there isn't enough real content yet (avoids writing empty
    # placeholder notes early in a session, or when the transcript failed to parse).
    if ($conversationText.Length -lt 200) { exit 0 }

    if ($conversationText.Length -gt 8000) {
        $conversationText = $conversationText.Substring(0, 8000) + "`n`n...(truncated)"
    }

    # ---- Detect project name from git repo ------------------------------------
    $projectName = '_unknown'
    if ($cwd -and (Test-Path $cwd)) {
        try {
            $gitRoot = & git -C $cwd rev-parse --show-toplevel 2>$null
            if ($LASTEXITCODE -eq 0 -and $gitRoot) {
                $projectName = Split-Path ($gitRoot.Trim()) -Leaf
            }
        } catch {}
        if ($projectName -eq '_unknown') {
            $projectName = Split-Path $cwd -Leaf
        }
    }
    # Sanitize folder name
    $projectName = $projectName -replace '[\\/:*?"<>|]', '_'

    $projectDir   = Join-Path $projectsBase $projectName
    $projectIndex = Join-Path $projectDir 'Index.md'
    $projectSessDir = Join-Path $projectDir 'Sessions'

    # ---- Generate structured insights via claude CLI --------------------------
    $sessionTitle       = 'Untitled Session'
    $summary            = ''
    $globalPatternsBlock  = ''
    $projectPatternsBlock = ''
    $globalMistakesBlock  = ''
    $projectMistakesBlock = ''
    $decisionsBlock     = ''
    $nextActions        = ''
    $parsedOk           = $false

    if ($conversationText -and (Test-Path $claudeBin)) {
        try {
            $p1  = 'Analyze the following Claude Code session log and respond ONLY with a JSON object (no markdown, no extra text).'
            $p2  = 'Classify each pattern and mistake as either global (applies to any project) or project-specific. Global items must be CONCRETE, NON-OBVIOUS and ACTIONABLE in any other project (e.g. a specific tool/OS/API behavior and its workaround). Generic advice (plan first, test, compare options, document) and anything tied to this project, its personas or its domain is NOT global. Most sessions have NO global item: return [] unless you are sure.'
            $p3  = '{'
            $p4  = '  "title": "One-line session title in Japanese (under 20 chars)",'
            $p5  = '  "summary": "2-3 sentence Japanese summary of what was accomplished",'
            $p6  = '  "global_patterns": ["Cross-project reusable approach in Japanese, one sentence under 80 chars (0-1 items, usually [])"],'
            $p7  = '  "project_patterns": ["This-project-specific approach in Japanese (up to 2 items)"],'
            $p8  = '  "global_mistakes": ["Cross-project pitfall and its workaround in Japanese, one sentence under 80 chars (0-1 items, usually [])"],'
            $p9  = '  "project_mistakes": ["This-project-specific pitfall in Japanese (up to 2 items)"],'
            $p10 = '  "decisions": ["Key design/policy decision in Japanese (up to 2 items)"],'
            $p11 = '  "next_actions": "What to do next session in Japanese (1-2 sentences)"'
            $p12 = '}'
            $promptText = ($p1,$p2,$p3,$p4,$p5,$p6,$p7,$p8,$p9,$p10,$p11,$p12,'','Session log:',$conversationText) -join "`n"

            [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

            # Run the nested claude CLI call with a hard timeout so it can never hang
            # indefinitely. (Recursive re-triggering of this same hook is already
            # prevented by the stop_hook_active check and the machine-wide mutex
            # above, so the nested call keeps the normal config dir/credentials.)
            # Run from a neutral, project-less directory so this nested call is a
            # plain one-shot completion — it must NOT load the calling project's
            # CLAUDE.md/persona/rules/hooks/plugins (that's what made this call take
            # 20-30s instead of a couple of seconds, and risks nested-hook surprises).
            $neutralCwd = Join-Path $env:TEMP 'claude-hook-neutral-cwd'
            if (-not (Test-Path $neutralCwd)) { New-Item -ItemType Directory -Force -Path $neutralCwd | Out-Null }

            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $claudeBin
            $psi.Arguments = '--print --model claude-haiku-4-5-20251001'
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false
            $psi.WorkingDirectory = $neutralCwd

            $proc = New-Object System.Diagnostics.Process
            $proc.StartInfo = $psi
            [void]$proc.Start()
            $proc.StandardInput.Write($promptText)
            $proc.StandardInput.Close()

            # Must drain both stdout and stderr concurrently — reading only one
            # while the process fills the other's pipe buffer deadlocks the call.
            $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
            $stderrTask = $proc.StandardError.ReadToEndAsync()
            $finished = $proc.WaitForExit(45000)
            if (-not $finished) {
                try { $proc.Kill() } catch {}
                $rawJson = ''
            } else {
                [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask), 5000) | Out-Null
                $rawJson = $stdoutTask.Result
            }

            if ($rawJson -match '(?s)\{[\s\S]+\}') { $rawJson = $Matches[0] }

            # ConvertFrom-Json silently returns $null for empty/whitespace input
            # instead of throwing — without this check a timed-out/empty response
            # would fall through with $parsedOk=$true and every field blank (this
            # is what produced the pile of empty notes before this fix).
            $parsed = $rawJson | ConvertFrom-Json
            if ($null -eq $parsed -or -not $parsed.title) { throw "Empty or unusable AI response" }

            $sessionTitle       = $parsed.title
            $summary            = $parsed.summary
            $globalPatternsBlock  = ($parsed.global_patterns  | Where-Object { $_ } | ForEach-Object { "- $_" }) -join "`n"
            $projectPatternsBlock = ($parsed.project_patterns | Where-Object { $_ } | ForEach-Object { "- $_" }) -join "`n"
            $globalMistakesBlock  = ($parsed.global_mistakes  | Where-Object { $_ } | ForEach-Object { "- $_" }) -join "`n"
            $projectMistakesBlock = ($parsed.project_mistakes | Where-Object { $_ } | ForEach-Object { "- $_" }) -join "`n"
            $decisionsBlock     = ($parsed.decisions | Where-Object { $_ } | ForEach-Object { "- $_" }) -join "`n"
            $nextActions        = $parsed.next_actions
            $parsedOk           = $true
        } catch {
            $summary = "AI summary failed: $($_.Exception.Message)"
        }
    }

    # Don't write anything if we couldn't produce a real summary (avoids the
    # empty/placeholder notes that piled up before this fix).
    if (-not $parsedOk) { exit 0 }

    $utf8 = New-Object System.Text.UTF8Encoding $false

    # ---- Ensure directories exist ---------------------------------------------
    foreach ($dir in @($globalSessDir, $projectSessDir)) {
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    }

    # ---- Save session note to project Sessions/ --------------------------------
    $noteLines = @(
        '---',
        "date: $date",
        "time: `"$time`"",
        "title: `"$sessionTitle`"",
        "project: `"$projectName`"",
        "session_id: `"$sessionId`"",
        "cwd: `"$cwd`"",
        'tags:',
        '  - claude-code',
        '  - session',
        "  - $projectName",
        '---',
        '',
        "# $sessionTitle",
        '',
        '## Summary',
        $summary,
        '',
        '## Global Patterns / Learnings',
        $globalPatternsBlock,
        '',
        '## Project Patterns / Learnings',
        $projectPatternsBlock,
        '',
        '## Global Mistakes / Pitfalls',
        $globalMistakesBlock,
        '',
        '## Project Mistakes / Pitfalls',
        $projectMistakesBlock,
        '',
        '## Decisions',
        $decisionsBlock,
        '',
        '## Next Actions',
        $nextActions,
        '',
        '---',
        "*Auto-generated by Claude Code Stop Hook ($date $time)*"
    )
    $noteContent = $noteLines -join "`n"

    # Reuse the same note filename for the life of this session (looked up via the
    # lock dir) so repeated Stop events update one file instead of piling up a new
    # file every few minutes.
    $noteRefFile = Join-Path $lockDir "$sessionId.notefile"
    if (Test-Path $noteRefFile) {
        $noteFileName = (Get-Content $noteRefFile -Raw -ErrorAction SilentlyContinue).Trim()
    }
    if (-not $noteFileName) {
        $noteFileName = "$date $time.md"
        try { [System.IO.File]::WriteAllText($noteRefFile, $noteFileName) } catch {}
    }
    $notePath = Join-Path $projectSessDir $noteFileName
    $isNewNote = -not (Test-Path $notePath)
    try { [System.IO.File]::WriteAllText($notePath, $noteContent, $utf8) } catch {}

    # ---- Initialize project Index.md if it doesn't exist ---------------------
    if (-not (Test-Path $projectIndex)) {
        $projIndexTemplate = @(
            '---',
            "title: $projectName - Claude Code ナレッジ",
            'tags: [claude-code, index, project]',
            "updated: $date",
            '---',
            '',
            "# $projectName",
            '',
            '## プロジェクト固有パターン',
            '',
            '<!-- PATTERNS_START -->',
            '<!-- PATTERNS_END -->',
            '',
            '## プロジェクト固有の注意点',
            '',
            '<!-- MISTAKES_START -->',
            '<!-- MISTAKES_END -->',
            '',
            '## 決定事項',
            '',
            '<!-- DECISIONS_START -->',
            '<!-- DECISIONS_END -->',
            '',
            '## セッション履歴',
            '',
            '<!-- SESSIONS_START -->',
            '<!-- SESSIONS_END -->'
        ) -join "`n"
        try { [System.IO.File]::WriteAllText($projectIndex, $projIndexTemplate, $utf8) } catch {}
    }

    # ---- Append to _Global/Inbox.md (only on this session's first note, to avoid
    #      re-appending near-duplicate insights every debounce interval).
    #      The curated _Global/Index.md is NOT touched here: it is rebuilt weekly
    #      from the inbox by consolidate-global-index.ps1 (keeps it small enough
    #      to be read in full at session start). --------------------------------
    if ($parsedOk -and $isNewNote -and ($globalPatternsBlock -or $globalMistakesBlock)) {
        try {
            if (-not (Test-Path $globalInbox)) {
                $inboxTemplate = @(
                    '---',
                    'title: Global Inbox (未整理の新しい知見)',
                    'tags: [claude-code, inbox, memory]',
                    '---',
                    '',
                    '# Global Inbox',
                    '',
                    '> Stop Hook が追記する未整理の知見。週1回 consolidate-global-index.ps1 が Index.md に統合し、統合済みの行は archive/ に移す。セッション開始時には読まない。',
                    '',
                    '## パターン',
                    '',
                    '<!-- PATTERNS_START -->',
                    '<!-- PATTERNS_END -->',
                    '',
                    '## 注意点',
                    '',
                    '<!-- MISTAKES_START -->',
                    '<!-- MISTAKES_END -->'
                ) -join "`n"
                [System.IO.File]::WriteAllText($globalInbox, $inboxTemplate, $utf8)
            }
            $idx = [System.IO.File]::ReadAllText($globalInbox, $utf8)
            # Skip exact duplicates of text already waiting in the inbox.
            $newP = ($parsed.global_patterns | Where-Object { $_ -and ($idx -notmatch [regex]::Escape($_)) } | ForEach-Object { "- ($date) [$projectName] $_" }) -join "`n"
            $newM = ($parsed.global_mistakes | Where-Object { $_ -and ($idx -notmatch [regex]::Escape($_)) } | ForEach-Object { "- ($date) [$projectName] $_" }) -join "`n"
            if ($newP) { $idx = $idx.Replace('<!-- PATTERNS_START -->', "<!-- PATTERNS_START -->`n$newP") }
            if ($newM) { $idx = $idx.Replace('<!-- MISTAKES_START -->', "<!-- MISTAKES_START -->`n$newM") }
            if ($newP -or $newM) { [System.IO.File]::WriteAllText($globalInbox, $idx, $utf8) }
        } catch {}
    }

    # ---- Update Projects/<name>/Index.md --------------------------------------
    if ((Test-Path $projectIndex) -and $parsedOk) {
        try {
            $idx = [System.IO.File]::ReadAllText($projectIndex, $utf8)
            $noteLinkName = $noteFileName -replace '\.md$', ''
            if ($isNewNote -or ($idx -notmatch [regex]::Escape("[[$noteLinkName]]"))) {
                $sesLink = "- [[$noteLinkName]] - $sessionTitle"
                $idx = $idx -replace '(<!-- SESSIONS_START -->)', "`$1`n$sesLink"
            }
            # Only append pattern/mistake/decision bullets on this session's first
            # note — later debounced updates would just re-derive near-duplicates.
            if ($isNewNote) {
                if ($projectPatternsBlock) {
                    $newP = ($parsed.project_patterns | Where-Object { $_ } | ForEach-Object { "- ($date) $_" }) -join "`n"
                    $idx  = $idx -replace '(<!-- PATTERNS_START -->)', "`$1`n$newP"
                }
                if ($projectMistakesBlock) {
                    $newM = ($parsed.project_mistakes | Where-Object { $_ } | ForEach-Object { "- ($date) $_" }) -join "`n"
                    $idx  = $idx -replace '(<!-- MISTAKES_START -->)', "`$1`n$newM"
                }
                if ($decisionsBlock) {
                    $newD = ($parsed.decisions | Where-Object { $_ } | ForEach-Object { "- ($date) $_" }) -join "`n"
                    $idx  = $idx -replace '(<!-- DECISIONS_START -->)', "`$1`n$newD"
                }
            }
            [System.IO.File]::WriteAllText($projectIndex, $idx, $utf8)
        } catch {}
    }

    # ---- Update master Index.md (project list) --------------------------------
    if ((Test-Path $masterIndex) -and $parsedOk) {
        try {
            $idx = [System.IO.File]::ReadAllText($masterIndex, $utf8)
            $projLink = "- [[Projects/$projectName/Index]] ($date)"
            if ($idx -notmatch [regex]::Escape("[[Projects/$projectName/Index]]")) {
                $idx = $idx -replace '(<!-- PROJECTS_START -->)', "`$1`n$projLink"
                [System.IO.File]::WriteAllText($masterIndex, $idx, $utf8)
            }
        } catch {}
    }
}
finally {
    try { $mutex.ReleaseMutex() } catch {}
    $mutex.Dispose()
}
