# compact-plus

[English README](./README.md) | [アーキテクチャ](./docs/architecture.ja.md)

Claude Code と Codex の `/compact` 前後で作業状態を保存・復旧する透過型プラグイン。どちらの圧縮アルゴリズムも置き換えず、公式 hook 経路で圧縮前後を強化する。

## 何ができるか

- 圧縮前に transcript を backup し、LLM で 10 見出しの state file を書き出す
- 圧縮後に state file、plan file、原文再読 note を additionalContext として注入する
- transcriptで機械的に観測できたskillとcommandを復元する。Codexで観測できないskillは`Not verified`と記録する
- コンテキスト使用率がruntime別の指定閾値を超えたら、次のuser promptで`/compact`を推奨する通知を出す
- 通知と同時に state file の Active Plan / Current Phase / 直近 Session Decision を 3 行 additionalContext に注入し、圧縮直前まで agent が作業の大局を見失わないようにする (compact 動作そのものは変わらないが、warn 発火から実 `/compact` までの数ターンで agent が脱線するのを防ぐ focus 補助)
- `/compact-plus` skill で手動 state 保存もできる

## 使い方

インストール後は普通に `/compact` を実行するだけで動く。**追加の操作は不要**、完全透過型。

- 手動 `/compact` でも auto-compact でも同じ経路で hook が発火する
- 圧縮前: transcript backup と 10 見出し state file 生成が PreCompact hook で自動実行される
- 圧縮後: Claude CodeとCodexは最初のpost-compaction prompt前に`SessionStart(source=compact)`でstateを一度だけ自動注入する
- agent が特定 skill を呼ぶ必要も、事前に何かを実行する必要もない

任意で強化する場合:

- `/compact 重要な設計判断は必ず残して` のように引数を付けると、その内容が state 生成 LLM への priority guidance になる
- 復旧メモを厚く残したい時は圧縮直前に `/compact-plus` を明示的に呼ぶと、agent 自身が構造化 state を書く手動 fallback 経路に入る

## 前提

- Claude Code v2.x 以降、またはplugin compaction hook対応のCodex
- LLM backend として `claude -p` または `codex exec`
- default 構成では primary に `claude -p --model claude-sonnet-5 --effort medium`、fallback に `codex exec --model gpt-5.3-codex-spark` を使う
- fallback の Codex Spark は ChatGPT Pro が前提。`gpt-5.4` / `gpt-5.5` などへ切り替え可能

## インストール

### Claude Code

このGitHub repositoryをmarketplaceとして追加し、そこからpluginをinstallする。

```bash
claude plugin marketplace add u-ichi/compact-plus --scope user
claude plugin install compact-plus@compact-plus
```

### Codex

同じGitHub repositoryをmarketplaceとして追加し、Codex pluginをinstallする。

```bash
codex plugin marketplace add u-ichi/compact-plus
codex plugin add compact-plus@compact-plus
```

Codexが確認を求めたらhook定義をreviewして信頼する。
install済みのpluginとhookを読み込ませるため、install後は新しいthreadを開始する。

### 更新

GitHub marketplaceのsnapshotを更新してから、pluginを更新または再installする。

```bash
# Claude Code
claude plugin update compact-plus@compact-plus

# Codex
codex plugin marketplace upgrade compact-plus
codex plugin add compact-plus@compact-plus
```

ローカル開発では、marketplace追加commandの`u-ichi/compact-plus`をこのrepositoryの絶対pathへ置き換える。
plugin参照は`compact-plus@compact-plus`のまま変えない。

## 設定

Claude Code plugin の標準に従い、`~/.claude/settings.json` の `env` block に env var を書く。session ごとの一時上書きは shell の `export` でもよい。

### backend 上書き

primary / fallback を丸ごと差し替える env var は 2 個。

| env var | 意味 |
|---|---|
| `COMPACT_PLUS_PRIMARY_BACKEND` | primary で実行する shell コマンド全体。空文字列 (`""`) で primary skip |
| `COMPACT_PLUS_FALLBACK_BACKEND` | fallback で実行する shell コマンド全体。空文字列で fallback skip |

コマンド内で参照できる env var:

- `$SYSTEM_PROMPT`: LLM 用 system prompt (`prompts/state-summary.md` の内容)
- `$SESSION_ID`: Claude Code session id
- `$TRANSCRIPT_PATH`: transcript JSONL path
- `$MAX_OUTPUT_TOKENS`: LLM 出力上限

デフォルト値は `hooks/precompact-state-summary.sh` に直書きしている。

`~/.claude/settings.json` 例。Haiku で安く済ませたい場合:

```json
{
  "env": {
    "COMPACT_PLUS_PRIMARY_BACKEND": "claude -p --model claude-haiku-4-5-20251001 --effort low --permission-mode dontAsk --output-format text --no-session-persistence --system-prompt \"$SYSTEM_PROMPT\""
  }
}
```

primary を Codex Spark に差し替える例 (ChatGPT Pro 前提、Cerebras 経由で高速):

```json
{
  "env": {
    "COMPACT_PLUS_PRIMARY_BACKEND": "tmp=$(mktemp \"${TMPDIR:-/tmp}/compact-plus-codex.XXXXXX\"); { printf \"%s\\n\\n\" \"$SYSTEM_PROMPT\"; cat; } | codex exec --model gpt-5.3-codex-spark --sandbox read-only --skip-git-repo-check --dangerously-bypass-hook-trust --ignore-user-config --ephemeral --output-last-message \"$tmp\" - >/dev/null && cat \"$tmp\"; status=$?; rm -f \"$tmp\"; exit \"$status\""
  }
}
```

Codex 経路は stdout に preamble が混ざる場合があるため、`--output-last-message "$tmp"` で最終メッセージだけ取り出す必要がある (これは default fallback の実装と同じ形)。

fallback を無効化する例:

```json
{
  "env": {
    "COMPACT_PLUS_FALLBACK_BACKEND": ""
  }
}
```

### transcript / squash / two-pass のチューニング env

| env var | default | 意味 |
|---|---|---|
| `COMPACT_PLUS_TRANSCRIPT_MODE` | `incremental` | `incremental` / `head-tail` / `tail` |
| `COMPACT_PLUS_TRANSCRIPT_HEAD_TURNS` | `5` | head 側で切り出す turn 数 |
| `COMPACT_PLUS_TRANSCRIPT_TAIL_TURNS` | `25` | tail 側で切り出す turn 数 |
| `COMPACT_PLUS_TRANSCRIPT_HEAD_KB` | `10` | head 側 byte cap (KB) |
| `COMPACT_PLUS_TRANSCRIPT_TAIL_KB` | `40` | tail 側 byte cap (KB) |
| `COMPACT_PLUS_INCREMENTAL_REFRESH` | `10` | N 回に 1 回全再構築。`0` で無効 |
| `COMPACT_PLUS_MAX_OUTPUT_TOKENS` | `4096` | LLM 出力上限。backend が参照する場合に使う |
| `COMPACT_PLUS_SQUASH_ENABLED` | `1` | tool_result squash on/off |
| `COMPACT_PLUS_SQUASH_READ_LINES` | `100` | Read tool `> N` 行で `[Read: N lines from path]` に置換 |
| `COMPACT_PLUS_SQUASH_BASH_CHARS` | `500` | Bash tool `> N` chars で `[Bash: exit code, N chars output]` に置換 |
| `COMPACT_PLUS_TWO_PASS` | `1` | 2-pass self-critique on/off |

### warn 閾値

Claude CodeとCodexは別設定を使う。

| runtime | env var | default | 取得元 |
|---|---|---:|---|
| Claude Code | `COMPACT_WARN_THRESHOLD` | base repository設定 | `home/hooks/claude/statusline.sh`がmarkerを生成 |
| Codex | `COMPACT_PLUS_CODEX_WARN_THRESHOLD` | `75` | 現在threadのrolloutにある最新token-count event |

どちらもコンテキスト**使用率**。片方の変更はもう片方へ影響しない。Codexは表示と同じ実効window基準を使い、現在の固定baseline 12,000 tokenを分子・分母から除外する。rolloutの`session_meta.id`と現在の`session_id`の一致も確認し、欠損・不正・不一致なら通知しない。

### `/compact` 引数

`/compact 重要な設計判断は必ず残して` のように任意の自然文引数を渡すと、state 生成 LLM に priority guidance として反映される。

## 動作フロー

1. **PreCompact hook**
   - `precompact-transcript-backup.sh` が transcript JSONL を `~/.claude/backups/transcripts/` または `${CODEX_HOME:-$HOME/.codex}/backups/transcripts/` にコピーする
   - `precompact-state-summary.sh` が transcript を semantic chunking + tool output squash 後、primary / fallback backend で LLM を呼び、10 見出しの state file を書く
2. **PostCompact hook**
   - `compaction-recovery.sh` が recovery marker を書き、warn cooldown をリセットする
3. **復旧hook**
   - `sessionstart-compaction-recovery.sh` がClaude CodeとCodexの`SessionStart(source=compact)`を処理する
   - recovery markerを一度だけconsumeし、保存済みstate本文、存在する場合のactive plan参照、original-source reminderを`additionalContext`へ注入する
   - `userpromptsubmit-compact-plus-reminder.sh` が warn marker 検知時に軽い notification と state 3 行 recitation を additionalContext に注入する
   - `userpromptsubmit-compaction-recovery.sh` は fallback channel として登録を維持する。Codexがstart hookを配送するのはroot threadだけであり、親がspawnしたsubagentには圧縮後のstart hookが来ないため、復旧は次の`UserPromptSubmit`で届く (親からの送信はsubagentにはuser inputとして入る)。markerは1度で消費されるので、`SessionStart`で復旧済みのthreadは次のpromptでは何もしない
4. **手動 fallback (`/compact-plus` skill)**
   - agent 自身が SKILL.md の 10 見出し手順に従って state file を書く

## state file 見出し構成

`# Compact Prep State` から始まる 10 見出し。SKILL.md 手動手順と LLM 生成の両方で同じ順序を使う。

1. `## Active Plan`
2. `## Current Phase`
3. `## TaskList Summary`
4. `## Session Decisions`
5. `## Constraints and Blockers`
6. `## Worker Topology`
7. `## Skills Invoked`
8. `## Editing Files`
9. `## Failed Attempts`
10. `## Recovery Notes`

## marker ファイル

| path | writer | reader | 目的 |
|---|---|---|---|
| `${TMPDIR}/claude-compact-state/<session_id>.md` | `precompact-state-summary.sh` / `/compact-plus` skill | recovery hook / agent | 圧縮前 state |
| `${TMPDIR}/claude-compact-state-offset/<session_id>` | `precompact-state-summary.sh` | `precompact-state-summary.sh` | incremental 用 byte offset |
| `${TMPDIR}/claude-compact-state-counter/<session_id>` | `precompact-state-summary.sh` | `precompact-state-summary.sh` | refresh cycle counter |
| `${TMPDIR}/claude-compacted/<session_id>` | `compaction-recovery.sh` | `sessionstart-compaction-recovery.sh` | one-shot PostCompact marker |
| `${TMPDIR}/claude-compact-warn/<session_id>` | base repo `statusline.sh` | `userpromptsubmit-compact-plus-reminder.sh` | 閾値超過通知 |
| `${TMPDIR}/claude-compact-warned/<session_id>` | `userpromptsubmit-compact-plus-reminder.sh` | statusline / recovery hook | 通知 cooldown |
| `${TMPDIR}/claude-active-plan/<session_id>` | plan-management hook | recovery hook | active plan path |
| `${TMPDIR}/codex-compact-state/<thread_id>.md` | `precompact-state-summary.sh` / `/compact-plus` skill | Codex recovery hook / agent | Codex圧縮前state |
| `${TMPDIR}/codex-compacted/<thread_id>` | `compaction-recovery.sh` | `sessionstart-compaction-recovery.sh` | Codex one-shot recovery marker |
| `${TMPDIR}/codex-compact-warned/<thread_id>` | reminder hook | reminder / recovery hook | Codex通知cooldown |

Codexの`<thread_id>`は実際に圧縮したthreadを指す。hook入力の`session_id`はroot threadと全子孫で共有するidで、親がspawnしたsubagentにはさらに`agent_id`が付く。そのため成果物のキーは`agent_id`があればそれを使い、無い時だけ`session_id`を使う (`scripts/runtime-paths.sh`の`compact_plus_artifact_key`)。`session_id`だけで名前を付けると、subagentのstateが親の名前で保存され、親のstate fileを上書きしてしまう。

## Architecture

設計、Claude Code / Codex CLI の compact 仕様比較、marker file の所有関係は [docs/architecture.ja.md](./docs/architecture.ja.md) を参照。

## Development Checks

```bash
python3 -m json.tool .claude-plugin/plugin.json >/dev/null
python3 -m json.tool .claude-plugin/marketplace.json >/dev/null
python3 -m json.tool .codex-plugin/plugin.json >/dev/null
python3 -m json.tool .agents/plugins/marketplace.json >/dev/null
python3 -m json.tool hooks/hooks.json >/dev/null
bash -n hooks/*.sh scripts/*.sh tests/*.sh
bash tests/test-runtime.sh
```
