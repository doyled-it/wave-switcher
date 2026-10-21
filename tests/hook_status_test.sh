#!/bin/zsh
# Unit tests for wave-claude-hook.sh status decisions.
#
# No Wave/Hammerspoon needed: a stub `wsh` on PATH records the flag color the
# hook would set, and we assert it per event + payload. Run: tests/hook_status_test.sh
set -u
here="${0:A:h}"
HOOK="$here/../WaveSwitcher.spoon/wave-claude-hook.sh"

GREEN="#58c142"; BLUE="#4a9eff"; PURPLE="#a970ff"; GOLD="#e0b956"; TEAL="#20c4b0"; COMPACT="#e86f9e"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/wsh" <<'STUB'
#!/bin/sh
echo "$@" >> "$WSH_LOG"
exit 0
STUB
chmod +x "$tmp/bin/wsh"

pass=0; fail=0
# run_case <name> <event> <tabid> <expected-color> <payload-json>
run_case() {
  local name="$1" event="$2" tabid="$3" want="$4" payload="$5"
  local log="$tmp/wsh.log"; : > "$log"
  printf '%s' "$payload" | \
    env -i HOME="$HOME" PATH="$tmp/bin:/usr/bin:/bin" TMPDIR="$tmp" \
        WAVETERM_TABID="$tabid" WSH_LOG="$log" \
        /bin/zsh "$HOOK" "$event" >/dev/null 2>&1
  # Last flagcolor the hook set (strip to the hex).
  local got
  got="$(grep -o 'tab:flagcolor=#[0-9a-fA-F]*' "$log" | tail -1 | sed 's/.*=//')"
  if [ "$got" = "$want" ]; then
    print -r -- "ok   - $name ($got)"; pass=$((pass+1))
  else
    print -r -- "FAIL - $name: want $want got '${got:-<none>}'"; fail=$((fail+1))
  fi
}

# A backgrounded shell task (has command, no agent_type) -> shell/teal.
run_case "Stop: bg shell task -> teal" Stop tab-a "$TEAL" \
  '{"session_id":"s","background_tasks":[{"id":"1","type":"shell","status":"running","command":"python train.py"}]}'

# Nothing in flight -> green.
run_case "Stop: nothing -> green" Stop tab-b "$GREEN" \
  '{"session_id":"s","background_tasks":[]}'

# No background_tasks key at all -> green.
run_case "Stop: no bg key -> green" Stop tab-c "$GREEN" \
  '{"session_id":"s"}'

# A subagent entry in background_tasks (has agent_type) must NOT count as shell.
run_case "Stop: subagent-only bg -> green (not teal)" Stop tab-d "$GREEN" \
  '{"background_tasks":[{"id":"2","type":"subagent","status":"running","agent_type":"explore"}]}'

# A monitor task (e.g. an artifact live-update monitor, armed on publish) has no
# shell command and must NOT count as shell.
run_case "Stop: monitor-only bg -> green (not teal)" Stop tab-mon "$GREEN" \
  '{"background_tasks":[{"id":"m","type":"monitor","status":"running","description":"live updates for artifact https://..."}]}'

# Mixed: a subagent AND a real shell task -> teal (the shell task still counts).
run_case "Stop: shell + subagent bg -> teal" Stop tab-e "$TEAL" \
  '{"background_tasks":[{"type":"subagent","agent_type":"x"},{"type":"shell","command":"sleep 99"}]}'

# Regression: active subagent markers still take precedence -> purple.
mkdir -p "$tmp/wsw-subs-tab-f.d"; : > "$tmp/wsw-subs-tab-f.d/agent1"
run_case "Stop: subagent markers -> purple (precedence over shell)" Stop tab-f "$PURPLE" \
  '{"background_tasks":[{"type":"shell","command":"sleep 99"}]}'

# Regression: PostTool with no subagents -> blue (unchanged).
run_case "PostTool: no subs -> blue" PostTool tab-g "$BLUE" '{}'

# Compaction: PreCompact -> compacting; PostCompact resumes working (blue, or
# purple if subagents are live).
run_case "PreCompact -> compacting" PreCompact tab-h "$COMPACT" '{}'
run_case "PostCompact: no subs -> blue" PostCompact tab-i "$BLUE" '{}'
mkdir -p "$tmp/wsw-subs-tab-j.d"; : > "$tmp/wsw-subs-tab-j.d/agentX"
run_case "PostCompact: subagents -> purple" PostCompact tab-j "$PURPLE" '{}'

print -r -- ""
print -r -- "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
