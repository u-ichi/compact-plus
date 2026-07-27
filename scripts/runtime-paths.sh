#!/usr/bin/env bash

# Shared runtime and storage paths for Claude Code and Codex hooks.
# COMPACT_PLUS_RUNTIME is an explicit test/debug override. Codex plugin hooks
# set PLUGIN_ROOT; Claude Code plugin hooks only set CLAUDE_PLUGIN_ROOT.

if [[ -n "${COMPACT_PLUS_RUNTIME:-}" ]]; then
  COMPACT_PLUS_RUNTIME_NAME="$COMPACT_PLUS_RUNTIME"
elif [[ -n "${PLUGIN_ROOT:-}" ]]; then
  COMPACT_PLUS_RUNTIME_NAME="codex"
else
  COMPACT_PLUS_RUNTIME_NAME="claude"
fi

case "$COMPACT_PLUS_RUNTIME_NAME" in
  codex)
    COMPACT_PLUS_STATE_DIR="${TMPDIR:-/tmp}/codex-compact-state" # lint:allow-os-tmp
    COMPACT_PLUS_OFFSET_DIR="${TMPDIR:-/tmp}/codex-compact-state-offset" # lint:allow-os-tmp
    COMPACT_PLUS_COUNTER_DIR="${TMPDIR:-/tmp}/codex-compact-state-counter" # lint:allow-os-tmp
    COMPACT_PLUS_MARKER_DIR="${TMPDIR:-/tmp}/codex-compacted" # lint:allow-os-tmp
    COMPACT_PLUS_INJECTED_DIR="${TMPDIR:-/tmp}/codex-compact-injected" # lint:allow-os-tmp
    COMPACT_PLUS_WARN_DIR="${TMPDIR:-/tmp}/codex-compact-warn" # lint:allow-os-tmp
    COMPACT_PLUS_WARNED_DIR="${TMPDIR:-/tmp}/codex-compact-warned" # lint:allow-os-tmp
    COMPACT_PLUS_PLAN_POINTER_DIR="${TMPDIR:-/tmp}/codex-active-plan" # lint:allow-os-tmp
    COMPACT_PLUS_BACKUP_DIR="${CODEX_HOME:-${HOME}/.codex}/backups/transcripts"
    ;;
  claude|*)
    COMPACT_PLUS_RUNTIME_NAME="claude"
    COMPACT_PLUS_STATE_DIR="${TMPDIR:-/tmp}/claude-compact-state" # lint:allow-os-tmp
    COMPACT_PLUS_OFFSET_DIR="${TMPDIR:-/tmp}/claude-compact-state-offset" # lint:allow-os-tmp
    COMPACT_PLUS_COUNTER_DIR="${TMPDIR:-/tmp}/claude-compact-state-counter" # lint:allow-os-tmp
    COMPACT_PLUS_MARKER_DIR="${TMPDIR:-/tmp}/claude-compacted" # lint:allow-os-tmp
    COMPACT_PLUS_INJECTED_DIR="${TMPDIR:-/tmp}/claude-compact-injected" # lint:allow-os-tmp
    COMPACT_PLUS_WARN_DIR="${TMPDIR:-/tmp}/claude-compact-warn" # lint:allow-os-tmp
    COMPACT_PLUS_WARNED_DIR="${TMPDIR:-/tmp}/claude-compact-warned" # lint:allow-os-tmp
    COMPACT_PLUS_PLAN_POINTER_DIR="${TMPDIR:-/tmp}/claude-active-plan" # lint:allow-os-tmp
    COMPACT_PLUS_BACKUP_DIR="${HOME}/.claude/backups/transcripts"
    ;;
esac

# Resolve the per-thread key used for every artifact file name.
#
# Codex sets session_id to the identity shared by the root thread and all of its
# descendant threads, and adds agent_id for thread-spawn subagents. Keying on
# session_id alone stores a subagent's state, transcript backup, and marker under
# the parent's name, so the child never finds its own state and the parent's state
# file is overwritten. Prefer agent_id and fall back to session_id.
#
# Reads the hook input JSON from $1 and prints the key (empty when both absent).
compact_plus_artifact_key() {
  printf '%s' "${1:-}" | jq -r '.agent_id // .session_id // empty' 2>/dev/null || true
}

export COMPACT_PLUS_RUNTIME_NAME
export COMPACT_PLUS_STATE_DIR
export COMPACT_PLUS_OFFSET_DIR
export COMPACT_PLUS_COUNTER_DIR
export COMPACT_PLUS_MARKER_DIR
export COMPACT_PLUS_INJECTED_DIR
export COMPACT_PLUS_WARN_DIR
export COMPACT_PLUS_WARNED_DIR
export COMPACT_PLUS_PLAN_POINTER_DIR
export COMPACT_PLUS_BACKUP_DIR
