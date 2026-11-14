# Claude Code × Obsidian 自動メモリシステム

Claude Code のセッションが終了するたびに、AI が会話内容を要約して Obsidian Vault へ自動保存する仕組みです。知見はグローバル（全プロジェクト共通）とプロジェクト固有に分類して管理されます。

## 何ができるか

- セッション終了 → Stop Hook → AI 要約 → Obsidian 保存が**完全自動**
- **二層知識管理**: PowerShell・CLI 等の汎用ノウハウは `_Global/`、リポジトリ固有の決定や規約は `Projects/<リポジトリ名>/` へ自動分類
- セッション開始時に Claude が両方のインデックスを自動読み込み → 過去の知見を即座に活用
- セッションノートは `Projects/<repo>/Sessions/YYYY-MM-DD HH-mm.md` に保存

## ディレクトリ構成

```
ObsidianVault/ClaudeCode/
├── Index.md                   ← マスター（プロジェクト一覧）
├── _Global/
│   ├── Index.md               ← 全プロジェクト共通の知見（厳選版・約200行。毎セッション全文を読む）
│   ├── Inbox.md               ← Stop Hook が追記する未整理の新しい知見
│   ├── archive/               ← 過去の全記録・統合済みInbox・厳選版のバックアップ・統合ログ
│   └── Sessions/
└── Projects/
    └── <リポジトリ名>/
        ├── Index.md           ← プロジェクト固有の知見
        └── Sessions/
            └── 2026-05-23 15-42.md
```

```
~/.claude/
├── settings.json              ← Stop Hook 登録
├── save-session-notes.ps1     ← メイン処理スクリプト
├── consolidate-global-index.ps1 ← 週1回 Inbox を厳選版 Index に統合（タスクスケジューラ ClaudeObsidianConsolidate）
└── rules/
    └── obsidian_memory.md     ← セッション開始時の読み込み指示
```

## セットアップ

### 前提条件

- Windows 10/11
- [Claude Code CLI](https://claude.ai/download) インストール済み・ログイン済み
- Obsidian インストール済み（Vault のフォルダは任意）

### インストール

```powershell
# デフォルト Vault パスの場合
powershell -ExecutionPolicy Bypass -File setup.ps1

# Vault パスを指定する場合
powershell -ExecutionPolicy Bypass -File setup.ps1 -VaultPath "D:\MyVault\ClaudeCode"
```

setup.ps1 が以下を自動実行します：

1. Vault ディレクトリ構造を作成（`_Global/`, `Projects/`）
2. `save-session-notes.ps1` を `~/.claude/` にコピー（Vault パスを書き換え）
3. `obsidian_memory.md` を `~/.claude/rules/` にコピー
4. `~/.claude/settings.json` に Stop Hook を追加
5. `claude.exe` の存在確認

### 動作確認

Claude Code セッションを終了し、以下を確認：

```
ObsidianVault/ClaudeCode/_Global/Index.md        ← グローバル知見が追加されている
ObsidianVault/ClaudeCode/Projects/<repo>/Index.md ← プロジェクト固有知見が追加されている
ObsidianVault/ClaudeCode/Projects/<repo>/Sessions/ ← セッションノートが生成されている
```

## 技術的な注意点

| 問題 | 原因 | 対処 |
|------|------|------|
| 日本語が文字化け | PS5.1 の CP932 デフォルト | スクリプトを UTF-8 BOM 付きで保存 + `[Console]::OutputEncoding = UTF8` |
| AI 要約が動かない | `claude.exe` が見つからない | `~/.local/bin/claude.exe` のパスを確認 |
| Hook が実行されない | ExecutionPolicy | Hook コマンドに `-ExecutionPolicy Bypass` を含める |
| JSON パースエラー | 配列のまま正規表現 | `($rawLines -join "\`n")` で文字列化してから処理 |

## ファイル説明

| ファイル | 役割 |
|----------|------|
| `setup.ps1` | ワンコマンドインストーラー |
| `scripts/save-session-notes.ps1` | Stop Hook から呼ばれるメイン処理 |
| `rules/obsidian_memory.md` | Claude にインデックス読み込みを指示するルール |
| `templates/Global-Index.md` | `_Global/Index.md` の初期テンプレート |
| `templates/Project-Index.md` | `Projects/<name>/Index.md` のテンプレート |
| `docs/index.html` | システム解説 HTML |

## データフロー

```
セッション終了
  → Stop Hook 発火
  → save-session-notes.ps1 実行
  → JSONL トランスクリプト抽出
  → git rev-parse でリポジトリ名検出
  → claude.exe --print で AI 要約（global / project に自動分類）
  → _Global/Inbox.md に追記（グローバル知見。具体的なものだけ・通常は0件）
  → Projects/<repo>/Index.md 更新（プロジェクト固有知見）
  → Projects/<repo>/Sessions/ にセッションノート保存
  → マスター Index.md にプロジェクト登録

毎週日曜 12:00（タスクスケジューラ。PCが起動していなければ次回起動時）
  → consolidate-global-index.ps1 が Inbox を Index.md に統合（重複は支持件数に加算、一般論は捨てる、各60件・全体260行以内）
  → 出力を検証してから書き込み（マーカー・行数・項目の激減をチェック）、旧版は archive/ にバックアップ

次のセッション開始
  → obsidian_memory.md により _Global/Index.md を読み込み
  → Projects/<repo>/Index.md を読み込み
  → 過去の知見を活用して作業開始
```

## ライセンス

[MIT License](LICENSE) です。
