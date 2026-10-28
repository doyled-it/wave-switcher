#!/bin/zsh
# Pure-logic tests for the status overlay. The only Lua 5.4 runtime on this
# machine is Hammerspoon, so run through a BOUNDED `hs -c` (a bare one can hang).
# Run: tests/overlay_test.sh
set -u
here="${0:A:h}"
WSW_SPOON_INIT="$here/../WaveSwitcher.spoon/init.lua"
out="$(perl -e 'alarm 25; exec @ARGV' hs -c "WSW_SPOON_INIT='$WSW_SPOON_INIT'; dofile('$here/overlay_test.lua')" 2>&1)"
print -r -- "$out"
print -r -- "$out" | grep -qx 'ALL PASS'
