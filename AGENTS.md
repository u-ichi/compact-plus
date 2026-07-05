# compact-plus Project Instructions

This repository manages the Claude Code plugin that preserves and restores working state around
Claude Code context compaction.

## Scope

- This repository manages only the `compact-plus` plugin itself.
- Do not change the base repository `home/`, `install.sh`, or Claude/Codex configuration distribution scripts.

## Shared State

| path | writer | reader | purpose |
|---|---|---|---|
| `${TMPDIR:-/tmp}/claude-compact-state/<session_id>.md` | `precompact-state-summary.sh` / `/compact-plus` skill | `userpromptsubmit-compaction-recovery.sh` / agent | pre-compaction recovery state |
| `${TMPDIR:-/tmp}/claude-compact-state-offset/<session_id>` | `precompact-state-summary.sh` | `precompact-state-summary.sh` | incremental byte offset |
| `${TMPDIR:-/tmp}/claude-compact-state-counter/<session_id>` | `precompact-state-summary.sh` | `precompact-state-summary.sh` | refresh cycle counter |
| `${TMPDIR:-/tmp}/claude-compacted/<session_id>` | `compaction-recovery.sh` | `userpromptsubmit-compaction-recovery.sh` | PostCompact marker |
| `${TMPDIR:-/tmp}/claude-compact-warn/<session_id>` | statusline side | `userpromptsubmit-compact-plus-reminder.sh` | compact-plus suggestion marker |
| `${TMPDIR:-/tmp}/claude-compact-warned/<session_id>` | `userpromptsubmit-compact-plus-reminder.sh` | statusline side / `compaction-recovery.sh` | suggestion cooldown marker |
| `${TMPDIR:-/tmp}/claude-active-plan/<session_id>` | plan-management hook | `userpromptsubmit-compaction-recovery.sh` | active plan file pointer |

## External Dependencies

- Session id detection uses `~/.claude/scripts/get-session-id.sh`. Keep this reference for Codex compatibility.
- `skills/compact-plus/SKILL.md` is the Claude plugin skill entrypoint.
- Hook scripts run through `hooks/hooks.json` as a Claude Code plugin.
- Runtime tuning uses Claude Code `settings.json` `env` values. See `README.md` for the env var list and default behavior.

## Hook Scripts

- `precompact-transcript-backup.sh`: backs up the transcript to `~/.claude/backups/transcripts/` during PreCompact.
- `precompact-state-summary.sh`: generates a state file during PreCompact using incremental transcript reads, semantic head/tail fallback, tool output squash, two-pass prompt metadata, custom `/compact` instructions, and Skills Invoked extraction.
- `compaction-recovery.sh`: writes a recovery marker during PostCompact and clears the compact warning cooldown.
- `userpromptsubmit-compaction-recovery.sh`: consumes the recovery marker once and injects a state file or transcript backup reference through additionalContext, including the original-source factual note and Skills Invoked guidance when present.
- `userpromptsubmit-compact-plus-reminder.sh`: consumes the compact warning marker once, suggests `/compact` or `/compact-plus`, and includes a three-line state recitation when available.

## Implementation Discipline

- Hooks must fail open and must not block compaction.
- Do not write machine-specific absolute paths into git-tracked files.
- Use `${CLAUDE_PLUGIN_ROOT}`, `${HOME}`, `${TMPDIR:-/tmp}`, and repository-relative paths.

## Version bump policy

Every commit must bump the plugin version, following semver. Commits without a
version bump are not allowed. Keep the following three slots in sync at the
same value — the `Check version consistency` step in `.github/workflows/test.yml`
enforces this and will fail CI on any mismatch:

1. `.claude-plugin/plugin.json` (`version`)
2. `.claude-plugin/marketplace.json` (`metadata.version`)
3. `.claude-plugin/marketplace.json` (`plugins[0].version`)

| Change type | Bump | Example |
|-------------|------|---------|
| Bug fix, display tweak, refactor, docs | patch (1.0.0 → 1.0.1) | Fix a silent hook failure, small README edit |
| New feature, new skill, extension of existing behavior | minor (1.0.0 → 1.1.0) | Add a new hook, extend the `/compact-plus` skill |
| Breaking change, incompatible skill / hook I/O change | major (1.0.0 → 2.0.0) | Incompatible shared-state file format change |

When in doubt, prefer patch.
