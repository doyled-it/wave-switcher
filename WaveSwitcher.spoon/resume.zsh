# WaveSwitcher resume — auto-resume the Claude Code session that was running in
# this Wave Terminal tab if Wave restarted. The Claude Code SessionStart hook
# records the session id on the block; SessionEnd clears it on a clean exit, so
# this only fires after an unexpected restart. Interactive shells only; it
# consumes the marker so it can't loop, and never runs inside Claude's own
# (non-interactive) tool shells or in bare-terminal tabs.
if [[ -o interactive && -n "$WAVETERM_BLOCKID" && -z "$CLAUDE_RESUMED" ]]; then
  __wsw_wsh="$HOME/Library/Application Support/waveterm/bin/wsh"
  if [[ -x "$__wsw_wsh" ]] && command -v claude >/dev/null 2>&1; then
    __wsw_sid="$("$__wsw_wsh" getmeta -b this --raw "claude:resume" 2>/dev/null)"
    if [[ -n "$__wsw_sid" && "$__wsw_sid" != "null" ]]; then
      "$__wsw_wsh" setmeta -b this "claude:resume=" >/dev/null 2>&1
      export CLAUDE_RESUMED=1
      echo "Resuming Claude session ($__wsw_sid)..."
      claude --resume "$__wsw_sid"
    fi
  fi
  unset __wsw_wsh __wsw_sid
fi
