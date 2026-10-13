# Renders Gemini CLI stream-json lines as a readable transcript (used with jq -R -r -j).
def short: tostring | gsub("[\r\n]+"; " ") | if length > 160 then .[0:157] + "..." else . end;
def tool_summary:
  (.parameters // {}) as $tool_input
  | ($tool_input.command // $tool_input.file_path // $tool_input.absolute_path // $tool_input.path
     // $tool_input.pattern // $tool_input.url // $tool_input.query // $tool_input.description
     // ($tool_input | tostring))
  | short;

. as $raw_line
| (try fromjson catch null) as $event
| if ($event | type) != "object" then $raw_line + "\n"
  elif $event.type == "init" then
    "── gemini session \($event.session_id // "?") · model \($event.model // "?")\n"
  elif $event.type == "message" and $event.role == "assistant" then
    if $event.delta == true then $event.content // "" else "\n" + ($event.content // "") + "\n" end
  elif $event.type == "tool_use" then
    "\n→ \($event.tool_name // "?"): \($event | tool_summary)\n"
  elif $event.type == "tool_result" and $event.status == "error" then
    "  ✗ \($event.error.message // $event.output // "error" | short)\n"
  elif $event.type == "error" then
    "! \($event.severity // "error"): \($event.message // "" | short)\n"
  elif $event.type == "result" then
    "\n── result: \($event.status // "?") · tokens in \($event.stats.input_tokens // "?") out \($event.stats.output_tokens // "?") · \((($event.stats.duration_ms // 0) / 1000) | floor)s"
    + (if $event.error then " · \($event.error.message // "" | short)" else "" end) + "\n"
  else empty end
