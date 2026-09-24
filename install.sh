#!/bin/sh
# WaveSwitcher installer.
#
# One-line install:
#   curl -fsSL https://gitlab.mitre.org/mdoyle/wave-switcher/-/raw/main/install.sh | sh
#
# Or from a local clone:
#   ./install.sh
#
# Downloads the Spoon into ~/.hammerspoon/Spoons, wires up init.lua, and reloads
# Hammerspoon. Override the download source with WAVESWITCHER_RAW if needed.
set -e

RAW="${WAVESWITCHER_RAW:-https://gitlab.mitre.org/mdoyle/wave-switcher/-/raw/main}"
DEST="$HOME/.hammerspoon/Spoons/WaveSwitcher.spoon"
INIT="$HOME/.hammerspoon/init.lua"

# --- checks ---------------------------------------------------------------
[ "$(uname)" = "Darwin" ] || { echo "WaveSwitcher requires macOS."; exit 1; }
[ -x /usr/bin/sqlite3 ]   || { echo "sqlite3 not found (unexpected on macOS)."; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl is required."; exit 1; }

if [ ! -d "/Applications/Hammerspoon.app" ]; then
  echo "!! Hammerspoon is not installed. Install it first:"
  echo "     brew install --cask hammerspoon"
  echo "   (or download from https://www.hammerspoon.org), then re-run this."
  exit 1
fi

if [ ! -d "$HOME/Library/Application Support/waveterm" ]; then
  echo "!! Wave Terminal data not found. Install Wave Terminal (https://waveterm.dev)"
  echo "   and run it once. Continuing anyway."
fi

# --- locate source: local clone if present, else download -----------------
LOCAL=""
for d in "$(dirname "$0" 2>/dev/null)" "$PWD"; do
  if [ -n "$d" ] && [ -f "$d/WaveSwitcher.spoon/init.lua" ]; then LOCAL="$d/WaveSwitcher.spoon"; break; fi
done

mkdir -p "$DEST"
if [ -n "$LOCAL" ]; then
  echo "Installing from local clone: $LOCAL"
  cp "$LOCAL/init.lua"         "$DEST/init.lua"
  cp "$LOCAL/wave-sessions.sh" "$DEST/wave-sessions.sh"
else
  echo "Downloading WaveSwitcher from $RAW"
  curl -fsSL "$RAW/WaveSwitcher.spoon/init.lua"         -o "$DEST/init.lua"
  curl -fsSL "$RAW/WaveSwitcher.spoon/wave-sessions.sh" -o "$DEST/wave-sessions.sh"
fi
chmod +x "$DEST/wave-sessions.sh"
echo "Installed Spoon -> $DEST"

# --- wire up init.lua -----------------------------------------------------
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

# --- reload Hammerspoon if the CLI is available ---------------------------
if command -v hs >/dev/null 2>&1; then
  hs -c 'hs.reload()' >/dev/null 2>&1 || true
  echo "Reloaded Hammerspoon."
else
  echo "Reload Hammerspoon from its menu-bar icon -> Reload Config."
fi

cat <<'EOF'

Done. Two final steps:
  1. Grant Hammerspoon Accessibility permission (needed to send keystrokes):
       System Settings -> Privacy & Security -> Accessibility -> enable Hammerspoon
  2. Focus Wave Terminal and press Ctrl+K.
EOF
