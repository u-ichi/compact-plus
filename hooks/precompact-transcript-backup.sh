#!/usr/bin/env bash
# PreCompact hook: copy transcript_path to persistent backup storage.
# fail-open: do not block compaction even when backup fails.

set -euo pipefail
trap 'exit 0' ERR

INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)

[[ -n "$SESSION_ID" ]] || exit 0
[[ -n "$TRANSCRIPT_PATH" ]] || exit 0
[[ -f "$TRANSCRIPT_PATH" ]] || exit 0

BACKUP_DIR="${HOME}/.claude/backups/transcripts"
mkdir -p "$BACKUP_DIR" 2>/dev/null || true

EPOCH=$(date +%s)
DEST="$BACKUP_DIR/${EPOCH}-${SESSION_ID}.jsonl"
cp "$TRANSCRIPT_PATH" "$DEST" 2>/dev/null || exit 0

# mapfile is a bash 4+ builtin and stock macOS /bin/bash is 3.2, so use a
# POSIX while-read loop to prune old backups instead.
find "$BACKUP_DIR" -maxdepth 1 -type f -name "*-${SESSION_ID}.jsonl" -print 2>/dev/null \
  | sort -r \
  | tail -n +21 \
  | while IFS= read -r old; do
      rm -f "$old" 2>/dev/null || true
    done

exit 0
