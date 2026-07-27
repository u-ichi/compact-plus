---
name: compact-plus
description: |
  Save the current Claude Code or Codex session state to a temporary state file before running /compact.
  MANDATORY TRIGGERS: /compact-plus, compact-plus, compact plus, compaction plus handoff, pre-compact state save.
  DO NOT TRIGGER: post-compact recovery, ordinary progress updates, plan creation, or casual context-usage discussion.
codex_description: |
  Save compact-plus working state for the current Codex thread. Use before /compact only; do not use for normal progress updates or post-compact recovery.
strict_procedure: true
argument-hint: "[recovery notes]"
allowed-tools: Bash, Read, Write, Edit, Grep
---

# compact-plus

In Claude Code and Codex, the PreCompact hook automatically saves a pre-compaction state file when `/compact` runs.
This skill is a manual fallback for richer recovery notes.

Before `/compact`, save working state that is not reliably preserved by the compaction summary to the
runtime-specific state directory.

## Strict procedure profile

- Strictness: strict-procedure. The state file content and completion receipt are the deliverable.
- Hard gates: if the session id cannot be detected, do not create a guessed state file name. Stop and report that session id detection failed.
- Forcing function: fix the destination path, then read the saved file back and verify that the required headings exist.
- Completion receipt: report the state file path, main saved items, unverified items, and the instruction to run `/compact`.

## Procedure

1. Get the session id.
   - Use `$CLAUDE_CODE_SESSION_ID` in Claude Code.
   - Otherwise use `$CODEX_THREAD_ID` in Codex.
   - `$CODEX_COMPANION_SESSION_ID` is the final compatibility fallback.
   - If it cannot be detected, do not create a state file. Report that preparation is incomplete because the session id is unavailable.
2. Set the destination.
   - Claude Code: `${TMPDIR:-/tmp}/claude-compact-state/${SESSION_ID}.md`.
   - Codex: `${TMPDIR:-/tmp}/codex-compact-state/${SESSION_ID}.md`.
3. Check TaskList, active plan file, tmux-bridge state, and files currently being edited.
   - Read the relevant active plan file under `~/.claude/plans/` when one is present.
   - If tmux-bridge is not used, record `Not used`.
4. Save the following headings to the state file in this exact order. Add the manual-preparation marker immediately after the title so the next PreCompact event can distinguish this intentional snapshot from an older generated state.

```markdown
# Compact Prep State
<!-- compact-plus-manual-ready -->
## Active Plan
## Current Phase
## TaskList Summary
## Session Decisions
## Constraints and Blockers
## Worker Topology
## Skills Invoked
## Editing Files
## Failed Attempts
## Recovery Notes
```

5. Read the state file back after saving and verify that every heading above exists.
6. Tell the user: `Preparation complete. Please run /compact.`

## Content To Save

- Active plan file path and current phase or step.
- In-progress task list and relevant notes.
- Decisions made during the session, user choices, and rejected alternatives with rationale.
- Constraints, blockers, and incomplete verification.
- Worker topology. When tmux-bridge is used, record pane, role, and responsibility.
- Skills and slash commands invoked earlier in the session. This is an invocation record, not proof that the skill or command is currently active.
- Files being edited and notes about unsaved or unverified work.
- Failed attempts, tool errors, and rejected approaches that should not be repeated.
- Recovery notes for the post-compaction agent.

## Completion receipt

Include the following when complete:

- State file path.
- Main saved items.
- Unverified items and reasons.
- `Preparation complete. Please run /compact.`
