#!/bin/zsh
# WaveSwitcher <-> Claude Code integration hook (single entry point).
#
# Invoked by Claude Code with the event name as the first argument. It keeps the
# Wave tab's status flag in sync (green idle / blue running / purple subagents /
# gold needs-input), records the session id for restart resume, and posts a
# clickable notification when input is needed.
#
# "Subagents" is sticky for the turn: once an Agent/Task subagent is dispatched,
# the tab stays purple through the orchestration between subagents until the turn
# ends (Stop) or a new prompt arrives. We track that with a per-tab marker file
# so the frequent PostTool check is just a file test (no extra `wsh` calls).
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
PURPLE="#a970ff"  # subagents (subagent-driven work this turn)
GOLD="#e0b956"    # needs your input

flag() { wsh setmeta -b tab "tab:flagcolor=$1" >/dev/null 2>&1; }

SDD="${TMPDIR:-/tmp}/wsw-sdd-${WAVETERM_TABID:-unknown}"  # present = subagents active this turn

case "$event" in
  SessionStart)
    rm -f "$SDD"
    flag "$GREEN"
    sid="$(field session_id)"
    [ -n "$sid" ] && wsh setmeta -b this "claude:resume=$sid" >/dev/null 2>&1
    ;;
  UserPromptSubmit) rm -f "$SDD"; flag "$BLUE" ;;
  Stop)             rm -f "$SDD"; flag "$GREEN" ;;
  Subagents)        : > "$SDD"; flag "$PURPLE" ;;         # Agent/Task dispatched
  PostTool)         [ -e "$SDD" ] && flag "$PURPLE" || flag "$BLUE" ;;
  NeedsInput)       flag "$GOLD"; "$here/wave-notify.sh" input    >/dev/null 2>&1 ;;
  Question)         flag "$GOLD"; "$here/wave-notify.sh" question >/dev/null 2>&1 ;;
  SessionEnd)       wsh setmeta -b this "claude:resume=" >/dev/null 2>&1 ;;
esac
exit 0
