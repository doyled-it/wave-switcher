#!/bin/zsh
# Post a "needs input" notification for the current Wave tab. Routes through
# WaveSwitcher (Hammerspoon) so the notification names the workspace/tab and
# jumps to that tab when clicked. Falls back to `wsh notify` if the `hs` CLI
# isn't available.
#
# Usage: wave-notify.sh [input|question] [claude|codex]
kind="${1:-input}"
agent="${2:-claude}"
[[ "$agent" == codex ]] && label="Codex" || { agent=claude; label="Claude"; }
ws="$WAVETERM_WORKSPACEID"
tab="$WAVETERM_TABID"

if command -v hs >/dev/null 2>&1 && [ -n "$ws" ] && [ -n "$tab" ]; then
  # Bound IPC: a stuck hs client must never hold up an approval prompt.
  perl -e 'alarm 2; exec @ARGV' hs -c "if spoon and spoon.WaveSwitcher then spoon.WaveSwitcher:notify('$ws','$tab','$kind','$agent') end" >/dev/null 2>&1 && exit 0
fi

# Fallback: plain notification.
[ "$kind" = "question" ] && msg="$label has a question" || msg="$label needs your input"
[[ "$agent" == claude ]] && label="Claude Code"
wsh notify "$msg" -t "$label" >/dev/null 2>&1
exit 0
