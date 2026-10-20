#!/bin/sh
# WaveSwitcher installer.
#
# One-line install:
#   curl -fsSL https://raw.githubusercontent.com/doyled-it/wave-switcher/main/install.sh | sh
# Or from a local clone:
#   ./install.sh
#
# Installs the Hammerspoon Spoon and (for Claude Code users) wires up the
# status-flag + session-resume integration. Flags:
#   --no-claude   skip the Claude Code integration (just install the switcher)
# Override the download source with WAVESWITCHER_RAW.
set -e

RAW="${WAVESWITCHER_RAW:-https://raw.githubusercontent.com/doyled-it/wave-switcher/main}"
DEST="$HOME/.hammerspoon/Spoons/WaveSwitcher.spoon"
INIT="$HOME/.hammerspoon/init.lua"
ZSHRC="$HOME/.zshrc"
WITH_CLAUDE=1
[ "$1" = "--no-claude" ] && WITH_CLAUDE=0

# --- checks ---------------------------------------------------------------
[ "$(uname)" = "Darwin" ] || { echo "WaveSwitcher requires macOS."; exit 1; }
[ -x /usr/bin/sqlite3 ]   || { echo "sqlite3 not found (unexpected on macOS)."; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl is required."; exit 1; }

if [ ! -d "/Applications/Hammerspoon.app" ]; then
  echo "!! Hammerspoon is not installed. Install it first:"
  echo "     brew install --cask hammerspoon"
  echo "   (or https://www.hammerspoon.org), then re-run this."
  exit 1
fi
[ -d "$HOME/Library/Application Support/waveterm" ] || \
  echo "!! Wave Terminal data not found (install https://waveterm.dev and run it once). Continuing."

# --- locate source: local clone if present, else download -----------------
LOCAL=""
for d in "$(dirname "$0" 2>/dev/null)" "$PWD"; do
  if [ -n "$d" ] && [ -f "$d/WaveSwitcher.spoon/init.lua" ]; then LOCAL="$d/WaveSwitcher.spoon"; break; fi
done

fetch() { # fetch <relpath> <dest>
  if [ -n "$LOCAL" ]; then cp "$LOCAL/$1" "$2"; else curl -fsSL "$RAW/WaveSwitcher.spoon/$1" -o "$2"; fi
}

mkdir -p "$DEST"
[ -n "$LOCAL" ] && echo "Installing from local clone: $LOCAL" || echo "Downloading WaveSwitcher from $RAW"
fetch init.lua            "$DEST/init.lua"
fetch wave-sessions.sh    "$DEST/wave-sessions.sh"
fetch wave-claude-hook.sh "$DEST/wave-claude-hook.sh"
fetch wave-notify.sh      "$DEST/wave-notify.sh"
fetch wave-usage.sh       "$DEST/wave-usage.sh"
fetch wave-gitinfo.sh     "$DEST/wave-gitinfo.sh"
fetch wave-termthemes.json "$DEST/wave-termthemes.json"
fetch resume.zsh          "$DEST/resume.zsh"
chmod +x "$DEST/wave-sessions.sh" "$DEST/wave-claude-hook.sh" "$DEST/wave-notify.sh" "$DEST/wave-usage.sh" "$DEST/wave-gitinfo.sh"
echo "Installed Spoon -> $DEST"

# --- wire up Hammerspoon init.lua -----------------------------------------
touch "$INIT"
if grep -q 'hs.loadSpoon("WaveSwitcher")' "$INIT"; then
  echo "WaveSwitcher already referenced in $INIT (left as-is)."
else
  cat >> "$INIT" <<'LUA'

-- WaveSwitcher: Ctrl+K work-stream switcher for Wave Terminal
hs.loadSpoon("WaveSwitcher")
spoon.WaveSwitcher:bindHotkeys({ open = {{"ctrl"}, "k"} })
spoon.WaveSwitcher:start()
LUA
  echo "Added WaveSwitcher to $INIT"
fi

# --- Claude Code integration: status flags + session resume ---------------
if [ "$WITH_CLAUDE" = "1" ] && [ -d "$HOME/.claude" ]; then
  if command -v python3 >/dev/null 2>&1; then
    HOOK="$DEST/wave-claude-hook.sh" python3 - "$HOME/.claude/settings.json" <<'PY'
import json, os, sys
path = sys.argv[1]
hook = os.environ["HOOK"]
try:
    with open(path) as f: cfg = json.load(f)
except Exception:
    cfg = {}
hooks = cfg.setdefault("hooks", {})
# (event, matcher, arg)
wanted = [
    ("SessionStart",     "", "SessionStart"),
    ("UserPromptSubmit", "", "UserPromptSubmit"),
    ("PostToolUse",      "", "PostTool"),
    ("Stop",             "", "Stop"),
    ("SubagentStart",    "", "SubStart"),
    ("SubagentStop",     "", "SubStop"),
    ("PreCompact",       "", "PreCompact"),
    ("PostCompact",      "", "PostCompact"),
    ("Notification", "permission_prompt",  "NeedsInput"),
    ("Notification", "elicitation_dialog", "NeedsInput"),
    ("PreToolUse",   "AskUserQuestion",    "Question"),
    ("SessionEnd",       "", "SessionEnd"),
]
def has(arr, matcher, cmd):
    for e in arr:
        if e.get("matcher", "") == matcher and any(h.get("command") == cmd for h in e.get("hooks", [])):
            return True
    return False
added = 0
for event, matcher, arg in wanted:
    cmd = f"{hook} {arg}"
    arr = hooks.setdefault(event, [])
    if has(arr, matcher, cmd): continue
    entry = {"hooks": [{"type": "command", "command": cmd}]}
    if matcher: entry["matcher"] = matcher
    arr.append(entry); added += 1
if added:
    import shutil, time
    if os.path.exists(path):
        shutil.copy(path, path + ".bak." + time.strftime("%Y%m%d%H%M%S"))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f: json.dump(cfg, f, indent=2)
print(f"Claude hooks: added {added} entr" + ("y" if added==1 else "ies") + f" to {path}")
PY
  else
    echo "python3 not found — skipping Claude settings merge (see README to add hooks manually)."
  fi

  # zsh auto-resume snippet
  if [ -f "$ZSHRC" ] && grep -q "WaveSwitcher resume" "$ZSHRC"; then
    echo "Resume snippet already in $ZSHRC (left as-is)."
  else
    printf '\n' >> "$ZSHRC"
    cat "$DEST/resume.zsh" >> "$ZSHRC"
    echo "Added resume snippet to $ZSHRC"
  fi
elif [ "$WITH_CLAUDE" = "1" ]; then
  echo "No ~/.claude found — skipping Claude Code integration."
fi

# --- reload Hammerspoon ---------------------------------------------------
if command -v hs >/dev/null 2>&1; then
  hs -c 'hs.reload()' >/dev/null 2>&1 || true
  echo "Reloaded Hammerspoon."
else
  echo "Reload Hammerspoon from its menu-bar icon -> Reload Config."
fi

cat <<'EOF'

Done. Final steps:
  1. Grant Hammerspoon Accessibility permission (needed to send keystrokes):
       System Settings -> Privacy & Security -> Accessibility -> enable Hammerspoon
  2. Focus Wave Terminal and press Ctrl+K.
  3. (If you enabled the Claude integration) open a new terminal tab so the
     resume snippet loads, and restart your Claude sessions so the status
     flags/resume markers start recording.
EOF
