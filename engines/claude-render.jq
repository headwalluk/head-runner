# Renders Claude Code stream-json lines as a readable transcript (used with jq -R -r -j).
def short: tostring | gsub("[\r\n]+"; " ") | if length > 160 then .[0:157] + "..." else . end;
def tool_summary:
  (.input // {}) as $tool_input
  | ($tool_input.command // $tool_input.file_path // $tool_input.path // $tool_input.pattern
     // $tool_input.url // $tool_input.query // $tool_input.description // ($tool_input | tostring))
  | short;
def result_text:
  if type == "array" then map(.text? // "") | join(" ") else tostring end;

. as $raw_line
| (try fromjson catch null) as $event
| if ($event | type) != "object" then $raw_line + "\n"
  elif $event.type == "system" and $event.subtype == "init" then
    "── claude session \($event.session_id // "?") · model \($event.model // "?")\n"
  elif $event.type == "assistant" then
    ($event.message.content // [])[]
    | if .type == "text" then "\n" + .text + "\n"
      elif .type == "tool_use" then "→ \(.name): \(tool_summary)\n"
      else empty end
  elif $event.type == "user" then
    ($event.message.content // [])
    | if type == "array" then
        .[] | select(.type? == "tool_result" and .is_error? == true)
        | "  ✗ \(.content | result_text | short)\n"
      else empty end
  elif $event.type == "result" then
    "── result: \($event.subtype // "?") · turns \($event.num_turns // "?") · cost $\($event.total_cost_usd // "?") · \((($event.duration_ms // 0) / 1000) | floor)s\n"
  else empty end
