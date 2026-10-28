#!/bin/zsh
# Pure-logic tests for the status overlay, run under standalone lua so they
# never touch the live Hammerspoon. Run: tests/overlay_test.sh
set -u
here="${0:A:h}"
export WSW_SPOON_INIT="$here/../WaveSwitcher.spoon/init.lua"
out="$(lua "$here/overlay_test.lua" 2>&1)"
print -r -- "$out"
# Exit status comes from this grep: pass only if a line is exactly ALL PASS.
print -r -- "$out" | grep -qx 'ALL PASS'
