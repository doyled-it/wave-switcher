#!/bin/zsh
# Post a "needs input" notification for the current Wave tab. Routes through
# WaveSwitcher (Hammerspoon) so the notification names the workspace/tab and
# jumps to that tab when clicked. Falls back to `wsh notify` if the `hs` CLI
# isn't available.
#
# Usage: wave-notify.sh [input|question]
kind="${1:-input}"
ws="$WAVETERM_WORKSPACEID"
tab="$WAVETERM_TABID"

if command -v hs >/dev/null 2>&1 && [ -n "$ws" ] && [ -n "$tab" ]; then
  hs -c "if spoon and spoon.WaveSwitcher then spoon.WaveSwitcher:notify('$ws','$tab','$kind') end" >/dev/null 2>&1 && exit 0
fi

# Fallback: plain notification.
[ "$kind" = "question" ] && msg="Claude has a question" || msg="Claude needs your input"
wsh notify "$msg" -t "Claude Code" >/dev/null 2>&1
exit 0
