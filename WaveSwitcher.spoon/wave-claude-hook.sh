#!/bin/zsh
# WaveSwitcher <-> Claude Code integration hook.
#
# Invoked by Claude Code with the event name as the first argument. It:
#   * sets the Wave tab's status flag, which WaveSwitcher shows as a status dot
#     (green = idle, blue = running, purple = subagents, gold = needs input),
#   * records / clears this session's id on the terminal block so WaveSwitcher's
#     shell snippet can auto-resume it after a Wave Terminal restart, and
#   * posts a clickable "needs input" notification (via wave-notify.sh).
#
# Depends only on Wave's `wsh` (no jq). Reads the hook JSON payload on stdin.

event="$1"
payload="$(cat 2>/dev/null)"
here="${0:A:h}"   # directory of this script

# Extract a top-level JSON string field without jq.
field() {
  printf '%s' "$payload" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
}

GREEN="#58c142"   # idle / done
BLUE="#4a9eff"    # running
PURPLE="#a970ff"  # subagents (subagent-driven work)
GOLD="#e0b956"    # needs your input

case "$event" in
  SessionStart)
    wsh setmeta -b tab "tab:flagcolor=$GREEN" >/dev/null 2>&1
    sid="$(field session_id)"
    [ -n "$sid" ] && wsh setmeta -b this "claude:resume=$sid" >/dev/null 2>&1
    ;;
  UserPromptSubmit) wsh setmeta -b tab "tab:flagcolor=$BLUE"   >/dev/null 2>&1 ;;
  # After each (main-session) tool finishes, Claude is working again. This also
  # clears a stale "needs input"/"subagents" flag once the Agent tool returns.
  PostTool)         wsh setmeta -b tab "tab:flagcolor=$BLUE"   >/dev/null 2>&1 ;;
  Subagents)        wsh setmeta -b tab "tab:flagcolor=$PURPLE" >/dev/null 2>&1 ;;
  Stop)             wsh setmeta -b tab "tab:flagcolor=$GREEN"  >/dev/null 2>&1 ;;
  NeedsInput)
    wsh setmeta -b tab "tab:flagcolor=$GOLD" >/dev/null 2>&1
    "$here/wave-notify.sh" input >/dev/null 2>&1
    ;;
  Question)
    wsh setmeta -b tab "tab:flagcolor=$GOLD" >/dev/null 2>&1
    "$here/wave-notify.sh" question >/dev/null 2>&1
    ;;
  SessionEnd)       wsh setmeta -b this "claude:resume=" >/dev/null 2>&1 ;;
esac
exit 0
