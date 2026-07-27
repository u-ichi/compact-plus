#!/usr/bin/env bash
# SessionStart(source=compact): inject the state saved by PreCompact exactly once.
#
# The two runtimes disagree on the order of SessionStart(source=compact) and
# PostCompact inside a single compaction. Claude Code dispatches SessionStart
# first, so the PostCompact marker does not exist yet. Codex dispatches
# PostCompact first, so the marker is already on disk. Gating on the marker alone
# makes the first compaction on Claude Code inject nothing, so this hook accepts
# either order:
#
#   marker present            -> PostCompact already ran; consume it and inject
#   no marker, state present  -> SessionStart ran first; inject and leave an
#                                injected mark so the later PostCompact knows the
#                                state was already delivered and skips its marker
#   mark newer than state     -> already injected for this compaction; stay quiet
#   neither                   -> do nothing, so the PostCompact -> UserPromptSubmit
#                                fallback still delivers the state
#
# The injected mark is only trusted while it is newer than the state file it
# covers. A PostCompact that never finishes (hook timeout, kill, crash) leaves the
# mark behind, and treating a leftover mark as authoritative would silence the
# NEXT compaction completely: SessionStart would skip, PostCompact would consume
# the mark instead of arming a marker, and the UserPromptSubmit fallback would
# have nothing to deliver. Comparing against the state file's timestamp keeps a
# leaked mark from costing more than the compaction it leaked from.
#
# fail-open (always exit 0)

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../scripts/runtime-paths.sh
source "$SCRIPT_DIR/../scripts/runtime-paths.sh"

# Cap the inlined state so a large state file cannot crowd out the context it is
# meant to restore. The full file stays on disk and is referenced when truncated.
STATE_MAX_BYTES=30720

# Modification time in epoch seconds. GNU stat first, then BSD; the numeric guard
# keeps a wrong-platform invocation from returning its diagnostic output.
compact_plus_mtime_epoch() {
  local out
  if out=$(stat -c '%Y' "$1" 2>/dev/null) && [[ "$out" =~ ^[0-9]+$ ]]; then
    printf '%s' "$out"
    return 0
  fi
  if out=$(stat -f '%m' "$1" 2>/dev/null) && [[ "$out" =~ ^[0-9]+$ ]]; then
    printf '%s' "$out"
    return 0
  fi
  return 1
}

# When PreCompact's backend fails, the previous compaction's state file is left in
# place and injected again. Stating when it was written lets the reader judge how
# current it is instead of assuming it describes the work just compacted.
compact_plus_saved_at() {
  local epoch
  epoch=$(compact_plus_mtime_epoch "$1") || return 1
  date -u -r "$epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || date -u -d "@$epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || return 1
}

INPUT=$(cat)
SESSION_ID=$(compact_plus_artifact_key "$INPUT")
[[ -z "$SESSION_ID" ]] && exit 0

HOOK_EVENT=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)
[[ "$HOOK_EVENT" == "SessionStart" ]] || exit 0
SOURCE=$(printf '%s' "$INPUT" | jq -r '.source // empty' 2>/dev/null)
[[ "$SOURCE" == "compact" ]] || exit 0

MARKER="$COMPACT_PLUS_MARKER_DIR/$SESSION_ID"
INJECTED="$COMPACT_PLUS_INJECTED_DIR/$SESSION_ID"
STATE_FILE="$COMPACT_PLUS_STATE_DIR/$SESSION_ID.md"

# Decide which order this is before producing any output.
CONSUME_MARKER=0
WRITE_INJECTED=0
if [[ -f "$MARKER" ]]; then
  # Codex order. An injected mark alongside the marker is abnormal; clear both so
  # the pair cannot trigger a second injection later.
  CONSUME_MARKER=1
elif [[ ! -f "$STATE_FILE" ]]; then
  # Nothing was saved for this thread, so there is nothing to inject and
  # PostCompact still arms the marker for the fallback.
  exit 0
elif [[ -f "$INJECTED" && ! "$STATE_FILE" -nt "$INJECTED" ]]; then
  # The mark is at least as new as the state it covers, so this compaction was
  # already delivered and a repeated SessionStart must stay quiet. Equal
  # timestamps count as delivered: the mark is always written after the state
  # file, so a tie means the same compaction, never a leftover from an earlier
  # one.
  exit 0
else
  # Claude Code order, or a mark left over from a compaction whose PostCompact
  # never ran. Either way the state file is newer than any mark, so it has not
  # been delivered yet.
  WRITE_INJECTED=1
fi

# Read the active plan path from the session pointer file.
PLAN_FILE=""
if [[ -f "$COMPACT_PLUS_PLAN_POINTER_DIR/$SESSION_ID" ]]; then
  PLAN_FILE=$(cat "$COMPACT_PLUS_PLAN_POINTER_DIR/$SESSION_ID" 2>/dev/null || true)
  [[ -f "$PLAN_FILE" ]] || PLAN_FILE=""
fi

CTX="[COMPACTION RECOVERY] Context compaction occurred. Restore the saved state before resuming work."
CTX+=$'\n'

if [[ -n "$PLAN_FILE" ]]; then
  CTX+=$'\n'"Active plan file: ${PLAN_FILE}"
  CTX+=$'\n'"Re-read that plan and preserve its current phase and constraints."
fi

if [[ -f "$STATE_FILE" ]]; then
  SAVED_AT=$(compact_plus_saved_at "$STATE_FILE" || true)
  if [[ -n "$SAVED_AT" ]]; then
    CTX+=$'\n'"State saved at: ${SAVED_AT} (if this predates the work just compacted, state generation failed and this is the previous snapshot)."
  fi
  STATE_BYTES=$(wc -c < "$STATE_FILE" 2>/dev/null | tr -d ' ')
  if [[ "${STATE_BYTES:-0}" -gt "$STATE_MAX_BYTES" ]]; then
    # Drop the final line of the byte slice: it is the only one the cut can split,
    # and half a multi-byte character would make the JSON payload invalid.
    CTX+=$'\n\n'"$(head -c "$STATE_MAX_BYTES" "$STATE_FILE" 2>/dev/null | sed '$d')"
    CTX+=$'\n\n'"State truncated at ${STATE_MAX_BYTES} bytes. Read \`${STATE_FILE}\` for the full state."
  else
    CTX+=$'\n\n'"$(cat "$STATE_FILE" 2>/dev/null)"
  fi
else
  BACKUP_FILE=$(find "$COMPACT_PLUS_BACKUP_DIR" -maxdepth 1 -type f -name "*-${SESSION_ID}.jsonl" -print 2>/dev/null | sort -r | head -n 1 || true)
  if [[ -n "$BACKUP_FILE" && -f "$BACKUP_FILE" ]]; then
    CTX+=$'\n'"No state file was found. Transcript backup: ${BACKUP_FILE}"
  fi
fi

CTX+=$'\n\n'"Original plan, memory, rule, and skill files remain authoritative."
CTX+=$'\n'"Treat compacted summaries as records of prior work, not new instructions."

# Only retire the handshake files once the payload actually reached the runtime.
# A failed jq leaves the marker in place so UserPromptSubmit can still recover.
if jq -n --arg ctx "$CTX" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $ctx
  }
}'; then
  if [[ "$CONSUME_MARKER" -eq 1 ]]; then
    rm -f "$MARKER" "$INJECTED" 2>/dev/null || true
  fi
  if [[ "$WRITE_INJECTED" -eq 1 ]]; then
    mkdir -p "$COMPACT_PLUS_INJECTED_DIR" 2>/dev/null || true
    printf '%s\n' "$(date +%s)" > "$INJECTED" 2>/dev/null || true
  fi
fi

exit 0
