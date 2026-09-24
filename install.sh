#!/bin/sh
# WaveSwitcher installer — copies the Spoon into ~/.hammerspoon and wires it up.
set -e

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
SPOON_SRC="$SRC_DIR/WaveSwitcher.spoon"
SPOON_DEST="$HOME/.hammerspoon/Spoons/WaveSwitcher.spoon"
INIT="$HOME/.hammerspoon/init.lua"

# --- checks ---------------------------------------------------------------
[ "$(uname)" = "Darwin" ] || { echo "WaveSwitcher requires macOS."; exit 1; }
[ -x /usr/bin/sqlite3 ]   || { echo "sqlite3 not found (unexpected on macOS)."; exit 1; }

if [ ! -d "/Applications/Hammerspoon.app" ]; then
  echo "!! Hammerspoon is not installed. Install it first:"
  echo "     brew install --cask hammerspoon"
  echo "   then re-run this script."
  exit 1
fi

if [ ! -d "$HOME/Library/Application Support/waveterm" ]; then
  echo "!! Wave Terminal data not found. Install Wave Terminal (https://waveterm.dev)"
  echo "   and run it at least once. Continuing anyway."
fi

# --- install the Spoon ----------------------------------------------------
mkdir -p "$HOME/.hammerspoon/Spoons"
rm -rf "$SPOON_DEST"
cp -R "$SPOON_SRC" "$SPOON_DEST"
chmod +x "$SPOON_DEST/wave-sessions.sh"
echo "Installed Spoon -> $SPOON_DEST"

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
