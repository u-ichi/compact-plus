# compact-plus アーキテクチャ

[English architecture](./architecture.md) | [README](../README.md) | [日本語 README](../README.ja.md)

compact-plus は、Claude Code と Codex の context compaction 前後で作業状態を保存・復旧するplugin。どちらの圧縮処理も置き換えず、公式hook eventを使って、圧縮前にtranscriptと構造化state summaryを保存し、圧縮後に復旧誘導を注入する。

## 1. 目的と対象外

### 目的

- Claude CodeまたはCodexがcontextを圧縮する前にtask stateを保存する。
- compact 後の conversation summary の外側に復旧データを保持する。
- compact 直後の次 user prompt で、保存 state、関連 plan file、必要な原文 instruction source の再読を促す。
- hook failure は fail open にして、compaction 自体を妨げない。
- installed hook file を編集せず、LLM backend を設定で差し替えられるようにする。

### 対象外

- compact-plusはClaude CodeまたはCodex内部のcompaction algorithmを変更しない。
- compact-plus は Claude Code の compaction prompt を置き換える公式設定を提供しない。確認した Claude Code 公式 docs では `/compact [instructions]` と hook による拡張点は公開されているが、Codex CLI の `compact_prompt` 相当の user setting は確認できない。
- compact-plusは`/compact`を発火せず、terminal入力を注入しない。Herdrによる強制自動compactは別設計とする。
- compact-plusはbase repositoryのClaude statusline threshold hookを所有せず、そのmarkerを読む。Codex通知はpluginが現在threadのrolloutから算出する。

## 2. Claude Code の compaction surface

Claude Code は `/compact` slash command で conversation を summarize し、context を空ける。`/compact focus on the current implementation plan` のように command 後へ任意テキストを渡すと、それが compact instruction として扱われる。

compact-plus に関係する Claude Code hook event:

| Event | compact-plus の用途 |
|---|---|
| `PreCompact` | compaction 前に transcript backup と state file 生成を行う |
| `PostCompact` | compaction 後に注入済み印を consume するか recovery marker を書き、warn cooldown を reset する |
| `SessionStart`, matcher `compact` | 最初のpost-compaction prompt前に保存済みstateを`additionalContext`へ注入する |
| `UserPromptSubmit` | `SessionStart(source=compact)` が届かなかった thread への fallback 経路 |

Claude Codeは1回のcompactionの中で`SessionStart(source=compact)`を`PostCompact`より**先**に配送する。これはCodexと逆順である。この順序差を吸収するhandshakeは第5節に書く。

Claude Code plugin hook は `hooks/hooks.json` で設定する。`PreCompact` / `PostCompact` では `manual` と `auto` の matcher 値が公式 docs に記載されている。Claude Code docs では、これらの compact event に対して command / HTTP / MCP tool hook が示されており、compact-plus は command hook を使う。

Claude Code settings は `settings.json` の `env` key で environment variable を設定できる。compact-plus は backend と transcript tuning をこの設定面で受け取る。Claude Code docs には auto-compaction threshold percentage を変える `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` も記載されているが、これは compact-plus の state capture とは別の閾値設定。

## 3. Codex CLI の compaction surface

Codex CLIはClaude Codeとは別のcompaction modelとconfiguration surfaceを持つ。compact-plusはCodex plugin manifestを同梱し、manual/auto compaction前後のCodex hookを使う。

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

確認したCodex manualではhookはcommand-only。`PreCompact` / `PostCompact`には`session_id`、`turn_id`、`transcript_path`、`trigger`などが渡され、`trigger`は`manual`または`auto`。`SessionStart`はmatcher `compact`と`additionalContext`を使える。transcript形式はstable interfaceではないため、parse失敗時はfail openとする。

### compact-plusがCodexへ追加する処理

Codex pluginはClaude Code pluginと同じstate生成scriptを使うが、`scripts/runtime-paths.sh`が`PLUGIN_ROOT` environment variableからruntimeを判定し、保存先を分離する。
Codex用state、incremental offset、refresh counter、recovery marker、plan pointer、通知cooldown、transcript backupはClaude Code sessionとpathを共有しない。
Codexのtranscript backupは`${CODEX_HOME:-$HOME/.codex}/backups/transcripts/`へ保存する。

manual compactとauto compactionは同じCodex hook sequenceを通る。

1. `PreCompact`が現在のthread idに対応するversioned transcript backupと構造化state fileを作る。
2. `PostCompact`がone-shot recovery markerを書き、そのthreadの通知cooldownを削除する。
3. compact直後の継続はCodex標準のcompact summaryが担う。
4. 最初のpost-compaction prompt前に`SessionStart(source=compact)`がmarkerをconsumeし、保存済みstate本文、任意のplan path、原文再読reminderを`additionalContext`へ追加する。

上の「現在のthread id」は、hook入力に`agent_id`があればその値、無ければ`session_id`である。Codexの`session_id`はroot threadと全子孫で共有するidで、親がspawnしたsubagentにはさらに`agent_id`が付く。`session_id`だけでキーを作ると、subagentのstateが親の名前で保存され、親のstate fileを上書きしてしまう。

手順4はroot threadだけに当てはまる。Codexがthread-spawn subagentへstart hookを配送するのはstart sourceが`Startup`の時だけで、圧縮後のsubagentにはstart hookが来ない。そのためsubagentの復旧は次の`UserPromptSubmit`で届く (親からの送信はsubagentにuser inputとして入るのでこのhookは動く)。どちらの経路も同じone-shot markerを読むので、注入するのは一方だけになる。

Codex通知はClaude Codeのstatusline markerに依存しない。
compact-plusは対象promptごとに現在transcriptの末尾500 recordから最新の利用可能な`token_count` eventを読み、rolloutの`session_meta.id`とhook inputの`session_id`が一致することを先に確認する。
transcript欠損、`session_meta`の読取不能またはthread id不一致、末尾500 record内に利用可能な`token_count` eventがない場合は通知しない。
新しいeventが利用不能でも、同じ範囲にある以前の利用可能なeventは候補に残す。

確認したCodex runtimeでは、context表示に固定12,000 tokenのbaselineが含まれる。
compact-plusは同じ実効window基準で使用率を算出する。

```text
実効使用率 =
  max(total tokens - 12,000, 0)
  / (model context window - 12,000)
  * 100
```

`COMPACT_PLUS_CODEX_WARN_THRESHOLD`が通知開始点を制御し、defaultは`75`。
`1`から`100`の範囲外は`75`へ戻す。
通知後はthread別cooldownが再通知を抑え、`PostCompact`がcooldownを削除する。
state fileがあれば、Active Plan、Current Phase、直近のSession Decisionも通知へ追加する。

この処理は作業の区切りで`/compact`を提案するだけで、command実行やterminal入力注入は行わない。
Herdrによる強制compactは別設計とする。

Codex が同梱する default の compaction prompt は明示的に handoff を指向している。テンプレート [`codex-rs/prompts/templates/compact/prompt.md`](https://github.com/openai/codex/blob/main/codex-rs/prompts/templates/compact/prompt.md) は圧縮を "CONTEXT CHECKPOINT COMPACTION" と位置づけ、圧縮 LLM に以下 4 セクションを含めるよう指示する:

1. 現在の進捗と主要な意思決定
2. 重要な context / 制約 / user preferences
3. 残作業 (次に取るべき step)
4. 継続に必要な重要データ / 例 / 参照

Codex ユーザーは無設定でこの handoff 設計の恩恵を受ける。

OpenAI Responses API にも `context_management` と `/responses/compact` endpoint による server-side context compaction がある。この API は encrypted compaction item を返すもので、Claude Code plugin hook とは別の仕組み。

## 4. compact 能力比較

「圧縮を挟んでもセッションを続けられるか」という user 効能の軸で 3 者を比較する (実装手段ではなく効能を行に取っている)。

| 効能 | Claude Code (baseline) | Codex CLI (built-in) | Claude CodeまたはCodex + compact-plus |
|---|---|---|---|
| 圧縮後もセッション目的 (goal) が保存される | △ (非構造化 summary 依存で薄まりやすい) | ○ (CONTEXT CHECKPOINT prompt が「進捗 / 意思決定」を必須セクション化) | ○ (`## Active Plan` / `## Current Phase` に外部化) |
| 圧縮後に残作業が明確に引き継がれる | △ (同上) | ○ (「remaining work (clear next steps)」を必須セクション化) | ○ (`## TaskList Summary` / `## Recovery Notes` に外部化) |
| 圧縮後に重要な意思決定が保存される | △ (同上) | ○ (「key decisions made」を必須セクション化) | ○ (`## Session Decisions` として独立見出しに外部化) |
| 圧縮後に呼び出し済みskillを復元できる | × | × | transcript証拠がある場合は○、なければ`Not verified` |
| 圧縮 summary の memory / rule 言及による scope drift を補正できる | × | × | ○ (recovery hook が「原文優先」factual note を注入) |
| ユーザーが自然文で「これは残せ」とpriority指示できる | △ (`/compact <text>`はhookまで届くがbuilt-in summaryへの反映は未文書化) | × (compactごとの自然文argumentは未文書化) | Claude: ○ (instructionをstate生成LLMへ転送)、Codex: × (compact前にconversationまたはstateへpriorityを記録する) |
| 圧縮してもtranscript実体が保持される | ○ (transcript JSONL) | ○ (rollout file全保持) | ○ (加えてruntime別versioned backup) |
| コンテキスト限界の手前でagent / userに気づかせる | △ (statusline %表示のみ) | × (独自実装が必要) | ○ (Claude markerまたはCodex token-count通知 + 3行recitation) |
| 復旧メモを agent 自身が構造化して書ける手動経路がある | × | × | ○ (`/compact-plus` skill) |
| 圧縮 summary の作られ方をユーザーが差替えできる | × | ○ (`compact_prompt` / `experimental_compact_prompt_file`) | 対象外 (compaction prompt には手を入れない設計) |

compact-plusはどちらのcompaction promptにも手を入れず、構造化stateを圧縮の外へ置いて後段のrecoveryで戻す。これによりClaude CodeとCodexの双方へ、明示的な復旧参照とruntime別の閾値通知を追加する。

## 5. Runtime flow

1. `PreCompact` が開始する。
2. `precompact-transcript-backup.sh`がtranscript JSONLをruntime別backup directoryへcopyする。
3. `precompact-state-summary.sh` が設定済み mode に従って transcript を読む。
   - `incremental`: 前回 offset 以降の new bytes を読み、一定周期で full refresh する。
   - `head-tail`: 初期 context と直近 context を残す。
   - `tail`: 直近 context だけを残す。
4. `precompact-state-summary.sh` が大きな Read / Bash output に tool output squash を適用する。
5. script が primary backend を呼ぶ。失敗し、fallback が有効なら fallback backend を呼ぶ。
6. state fileをruntime別state directoryへ書く。
7. compaction hookが走る。発火順はruntimeで異なるため、次の8と9は互いに逆順になる。
   - Claude Code: `SessionStart(source=compact)` が先、`PostCompact` が後。
   - Codex: `PostCompact` が先、`SessionStart(source=compact)` が後。
8. `compaction-recovery.sh`がwarn cooldown markerを削除する。注入済み印がある場合は`SessionStart`が既にstateを届けているので、その印をconsumeしrecovery markerを書かない。無い場合はruntime別markerを書く。
9. `sessionstart-compaction-recovery.sh`が最初のpost-compaction prompt前に注入する。存在するhandshake signalに応じて動く。markerがあれば`PostCompact`が先に走ったということなのでそれをconsumeする。markerが無くstate fileがあれば`SessionStart`が先に走ったということなので、注入した上で8のために注入済み印を残す。どちらも無ければ何もせず、`PostCompact`から`UserPromptSubmit`へのfallbackを残す。Codexのthread-spawn subagentは圧縮後にstart hookが来ないため、常にこのfallbackで復旧する。recovery hookは以下を注入する。
   - 保存済みstate file本文 (30720 bytesで打ち切り、全文fileへのpathを併記)
   - active plan path があればその path
   - original-source factual note
10. Claudeはstatusline warning markerをconsumeする。Codexは現在threadの最新token-count eventから使用率を算出し、`COMPACT_PLUS_CODEX_WARN_THRESHOLD`（default `75`）で通知する。

注入済み印は実際に出力を出した`SessionStart`だけが書くので、このhookを配送しないruntimeでは印が生まれず、`PostCompact`は`UserPromptSubmit` fallback用のmarkerを書き続ける。

印は「対象のstate fileより新しい間」だけ有効として扱う。hook timeoutやprocess killで`PostCompact`が完走しないと印が残る。これを無条件に信頼すると次のcompactionが全経路で消える。`SessionStart`は印を見て黙り、`PostCompact`はmarkerを書かずに印をconsumeし、fallbackには配るものが無い、という連鎖になるためである。timestampで比較すれば、次の`PreCompact`が印より新しいstate fileを書くので、leakした印の被害はleak元のcompaction 1回に閉じる。timestampが同値の場合は配送済みとして扱う。印は必ずstate fileより後に書かれるので、同値は同一compactionを意味するからである。

注入本文にはstate fileの生成時刻も入れる。`PreCompact`のbackendが失敗した回は前回のstate fileがそのまま再注入されるため、その時刻が「このstateは今回圧縮した作業より前のものだ」と読み手へ伝える唯一の手がかりになる。

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
| `${TMPDIR:-/tmp}/claude-compacted/<session_id>` | `compaction-recovery.sh` | `sessionstart-compaction-recovery.sh` と `userpromptsubmit-compaction-recovery.sh` | one-shot recovery trigger。`SessionStart`が未注入の時だけ書かれる |
| `${TMPDIR:-/tmp}/claude-compact-injected/<session_id>` | `sessionstart-compaction-recovery.sh` | `compaction-recovery.sh` | 注入済み印。後から走る`PostCompact`へstate配送済みを伝える |
| `${TMPDIR:-/tmp}/claude-compact-warn/<session_id>` | base repository statusline hook | `userpromptsubmit-compact-plus-reminder.sh` | Threshold warning。compact-plus は producer を所有しない |
| `${TMPDIR:-/tmp}/claude-compact-warned/<session_id>` | `userpromptsubmit-compact-plus-reminder.sh` | statusline side と recovery hook | Notification cooldown |
| `${TMPDIR:-/tmp}/claude-active-plan/<session_id>` | plan-management hook | recovery hook | Active plan pointer。compact-plus は producer を所有しない |
| `${TMPDIR:-/tmp}/codex-compact-state/<thread_id>.md` | `precompact-state-summary.sh`または`/compact-plus` skill | Codex recovery hookとagent | Codex state payload |
| `${TMPDIR:-/tmp}/codex-compact-state-offset/<thread_id>` | `precompact-state-summary.sh` | `precompact-state-summary.sh` | Codex incremental transcript offset |
| `${TMPDIR:-/tmp}/codex-compact-state-counter/<thread_id>` | `precompact-state-summary.sh` | `precompact-state-summary.sh` | Codex full-refresh cadence counter |
| `${TMPDIR:-/tmp}/codex-compacted/<thread_id>` | `compaction-recovery.sh` | `sessionstart-compaction-recovery.sh` と `userpromptsubmit-compaction-recovery.sh` | Codex one-shot recovery trigger |
| `${TMPDIR:-/tmp}/codex-compact-injected/<thread_id>` | `sessionstart-compaction-recovery.sh` | `compaction-recovery.sh` | 同じhandshake用のCodex注入済み印 |
| `${TMPDIR:-/tmp}/codex-active-plan/<thread_id>` | 任意の外部plan-management hook | Codex recovery hook | 任意のCodex active-plan pointer |
| `${TMPDIR:-/tmp}/codex-compact-warned/<thread_id>` | reminder hook | reminderとrecovery hook | Codex通知cooldown |
| `${CODEX_HOME:-$HOME/.codex}/backups/transcripts/<epoch>-<thread_id>.jsonl` | `precompact-transcript-backup.sh` | Codex recovery hookとagent | Codex transcriptのversioned backup。threadごとに新しい20件を保持 |

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
| `COMPACT_PLUS_CODEX_WARN_THRESHOLD` | Codexの実効context使用率通知閾値。default `75` |

Claudeの`COMPACT_WARN_THRESHOLD`はbase repositoryが所有する。producerが`home/hooks/claude/statusline.sh`だから。2つの閾値は独立している。

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
