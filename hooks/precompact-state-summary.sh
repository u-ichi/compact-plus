#!/usr/bin/env bash
# PreCompact hook: create or update a compact-plus state file from the transcript.
# fail-open: do not block compaction when config, LLM, or filesystem work fails.

set -euo pipefail
trap 'exit 0' ERR

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLUGIN_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
PROMPT_FILE="$PLUGIN_ROOT/prompts/state-summary.md"

STATE_DIR="${TMPDIR:-/tmp}/claude-compact-state" # lint:allow-os-tmp
OFFSET_DIR="${TMPDIR:-/tmp}/claude-compact-state-offset" # lint:allow-os-tmp
COUNTER_DIR="${TMPDIR:-/tmp}/claude-compact-state-counter" # lint:allow-os-tmp

COMPACT_PLUS_TRANSCRIPT_MODE="${COMPACT_PLUS_TRANSCRIPT_MODE:-incremental}"
COMPACT_PLUS_TRANSCRIPT_HEAD_TURNS="${COMPACT_PLUS_TRANSCRIPT_HEAD_TURNS:-5}"
COMPACT_PLUS_TRANSCRIPT_TAIL_TURNS="${COMPACT_PLUS_TRANSCRIPT_TAIL_TURNS:-25}"
COMPACT_PLUS_TRANSCRIPT_HEAD_KB="${COMPACT_PLUS_TRANSCRIPT_HEAD_KB:-10}"
COMPACT_PLUS_TRANSCRIPT_TAIL_KB="${COMPACT_PLUS_TRANSCRIPT_TAIL_KB:-40}"
COMPACT_PLUS_INCREMENTAL_REFRESH="${COMPACT_PLUS_INCREMENTAL_REFRESH:-10}"
COMPACT_PLUS_MAX_OUTPUT_TOKENS="${COMPACT_PLUS_MAX_OUTPUT_TOKENS:-4096}"
COMPACT_PLUS_SQUASH_ENABLED="${COMPACT_PLUS_SQUASH_ENABLED:-1}"
COMPACT_PLUS_SQUASH_READ_LINES="${COMPACT_PLUS_SQUASH_READ_LINES:-100}"
COMPACT_PLUS_SQUASH_BASH_CHARS="${COMPACT_PLUS_SQUASH_BASH_CHARS:-500}"
COMPACT_PLUS_TWO_PASS="${COMPACT_PLUS_TWO_PASS:-1}"

DEFAULT_PRIMARY_BACKEND='claude -p --model claude-sonnet-5 --effort medium --permission-mode dontAsk --output-format text --no-session-persistence --system-prompt "$SYSTEM_PROMPT"'
PRIMARY_CMD="${COMPACT_PLUS_PRIMARY_BACKEND-$DEFAULT_PRIMARY_BACKEND}"

DEFAULT_FALLBACK_BACKEND='tmp=$(mktemp "${TMPDIR:-/tmp}/compact-plus-codex.XXXXXX"); { printf "%s\n\n" "$SYSTEM_PROMPT"; cat; } | codex exec --model gpt-5.3-codex-spark --sandbox read-only --skip-git-repo-check --dangerously-bypass-hook-trust --ignore-user-config --ephemeral --output-last-message "$tmp" - >/dev/null && cat "$tmp"; status=$?; rm -f "$tmp"; exit "$status"'
FALLBACK_CMD="${COMPACT_PLUS_FALLBACK_BACKEND-$DEFAULT_FALLBACK_BACKEND}"

INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)
TRIGGER=$(printf '%s' "$INPUT" | jq -r '.trigger // "unknown"' 2>/dev/null || printf 'unknown')
CUSTOM_INSTRUCTIONS=$(printf '%s' "$INPUT" | jq -r '.custom_instructions // empty' 2>/dev/null || true)

[[ -n "$SESSION_ID" ]] || exit 0
[[ -n "$TRANSCRIPT_PATH" ]] || exit 0
[[ -f "$TRANSCRIPT_PATH" ]] || exit 0
[[ -f "$PROMPT_FILE" ]] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

STATE_FILE="$STATE_DIR/$SESSION_ID.md"
OFFSET_FILE="$OFFSET_DIR/$SESSION_ID"
COUNTER_FILE="$COUNTER_DIR/$SESSION_ID"
mkdir -p "$STATE_DIR" "$OFFSET_DIR" "$COUNTER_DIR" 2>/dev/null || true

cap_bytes() {
  local kb="$1"
  local mode="$2"
  local max_bytes=$((kb * 1024))
  if [[ "$max_bytes" -le 0 ]]; then
    cat
  elif [[ "$mode" == "tail" ]]; then
    tail -c "$max_bytes"
  else
    head -c "$max_bytes"
  fi
}

jq_string() {
  local filter="$1"
  local json="$2"
  printf '%s' "$json" | jq -r "$filter" 2>/dev/null || true
}

extract_text() {
  local json="$1"
  jq_string '
    def text_value:
      if type == "string" then .
      elif type == "array" then ([.[]? | if type == "string" then . elif type == "object" then (.text? // .content? // "") else "" end] | join("\n"))
      elif type == "object" then (.text? // .content? // "")
      else "" end;
    [
      (.content? | text_value),
      (.message.content? | text_value),
      (.result? | text_value),
      (.output? | text_value),
      (.tool_result? | text_value)
    ] | map(select(. != null and . != "")) | first // ""
  ' "$json"
}

extract_tool_name() {
  local json="$1"
  jq_string '
    [
      .tool_name?, .name?,
      (.message.content[]? | objects | select(.type? == "tool_use") | .name?),
      (.message.content[]? | objects | select(.type? == "tool_result") | .name?)
    ] | map(select(. != null and . != "")) | first // ""
  ' "$json"
}

extract_refs() {
  local json="$1"
  local refs
  refs=$(printf '%s' "$json" | jq -r '.. | strings | select(test("(/[^[:space:]\"'\'']+|https?://[^[:space:]\"'\'']+)"))' 2>/dev/null | head -n 5 | tr '\n' ' ' || true)
  refs=${refs% }
  printf '%s' "${refs:-unknown path}"
}

process_json_line() {
  local line="$1"
  local json tool text refs line_count char_count exit_code match_count

  json=$(printf '%s' "$line" | jq -c '.' 2>/dev/null) || {
    printf '%s\n' "$line"
    return
  }

  [[ "$COMPACT_PLUS_SQUASH_ENABLED" == "1" ]] || {
    printf '%s\n' "$json"
    return
  }

  tool=$(extract_tool_name "$json")
  text=$(extract_text "$json")
  refs=$(extract_refs "$json")
  line_count=$(printf '%s' "$text" | awk 'END { print NR }')
  char_count=${#text}

  case "$tool" in
    Read)
      if [[ "$line_count" -gt "$COMPACT_PLUS_SQUASH_READ_LINES" ]]; then
        printf '[Read: %s lines from %s]\n' "$line_count" "$refs"
        return
      fi
      ;;
    Bash)
      if [[ "$char_count" -gt "$COMPACT_PLUS_SQUASH_BASH_CHARS" ]]; then
        exit_code=$(jq_string '.exit_code // .status // .metadata.exit_code // "unknown"' "$json")
        printf '[Bash: exit %s, %s chars output; refs: %s]\n' "$exit_code" "$char_count" "$refs"
        return
      fi
      ;;
    Grep|Glob)
      if [[ "$line_count" -gt "$COMPACT_PLUS_SQUASH_READ_LINES" ]]; then
        match_count=$(printf '%s' "$text" | awk 'END { print NR }')
        printf '[%s: %s matches; refs: %s]\n' "$tool" "$match_count" "$refs"
        return
      fi
      ;;
  esac

  printf '%s\n' "$json"
}

process_transcript_stream() {
  while IFS= read -r line || [[ -n "$line" ]]; do
    process_json_line "$line"
  done
}

semantic_head_tail() {
  local path="$1"
  local head_part tail_part
  # perf: slice the RAW file first, then squash. process_json_line emits exactly one
  # line per input line, so slicing before is equivalent to slicing after -- but it
  # drops jq spawns from O(all lines) to O(head+tail). On Windows/Git Bash a full-file
  # scan is ~5 jq spawns x every line and blows the hook timeout on big transcripts.
  head_part=$(head -n "$COMPACT_PLUS_TRANSCRIPT_HEAD_TURNS" "$path" | process_transcript_stream | cap_bytes "$COMPACT_PLUS_TRANSCRIPT_HEAD_KB" head)
  tail_part=$(tail -n "$COMPACT_PLUS_TRANSCRIPT_TAIL_TURNS" "$path" | process_transcript_stream | cap_bytes "$COMPACT_PLUS_TRANSCRIPT_TAIL_KB" tail)
  printf 'Transcript head (%s turns max):\n%s\n\nTranscript tail (%s turns max):\n%s\n' \
    "$COMPACT_PLUS_TRANSCRIPT_HEAD_TURNS" "$head_part" "$COMPACT_PLUS_TRANSCRIPT_TAIL_TURNS" "$tail_part"
}

semantic_tail() {
  local path="$1"
  # perf: same reasoning as semantic_head_tail -- slice raw, then squash.
  tail -n "$COMPACT_PLUS_TRANSCRIPT_TAIL_TURNS" "$path" | process_transcript_stream | cap_bytes "$COMPACT_PLUS_TRANSCRIPT_TAIL_KB" tail
}

transcript_from_offset() {
  local path="$1"
  local offset="$2"
  local size
  size=$(wc -c < "$path" | tr -d ' ')
  if [[ "$offset" -lt 0 || "$offset" -gt "$size" ]]; then
    return 1
  fi
  if [[ "$offset" -eq "$size" ]]; then
    printf '(no new transcript events since the previous compact)\n'
  else
    # perf: bound the raw window before squashing. Output is capped to TAIL_KB anyway,
    # so reading 20x that is far more than enough to fill it after squashing, while
    # keeping jq spawns bounded when a long stretch happened since the last compact.
    local raw_cap=$(( COMPACT_PLUS_TRANSCRIPT_TAIL_KB * 1024 * 20 ))
    if [[ "$raw_cap" -gt 0 ]]; then
      tail -c +"$((offset + 1))" "$path" | tail -c "$raw_cap" | process_transcript_stream | cap_bytes "$COMPACT_PLUS_TRANSCRIPT_TAIL_KB" tail
    else
      tail -c +"$((offset + 1))" "$path" | process_transcript_stream | cap_bytes "$COMPACT_PLUS_TRANSCRIPT_TAIL_KB" tail
    fi
  fi
}

state_is_valid() {
  [[ -f "$STATE_FILE" ]] && grep -q '^# Compact Prep State' "$STATE_FILE" 2>/dev/null
}

read_offset() {
  cat "$OFFSET_FILE"
}

offset_is_valid() {
  [[ -f "$OFFSET_FILE" ]] && grep -Eq '^[0-9]+$' "$OFFSET_FILE"
}

next_counter() {
  local value=0
  if [[ -f "$COUNTER_FILE" ]] && grep -Eq '^[0-9]+$' "$COUNTER_FILE"; then
    value=$(cat "$COUNTER_FILE")
  fi
  value=$((value + 1))
  printf '%s' "$value"
}

collect_skills_invoked() {
  local skills commands combined

  skills=$(
    jq -r '
      .message.content[]?
      | select(.type == "tool_use" and .name == "Skill")
      | .input.skill // empty
    ' "$TRANSCRIPT_PATH" 2>/dev/null || true
  )

  commands=$(
    jq -r '
      select(.type == "user")
      | .message.content? // .content? // empty
      | if type == "string" then .
        else (.[]? | .text? // empty)
        end
    ' "$TRANSCRIPT_PATH" 2>/dev/null \
      | grep -oE '<command-name>[^<]+</command-name>' \
      | sed -E 's|</?command-name>||g' \
      | grep -E '^/' || true
  )

  combined=$(printf '%s\n%s\n' "$skills" "$commands" | awk 'NF' | sort -u)
  if [[ -n "$combined" ]]; then
    printf '%s\n' "$combined"
  else
    printf '(none)\n'
  fi
}

build_user_prompt() {
  local mode="$1"
  local events="$2"
  local active_plan_path=""
  local active_plan_pointer="${TMPDIR:-/tmp}/claude-active-plan/$SESSION_ID" # lint:allow-os-tmp

  if [[ -f "$active_plan_pointer" ]]; then
    active_plan_path=$(head -n 1 "$active_plan_pointer" 2>/dev/null || true)
  fi

  printf 'session_id: %s\n' "$SESSION_ID"
  printf 'trigger: %s\n' "$TRIGGER"
  printf 'transcript_path: %s\n' "$TRANSCRIPT_PATH"
  printf 'mode: %s\n' "$mode"
  printf 'two_pass_enabled: %s\n' "$COMPACT_PLUS_TWO_PASS"
  if [[ -n "$active_plan_path" ]]; then
    printf 'active_plan: %s\n' "$active_plan_path"
  fi
  printf '\nExisting state (from previous /compact):\n'
  if state_is_valid && [[ "$mode" == "incremental" ]]; then
    cat "$STATE_FILE"
  else
    printf '(none)\n'
  fi
  printf '\n\nCustom instructions from user:\n%s\n' "${CUSTOM_INSTRUCTIONS:-"(none)"}"
  printf '\nSkills and commands invoked this session:\n%s\n' "$SKILLS_INVOKED_LIST"
  printf '\nNew events since last compact:\n%s\n' "$events"
  printf '\nTask: Generate or update the state summary using ADD, UPDATE, and PRESERVE operations.\n'
  printf 'Priority: honor user custom_instructions if provided.\n'
}

run_backend_if_set() {
  local cmd="$1"
  local user_prompt="$2"
  local output

  [[ -n "$cmd" ]] || return 1

  if output=$(SYSTEM_PROMPT="$SYSTEM_PROMPT" SESSION_ID="$SESSION_ID" TRANSCRIPT_PATH="$TRANSCRIPT_PATH" MAX_OUTPUT_TOKENS="$COMPACT_PLUS_MAX_OUTPUT_TOKENS" bash -c "$cmd" <<< "$user_prompt" 2>/dev/null); then
    if [[ "$(printf '%s\n' "$output" | head -n 1)" == "# Compact Prep State" ]]; then
      printf '%s\n' "$output"
      return 0
    fi
  fi
  return 1
}

run_backends() {
  local user_prompt="$1"
  if run_backend_if_set "$PRIMARY_CMD" "$user_prompt"; then
    return 0
  fi
  if run_backend_if_set "$FALLBACK_CMD" "$user_prompt"; then
    return 0
  fi
  return 1
}

TRANSCRIPT_SIZE=$(wc -c < "$TRANSCRIPT_PATH" | tr -d ' ')
CALL_COUNT=$(next_counter)
MODE="$COMPACT_PLUS_TRANSCRIPT_MODE"
EVENTS=""
OFFSET=0

case "$MODE" in
  tail)
    EVENTS=$(semantic_tail "$TRANSCRIPT_PATH")
    MODE="tail"
    ;;
  head-tail)
    EVENTS=$(semantic_head_tail "$TRANSCRIPT_PATH")
    MODE="head-tail"
    ;;
  incremental|*)
    MODE="incremental"
    if ! state_is_valid; then
      EVENTS=$(semantic_head_tail "$TRANSCRIPT_PATH")
      MODE="initial"
    elif [[ "$COMPACT_PLUS_INCREMENTAL_REFRESH" =~ ^[0-9]+$ ]] && [[ "$COMPACT_PLUS_INCREMENTAL_REFRESH" -gt 0 ]] && [[ $((CALL_COUNT % COMPACT_PLUS_INCREMENTAL_REFRESH)) -eq 0 ]]; then
      EVENTS=$(semantic_head_tail "$TRANSCRIPT_PATH")
      MODE="refresh"
    elif ! offset_is_valid; then
      EVENTS=$(semantic_head_tail "$TRANSCRIPT_PATH")
      MODE="initial"
    else
      OFFSET=$(read_offset)
      if ! EVENTS=$(transcript_from_offset "$TRANSCRIPT_PATH" "$OFFSET"); then
        EVENTS=$(semantic_head_tail "$TRANSCRIPT_PATH")
        MODE="initial"
      fi
    fi
    ;;
esac

SYSTEM_PROMPT=$(cat "$PROMPT_FILE")
SKILLS_INVOKED_LIST=$(collect_skills_invoked)
USER_PROMPT=$(build_user_prompt "$MODE" "$EVENTS")

OUTPUT=$(run_backends "$USER_PROMPT" || true)
[[ -n "$OUTPUT" ]] || exit 0

TMP_FILE=$(mktemp "${TMPDIR:-/tmp}/compact-plus-state.XXXXXX") # lint:allow-os-tmp
printf '%s\n' "$OUTPUT" > "$TMP_FILE"
mv "$TMP_FILE" "$STATE_FILE" 2>/dev/null || true
printf '%s\n' "$TRANSCRIPT_SIZE" > "$OFFSET_FILE" 2>/dev/null || true
printf '%s\n' "$CALL_COUNT" > "$COUNTER_FILE" 2>/dev/null || true

exit 0
