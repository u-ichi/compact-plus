# compact-plus Architecture

[Japanese architecture](./architecture.ja.md) | [README](../README.md) | [Japanese README](../README.ja.md)

compact-plus is a Claude Code and Codex plugin that captures working state around context compaction. It does not replace either compaction implementation. It uses documented hook events to save the source transcript and a structured state summary before compaction, then injects recovery guidance after compaction.

## 1. Goals and Non-Goals

### Goals

- Preserve task state before Claude Code or Codex compacts context.
- Keep recovery data outside the compacted conversation summary.
- Make the next user prompt after compaction reread the saved state, relevant plan file, and original instruction sources when needed.
- Keep hook failures non-blocking so compaction can continue.
- Support configurable LLM backends without editing installed hook files.

### Non-Goals

- compact-plus does not change Claude Code's or Codex's internal compaction algorithm.
- compact-plus does not provide a documented replacement for Claude Code's compaction prompt. The checked Claude Code documentation exposes `/compact [instructions]` and hook-based extension points, but no official user setting equivalent to Codex CLI `compact_prompt`.
- compact-plus does not trigger `/compact` or inject terminal input. Forced auto-compaction through Herdr is a separate design.
- compact-plus does not own the base repository's Claude statusline threshold hook; it consumes that hook's marker. Codex notification is plugin-owned and uses the current thread rollout.

## 2. Claude Code Compaction Surface

Claude Code exposes `/compact` as a slash command that summarizes the conversation to free context. It also accepts optional text after the command, for example `/compact focus on the current implementation plan`, and passes that text as compact instructions.

Claude Code hook events relevant to compact-plus:

| Event | compact-plus use |
|---|---|
| `PreCompact` | Back up the transcript and generate the state file before compaction |
| `PostCompact` | Write a recovery marker and reset the warning cooldown after compaction |
| `SessionStart`, matcher `compact` | Inject saved state through `additionalContext` before the first post-compaction prompt |

Claude Code plugin hooks are configured through `hooks/hooks.json`. For `PreCompact` and `PostCompact`, Claude Code documents `manual` and `auto` matcher values. Claude Code also documents command, HTTP, and MCP tool hooks for those compact events. compact-plus uses command hooks.

Claude Code settings can provide environment variables through the `env` key in `settings.json`. compact-plus uses that setting surface for backend and transcript tuning. Claude Code also documents `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE`, which changes the auto-compaction threshold percentage. That threshold setting is separate from compact-plus state capture.

## 3. Codex CLI Compaction Surface

Codex CLI has a separate compaction model and configuration surface. compact-plus ships a Codex plugin manifest and uses Codex hooks around manual and automatic compaction.

Codex CLI documents:

| Surface | Meaning |
|---|---|
| `/compact` | Summarizes visible conversation to free tokens |
| Auto compaction | Codex can compact long tasks automatically when context space is low |
| `model_auto_compact_token_limit` | Token threshold for auto compaction |
| `compact_prompt` | Inline prompt text used for compaction |
| `experimental_compact_prompt_file` | File path for a compaction prompt |
| `PreCompact` / `PostCompact` hooks | Command hooks around manual or auto compaction |
| Session transcripts | Local session data under `$CODEX_HOME/sessions`, defaulting to `~/.codex/sessions` |

Codex hooks are command-only in the checked manual. `PreCompact` and `PostCompact` expose fields such as `session_id`, `turn_id`, `transcript_path`, and `trigger`, where `trigger` is `manual` or `auto`. `SessionStart` supports matcher `compact` and `additionalContext`. The transcript format is convenient but not a stable hook interface, so parsing fails open.

### compact-plus Codex layer

The Codex plugin uses the same state-generation scripts as the Claude Code plugin, but `scripts/runtime-paths.sh` selects separate storage from the `PLUGIN_ROOT` environment variable. Codex state, incremental offsets, refresh counters, recovery markers, plan pointers, warning cooldowns, and transcript backups therefore do not share paths with Claude Code sessions. The Codex transcript backups live under `${CODEX_HOME:-$HOME/.codex}/backups/transcripts/`.

Manual and automatic compaction follow the same Codex hook sequence:

1. `PreCompact` creates a versioned transcript backup and the structured state file for the current thread id.
2. `PostCompact` writes a one-shot recovery marker and clears the thread's warning cooldown.
3. Codex's built-in compact summary continues the thread immediately.
4. Before the first post-compaction prompt, `SessionStart(source=compact)` consumes the marker and adds the saved state content, optional plan path, and original-source reminder through `additionalContext`.

"Current thread id" above is `agent_id` when hook input carries it and `session_id` otherwise. Codex sets `session_id` to the identity shared by the root thread and all of its descendants, and adds `agent_id` for a thread-spawn subagent, so a subagent keyed on `session_id` alone would store its state under the parent and overwrite the parent's own state file.

Step 4 applies to root threads only. Codex dispatches `SessionStart(source=compact)` to a thread-spawn subagent's start only when the start source is `Startup`; after compaction the subagent receives no start hook at all. Its recovery therefore arrives through the next `UserPromptSubmit`, which does run for subagents because parent messages are delivered as user input. Both channels read the same one-shot marker, so exactly one of them injects.

The Codex notification does not depend on Claude Code's statusline marker. On each eligible prompt, compact-plus reads the latest usable `token_count` event from the final 500 transcript records after verifying that the rollout's `session_meta.id` equals the hook input's `session_id`. A missing transcript, an unreadable or mismatched `session_meta`, or no usable `token_count` event in those records produces no notification. A newer unusable event does not discard an earlier usable event in the same range.

Codex's displayed context includes a fixed 12,000-token baseline in the checked runtime. compact-plus uses the same effective-window basis:

```text
effective usage % =
  max(total tokens - 12,000, 0)
  / (model context window - 12,000)
  * 100
```

`COMPACT_PLUS_CODEX_WARN_THRESHOLD` controls the notification point and defaults to `75`. Values outside `1` through `100` fall back to `75`. After a notification, a thread-specific cooldown suppresses repeats until `PostCompact` clears it. The notification adds the current state file's Active Plan, Current Phase, and most recent Session Decision when available.

This layer only recommends `/compact` at a work boundary. It does not execute the command or inject terminal input; Herdr-driven forced compaction remains a separate design.

The default compaction prompt shipped by Codex is deliberately handoff-oriented. The template at [`codex-rs/prompts/templates/compact/prompt.md`](https://github.com/openai/codex/blob/main/codex-rs/prompts/templates/compact/prompt.md) frames compaction as "CONTEXT CHECKPOINT COMPACTION" and requires the summarizing LLM to include four sections:

1. Current progress and key decisions made
2. Important context, constraints, or user preferences
3. What remains to be done (clear next steps)
4. Any critical data, examples, or references needed to continue

This is the built-in handoff engineering that users of Codex get without any configuration.

The OpenAI Responses API also has server-side context compaction through `context_management` and the `/responses/compact` endpoint. That API returns an encrypted compaction item and is not the same mechanism as Claude Code plugin hooks.

## 4. Compaction Capability Comparison

Compared along user-facing outcomes ("can the session actually continue past compaction?"), not implementation mechanisms.

| Outcome | Claude Code (baseline) | Codex CLI (built-in) | Claude Code or Codex + compact-plus |
|---|---|---|---|
| Session goal survives compaction | △ (relies on unstructured summary; easy to dilute) | ○ (CONTEXT CHECKPOINT prompt requires progress and key decisions as sections) | ○ (externalized to `## Active Plan` and `## Current Phase`) |
| Remaining work is handed off clearly | △ (same as above) | ○ (requires "remaining work (clear next steps)" as a section) | ○ (externalized to `## TaskList Summary` and `## Recovery Notes`) |
| Important decisions are preserved | △ (same as above) | ○ (requires "key decisions made" as a section) | ○ (externalized to `## Session Decisions`) |
| Skills invoked earlier can be recovered | × | × | ○ when transcript evidence exists; otherwise `Not verified` |
| Scope drift in the summary's memory / rule mentions is corrected | × | × | ○ (recovery hook injects an "originals are authoritative" factual note) |
| User can name priorities in natural language before compaction | △ (`/compact <text>` reaches hooks; the built-in effect on the summary is undocumented) | × (no documented per-compaction natural-language argument) | Claude: ○ (instructions are forwarded to the state-generation LLM); Codex: × (record priorities in the conversation or state before compacting) |
| The original transcript is preserved | ○ (transcript JSONL persists in place) | ○ (rollout file preserves the whole transcript) | ○ (plus runtime-specific versioned backups) |
| Agent and user are warned before context runs out | △ (statusline percentage only) | × (requires custom implementation) | ○ (Claude marker or Codex token-count notification plus a three-line recitation) |
| A manual, structured recovery-note path is available | × | × | ○ (the `/compact-plus` skill) |
| User can replace the compaction prompt itself | × | ○ (`compact_prompt` and `experimental_compact_prompt_file`) | Out of scope by design (does not touch the compaction prompt) |

compact-plus does not touch either compaction prompt. It places structured state outside compaction and re-injects it afterwards, adding explicit recovery references and separate threshold warnings to both runtimes.

## 5. Runtime Flow

1. `PreCompact` starts.
2. `precompact-transcript-backup.sh` copies the transcript JSONL to the runtime-specific backup directory.
3. `precompact-state-summary.sh` reads the transcript according to the configured mode:
   - `incremental`: read new bytes since the previous run, with periodic full refresh.
   - `head-tail`: keep early context and recent context.
   - `tail`: keep only recent context.
4. `precompact-state-summary.sh` applies tool output squash to large Read and Bash outputs.
5. The script calls the primary backend. If that fails and fallback is enabled, it calls the fallback backend.
6. The state file is written to the runtime-specific state directory.
7. `PostCompact` starts.
8. `compaction-recovery.sh` writes the runtime-specific marker and removes its warning cooldown marker.
9. Claude Code and Codex recover through `SessionStart(source=compact)` before the first post-compaction prompt. A Codex thread-spawn subagent receives no start hook after compaction, so it recovers on its next `UserPromptSubmit` instead. The recovery hook injects:
   - saved state file content,
   - active plan path when present,
   - original-source factual note.
10. Claude consumes the statusline marker. Codex calculates usage from the latest current-thread token-count event and warns at `COMPACT_PLUS_CODEX_WARN_THRESHOLD` (default `75`).

## 6. State File Format

Generated state files and manually created `/compact-plus` state files share the same heading order:

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

The stable heading order lets hooks and agents skim the file predictably after compaction. The state file is not treated as more authoritative than original project files, rules, skills, or plans. Recovery guidance explicitly reminds the agent to reread original sources when the compacted summary mentions them.

## 7. Marker Files and Ownership

| Path | Writer | Reader | Ownership rule |
|---|---|---|---|
| `${TMPDIR:-/tmp}/claude-compact-state/<session_id>.md` | `precompact-state-summary.sh` or `/compact-plus` skill | recovery hook and agent | State payload. Rewritten by each state-generation run |
| `${TMPDIR:-/tmp}/claude-compact-state-offset/<session_id>` | `precompact-state-summary.sh` | `precompact-state-summary.sh` | Incremental transcript offset. Internal to state generation |
| `${TMPDIR:-/tmp}/claude-compact-state-counter/<session_id>` | `precompact-state-summary.sh` | `precompact-state-summary.sh` | Refresh cadence counter. Internal to state generation |
| `${TMPDIR:-/tmp}/claude-compacted/<session_id>` | `compaction-recovery.sh` | `sessionstart-compaction-recovery.sh` | One-shot recovery trigger consumed by `SessionStart(source=compact)` |
| `${TMPDIR:-/tmp}/claude-compact-warn/<session_id>` | Base repository statusline hook | `userpromptsubmit-compact-plus-reminder.sh` | Threshold warning. compact-plus reads but does not own the producer |
| `${TMPDIR:-/tmp}/claude-compact-warned/<session_id>` | `userpromptsubmit-compact-plus-reminder.sh` | statusline side and recovery hook | Notification cooldown |
| `${TMPDIR:-/tmp}/claude-active-plan/<session_id>` | plan-management hook | recovery hook | Active plan pointer. compact-plus reads but does not own the producer |
| `${TMPDIR:-/tmp}/codex-compact-state/<thread_id>.md` | `precompact-state-summary.sh` or `/compact-plus` skill | Codex recovery hook and agent | Codex state payload |
| `${TMPDIR:-/tmp}/codex-compact-state-offset/<thread_id>` | `precompact-state-summary.sh` | `precompact-state-summary.sh` | Codex incremental transcript offset |
| `${TMPDIR:-/tmp}/codex-compact-state-counter/<thread_id>` | `precompact-state-summary.sh` | `precompact-state-summary.sh` | Codex full-refresh cadence counter |
| `${TMPDIR:-/tmp}/codex-compacted/<thread_id>` | `compaction-recovery.sh` | `sessionstart-compaction-recovery.sh` | Codex one-shot recovery trigger |
| `${TMPDIR:-/tmp}/codex-active-plan/<thread_id>` | Optional external plan-management hook | Codex recovery hook | Optional Codex active-plan pointer |
| `${TMPDIR:-/tmp}/codex-compact-warned/<thread_id>` | reminder hook | reminder and recovery hook | Codex notification cooldown |
| `${CODEX_HOME:-$HOME/.codex}/backups/transcripts/<epoch>-<thread_id>.jsonl` | `precompact-transcript-backup.sh` | Codex recovery hook and agent | Versioned Codex transcript backup; the newest 20 per thread are retained |

Hook scripts fail open. If a marker is missing, malformed, or already consumed, the hooks continue without blocking the user prompt or compaction.

## 8. Configuration Boundaries

compact-plus owns the following environment variables:

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
| `COMPACT_PLUS_CODEX_WARN_THRESHOLD` | Codex effective context usage notification threshold; default `75` |

The base repository owns Claude's `COMPACT_WARN_THRESHOLD`, because the producer is `home/hooks/claude/statusline.sh`. The two threshold settings are independent.

## 9. Source Notes

The architecture statements above were checked against official documentation:

- [Claude Code slash commands](https://code.claude.com/docs/en/commands)
- [Claude Code hooks](https://code.claude.com/docs/en/hooks)
- [Claude Code settings](https://code.claude.com/docs/en/settings)
- [Claude Code environment variables](https://code.claude.com/docs/en/env-vars)
- [OpenAI Codex hooks](https://developers.openai.com/codex/hooks)
- [OpenAI Codex config reference](https://developers.openai.com/codex/config-reference)
- [OpenAI Codex manual](https://developers.openai.com/codex/codex-manual.md)
- [OpenAI Responses API compaction guide](https://developers.openai.com/api/docs/guides/compaction)
