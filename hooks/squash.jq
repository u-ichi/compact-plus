# Transcript squashing for precompact-state-summary.sh.
#
# Read with -s (slurp): the input is the whole slice as an array, not one line
# at a time. That is required, not an optimisation.
#
# On a Claude Code transcript a tool_result line carries no tool name:
#
#     message.content[0] keys : content, tool_use_id, type
#
# The name lives on the preceding assistant line, inside tool_use.name, and the
# two are joined by tool_use_id. A reader that only sees the current line cannot
# resolve it, so every tool_result looks like an unnamed line and none of the
# Read / Bash / Grep / Glob branches can be taken. Slurping lets us build the
# tool_use_id -> name map before squashing.
#
# A pair split across the slice boundary stays unresolved and is emitted
# untouched. A boundary miss degrades to "not squashed", never to wrong output.
#
# Squashing stays per line and order preserving, so selecting the head/tail
# lines before squashing still yields the same lines; only the set of resolvable
# names shrinks with the slice.
#
# Do NOT switch this to --raw-input + fromjson: jq 1.7.1's raw-input reader
# splits multibyte characters that straddle its 4096-byte buffer, turning e.g.
# 理 into three U+FFFD. The JSON parser has no such bug.
#
# Invoked as: jq -c -r -s -f squash.jq --arg squash_enabled .. --arg read_lines ..
#                                      --arg bash_chars .. FILE
# -c -r means a squashed line prints as a bare string and every other line
# prints as compact JSON, matching what the per-line implementation emitted.

def linecount:
  if . == "" then 0
  else
    ((. / "\n") | length) as $n
    | if endswith("\n") then $n - 1 else $n end
  end;

def text_value:
  if type == "string" then .
  elif type == "array" then
    ([.[]? | if type == "string" then .
             elif type == "object" then (.text? // .content? // "")
             else "" end] | join("\n"))
  elif type == "object" then (.text? // .content? // "")
  else "" end;

# $names maps tool_use_id to the tool name, built from the whole slice below.
def tool_name($names):
  . as $j
  | [ (try $j.tool_name catch null),
      (try $j.name catch null),
      (try $j.payload.name catch null),
      (try ($j.message.content[]? | objects | select(.type? == "tool_use") | .name?) catch null),
      (try ($j.message.content[]? | objects | select(.type? == "tool_result") | .name?) catch null),
      (try ($j.message.content[]? | objects
            | select(.type? == "tool_result")
            | $names[.tool_use_id? // ""]) catch null)
    ] | map(select(type == "string" and . != "")) | first // "";

def text_body:
  . as $j
  | [ (try ($j.content | text_value) catch ""),
      (try ($j.message.content | text_value) catch ""),
      (try ($j.result | text_value) catch ""),
      (try ($j.output | text_value) catch ""),
      (try ($j.tool_result | text_value) catch ""),
      (try ($j.payload.content | text_value) catch ""),
      (try ($j.payload.message.content | text_value) catch ""),
      (try ($j.payload.output | text_value) catch ""),
      (try ($j.payload.text | text_value) catch "")
    ] | map(select(type == "string" and . != "")) | first // "";

def payload_type:
  . as $j
  | [ (try $j.payload.type catch null), (try $j.type catch null) ]
  | map(select(type == "string" and . != "")) | first // "";

def refs:
  [ .. | strings | select(test("(/[^[:space:]\"']+|https?://[^[:space:]\"']+)")) ]
  | join("\n") | split("\n") | .[0:5] | join(" ")
  | if . == "" then "unknown path" else . end;

($read_lines | tonumber? // 100) as $max_lines
| ($bash_chars | tonumber? // 500) as $max_chars
| . as $lines
| ( [ $lines[]
      | (try (.message.content[]? | objects | select(.type? == "tool_use")) catch empty)
      | select((.id? | type) == "string" and (.name? | type) == "string")
      | {key: .id, value: .name} ]
    | from_entries ) as $names
| $lines[]
| . as $j
| ($j | tool_name($names)) as $tool
| ($j | text_body) as $text
| ($j | payload_type) as $ptype
| ($text | linecount) as $line_count
| ($text | length) as $char_count
| if $squash_enabled != "1" then $j
  elif $ptype == "function_call_output" and $char_count > $max_chars then
    "[ToolResult: \($char_count) chars output; refs: \($j | refs)]"
  elif $tool == "Read" and $line_count > $max_lines then
    "[Read: \($line_count) lines from \($j | refs)]"
  elif $tool == "Bash" and $char_count > $max_chars then
    ($j.exit_code? // $j.status? // (try $j.metadata.exit_code catch null) // "unknown") as $code
    | "[Bash: exit \($code), \($char_count) chars output; refs: \($j | refs)]"
  elif ($tool == "Grep" or $tool == "Glob") and $line_count > $max_lines then
    "[\($tool): \($line_count) matches; refs: \($j | refs)]"
  else $j
  end
