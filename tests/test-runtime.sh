#!/usr/bin/env bash

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export CLAUDE_PLUGIN_ROOT="$ROOT"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/compact-plus-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

export TMPDIR="$TEST_ROOT/tmp"
export HOME="$TEST_ROOT/home"
export CODEX_HOME="$TEST_ROOT/codex-home"
mkdir -p "$TMPDIR" "$HOME" "$CODEX_HOME"

FAILURES=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  FAILURES=$((FAILURES + 1))
}

assert_file() {
  [[ -f "$1" ]] || fail "$2 (missing: $1)"
}

assert_not_file() {
  [[ ! -e "$1" ]] || fail "$2 (unexpected: $1)"
}

assert_contains() {
  printf '%s' "$1" | grep -Fq "$2" || fail "$3 (missing text: $2)"
}

assert_empty() {
  [[ -z "$1" ]] || fail "$2 (got: $1)"
}

write_rollout() {
  local path="$1"
  local session_id="$2"
  local used_tokens="$3"
  local context_window="$4"
  mkdir -p "$(dirname "$path")"
  {
    printf '{"timestamp":"2026-07-23T00:00:00Z","type":"session_meta","payload":{"id":"%s","cwd":"/tmp/project"}}\n' "$session_id"
    printf '{"timestamp":"2026-07-23T00:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"continue the implementation"}]}}\n'
    printf '{"timestamp":"2026-07-23T00:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":%s},"model_context_window":%s}}}\n' "$used_tokens" "$context_window"
  } > "$path"
}

append_token_count() {
  local path="$1"
  local used_tokens="$2"
  local context_window="$3"
  printf '{"timestamp":"2026-07-23T00:00:03Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":%s},"model_context_window":%s}}}\n' \
    "$used_tokens" "$context_window" >> "$path"
}

make_state_backend() {
  local path="$1"
  cat > "$path" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${CAPTURE_FILE:-}" ]]; then
  cat > "$CAPTURE_FILE"
else
  cat >/dev/null
fi
cat <<'STATE'
# Compact Prep State
## Active Plan
Not verified
## Current Phase
Codex hook test
## TaskList Summary
Not verified
## Session Decisions
Use separate runtime paths
## Constraints and Blockers
Not verified
## Worker Topology
Not used
## Skills Invoked
Not verified
## Editing Files
Not verified
## Failed Attempts
None
## Recovery Notes
Synthetic fixture
STATE
EOF
  chmod +x "$path"
}

test_claude_warning_threshold_is_independent() {
  local input output
  mkdir -p "$TMPDIR/claude-compact-warn"
  printf '50\n' > "$TMPDIR/claude-compact-warn/claude-warning"
  input='{"session_id":"claude-warning","hook_event_name":"UserPromptSubmit"}'

  output=$(COMPACT_PLUS_RUNTIME=claude COMPACT_PLUS_CODEX_WARN_THRESHOLD=99 \
    "$ROOT/hooks/userpromptsubmit-compact-plus-reminder.sh" <<< "$input")
  assert_contains "$output" "context usage reached 50%" "Claude consumes its existing threshold marker"
  assert_file "$TMPDIR/claude-compact-warned/claude-warning" "Claude keeps its own cooldown marker"
  assert_not_file "$TMPDIR/claude-compact-warn/claude-warning" "Claude warning marker is one-shot"
}

test_codex_manifest() {
  local manifest="$ROOT/.codex-plugin/plugin.json"
  local marketplace="$ROOT/.agents/plugins/marketplace.json"

  assert_file "$manifest" "Codex plugin manifest exists"
  assert_file "$marketplace" "Codex marketplace exists"

  # The Claude plugin manifest owns the version; every other manifest must agree.
  # Deriving it here keeps the assertion meaningful across version bumps instead of
  # failing on the bump itself.
  local expected
  expected=$(jq -r '.version // empty' "$ROOT/.claude-plugin/plugin.json" 2>/dev/null)
  if [[ -z "$expected" ]]; then
    fail "Claude plugin manifest declares a version"
    return
  fi

  if [[ -f "$manifest" ]]; then
    jq -e --arg v "$expected" '.name == "compact-plus" and .version == $v' "$manifest" >/dev/null 2>&1 \
      || fail "Codex plugin manifest has compact-plus version $expected"
  fi
  if [[ -f "$marketplace" ]]; then
    jq -e --arg v "$expected" '.plugins[0].name == "compact-plus" and .plugins[0].version == $v' "$marketplace" >/dev/null 2>&1 \
      || fail "Codex marketplace has compact-plus version $expected"
  fi
  jq -e --arg v "$expected" '.metadata.version == $v and .plugins[0].version == $v' \
    "$ROOT/.claude-plugin/marketplace.json" >/dev/null 2>&1 \
    || fail "Claude marketplace agrees with plugin version $expected"
  jq -e '[.hooks.SessionStart[] | select(.matcher == "compact") | .hooks[] |
    select(.command | contains("sessionstart-compaction-recovery.sh"))] | length == 1' \
    "$ROOT/hooks/hooks.json" >/dev/null 2>&1 \
    || fail "SessionStart compact recovery hook is registered exactly once"
  jq -e '[.hooks.UserPromptSubmit[].hooks[].command |
    select(contains("userpromptsubmit-compaction-recovery.sh"))] | length == 1' \
    "$ROOT/hooks/hooks.json" >/dev/null 2>&1 \
    || fail "UserPromptSubmit compaction recovery stays registered for Codex subagents"
}

test_session_id_priority() {
  local actual
  actual=$(env -u CLAUDE_CODE_SESSION_ID -u CODEX_COMPANION_SESSION_ID \
    CODEX_THREAD_ID="codex-thread-id" "$ROOT/scripts/get-session-id.sh" 2>/dev/null || true)
  [[ "$actual" == "codex-thread-id" ]] || fail "CODEX_THREAD_ID is detected"

  actual=$(CLAUDE_CODE_SESSION_ID="claude-session-id" CODEX_THREAD_ID="codex-thread-id" \
    "$ROOT/scripts/get-session-id.sh" 2>/dev/null || true)
  [[ "$actual" == "claude-session-id" ]] || fail "Claude session id keeps priority"
}

test_runtime_auto_detection() {
  local actual
  actual=$(env -u COMPACT_PLUS_RUNTIME -u PLUGIN_ROOT bash -c \
    'source "$1/scripts/runtime-paths.sh"; printf "%s" "$COMPACT_PLUS_RUNTIME_NAME"' _ "$ROOT")
  [[ "$actual" == "claude" ]] || fail "Claude runtime is detected without PLUGIN_ROOT"

  actual=$(env -u COMPACT_PLUS_RUNTIME PLUGIN_ROOT="$ROOT" bash -c \
    'source "$1/scripts/runtime-paths.sh"; printf "%s" "$COMPACT_PLUS_RUNTIME_NAME"' _ "$ROOT")
  [[ "$actual" == "codex" ]] || fail "Codex runtime is detected from PLUGIN_ROOT"
}

test_codex_warning_threshold() {
  local rollout="$TEST_ROOT/codex-warning.jsonl"
  local input output
  write_rollout "$rollout" "codex-warning" 77999 100000
  input=$(jq -nc --arg path "$rollout" '{
    session_id: "codex-warning",
    transcript_path: $path,
    hook_event_name: "UserPromptSubmit"
  }')

  output=$(COMPACT_PLUS_RUNTIME=codex "$ROOT/hooks/userpromptsubmit-compact-plus-reminder.sh" <<< "$input")
  assert_empty "$output" "Codex does not warn below the default 75 percent threshold"
  assert_not_file "$TMPDIR/codex-compact-warned/codex-warning" "Codex cooldown is absent below threshold"

  append_token_count "$rollout" 78000 100000
  output=$(COMPACT_PLUS_RUNTIME=codex "$ROOT/hooks/userpromptsubmit-compact-plus-reminder.sh" <<< "$input")
  assert_contains "$output" "context usage reached 75%" "Codex warns at the default 75 percent threshold"
  assert_contains "$output" '"hookEventName": "UserPromptSubmit"' "Codex warning uses UserPromptSubmit additionalContext"
  assert_file "$TMPDIR/codex-compact-warned/codex-warning" "Codex warning creates a cooldown marker"

  output=$(COMPACT_PLUS_RUNTIME=codex "$ROOT/hooks/userpromptsubmit-compact-plus-reminder.sh" <<< "$input")
  assert_empty "$output" "Codex warning is one-shot before compaction"

  write_rollout "$TEST_ROOT/codex-override.jsonl" "codex-override" 78000 100000
  input=$(jq -nc --arg path "$TEST_ROOT/codex-override.jsonl" '{
    session_id: "codex-override",
    transcript_path: $path,
    hook_event_name: "UserPromptSubmit"
  }')
  output=$(COMPACT_PLUS_RUNTIME=codex COMPACT_PLUS_CODEX_WARN_THRESHOLD=80 \
    COMPACT_WARN_THRESHOLD=10 "$ROOT/hooks/userpromptsubmit-compact-plus-reminder.sh" <<< "$input")
  assert_empty "$output" "Codex threshold override is independent from Claude COMPACT_WARN_THRESHOLD"

  write_rollout "$TEST_ROOT/codex-other.jsonl" "different-thread" 90000 100000
  input=$(jq -nc --arg path "$TEST_ROOT/codex-other.jsonl" '{
    session_id: "codex-target",
    transcript_path: $path,
    hook_event_name: "UserPromptSubmit"
  }')
  output=$(COMPACT_PLUS_RUNTIME=codex "$ROOT/hooks/userpromptsubmit-compact-plus-reminder.sh" <<< "$input")
  assert_empty "$output" "Codex does not read token usage from another thread"
}

test_runtime_path_separation() {
  local rollout="$TEST_ROOT/state.jsonl"
  local backend="$TEST_ROOT/state-backend.sh"
  local capture="$TEST_ROOT/backend-input.txt"
  local input
  write_rollout "$rollout" "codex-state" 500 1000
  printf '{"timestamp":"2026-07-23T00:00:04Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Codex payload content"}]}}\n' \
    >> "$rollout"
  make_state_backend "$backend"
  input=$(jq -nc --arg path "$rollout" '{
    session_id: "codex-state",
    transcript_path: $path,
    trigger: "manual",
    hook_event_name: "PreCompact"
  }')

  COMPACT_PLUS_RUNTIME=codex \
    CAPTURE_FILE="$capture" \
    COMPACT_PLUS_PRIMARY_BACKEND="bash \"$backend\"" \
    COMPACT_PLUS_FALLBACK_BACKEND="" \
    "$ROOT/hooks/precompact-state-summary.sh" <<< "$input"
  assert_file "$TMPDIR/codex-compact-state/codex-state.md" "Codex state uses the Codex state directory"
  assert_not_file "$TMPDIR/claude-compact-state/codex-state.md" "Codex state does not use the Claude state directory"
  if [[ -f "$capture" ]]; then
    assert_contains "$(cat "$capture")" "Codex payload content" "Codex rollout payload reaches the state backend"
    assert_contains "$(cat "$capture")" "Skills and commands invoked this session:" "Codex state prompt includes skill observation status"
  else
    fail "Codex state backend input was captured"
  fi

  input=$(jq -nc --arg path "$rollout" '{
    session_id: "claude-state",
    transcript_path: $path,
    trigger: "manual",
    hook_event_name: "PreCompact"
  }')
  COMPACT_PLUS_RUNTIME=claude \
    COMPACT_PLUS_PRIMARY_BACKEND="bash \"$backend\"" \
    COMPACT_PLUS_FALLBACK_BACKEND="" \
    "$ROOT/hooks/precompact-state-summary.sh" <<< "$input"
  assert_file "$TMPDIR/claude-compact-state/claude-state.md" "Claude state path remains unchanged"

  input=$(jq -nc --arg path "$rollout" '{
    session_id: "codex-backup",
    transcript_path: $path,
    trigger: "manual",
    hook_event_name: "PreCompact"
  }')
  COMPACT_PLUS_RUNTIME=codex "$ROOT/hooks/precompact-transcript-backup.sh" <<< "$input"
  if ! find "$CODEX_HOME/backups/transcripts" -type f -name '*-codex-backup.jsonl' -print -quit 2>/dev/null | grep -q .; then
    fail "Codex transcript backup uses CODEX_HOME"
  fi
}

test_state_generation_fails_open() {
  local input rollout
  rollout="$TEST_ROOT/fail-open.jsonl"
  write_rollout "$rollout" "backend-failure" 500 1000

  input=$(jq -nc '{
    session_id: "missing-transcript",
    transcript_path: "/missing/compact-plus-transcript.jsonl",
    trigger: "auto",
    hook_event_name: "PreCompact"
  }')
  COMPACT_PLUS_RUNTIME=codex "$ROOT/hooks/precompact-state-summary.sh" <<< "$input"
  assert_not_file "$TMPDIR/codex-compact-state/missing-transcript.md" "Missing transcript fails open without state"

  input=$(jq -nc --arg path "$rollout" '{
    session_id: "backend-failure",
    transcript_path: $path,
    trigger: "auto",
    hook_event_name: "PreCompact"
  }')
  COMPACT_PLUS_RUNTIME=codex \
    COMPACT_PLUS_PRIMARY_BACKEND="" \
    COMPACT_PLUS_FALLBACK_BACKEND="" \
    "$ROOT/hooks/precompact-state-summary.sh" <<< "$input"
  assert_not_file "$TMPDIR/codex-compact-state/backend-failure.md" "Backend failure fails open without partial state"
}

test_claude_recovery_is_sessionstart_one_shot() {
  local input output
  mkdir -p "$TMPDIR/claude-compact-state"
  printf '# Compact Prep State\n## Recovery Notes\nClaude recovery\n' \
    > "$TMPDIR/claude-compact-state/claude-recovery.md"

  input='{"session_id":"claude-recovery","hook_event_name":"PostCompact","trigger":"manual"}'
  COMPACT_PLUS_RUNTIME=claude "$ROOT/hooks/compaction-recovery.sh" <<< "$input"
  assert_file "$TMPDIR/claude-compacted/claude-recovery" "Claude PostCompact writes a recovery marker"

  input='{"session_id":"claude-recovery","hook_event_name":"SessionStart","source":"compact"}'
  output=$(COMPACT_PLUS_RUNTIME=claude "$ROOT/hooks/sessionstart-compaction-recovery.sh" <<< "$input")
  assert_contains "$output" '"hookEventName": "SessionStart"' "Claude recovery uses SessionStart additionalContext"
  assert_contains "$output" "Claude recovery" "Claude recovery injects the saved state content"
  assert_not_file "$TMPDIR/claude-compacted/claude-recovery" "Claude recovery consumes the marker"

  output=$(COMPACT_PLUS_RUNTIME=claude "$ROOT/hooks/sessionstart-compaction-recovery.sh" <<< "$input")
  assert_empty "$output" "Claude recovery is one-shot"
}

test_codex_recovery_is_one_shot() {
  local input output
  mkdir -p "$TMPDIR/codex-compact-state"
  printf '# Compact Prep State\n## Recovery Notes\nSynthetic recovery\n' \
    > "$TMPDIR/codex-compact-state/codex-recovery.md"

  input='{"session_id":"codex-recovery","hook_event_name":"PostCompact","trigger":"manual"}'
  COMPACT_PLUS_RUNTIME=codex "$ROOT/hooks/compaction-recovery.sh" <<< "$input"
  assert_file "$TMPDIR/codex-compacted/codex-recovery" "Codex PostCompact writes a Codex marker"
  assert_not_file "$TMPDIR/claude-compacted/codex-recovery" "Codex PostCompact does not write a Claude marker"

  input='{"session_id":"codex-recovery","hook_event_name":"SessionStart","source":"compact"}'
  output=$(COMPACT_PLUS_RUNTIME=codex "$ROOT/hooks/sessionstart-compaction-recovery.sh" <<< "$input")
  assert_contains "$output" '"hookEventName": "SessionStart"' "Codex recovery uses SessionStart additionalContext"
  assert_contains "$output" "Synthetic recovery" "Codex recovery injects the saved state content"
  assert_not_file "$TMPDIR/codex-compacted/codex-recovery" "Codex recovery consumes the marker"

  output=$(COMPACT_PLUS_RUNTIME=codex "$ROOT/hooks/sessionstart-compaction-recovery.sh" <<< "$input")
  assert_empty "$output" "Codex recovery is one-shot"
}

test_codex_subagent_keys_on_agent_id() {
  local input output backend rollout
  backend="$TEST_ROOT/subagent-backend.sh"
  rollout="$TEST_ROOT/subagent.jsonl"
  make_state_backend "$backend"
  write_rollout "$rollout" "child-thread" 500 1000

  # Codex passes session_id = root thread id and agent_id = this subagent's own
  # thread id. Artifacts must be keyed on the subagent, otherwise the child has no
  # state of its own and the parent's state file is overwritten.
  input=$(jq -nc --arg path "$rollout" '{
    session_id: "root-thread",
    agent_id: "child-thread",
    agent_type: "coder",
    transcript_path: $path,
    trigger: "auto",
    hook_event_name: "PreCompact"
  }')

  COMPACT_PLUS_RUNTIME=codex \
    COMPACT_PLUS_PRIMARY_BACKEND="bash \"$backend\"" \
    COMPACT_PLUS_FALLBACK_BACKEND="" \
    "$ROOT/hooks/precompact-state-summary.sh" <<< "$input"
  assert_file "$TMPDIR/codex-compact-state/child-thread.md" "Subagent state uses the subagent thread id"
  assert_not_file "$TMPDIR/codex-compact-state/root-thread.md" "Subagent state does not overwrite the root thread state"

  COMPACT_PLUS_RUNTIME=codex "$ROOT/hooks/precompact-transcript-backup.sh" <<< "$input"
  if ! find "$CODEX_HOME/backups/transcripts" -type f -name '*-child-thread.jsonl' -print -quit 2>/dev/null | grep -q .; then
    fail "Subagent transcript backup is named after the subagent thread"
  fi
  if find "$CODEX_HOME/backups/transcripts" -type f -name '*-root-thread.jsonl' -print -quit 2>/dev/null | grep -q .; then
    fail "Subagent transcript backup is not named after the root thread"
  fi

  input=$(jq -nc '{
    session_id: "root-thread",
    agent_id: "child-thread",
    agent_type: "coder",
    hook_event_name: "PostCompact",
    trigger: "auto"
  }')
  COMPACT_PLUS_RUNTIME=codex "$ROOT/hooks/compaction-recovery.sh" <<< "$input"
  assert_file "$TMPDIR/codex-compacted/child-thread" "Subagent PostCompact marker uses the subagent thread id"
  assert_not_file "$TMPDIR/codex-compacted/root-thread" "Subagent PostCompact marker does not claim the root thread"

  # Codex dispatches no start hook to a subagent after compaction, so recovery has
  # to arrive on the next prompt.
  input=$(jq -nc '{
    session_id: "root-thread",
    agent_id: "child-thread",
    agent_type: "coder",
    hook_event_name: "UserPromptSubmit"
  }')
  output=$(COMPACT_PLUS_RUNTIME=codex "$ROOT/hooks/userpromptsubmit-compaction-recovery.sh" <<< "$input")
  assert_contains "$output" '"hookEventName": "UserPromptSubmit"' "Subagent recovery arrives through UserPromptSubmit"
  assert_contains "$output" "$TMPDIR/codex-compact-state/child-thread.md" "Subagent recovery references the subagent state file"
  assert_not_file "$TMPDIR/codex-compacted/child-thread" "Subagent recovery consumes the marker"

  output=$(COMPACT_PLUS_RUNTIME=codex "$ROOT/hooks/userpromptsubmit-compaction-recovery.sh" <<< "$input")
  assert_empty "$output" "Subagent recovery is one-shot"
}

test_codex_root_thread_recovers_once() {
  local input session_input output
  mkdir -p "$TMPDIR/codex-compact-state"
  printf '# Compact Prep State\n## Recovery Notes\nRoot thread recovery\n' \
    > "$TMPDIR/codex-compact-state/root-once.md"

  input='{"session_id":"root-once","hook_event_name":"PostCompact","trigger":"auto"}'
  COMPACT_PLUS_RUNTIME=codex "$ROOT/hooks/compaction-recovery.sh" <<< "$input"

  session_input='{"session_id":"root-once","hook_event_name":"SessionStart","source":"compact"}'
  output=$(COMPACT_PLUS_RUNTIME=codex "$ROOT/hooks/sessionstart-compaction-recovery.sh" <<< "$session_input")
  assert_contains "$output" '"hookEventName": "SessionStart"' "Root thread still recovers at SessionStart"

  # Enabling the Codex UserPromptSubmit channel must not inject a second time.
  input='{"session_id":"root-once","hook_event_name":"UserPromptSubmit"}'
  output=$(COMPACT_PLUS_RUNTIME=codex "$ROOT/hooks/userpromptsubmit-compaction-recovery.sh" <<< "$input")
  assert_empty "$output" "Root thread does not recover twice through UserPromptSubmit"
}

test_codex_manifest
test_session_id_priority
test_runtime_auto_detection
test_claude_warning_threshold_is_independent
test_codex_warning_threshold
test_runtime_path_separation
test_state_generation_fails_open
test_claude_recovery_is_sessionstart_one_shot
test_codex_recovery_is_one_shot
test_codex_subagent_keys_on_agent_id
test_codex_root_thread_recovers_once

if [[ "$FAILURES" -ne 0 ]]; then
  printf '%s test assertion(s) failed\n' "$FAILURES" >&2
  exit 1
fi

printf 'All compact-plus runtime tests passed\n'
