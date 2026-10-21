# WaveSwitcher Codex resume: sourced from .zshrc; only interactive Wave shells.
if [[ -o interactive && -n "$WAVETERM_BLOCKID" && -z "$WAVESWITCHER_CODEX_RESUMED" ]]; then
  __wsw_codex_wsh="$HOME/Library/Application Support/waveterm/bin/wsh"
  if [[ -x "$__wsw_codex_wsh" ]] && command -v codex >/dev/null 2>&1; then
    __wsw_codex_sid="$("$__wsw_codex_wsh" getmeta -b this --raw 'codex:resume' 2>/dev/null)"
    if [[ -n "$__wsw_codex_sid" && "$__wsw_codex_sid" != null ]]; then
      "$__wsw_codex_wsh" setmeta -b this 'codex:resume=' >/dev/null 2>&1
      export WAVESWITCHER_CODEX_RESUMED=1
      print -r -- "Resuming Codex session ($__wsw_codex_sid)..."
      codex resume "$__wsw_codex_sid"
    fi
  fi
  unset __wsw_codex_wsh __wsw_codex_sid
fi
