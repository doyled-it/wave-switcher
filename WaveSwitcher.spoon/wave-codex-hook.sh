#!/bin/zsh
# Translate Codex lifecycle events into WaveSwitcher's shared status handler.
# User hooks also run outside Wave; those sessions must have no Wave side effects.
[[ -n "$WAVETERM_TABID" && -n "$WAVETERM_BLOCKID" ]] || exit 0
here="${0:A:h}"
normalized="$(python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    sid = d.get("session_id")
    if not isinstance(sid, str) or not sid or any(c in sid for c in "\r\n"):
        sys.exit(0)
    event = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] else d.get("hook_event_name")
    mapping = {"SessionStart": "SessionStart", "SessionEnd": "SessionEnd",
        "UserPromptSubmit": "UserPromptSubmit", "PostToolUse": "PostTool",
        "PermissionRequest": "NeedsInput", "Stop": "Stop", "Interrupt": "Stop",
        "SubagentStart": "SubStart", "SubagentStop": "SubStop",
        "PreCompact": "PreCompact", "PostCompact": "PostCompact"}
    if event == "PreToolUse":
        tool = d.get("tool_name", "").rsplit(".", 1)[-1]
        mapped = "Question" if tool in ("request_user_input", "AskUserQuestion") else "PostTool"
    elif event == "SessionStart" and d.get("source") == "compact":
        mapped = "PostCompact"  # compaction is not a fresh session: retain live agents
    else:
        mapped = mapping.get(event)
    if not mapped:
        sys.exit(0)
    print(mapped)
    # Forward only the fields the shared handler consumes. This also prevents a
    # nested tool argument from masquerading as a top-level session/agent id.
    print(json.dumps({k: d[k] for k in ("session_id", "agent_id", "tool_name", "background_tasks") if k in d}))
except (ValueError, TypeError, AttributeError):
    pass
' "${1:-}")" 2>/dev/null
[[ "$normalized" == *$'\n'* ]] || exit 0
event="${normalized%%$'\n'*}"
payload="${normalized#*$'\n'}"
# The shared handler locks and checks ownership for both providers, so changing
# from Codex to Claude participates in the same protocol.
printf '%s' "$payload" | WSW_AGENT=codex /bin/zsh "$here/wave-claude-hook.sh" "$event"
exit 0
