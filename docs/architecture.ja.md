# compact-plus アーキテクチャ

[English architecture](./architecture.md) | [README](../README.md) | [日本語 README](../README.ja.md)

compact-plus は、Claude Code の context compaction 前後で作業状態を保存・復旧する Claude Code plugin。Claude Code の圧縮処理そのものを置き換えず、公式 hook event を使って、圧縮前に transcript と構造化 state summary を保存し、圧縮後に復旧誘導を注入する。

## 1. 目的と対象外

### 目的

- Claude Code が context を圧縮する前に task state を保存する。
- compact 後の conversation summary の外側に復旧データを保持する。
- compact 直後の次 user prompt で、保存 state、関連 plan file、必要な原文 instruction source の再読を促す。
- hook failure は fail open にして、compaction 自体を妨げない。
- installed hook file を編集せず、LLM backend を設定で差し替えられるようにする。

### 対象外

- compact-plus は Claude Code 内部の compaction algorithm を変更しない。
- compact-plus は Claude Code の compaction prompt を置き換える公式設定を提供しない。確認した Claude Code 公式 docs では `/compact [instructions]` と hook による拡張点は公開されているが、Codex CLI の `compact_prompt` 相当の user setting は確認できない。
- compact-plus は Codex CLI session を直接管理しない。Codex は Claude Code plugin から fallback LLM backend として呼ぶ場合だけ関係する。
- compact-plus は base repository の statusline threshold hook を所有しない。その hook が書く marker を読むだけ。

## 2. Claude Code の compaction surface

Claude Code は `/compact` slash command で conversation を summarize し、context を空ける。`/compact focus on the current implementation plan` のように command 後へ任意テキストを渡すと、それが compact instruction として扱われる。

compact-plus に関係する Claude Code hook event:

| Event | compact-plus の用途 |
|---|---|
| `PreCompact` | compaction 前に transcript backup と state file 生成を行う |
| `PostCompact` | compaction 後に recovery marker を書き、warn cooldown を reset する |
| `UserPromptSubmit` | 次の user prompt で `additionalContext` に recovery guidance を注入する |

Claude Code plugin hook は `hooks/hooks.json` で設定する。`PreCompact` / `PostCompact` では `manual` と `auto` の matcher 値が公式 docs に記載されている。Claude Code docs では、これらの compact event に対して command / HTTP / MCP tool hook が示されており、compact-plus は command hook を使う。

Claude Code settings は `settings.json` の `env` key で environment variable を設定できる。compact-plus は backend と transcript tuning をこの設定面で受け取る。Claude Code docs には auto-compaction threshold percentage を変える `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` も記載されているが、これは compact-plus の state capture とは別の閾値設定。

## 3. Codex CLI の compaction surface

Codex CLI は Claude Code とは別の compaction model と configuration surface を持つ。この repository は Codex hook を install しないが、compact-plus が `codex exec` を fallback LLM backend として呼べるため、比較対象として重要。

Codex CLI 公式 docs で確認できる surface:

| Surface | 意味 |
|---|---|
| `/compact` | visible conversation を summarize して token を空ける |
| Auto compaction | 長い task で context space が不足すると Codex が自動 compact する場合がある |
| `model_auto_compact_token_limit` | auto compaction の token threshold |
| `compact_prompt` | compaction に使う inline prompt text |
| `experimental_compact_prompt_file` | compaction prompt file path |
| `PreCompact` / `PostCompact` hooks | manual / auto compaction 前後の command hook |
| Session transcripts | `$CODEX_HOME/sessions` 配下の local session data。default は `~/.codex/sessions` |

確認した Codex manual では、hook は command-only とされている。`PreCompact` / `PostCompact` hook には `turn_id` と `trigger` などが渡され、`trigger` は `manual` または `auto`。これらの event では plain text stdout は無視され、JSON output では `continue` などの common hook field が使える。

Codex が同梱する default の compaction prompt は明示的に handoff を指向している。テンプレート [`codex-rs/prompts/templates/compact/prompt.md`](https://github.com/openai/codex/blob/main/codex-rs/prompts/templates/compact/prompt.md) は圧縮を "CONTEXT CHECKPOINT COMPACTION" と位置づけ、圧縮 LLM に以下 4 セクションを含めるよう指示する:

1. 現在の進捗と主要な意思決定
2. 重要な context / 制約 / user preferences
3. 残作業 (次に取るべき step)
4. 継続に必要な重要データ / 例 / 参照

Codex ユーザーは無設定でこの handoff 設計の恩恵を受ける。

OpenAI Responses API にも `context_management` と `/responses/compact` endpoint による server-side context compaction がある。この API は encrypted compaction item を返すもので、Claude Code plugin hook とは別の仕組み。

## 4. compact 能力比較

| 能力 | Claude Code (baseline) | Codex CLI (built-in) | Claude Code + compact-plus |
|---|---|---|---|
| 圧縮前の構造化 state file | なし | なし (rollout file は transcript 全保持だが構造化された state artifact ではない) | 10 見出し state file を外部保存 |
| Transcript backup safety net | なし (transcript JSONL 実体は残る) | rollout file が全履歴保持 (`$CODEX_HOME/sessions`) | `~/.claude/backups/transcripts/` に世代管理 backup |
| 圧縮後の recovery 自動注入 | なし | 自作の SessionStart(source=compact) hook で可能 | `UserPromptSubmit` で自動注入 |
| 呼び出し済み skill の復元 | なし | なし | state file の `## Skills Invoked` から復元 |
| 圧縮 summary の scope drift 補正 | なし | なし | 「memory / rule / skill 言及は要約であり原文が authoritative」の factual note を注入 |
| user 側の priority guidance | `/compact [instructions]` を hook が受け取れる | `/compact` に相当 | Claude Code の instruction を state 生成 LLM に転送 |
| 閾値到達 warn 通知 | statusline に % 表示のみ | 独自実装が必要 | warn marker + reminder hook で明示的に通知 |
| 直近状態の recitation (Active Plan / Current Phase / 直近 Session Decision) | なし | なし | reminder hook が state 3 行を `additionalContext` 注入 |
| 手動 state 保存 skill | なし | なし | `/compact-plus` skill を提供 |
| 圧縮 LLM への handoff 構造化指示 | 公式には非公開、汎用 summarization 扱い | "CONTEXT CHECKPOINT COMPACTION" prompt を built-in で搭載、進捗/意思決定・context/制約・残作業・重要データ の 4 セクションを要求 | 圧縮 summary 自体は Claude Code に任せ、代わりに 10 見出し state file を圧縮対象の外に永続化し、圧縮後 hook で復元する |
| Compaction prompt 自体の差替 | 不可 | `compact_prompt` / `experimental_compact_prompt_file` で可 | 対象外 (compaction prompt ではなく hook 経路で state 保存する設計) |

Codex は 2 つの独自優位を持つ: user が compaction prompt を差し替えられる点と、default 自体が handoff 構造を持つ点。compact-plus は compaction prompt には一切手を入れず、代わりに handoff 構造を圧縮の外に置いた state file に持たせ、圧縮後の user prompt で復元させる。この間接化により Claude Code の公式拡張 surface に留まりながら Codex baseline に匹敵ないし超えるセッション継続を実現している。

## 5. Runtime flow

1. `PreCompact` が開始する。
2. `precompact-transcript-backup.sh` が transcript JSONL を `~/.claude/backups/transcripts/` に copy する。
3. `precompact-state-summary.sh` が設定済み mode に従って transcript を読む。
   - `incremental`: 前回 offset 以降の new bytes を読み、一定周期で full refresh する。
   - `head-tail`: 初期 context と直近 context を残す。
   - `tail`: 直近 context だけを残す。
4. `precompact-state-summary.sh` が大きな Read / Bash output に tool output squash を適用する。
5. script が primary backend を呼ぶ。失敗し、fallback が有効なら fallback backend を呼ぶ。
6. state file を `${TMPDIR:-/tmp}/claude-compact-state/<session_id>.md` に書く。
7. `PostCompact` が開始する。
8. `compaction-recovery.sh` が `${TMPDIR:-/tmp}/claude-compacted/<session_id>` を書き、warn cooldown marker を削除する。
9. 次の user prompt で `userpromptsubmit-compaction-recovery.sh` が recovery marker を consume し、以下を注入する。
   - state file path
   - active plan path があればその path
   - original-source factual note
   - Skills Invoked があれば skill 再読 guidance
10. statusline warning marker があれば、`userpromptsubmit-compact-plus-reminder.sh` が consume し、compact suggestion と短い state recitation を注入する。

## 6. State file format

LLM generated state file と `/compact-plus` manual state file は同じ heading order を使う。

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

heading order を固定することで、compaction 後の hook と agent が同じ順序で state を確認できる。state file は original project files、rules、skills、plans より authoritative ではない。recovery guidance は、compacted summary にそれらの言及がある場合、原文 source を再読するよう明示する。

## 7. Marker files と所有関係

| Path | Writer | Reader | Ownership rule |
|---|---|---|---|
| `${TMPDIR:-/tmp}/claude-compact-state/<session_id>.md` | `precompact-state-summary.sh` または `/compact-plus` skill | recovery hook と agent | State payload。state generation ごとに上書き |
| `${TMPDIR:-/tmp}/claude-compact-state-offset/<session_id>` | `precompact-state-summary.sh` | `precompact-state-summary.sh` | Incremental transcript offset。state generation 内部用 |
| `${TMPDIR:-/tmp}/claude-compact-state-counter/<session_id>` | `precompact-state-summary.sh` | `precompact-state-summary.sh` | Refresh cadence counter。state generation 内部用 |
| `${TMPDIR:-/tmp}/claude-compacted/<session_id>` | `compaction-recovery.sh` | `userpromptsubmit-compaction-recovery.sh` | One-shot recovery trigger。次 user prompt で consume |
| `${TMPDIR:-/tmp}/claude-compact-warn/<session_id>` | base repository statusline hook | `userpromptsubmit-compact-plus-reminder.sh` | Threshold warning。compact-plus は producer を所有しない |
| `${TMPDIR:-/tmp}/claude-compact-warned/<session_id>` | `userpromptsubmit-compact-plus-reminder.sh` | statusline side と recovery hook | Notification cooldown |
| `${TMPDIR:-/tmp}/claude-active-plan/<session_id>` | plan-management hook | recovery hook | Active plan pointer。compact-plus は producer を所有しない |

hook scripts は fail open する。marker がない、壊れている、またはすでに consume 済みの場合も、user prompt や compaction を block しない。

## 8. Configuration boundaries

compact-plus が所有する environment variable:

| env var | Scope |
|---|---|
| `COMPACT_PLUS_PRIMARY_BACKEND` | Primary LLM backend command |
| `COMPACT_PLUS_FALLBACK_BACKEND` | Fallback LLM backend command |
| `COMPACT_PLUS_TRANSCRIPT_MODE` | Transcript selection mode |
| `COMPACT_PLUS_TRANSCRIPT_HEAD_TURNS` | Head-side turn count |
| `COMPACT_PLUS_TRANSCRIPT_TAIL_TURNS` | Tail-side turn count |
| `COMPACT_PLUS_TRANSCRIPT_HEAD_KB` | Head-side byte cap |
| `COMPACT_PLUS_TRANSCRIPT_TAIL_KB` | Tail-side byte cap |
| `COMPACT_PLUS_INCREMENTAL_REFRESH` | Full refresh cadence |
| `COMPACT_PLUS_MAX_OUTPUT_TOKENS` | Backend output cap |
| `COMPACT_PLUS_SQUASH_ENABLED` | Tool output squash toggle |
| `COMPACT_PLUS_SQUASH_READ_LINES` | Read output squash threshold |
| `COMPACT_PLUS_SQUASH_BASH_CHARS` | Bash output squash threshold |
| `COMPACT_PLUS_TWO_PASS` | Two-pass critique toggle |

`COMPACT_WARN_THRESHOLD` は base repository が所有する。producer が `home/hooks/claude/statusline.sh` だから。compact-plus は resulting warning marker を読むだけ。

## 9. Source notes

上記の architecture 記述は以下の公式 docs で確認した。

- [Claude Code slash commands](https://code.claude.com/docs/en/commands)
- [Claude Code hooks](https://code.claude.com/docs/en/hooks)
- [Claude Code settings](https://code.claude.com/docs/en/settings)
- [Claude Code environment variables](https://code.claude.com/docs/en/env-vars)
- [OpenAI Codex hooks](https://developers.openai.com/codex/hooks)
- [OpenAI Codex config reference](https://developers.openai.com/codex/config-reference)
- [OpenAI Codex manual](https://developers.openai.com/codex/codex-manual.md)
- [OpenAI Responses API compaction guide](https://developers.openai.com/api/docs/guides/compaction)
