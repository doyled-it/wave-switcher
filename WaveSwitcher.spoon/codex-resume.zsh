# WaveSwitcher Codex resume: sourced from .zshrc; only interactive Wave shells.
if [[ -o interactive && -n "$WAVETERM_BLOCKID" && -z "$WAVESWITCHER_CODEX_RESUMED" ]]; then
  __wsw_codex_wsh="$HOME/Library/Application Support/waveterm/bin/wsh"
  if [[ -x "$__wsw_codex_wsh" ]] && command -v codex >/dev/null 2>&1; then
    __wsw_codex_sid=""
    __wsw_codex_lock="${TMPDIR:-/tmp}/wsw-codex-${WAVETERM_BLOCKID}.lock"
    if zmodload zsh/system 2>/dev/null &&
       { : >> "$__wsw_codex_lock"; } 2>/dev/null &&
       zsystem flock -t 2 -f __wsw_codex_lockfd "$__wsw_codex_lock" 2>/dev/null; then
      __wsw_codex_sid="$("$__wsw_codex_wsh" getmeta -b this --raw 'codex:resume' 2>/dev/null)"
      if [[ -n "$__wsw_codex_sid" && "$__wsw_codex_sid" != null ]]; then
        __wsw_codex_home="$("$__wsw_codex_wsh" getmeta -b this --raw 'codex:home' 2>/dev/null)"
        "$__wsw_codex_wsh" setmeta -b this 'codex:resume=' 'codex:home=' >/dev/null 2>&1
      fi
      # Release before launching Codex, whose SessionStart needs this same lock.
      zsystem flock -u "$__wsw_codex_lockfd" 2>/dev/null
    fi
    if [[ -n "$__wsw_codex_sid" && "$__wsw_codex_sid" != null ]]; then
      export WAVESWITCHER_CODEX_RESUMED=1
      print -r -- "Resuming Codex session ($__wsw_codex_sid)..."
      if [[ -n "$__wsw_codex_home" && "$__wsw_codex_home" != null ]]; then
        CODEX_HOME="$__wsw_codex_home" codex resume "$__wsw_codex_sid"
      else
        codex resume "$__wsw_codex_sid"
      fi
    fi
  fi
  unset __wsw_codex_wsh __wsw_codex_sid __wsw_codex_home __wsw_codex_lock __wsw_codex_lockfd
fi
