# compact-plus Project Instructions

This repository manages the Claude Code and Codex plugin that preserves and restores working state
around context compaction.

## Scope

- This repository manages only the `compact-plus` plugin itself.
- Do not change the base repository `home/`, `install.sh`, or Claude/Codex configuration distribution scripts.

## Shared State

| path | writer | reader | purpose |
|---|---|---|---|
| `${TMPDIR:-/tmp}/claude-compact-state/<session_id>.md` | `precompact-state-summary.sh` / `/compact-plus` skill | `userpromptsubmit-compaction-recovery.sh` / agent | pre-compaction recovery state |
| `${TMPDIR:-/tmp}/claude-compact-pending/<session_id>` | `precompact-state-summary.sh` | recovery hooks | pending compact-event token and manual-state flag |
| `${TMPDIR:-/tmp}/claude-compact-state-offset/<session_id>` | `precompact-state-summary.sh` | `precompact-state-summary.sh` | incremental byte offset |
| `${TMPDIR:-/tmp}/claude-compact-state-counter/<session_id>` | `precompact-state-summary.sh` | `precompact-state-summary.sh` | refresh cycle counter |
| `${TMPDIR:-/tmp}/claude-compacted/<session_id>` | `compaction-recovery.sh` | `userpromptsubmit-compaction-recovery.sh` | PostCompact marker |
| `${TMPDIR:-/tmp}/claude-compact-warn/<session_id>` | statusline side | `userpromptsubmit-compact-plus-reminder.sh` | compact-plus suggestion marker |
| `${TMPDIR:-/tmp}/claude-compact-warned/<session_id>` | `userpromptsubmit-compact-plus-reminder.sh` | statusline side / `compaction-recovery.sh` | suggestion cooldown marker |
| `${TMPDIR:-/tmp}/claude-active-plan/<session_id>` | plan-management hook | `userpromptsubmit-compaction-recovery.sh` | active plan file pointer |
| `${TMPDIR:-/tmp}/codex-compact-state/<thread_id>.md` | `precompact-state-summary.sh` / `/compact-plus` skill | `sessionstart-compaction-recovery.sh` / agent | Codex pre-compaction recovery state |
| `${TMPDIR:-/tmp}/codex-compact-pending/<thread_id>` | `precompact-state-summary.sh` | recovery hooks | pending compact-event token and manual-state flag |
| `${TMPDIR:-/tmp}/codex-compact-state-offset/<thread_id>` | `precompact-state-summary.sh` | `precompact-state-summary.sh` | Codex incremental byte offset |
| `${TMPDIR:-/tmp}/codex-compact-state-counter/<thread_id>` | `precompact-state-summary.sh` | `precompact-state-summary.sh` | Codex refresh cycle counter |
| `${TMPDIR:-/tmp}/codex-compacted/<thread_id>` | `compaction-recovery.sh` | `sessionstart-compaction-recovery.sh` | Codex PostCompact marker |
| `${TMPDIR:-/tmp}/codex-compact-warned/<thread_id>` | `userpromptsubmit-compact-plus-reminder.sh` | reminder / recovery hook | Codex notification cooldown |

Every artifact file name is keyed by `compact_plus_artifact_key` in `scripts/runtime-paths.sh`, which prefers `agent_id` and falls back to `session_id`. Codex sets `session_id` to the identity shared by the root thread and all of its descendants, and adds `agent_id` for a thread-spawn subagent, so keying on `session_id` alone files a subagent's state under the parent and overwrites the parent's own state file. Add new artifact paths through this helper rather than reading `.session_id` directly.

Recovery delivery differs per thread kind on Codex. `SessionStart(source=compact)` is dispatched to root threads only; a thread-spawn subagent gets no start hook after compaction, so `userpromptsubmit-compaction-recovery.sh` also runs for Codex `UserPromptSubmit`. The marker is consumed once, so only one of the two channels injects.

## External Dependencies

- Session id detection uses `$CLAUDE_CODE_SESSION_ID`, `$CODEX_THREAD_ID`, then `$CODEX_COMPANION_SESSION_ID`.
- `skills/compact-plus/SKILL.md` is the Claude Code and Codex plugin skill entrypoint.
- Hook scripts run through shared `hooks/hooks.json`; scripts select runtime-specific storage.
- Runtime tuning uses Claude Code `settings.json` `env` values. See `README.md` for the env var list and default behavior.

## Hook Scripts

- `sessionstart-export-session-id.sh`: SessionStart hook that appends `export CLAUDE_CODE_SESSION_ID=<id>` to `$CLAUDE_ENV_FILE`, making the session id available to subsequent Bash tool calls and skill scripts inside the same session. Runs on every SessionStart matcher.
- `precompact-transcript-backup.sh`: backs up the transcript to the Claude Code or Codex backup directory during PreCompact.
- `precompact-state-summary.sh`: records the compact event and returns quickly during PreCompact; a detached worker generates a state file using incremental transcript reads, semantic head/tail fallback, tool output squash, two-pass prompt metadata, custom `/compact` instructions, and Skills Invoked extraction.
- `compaction-recovery.sh`: writes a recovery marker during PostCompact and clears the compact warning cooldown.
- `userpromptsubmit-compaction-recovery.sh`: consumes the recovery marker once and injects a state file or transcript backup reference through additionalContext, including the original-source factual note and Skills Invoked guidance when present.
- `userpromptsubmit-compact-plus-reminder.sh`: consumes the compact warning marker once, suggests `/compact` or `/compact-plus`, and includes a three-line state recitation when available.
- `sessionstart-compaction-recovery.sh`: on Codex `SessionStart(source=compact)`, consumes the Codex marker and injects recovery guidance once.

## Implementation Discipline

- Hooks must fail open and must not block compaction.
- Do not write machine-specific absolute paths into git-tracked files.
- Use `${CLAUDE_PLUGIN_ROOT}`, `${HOME}`, `${TMPDIR:-/tmp}`, and repository-relative paths.

## Commit message language

Commit messages in this repository are written in English. The marker file
`.commit-lang-en` at the repository root declares this, and
`.githooks/commit-msg` rejects any commit whose message contains Japanese
text. Comment lines and everything after the `--verbose` scissors line are
excluded from the check.

The hook is tracked in the repository but git does not enable it
automatically. Run this once per clone:

```
git config core.hooksPath .githooks
```

## Version bump policy

Every commit must bump the plugin version, following semver. Commits without a
version bump are not allowed. Keep the following six slots in sync at the
same value — the `Check version consistency` step in `.github/workflows/test.yml`
enforces this and will fail CI on any mismatch:

1. `.claude-plugin/plugin.json` (`version`)
2. `.claude-plugin/marketplace.json` (`metadata.version`)
3. `.claude-plugin/marketplace.json` (`plugins[0].version`)
4. `.codex-plugin/plugin.json` (`version`)
5. `.agents/plugins/marketplace.json` (`metadata.version`)
6. `.agents/plugins/marketplace.json` (`plugins[0].version`)

| Change type | Bump | Example |
|-------------|------|---------|
| Bug fix, display tweak, refactor, docs | patch (1.0.0 → 1.0.1) | Fix a silent hook failure, small README edit |
| New feature, new skill, extension of existing behavior | minor (1.0.0 → 1.1.0) | Add a new hook, extend the `/compact-plus` skill |
| Breaking change, incompatible skill / hook I/O change | major (1.0.0 → 2.0.0) | Incompatible shared-state file format change |

When in doubt, prefer patch.
