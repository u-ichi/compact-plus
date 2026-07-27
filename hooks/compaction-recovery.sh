#!/bin/bash
# PostCompact hook (matcher: ""): record compaction with a marker file.
# PostCompact does not support additionalContext output, so the marker is
# consumed by SessionStart(source=compact), which injects the saved state. Codex
# thread-spawn subagents get no start hook after compaction, so UserPromptSubmit
# stays as their delivery channel.
#
# fail-open (always exit 0)

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../scripts/runtime-paths.sh
source "$SCRIPT_DIR/../scripts/runtime-paths.sh"

INPUT=$(cat)
SESSION_ID=$(compact_plus_artifact_key "$INPUT")
[[ -z "$SESSION_ID" ]] && exit 0

# On Claude Code, SessionStart(source=compact) runs before this hook and leaves an
# injected mark once it has delivered the state. Consume that mark instead of
# writing a marker, otherwise UserPromptSubmit would inject the same state a
# second time on the next prompt.
INJECTED="$COMPACT_PLUS_INJECTED_DIR/$SESSION_ID"
if [[ -f "$INJECTED" ]]; then
  rm -f "$INJECTED" 2>/dev/null || true
else
  # Write the marker file. The recovery hook that runs next consumes it once.
  MARKER_DIR="$COMPACT_PLUS_MARKER_DIR"
  mkdir -p "$MARKER_DIR" 2>/dev/null || true
  printf '%s\n' "$(date +%s)" > "$MARKER_DIR/$SESSION_ID" 2>/dev/null || true
fi

# Reset the compact reminder cooldown after compact runs.
WARN_DIR="$COMPACT_PLUS_WARNED_DIR"
rm -f "$WARN_DIR/$SESSION_ID" 2>/dev/null || true

exit 0
