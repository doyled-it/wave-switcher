#!/bin/zsh
# WaveSwitcher <-> Claude Code integration hook (single entry point).
#
# Invoked by Claude Code with the event name as the first argument. Keeps the
# Wave tab's status flag in sync (green idle / blue running / purple subagents /
# gold needs-input), records the session id for restart resume, and posts a
# clickable notification when input is needed.
#
# "Subagents" is driven by a per-tab SET of live subagent ids rather than a
# counter. Each subagent carries a unique "agent_id" in the SubagentStart /
# SubagentStop hook payloads; we add it on start and remove it on stop. The tab
# is purple whenever the set is non-empty. A set is immune to the two ways a
# counter desynced in practice:
#   * SubagentStop fires more than once, or for a subagent whose SubagentStart
#     we never saw (e.g. it started before this session was wired, or a nested
#     stop) -- removing an absent id is a harmless no-op, instead of driving a
#     counter below the true number of live subagents and flipping the tab green
#     while subagents are still running.
#   * Events double-fire -- adding/removing the same id twice is idempotent.
# The set is reset only at SessionStart (a genuinely fresh session); it is NOT
# reset on each prompt, because detached/background subagents (Workflow / SDD)
# legitimately outlive the turn that launched them. A prune drops stale entries
# whose SubagentStop was missed (crash), so the tab can't get stuck purple.
#
# Codex uses this same status engine through wave-codex-hook.sh (WSW_AGENT=codex).
# Reads the hook JSON payload on stdin; needs wsh and python3 for background tasks.

event="$1"
payload="$(cat 2>/dev/null)"
here="${0:A:h}"
agent="${WSW_AGENT:-claude}"
[[ "$agent" == codex ]] || agent=claude

field() {
  printf '%s' "$payload" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
}

GREEN="#58c142"   # idle / done
BLUE="#4a9eff"    # running
PURPLE="#a970ff"  # subagents active
TEAL="#20c4b0"    # idle, but a background shell task is still running
COMPACT="#e86f9e" # compacting context
GOLD="#e0b956"    # needs your input

zmodload zsh/datetime 2>/dev/null  # $EPOCHSECONDS, no fork
# Set the tab's status color and stamp the activity time (epoch seconds) in one
# call, so the switcher can show how long a session has been in its current state.
flag() { wsh setmeta -b tab "tab:flagcolor=$1" "waveswitcher:activity=${EPOCHSECONDS:-$(date +%s)}" >/dev/null 2>&1; }

# --- live-subagent set: one marker file per agent_id, in a per-tab dir --------
SUBDIR="${TMPDIR:-/tmp}/wsw-subs-${WAVETERM_TABID:-unknown}.d"
[[ "$agent" == codex ]] && SUBDIR="${TMPDIR:-/tmp}/wsw-codex-subs-${WAVETERM_TABID}.d"
STALE_MIN=120                               # drop markers older than this (missed stop)
sub_add()   { [ -n "$1" ] && { mkdir -p "$SUBDIR" 2>/dev/null; : > "$SUBDIR/$1" 2>/dev/null; }; }
sub_del()   { [ -n "$1" ] && rm -f "$SUBDIR/$1" 2>/dev/null; }
sub_reset() { rm -rf "$SUBDIR" 2>/dev/null; }
sub_prune() { [ -d "$SUBDIR" ] && find "$SUBDIR" -type f -mmin +$STALE_MIN -delete 2>/dev/null; }
sub_active() { sub_prune; [ -d "$SUBDIR" ] && [ -n "$(ls -A "$SUBDIR" 2>/dev/null)" ]; }  # 0 = subagents live

# --- background shell task -----------------------------------------------------
# When Claude finishes a turn, its hook payload carries "background_tasks": the
# work still in flight. A real background *command* (a script / dev server it
# launched and left running) carries a "command" field; subagents carry
# "agent_type" (the purple state), and monitor / mcp / workflow tasks carry
# neither. Only a task with a command means the session is "shell", not idle --
# so an armed artifact-update monitor or a live MCP task does NOT turn it teal.
bg_shell_active() {  # 0 = a background shell command is running
  printf '%s' "$payload" | python3 -c '
import json, sys
try:
    tasks = (json.load(sys.stdin) or {}).get("background_tasks") or []
except Exception:
    sys.exit(1)
sys.exit(0 if any(t.get("command") for t in tasks) else 1)
' 2>/dev/null
}

# Pick the color when work settles (turn ends, or a subagent stops): purple if
# subagents are live, else teal if a background shell task is still running,
# else green (truly idle and ready for the next message).
settle_idle() {
  if sub_active; then flag "$PURPLE"
  elif bg_shell_active; then flag "$TEAL"
  else flag "$GREEN"; fi
}

# TEMP DEBUG: set a flag file at ${TMPDIR}/wsw-debug to log every invocation.
if [ -n "$WSW_DEBUG" ] || [ -f "${TMPDIR:-/tmp}/wsw-debug" ]; then
  sub_active && act=Y || act=N
  bg_shell_active && bga=Y || bga=N
  printf '%s tab=%s ev=%-16s tool=%-18s aid=%-18s subs=%s bg=%s\n' \
    "$(date +%H:%M:%S)" "${WAVETERM_TABID:0:8}" "$event" "$(field tool_name)" "$(field agent_id)" "$act" "$bga" \
    >> "${TMPDIR:-/tmp}/wsw-hook.log" 2>/dev/null
  # Log just the background_tasks array (not the prompt text) to learn its shape.
  printf '%s' "$payload" | python3 -c 'import json,sys
try: d=json.load(sys.stdin) or {}
except Exception: d={}
print("   background_tasks="+json.dumps(d.get("background_tasks")))' \
    >> "${TMPDIR:-/tmp}/wsw-hook.log" 2>/dev/null
fi

case "$event" in
  SessionStart)
    sub_reset; flag "$GREEN"
    sid="$(field session_id)"
    if [ -n "$sid" ]; then
      # A block can run either CLI. Clear the other provider's stale resume id,
      # including ids written by old Claude hooks copied into Codex settings.
      if [[ "$agent" == codex ]]; then
        codex_home="${CODEX_HOME:-$HOME/.codex}"
        codex_home="${codex_home:A}"
        wsh setmeta -b this "codex:resume=$sid" "codex:home=$codex_home" 'claude:resume=' >/dev/null 2>&1
      else
        wsh setmeta -b this "claude:resume=$sid" 'codex:resume=' 'codex:home=' >/dev/null 2>&1
      fi
    fi
    ;;
  SessionEnd)       if [[ "$agent" == codex ]]; then
                      wsh setmeta -b this 'codex:resume=' 'codex:home=' >/dev/null 2>&1
                    else
                      wsh setmeta -b this 'claude:resume=' >/dev/null 2>&1
                    fi ;;
  UserPromptSubmit) sub_active && flag "$PURPLE" || flag "$BLUE" ;;   # keep prior live subagents
  SubStart)         sub_add "$(field agent_id)"; flag "$PURPLE" ;;    # a subagent started
  SubStop)          sub_del "$(field agent_id)"; settle_idle ;;        # a subagent finished
  Stop)             settle_idle ;;                                     # turn ended
  PreCompact)       flag "$COMPACT" ;;                                 # compacting context
  PostCompact)      sub_active && flag "$PURPLE" || flag "$BLUE" ;;    # back to work
  PostTool)         sub_active && flag "$PURPLE" || flag "$BLUE" ;;
  NeedsInput)       flag "$GOLD"; "$here/wave-notify.sh" input "$agent"    >/dev/null 2>&1 ;;
  Question)         flag "$GOLD"; "$here/wave-notify.sh" question "$agent" >/dev/null 2>&1 ;;
esac
exit 0
