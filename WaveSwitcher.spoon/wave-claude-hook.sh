#!/bin/zsh
# WaveSwitcher <-> Claude Code integration hook (single entry point).
#
# Invoked by Claude Code with the event name as the first argument. Keeps the
# Wave tab's status flag in sync (green idle / blue running / purple subagents /
# gold needs-input), records the session id for restart resume, and posts a
# clickable notification when input is needed.
#
# "Subagents" is driven by a per-tab counter: +1 when an Agent/Task subagent is
# dispatched (PreToolUse), -1 on SubagentStop. While the count is > 0 the tab is
# purple -- which keeps it purple even after the main turn's Stop fires, because
# detached/background subagents outlive the turn and only fire SubagentStop when
# they actually finish. New prompts / session start reset the count.
#
# Depends only on Wave's `wsh`. Reads the hook JSON payload on stdin.

event="$1"
payload="$(cat 2>/dev/null)"
here="${0:A:h}"

field() {
  printf '%s' "$payload" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
}

GREEN="#58c142"   # idle / done
BLUE="#4a9eff"    # running
PURPLE="#a970ff"  # subagents active
GOLD="#e0b956"    # needs your input

flag() { wsh setmeta -b tab "tab:flagcolor=$1" >/dev/null 2>&1; }

CNT="${TMPDIR:-/tmp}/wsw-subs-${WAVETERM_TABID:-unknown}"  # active-subagent count
getn() { local n; n="$(cat "$CNT" 2>/dev/null)"; case "$n" in ''|*[!0-9]*) echo 0;; *) echo "$n";; esac; }
setn() { printf '%s' "$1" > "$CNT" 2>/dev/null; }

case "$event" in
  SessionStart)
    setn 0; flag "$GREEN"
    sid="$(field session_id)"
    [ -n "$sid" ] && wsh setmeta -b this "claude:resume=$sid" >/dev/null 2>&1
    ;;
  SessionEnd)       wsh setmeta -b this "claude:resume=" >/dev/null 2>&1 ;;
  UserPromptSubmit) setn 0; flag "$BLUE" ;;
  Subagents)        n=$(getn); setn $((n+1)); flag "$PURPLE" ;;              # Agent/Task dispatched
  SubStop)          n=$(getn); n=$((n>0?n-1:0)); setn "$n"
                    [ "$n" -gt 0 ] && flag "$PURPLE" || flag "$GREEN" ;;      # a subagent finished
  Stop)             n=$(getn); [ "$n" -gt 0 ] && flag "$PURPLE" || flag "$GREEN" ;;
  PostTool)         n=$(getn); [ "$n" -gt 0 ] && flag "$PURPLE" || flag "$BLUE" ;;
  NeedsInput)       flag "$GOLD"; "$here/wave-notify.sh" input    >/dev/null 2>&1 ;;
  Question)         flag "$GOLD"; "$here/wave-notify.sh" question >/dev/null 2>&1 ;;
esac
exit 0
