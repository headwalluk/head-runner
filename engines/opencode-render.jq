# Renders OpenCode "run --format json" lines as a readable transcript (used with jq -R -r -j).
def short: tostring | gsub("[\r\n]+"; " ") | if length > 160 then .[0:157] + "..." else . end;
def tool_summary:
  (.state.input // .input // {}) as $tool_input
  | ($tool_input.command // $tool_input.filePath // $tool_input.file_path // $tool_input.path
     // $tool_input.pattern // $tool_input.url // $tool_input.query // $tool_input.description
     // ($tool_input | tostring))
  | short;

. as $raw_line
| (try fromjson catch null) as $event
| if ($event | type) != "object" then $raw_line + "\n"
  elif $event.type == "text" then "\n" + ($event.part.text // "") + "\n"
  elif ($event.type == "tool_use" or $event.type == "tool") then
    ($event.part // {}) as $tool_part
    | if ($tool_part.state.status? // "") == "error" then
        "→ \($tool_part.tool // "tool"): \($tool_part | tool_summary)\n  ✗ \(($tool_part.state.error // "error") | short)\n"
      else "→ \($tool_part.tool // "tool"): \($tool_part | tool_summary)\n" end
  elif $event.type == "error" then "✗ error: \(($event.error // $event.part // $event) | short)\n"
  elif $event.type == "step_start" or $event.type == "step_finish" then empty
  else "· \($event.type)\n" end
