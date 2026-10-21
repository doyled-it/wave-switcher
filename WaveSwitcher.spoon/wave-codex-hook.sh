#!/bin/zsh
# Translate Codex lifecycle events into WaveSwitcher's shared status handler.
# User hooks also run outside Wave; those sessions must have no Wave side effects.
[[ -n "$WAVETERM_TABID" && -n "$WAVETERM_BLOCKID" ]] || exit 0
here="${0:A:h}"
# Serialize the ownership check with SessionStart/End and status writes. Codex
# can deliver an older thread's hooks after a new thread starts in this block.
# Keep the lock file: unlinking it would let concurrent hooks lock two inodes.
zmodload zsh/system 2>/dev/null || exit 0
lockfile="${TMPDIR:-/tmp}/wsw-codex-${WAVETERM_BLOCKID}.lock"
: >> "$lockfile" 2>/dev/null || exit 0
zsystem flock -t 2 -f lockfd "$lockfile" 2>/dev/null || exit 0
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
    print(sid)
    # Forward only the fields the shared handler consumes. This also prevents a
    # nested tool argument from masquerading as a top-level session/agent id.
    print(json.dumps({k: d[k] for k in ("session_id", "agent_id", "tool_name", "background_tasks") if k in d}))
except (ValueError, TypeError, AttributeError):
    pass
' "${1:-}")" 2>/dev/null
[[ "$normalized" == *$'\n'* ]] || exit 0
event="${normalized%%$'\n'*}"
rest="${normalized#*$'\n'}"
sid="${rest%%$'\n'*}"
payload="${rest#*$'\n'}"
if [[ "$event" != SessionStart ]]; then
  current_sid="$(wsh getmeta -b this --raw 'codex:resume' 2>/dev/null)" || exit 0
  [[ "$current_sid" == "$sid" ]] || exit 0
fi
printf '%s' "$payload" | WSW_AGENT=codex /bin/zsh "$here/wave-claude-hook.sh" "$event"
exit 0
