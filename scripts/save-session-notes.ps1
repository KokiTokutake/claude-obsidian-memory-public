# save-session-notes.ps1 - Save Claude Code session insights to Obsidian Vault
# Structure: _Global/ for cross-project knowledge, Projects/<repo>/ for project-specific

param()

# ---- Config ---------------------------------------------------------------
$vaultBase    = 'C:\Users\USERNAME\OneDrive\ObsidianVault\ClaudeCode'
$globalDir    = Join-Path $vaultBase '_Global'
$globalIndex  = Join-Path $globalDir 'Index.md'
$globalSessDir = Join-Path $globalDir 'Sessions'
$projectsBase = Join-Path $vaultBase 'Projects'
$masterIndex  = Join-Path $vaultBase 'Index.md'
$projectsDir  = "$env:USERPROFILE\.claude\projects"
$claudeBin    = "$env:USERPROFILE\.local\bin\claude.exe"
$date         = Get-Date -Format 'yyyy-MM-dd'
$time         = Get-Date -Format 'HH-mm'

# ---- Read session_id from stdin -------------------------------------------
$stdinJson = ''
try { $stdinJson = [Console]::In.ReadToEnd() } catch {}
$sessionData = $null
try { $sessionData = $stdinJson | ConvertFrom-Json } catch {}
$sessionId = if ($sessionData -and $sessionData.session_id) { $sessionData.session_id } else { '' }

# ---- Find transcript file -------------------------------------------------
$transcriptPath = $null
if ($sessionId -and (Test-Path $projectsDir)) {
    $f = Get-ChildItem -Path $projectsDir -Recurse -Filter "$sessionId.jsonl" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { $transcriptPath = $f.FullName }
}
if (-not $transcriptPath -and (Test-Path $projectsDir)) {
    $f = Get-ChildItem -Path $projectsDir -Recurse -Filter '*.jsonl' -ErrorAction SilentlyContinue |
         Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($f) { $transcriptPath = $f.FullName }
}

# ---- Extract conversation text --------------------------------------------
$conversationParts = @()
$cwd = ''
if ($transcriptPath) {
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
}
$conversationText = $conversationParts -join "`n`n"
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
        $p2  = 'Classify each pattern and mistake as either global (applies to any project) or project-specific.'
        $p3  = '{'
        $p4  = '  "title": "One-line session title in Japanese (under 20 chars)",'
        $p5  = '  "summary": "2-3 sentence Japanese summary of what was accomplished",'
        $p6  = '  "global_patterns": ["Cross-project reusable approach in Japanese (up to 2 items)"],'
        $p7  = '  "project_patterns": ["This-project-specific approach in Japanese (up to 2 items)"],'
        $p8  = '  "global_mistakes": ["Cross-project pitfall in Japanese (up to 2 items)"],'
        $p9  = '  "project_mistakes": ["This-project-specific pitfall in Japanese (up to 2 items)"],'
        $p10 = '  "decisions": ["Key design/policy decision in Japanese (up to 2 items)"],'
        $p11 = '  "next_actions": "What to do next session in Japanese (1-2 sentences)"'
        $p12 = '}'
        $promptText = ($p1,$p2,$p3,$p4,$p5,$p6,$p7,$p8,$p9,$p10,$p11,$p12,'','Session log:',$conversationText) -join "`n"

        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $rawLines = $promptText | & $claudeBin --print --model claude-haiku-4-5-20251001 2>$null
        $rawJson  = ($rawLines -join "`n")
        if ($rawJson -match '(?s)\{[\s\S]+\}') { $rawJson = $Matches[0] }

        $parsed = $rawJson | ConvertFrom-Json
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
} elseif (-not $conversationText) {
    $summary = 'No conversation content found.'
} else {
    $summary = 'claude CLI not found. Add notes manually.'
}

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
$notePath = Join-Path $projectSessDir "$date $time.md"
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

# ---- Update _Global/Index.md ----------------------------------------------
if ((Test-Path $globalIndex) -and $parsedOk) {
    try {
        $idx = [System.IO.File]::ReadAllText($globalIndex, $utf8)
        if ($globalPatternsBlock) {
            $newP = ($parsed.global_patterns | Where-Object { $_ } | ForEach-Object { "- ($date) $_" }) -join "`n"
            $idx  = $idx -replace '(<!-- PATTERNS_START -->)', "`$1`n$newP"
        }
        if ($globalMistakesBlock) {
            $newM = ($parsed.global_mistakes | Where-Object { $_ } | ForEach-Object { "- ($date) $_" }) -join "`n"
            $idx  = $idx -replace '(<!-- MISTAKES_START -->)', "`$1`n$newM"
        }
        [System.IO.File]::WriteAllText($globalIndex, $idx, $utf8)
    } catch {}
}

# ---- Update Projects/<name>/Index.md --------------------------------------
if ((Test-Path $projectIndex) -and $parsedOk) {
    try {
        $idx = [System.IO.File]::ReadAllText($projectIndex, $utf8)
        $sesLink = "- [[$date $time]] - $sessionTitle"
        $idx = $idx -replace '(<!-- SESSIONS_START -->)', "`$1`n$sesLink"
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
