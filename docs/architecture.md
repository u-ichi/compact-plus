# compact-plus Architecture

[Japanese architecture](./architecture.ja.md) | [README](../README.md) | [Japanese README](../README.ja.md)

compact-plus is a Claude Code plugin that captures working state around Claude Code context compaction. It does not replace Claude Code compaction. Instead, it uses documented Claude Code hook events to save the source transcript and a structured state summary before compaction, then injects recovery guidance after compaction.

## 1. Goals and Non-Goals

### Goals

- Preserve task state before Claude Code compacts context.
- Keep recovery data outside the compacted conversation summary.
- Make the next user prompt after compaction reread the saved state, relevant plan file, and original instruction sources when needed.
- Keep hook failures non-blocking so compaction can continue.
- Support configurable LLM backends without editing installed hook files.

### Non-Goals

- compact-plus does not change Claude Code's internal compaction algorithm.
- compact-plus does not provide a documented replacement for Claude Code's compaction prompt. The checked Claude Code documentation exposes `/compact [instructions]` and hook-based extension points, but no official user setting equivalent to Codex CLI `compact_prompt`.
- compact-plus does not manage Codex CLI sessions directly. Codex is only an optional fallback LLM backend for the Claude Code plugin.
- compact-plus does not own the base repository statusline threshold hook; it only consumes the marker written by that hook.

## 2. Claude Code Compaction Surface

Claude Code exposes `/compact` as a slash command that summarizes the conversation to free context. It also accepts optional text after the command, for example `/compact focus on the current implementation plan`, and passes that text as compact instructions.

Claude Code hook events relevant to compact-plus:

| Event | compact-plus use |
|---|---|
| `PreCompact` | Back up the transcript and generate the state file before compaction |
| `PostCompact` | Write a recovery marker and reset the warning cooldown after compaction |
| `UserPromptSubmit` | Inject recovery guidance through `additionalContext` on the next user prompt |

Claude Code plugin hooks are configured through `hooks/hooks.json`. For `PreCompact` and `PostCompact`, Claude Code documents `manual` and `auto` matcher values. Claude Code also documents command, HTTP, and MCP tool hooks for those compact events. compact-plus uses command hooks.

Claude Code settings can provide environment variables through the `env` key in `settings.json`. compact-plus uses that setting surface for backend and transcript tuning. Claude Code also documents `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE`, which changes the auto-compaction threshold percentage. That threshold setting is separate from compact-plus state capture.

## 3. Codex CLI Compaction Surface

Codex CLI has a separate compaction model and configuration surface. This repository does not install Codex hooks, but Codex matters because compact-plus can call `codex exec` as a fallback LLM backend.

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

Codex hooks are command-only in the checked manual. `PreCompact` and `PostCompact` hooks expose fields such as `turn_id` and `trigger`, where `trigger` is `manual` or `auto`. Plain text stdout is ignored for those events, while JSON output can use common hook fields such as `continue`.

The default compaction prompt shipped by Codex is deliberately handoff-oriented. The template at [`codex-rs/prompts/templates/compact/prompt.md`](https://github.com/openai/codex/blob/main/codex-rs/prompts/templates/compact/prompt.md) frames compaction as "CONTEXT CHECKPOINT COMPACTION" and requires the summarizing LLM to include four sections:

1. Current progress and key decisions made
2. Important context, constraints, or user preferences
3. What remains to be done (clear next steps)
4. Any critical data, examples, or references needed to continue

This is the built-in handoff engineering that users of Codex get without any configuration.

The OpenAI Responses API also has server-side context compaction through `context_management` and the `/responses/compact` endpoint. That API returns an encrypted compaction item and is not the same mechanism as Claude Code plugin hooks.

## 4. Compaction Capability Comparison

| Capability | Claude Code (baseline) | Codex CLI (built-in) | Claude Code + compact-plus |
|---|---|---|---|
| Structured pre-compaction state file | None | None (the rollout file preserves the whole transcript but is not a structured state artifact) | 10-section state file written to disk |
| Transcript backup safety net | None (transcript JSONL persists in place) | Full rollout file kept in `$CODEX_HOME/sessions` | Versioned backup copies under `~/.claude/backups/transcripts/` |
| Automatic post-compaction recovery injection | None | Possible only via a user-authored SessionStart(source=compact) hook | Automatic through `UserPromptSubmit` |
| Recall of skills invoked earlier | None | None | Restored from the `## Skills Invoked` section of the state file |
| Correction for summary scope drift | None | None | Injects a factual note that memory / rule / skill mentions in the compacted summary are lossy and originals are authoritative |
| User-side priority guidance | `/compact [instructions]` reaches hooks | Equivalent via `/compact` | Forwards Claude Code instructions to the state-generation LLM |
| Threshold warn notification | Statusline percentage only | Requires custom implementation | Explicit warn marker plus a reminder hook |
| Recitation of current focus (Active Plan / Current Phase / recent Session Decision) | None | None | Reminder hook injects a three-line state recitation as `additionalContext` |
| Manual state save skill | None | None | Provides the `/compact-plus` skill |
| Structured handoff prompt for the compaction LLM | Not published; treated as generic summarization | Ships a "CONTEXT CHECKPOINT COMPACTION" prompt that requires progress/decisions, context/constraints, remaining work, and critical data/references as sections | Leaves the compaction summary as-is; instead persists a 10-section state file outside the compacted context and injects it back on resume |
| Replacing the compaction prompt itself | Not possible | Yes, via `compact_prompt` and `experimental_compact_prompt_file` | Out of scope by design (uses hook-side state capture instead) |

Codex ships two distinct advantages here: it lets users replace the compaction prompt, and its default already applies structured handoff engineering. compact-plus does not enter the compaction prompt at all. Instead it places the handoff structure in an external state file that the recovery hook re-injects on the next user prompt. On the axis of "session continuity around compaction," this indirection lets Claude Code + compact-plus match or exceed the Codex baseline while staying inside Claude Code's documented extension surface.

## 5. Runtime Flow

1. `PreCompact` starts.
2. `precompact-transcript-backup.sh` copies the transcript JSONL to `~/.claude/backups/transcripts/`.
3. `precompact-state-summary.sh` reads the transcript according to the configured mode:
   - `incremental`: read new bytes since the previous run, with periodic full refresh.
   - `head-tail`: keep early context and recent context.
   - `tail`: keep only recent context.
4. `precompact-state-summary.sh` applies tool output squash to large Read and Bash outputs.
5. The script calls the primary backend. If that fails and fallback is enabled, it calls the fallback backend.
6. The state file is written to `${TMPDIR:-/tmp}/claude-compact-state/<session_id>.md`.
7. `PostCompact` starts.
8. `compaction-recovery.sh` writes `${TMPDIR:-/tmp}/claude-compacted/<session_id>` and removes the warning cooldown marker.
9. On the next user prompt, `userpromptsubmit-compaction-recovery.sh` consumes the recovery marker and injects:
   - state file path,
   - active plan path when present,
   - original-source factual note,
   - Skills Invoked guidance when present.
10. If a statusline warning marker exists, `userpromptsubmit-compact-plus-reminder.sh` consumes it and injects a compact suggestion plus a short state recitation.

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
| `${TMPDIR:-/tmp}/claude-compacted/<session_id>` | `compaction-recovery.sh` | `userpromptsubmit-compaction-recovery.sh` | One-shot recovery trigger. Consumed on the next user prompt |
| `${TMPDIR:-/tmp}/claude-compact-warn/<session_id>` | Base repository statusline hook | `userpromptsubmit-compact-plus-reminder.sh` | Threshold warning. compact-plus reads but does not own the producer |
| `${TMPDIR:-/tmp}/claude-compact-warned/<session_id>` | `userpromptsubmit-compact-plus-reminder.sh` | statusline side and recovery hook | Notification cooldown |
| `${TMPDIR:-/tmp}/claude-active-plan/<session_id>` | plan-management hook | recovery hook | Active plan pointer. compact-plus reads but does not own the producer |

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

The base repository owns `COMPACT_WARN_THRESHOLD`, because the producer is `home/hooks/claude/statusline.sh`. compact-plus only consumes the resulting warning marker.

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
