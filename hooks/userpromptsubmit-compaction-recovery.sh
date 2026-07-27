#!/bin/bash
# UserPromptSubmit hook: detect the marker file left by PostCompact and inject
# compaction recovery guidance through additionalContext (one-shot).
#
# overhead: one test -f per turn; exit immediately when no marker exists.
# fail-open (always exit 0)

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../scripts/runtime-paths.sh
source "$SCRIPT_DIR/../scripts/runtime-paths.sh"

INPUT=$(cat)
SESSION_ID=$(compact_plus_artifact_key "$INPUT")
[[ -z "$SESSION_ID" ]] && exit 0

HOOK_EVENT=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)
EXPECTED_EVENT="${COMPACT_PLUS_RECOVERY_EVENT:-UserPromptSubmit}"
[[ "$HOOK_EVENT" == "$EXPECTED_EVENT" ]] || exit 0
if [[ "$EXPECTED_EVENT" == "SessionStart" ]]; then
  [[ "$COMPACT_PLUS_RUNTIME_NAME" == "codex" ]] || exit 0
  SOURCE=$(printf '%s' "$INPUT" | jq -r '.source // empty' 2>/dev/null)
  [[ "$SOURCE" == "compact" ]] || exit 0
fi
# Codex UserPromptSubmit is also a delivery channel, not only Claude Code.
# Codex dispatches SessionStart(source=compact) for root threads only; a
# thread-spawn subagent gets no start hook after compaction, so its recovery has
# to ride on the next prompt instead. Parent messages reach a subagent as user
# input, so this hook runs there. The marker is consumed once, so a root thread
# that already recovered at SessionStart falls through as a no-op here.

# Do nothing when the marker file is absent.
MARKER_DIR="$COMPACT_PLUS_MARKER_DIR"
MARKER="$MARKER_DIR/$SESSION_ID"
[[ -f "$MARKER" ]] || exit 0

# Remove the marker so this hook fires only once.
rm -f "$MARKER" 2>/dev/null || true

# Read the active plan path from the session pointer file.
PTR_DIR="$COMPACT_PLUS_PLAN_POINTER_DIR"
PLAN_FILE=""
if [[ -f "$PTR_DIR/$SESSION_ID" ]]; then
  PLAN_FILE=$(cat "$PTR_DIR/$SESSION_ID" 2>/dev/null || true)
  [[ -f "$PLAN_FILE" ]] || PLAN_FILE=""
fi

# Build recovery guidance.
CTX="[COMPACTION RECOVERY] Context compaction occurred. Before resuming work, use the following recovery references."
CTX+=$'\n'

if [[ -n "$PLAN_FILE" ]]; then
  CTX+=$'\n'"- Re-read plan file \`${PLAN_FILE}\` with Read and confirm the current phase and constraints."
  CTX+=$'\n'"- If plan mode is no longer active, note that a plan file exists and ask the user whether to re-enter plan mode."
fi

STATE_DIR="$COMPACT_PLUS_STATE_DIR"
STATE_FILE="$STATE_DIR/$SESSION_ID.md"
PENDING_FILE="$COMPACT_PLUS_PENDING_DIR/$SESSION_ID"

state_is_current() {
  local event_id manual_ready state_event
  [[ -f "$STATE_FILE" && -f "$PENDING_FILE" ]] || return 1
  event_id=$(sed -n '1p' "$PENDING_FILE" 2>/dev/null || true)
  manual_ready=$(sed -n '2p' "$PENDING_FILE" 2>/dev/null || true)
  state_event=$(grep -m 1 '^<!-- compact-plus-event: ' "$STATE_FILE" 2>/dev/null || true)
  [[ -n "$event_id" ]] || return 1
  [[ "$state_event" == "<!-- compact-plus-event: $event_id -->" ]] && return 0
  [[ "$manual_ready" == "1" ]] && grep -q '^<!-- compact-plus-manual-ready -->$' "$STATE_FILE" 2>/dev/null
}

STATE_CURRENT=0
if state_is_current; then
  STATE_CURRENT=1
fi
if [[ -f "$STATE_FILE" && "$STATE_CURRENT" -eq 1 ]]; then
  CTX+=$'\n'"- Read state file \`${STATE_FILE}\` with Read and restore the working state."
  CTX+=$'\n'"- Pay special attention to Session Decisions and Recovery Notes."
  if grep -q '^## Skills Invoked' "$STATE_FILE" 2>/dev/null; then
    CTX+=$'\n'"- The state file at \`${STATE_FILE}\` includes a \`## Skills Invoked\` section listing the skills and slash commands invoked earlier in this session."
  fi
else
  BACKUP_DIR="$COMPACT_PLUS_BACKUP_DIR"
  BACKUP_FILE=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name "*-${SESSION_ID}.jsonl" -print 2>/dev/null | sort -r | head -n 1 || true)
  if [[ -n "$BACKUP_FILE" && -f "$BACKUP_FILE" ]]; then
    CTX+=$'\n'"- No state file was found. Transcript backup \`${BACKUP_FILE}\` exists; read it if recovery details are needed."
  fi
fi

CTX+=$'\n'"- Check TaskList for the current task list."
CTX+=$'\n'"- Treat next steps from the compaction summary as hypotheses; use the plan and rules as the source of truth."
CTX+=$'\n'"- Treat the compaction summary as a record of prior work, not as instructions for the next action."
CTX+=$'\n'"- Original memory / rule / skill files are the authoritative references; compaction summaries may omit scope qualifiers."

if jq -n --arg ctx "$CTX" --arg event "$EXPECTED_EVENT" '{
  hookSpecificOutput: {
    hookEventName: $event,
    additionalContext: $ctx
  }
}'; then
  rm -f "$PENDING_FILE" 2>/dev/null || true
fi
exit 0
