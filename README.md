# compact-plus

[Japanese README](./README.ja.md) | [Architecture](./docs/architecture.md)

A transparent Claude Code and Codex plugin that preserves working state around `/compact`. It does not replace either runtime's compaction algorithm; it augments compaction through documented hooks.

## What It Does

- Backs up the transcript before compaction and writes a 10-section state file with an LLM
- Injects the state file, plan file, and original-source reminder after compaction through `additionalContext`
- Recovers mechanically observable skills and commands; unobservable Codex skill use is recorded as `Not verified`
- When context usage crosses a configured threshold, the next user prompt receives a suggestion to run `/compact`
- Alongside that reminder, the plugin injects a three-line recitation (Active Plan, Current Phase, and the most recent Session Decision from the state file) into `additionalContext`, so the agent keeps its bearings during the last few turns before compaction actually runs. This does not change the compaction algorithm itself; it is a focus aid that reduces late-session drift between warn and the real `/compact`
- Provides the `/compact-plus` skill for manual state capture

## Usage

After installation, just run `/compact` as usual. **No additional action is required** — the flow is fully transparent.

- Both manual `/compact` and auto-compaction trigger the same hook path
- Before compaction: the PreCompact hook automatically backs up the transcript and generates the 10-section state file
- After compaction: Claude Code and Codex recover exactly once through `SessionStart(source=compact)` before the first post-compaction prompt
- The agent does not need to call any specific skill or perform any preparation

Optional enhancements:

- Pass an instruction such as `/compact keep the security-related decisions` to send priority guidance to the state-generation LLM
- Invoke `/compact-plus` manually right before compaction if you want to leave richer recovery notes; this switches to the fallback path where the agent writes the structured state itself

## Requirements

- Claude Code v2.x or later, or a Codex version with plugin compaction hooks
- An LLM backend through `claude -p` or `codex exec`
- The default configuration uses `claude -p --model claude-sonnet-5 --effort medium` as the primary backend and `codex exec --model gpt-5.3-codex-spark` as the fallback backend
- The Codex Spark fallback assumes ChatGPT Pro access. You can switch the fallback to models such as `gpt-5.4` or `gpt-5.5`

## Installation

### Claude Code

Add this GitHub repository as a marketplace, then install the plugin from it.

```bash
claude plugin marketplace add u-ichi/compact-plus --scope user
claude plugin install compact-plus@compact-plus
```

### Codex

Add the same GitHub repository as a marketplace, then install the Codex plugin.

```bash
codex plugin marketplace add u-ichi/compact-plus
codex plugin add compact-plus@compact-plus
```

Review and trust the hook definitions when Codex prompts.
Start a new thread after installation so Codex loads the installed plugin and hooks.

### Updating

Refresh the GitHub marketplace snapshot, then update or reinstall the plugin.

```bash
# Claude Code
claude plugin update compact-plus@compact-plus

# Codex
codex plugin marketplace upgrade compact-plus
codex plugin add compact-plus@compact-plus
```

For local development, replace `u-ichi/compact-plus` in the marketplace-add command with the absolute path to this repository.
The plugin reference remains `compact-plus@compact-plus`.

## Configuration

Following the Claude Code plugin model, write environment variables under the `env` block in `~/.claude/settings.json`. For temporary per-session overrides, shell `export` also works.

### Backend Overrides

Two environment variables replace the primary and fallback commands as whole shell commands.

| env var | Meaning |
|---|---|
| `COMPACT_PLUS_PRIMARY_BACKEND` | Complete shell command for the primary backend. Set to an empty string (`""`) to skip the primary backend |
| `COMPACT_PLUS_FALLBACK_BACKEND` | Complete shell command for the fallback backend. Set to an empty string to skip the fallback backend |

Environment variables available inside those commands:

- `$SYSTEM_PROMPT`: the LLM system prompt from `prompts/state-summary.md`
- `$SESSION_ID`: Claude Code session id
- `$TRANSCRIPT_PATH`: transcript JSONL path
- `$MAX_OUTPUT_TOKENS`: LLM output cap

Default values are embedded in `hooks/precompact-state-summary.sh`.

Example `~/.claude/settings.json` override for a lower-cost Haiku backend:

```json
{
  "env": {
    "COMPACT_PLUS_PRIMARY_BACKEND": "claude -p --model claude-haiku-4-5-20251001 --effort low --permission-mode dontAsk --output-format text --no-session-persistence --system-prompt \"$SYSTEM_PROMPT\""
  }
}
```

Example replacing the primary backend with Codex Spark (requires ChatGPT Pro; served through Cerebras for higher throughput):

```json
{
  "env": {
    "COMPACT_PLUS_PRIMARY_BACKEND": "tmp=$(mktemp \"${TMPDIR:-/tmp}/compact-plus-codex.XXXXXX\"); { printf \"%s\\n\\n\" \"$SYSTEM_PROMPT\"; cat; } | codex exec --model gpt-5.3-codex-spark --sandbox read-only --skip-git-repo-check --dangerously-bypass-hook-trust --ignore-user-config --ephemeral --output-last-message \"$tmp\" - >/dev/null && cat \"$tmp\"; status=$?; rm -f \"$tmp\"; exit \"$status\""
  }
}
```

Codex output can prepend a CLI preamble to stdout, so `--output-last-message "$tmp"` is used to capture only the final message. This mirrors the default fallback implementation.

Example disabling the fallback:

```json
{
  "env": {
    "COMPACT_PLUS_FALLBACK_BACKEND": ""
  }
}
```

### Transcript, Squash, and Two-Pass Tuning

| env var | default | Meaning |
|---|---|---|
| `COMPACT_PLUS_TRANSCRIPT_MODE` | `incremental` | Transcript selection mode: `incremental`, `head-tail`, or `tail` |
| `COMPACT_PLUS_TRANSCRIPT_HEAD_TURNS` | `5` | Number of turns to keep from the head side |
| `COMPACT_PLUS_TRANSCRIPT_TAIL_TURNS` | `25` | Number of turns to keep from the tail side |
| `COMPACT_PLUS_TRANSCRIPT_HEAD_KB` | `10` | Head-side byte cap in KB |
| `COMPACT_PLUS_TRANSCRIPT_TAIL_KB` | `40` | Tail-side byte cap in KB |
| `COMPACT_PLUS_RAW_DELTA_FACTOR` | `20` | Incremental mode reads at most `TAIL_KB * N` of raw transcript delta before squashing. Set `0` for unbounded |
| `COMPACT_PLUS_INCREMENTAL_REFRESH` | `10` | Full rebuild every N runs. Set `0` to disable |
| `COMPACT_PLUS_MAX_OUTPUT_TOKENS` | `4096` | LLM output cap for backends that read it |
| `COMPACT_PLUS_BACKEND_TIMEOUT` | `80` | Per-backend timeout in seconds. Primary and fallback run serially inside the 180s hook budget. Set `0` to disable |
| `COMPACT_PLUS_SQUASH_ENABLED` | `1` | Enables or disables tool result squash |
| `COMPACT_PLUS_SQUASH_READ_LINES` | `100` | Replaces Read tool output above N lines with `[Read: N lines from path]` |
| `COMPACT_PLUS_SQUASH_BASH_CHARS` | `500` | Replaces Bash output above N characters with `[Bash: exit code, N chars output]` |
| `COMPACT_PLUS_TWO_PASS` | `1` | Enables or disables two-pass self-critique |

### Warn Thresholds

Claude Code and Codex use separate settings:

| Runtime | env var | default | Source |
|---|---|---:|---|
| Claude Code | `COMPACT_WARN_THRESHOLD` | base repository setting | `home/hooks/claude/statusline.sh` writes the marker consumed by this plugin |
| Codex | `COMPACT_PLUS_CODEX_WARN_THRESHOLD` | `75` | compact-plus reads the latest token-count event from the current thread rollout |

Both values are context **usage** percentages. Changing one does not change the other. Codex uses the same effective-window basis as its context display by excluding the current 12,000-token fixed baseline. Codex also verifies that the rollout's `session_meta.id` matches the current `session_id`; missing, malformed, or mismatched rollout data produces no notification.

### `/compact` Arguments

When you pass natural-language instructions, such as `/compact keep the important design decisions`, compact-plus forwards those instructions to the state-generation LLM as priority guidance.

## Runtime Flow

1. **PreCompact hook**
   - `precompact-transcript-backup.sh` copies the transcript JSONL to `~/.claude/backups/transcripts/` or `${CODEX_HOME:-$HOME/.codex}/backups/transcripts/`
   - `precompact-state-summary.sh` applies semantic chunking and tool output squash to the transcript, then calls the primary or fallback backend and writes the 10-section state file
2. **PostCompact hook**
   - `compaction-recovery.sh` writes a recovery marker and resets the warning cooldown
3. **Recovery hook**
   - `sessionstart-compaction-recovery.sh` handles `SessionStart(source=compact)` for both Claude Code and Codex
   - It consumes the recovery marker exactly once and injects the saved state content, active plan reference when present, and original-source reminder through `additionalContext`
   - `userpromptsubmit-compaction-recovery.sh` stays registered as the fallback channel. Codex dispatches the start hook to root threads only, so a thread-spawn subagent receives no start hook after compaction and recovers through the next `UserPromptSubmit`; parent messages reach a subagent as user input. The marker is consumed once, so a thread that already recovered at `SessionStart` is a no-op on the following prompt
   - `userpromptsubmit-compact-plus-reminder.sh` consumes warn markers and injects a lightweight notification plus a three-line state recitation when available
4. **SessionStart hook**
   - `sessionstart-export-session-id.sh` writes `export CLAUDE_CODE_SESSION_ID=<id>` to `$CLAUDE_ENV_FILE` so the `/compact-plus` skill can obtain the session id through the bundled `scripts/get-session-id.sh` wrapper without depending on any file outside the plugin
5. **Manual fallback (`/compact-plus` skill)**
   - The agent follows the `SKILL.md` 10-section procedure and writes the state file manually

## State File Sections

State files start with `# Compact Prep State` and use the same 10-section order in both the manual skill and LLM-generated output.

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

## Marker Files

| path | writer | reader | Purpose |
|---|---|---|---|
| `${TMPDIR}/claude-compact-state/<session_id>.md` | `precompact-state-summary.sh` / `/compact-plus` skill | recovery hook / agent | Pre-compaction state |
| `${TMPDIR}/claude-compact-state-offset/<session_id>` | `precompact-state-summary.sh` | `precompact-state-summary.sh` | Incremental byte offset |
| `${TMPDIR}/claude-compact-state-counter/<session_id>` | `precompact-state-summary.sh` | `precompact-state-summary.sh` | Refresh cycle counter |
| `${TMPDIR}/claude-compacted/<session_id>` | `compaction-recovery.sh` | `sessionstart-compaction-recovery.sh` | One-shot PostCompact marker |
| `${TMPDIR}/claude-compact-warn/<session_id>` | base repo `statusline.sh` | `userpromptsubmit-compact-plus-reminder.sh` | Threshold warning |
| `${TMPDIR}/claude-compact-warned/<session_id>` | `userpromptsubmit-compact-plus-reminder.sh` | statusline / recovery hook | Notification cooldown |
| `${TMPDIR}/claude-active-plan/<session_id>` | plan-management hook | recovery hook | Active plan path |
| `${TMPDIR}/codex-compact-state/<thread_id>.md` | `precompact-state-summary.sh` / `/compact-plus` skill | Codex recovery hook / agent | Codex pre-compaction state |
| `${TMPDIR}/codex-compacted/<thread_id>` | `compaction-recovery.sh` | `sessionstart-compaction-recovery.sh` | Codex one-shot recovery marker |
| `${TMPDIR}/codex-compact-warned/<thread_id>` | reminder hook | reminder / recovery hook | Codex notification cooldown |

On Codex, `<thread_id>` is the thread that actually compacted. Hook input carries `session_id` as the identity shared by the root thread and all of its descendants, plus `agent_id` for a thread-spawn subagent, so every artifact is keyed on `agent_id` when present and on `session_id` otherwise (`compact_plus_artifact_key` in `scripts/runtime-paths.sh`). Keying on `session_id` alone would file a subagent's state under the parent and overwrite the parent's own state file.

## Architecture

See [docs/architecture.md](./docs/architecture.md) for the design overview, Claude Code and Codex CLI compaction comparison, hook boundaries, marker ownership, and source references.

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
