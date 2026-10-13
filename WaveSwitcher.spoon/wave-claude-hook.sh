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
# Depends only on Wave's `wsh`. Reads the hook JSON payload on stdin.

event="$1"
payload="$(cat 2>/dev/null)"
here="${0:A:h}"

field() {
  printf '%s' "$payload" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
}

GREEN="#58c142"   # idle / done
BLUE="#4a9eff"    # running
PURPLE="#a970ff"  # subagents active
GOLD="#e0b956"    # needs your input

flag() { wsh setmeta -b tab "tab:flagcolor=$1" >/dev/null 2>&1; }

# --- live-subagent set: one marker file per agent_id, in a per-tab dir --------
SUBDIR="${TMPDIR:-/tmp}/wsw-subs-${WAVETERM_TABID:-unknown}.d"
STALE_MIN=120                               # drop markers older than this (missed stop)
sub_add()   { [ -n "$1" ] && { mkdir -p "$SUBDIR" 2>/dev/null; : > "$SUBDIR/$1" 2>/dev/null; }; }
sub_del()   { [ -n "$1" ] && rm -f "$SUBDIR/$1" 2>/dev/null; }
sub_reset() { rm -rf "$SUBDIR" 2>/dev/null; }
sub_prune() { [ -d "$SUBDIR" ] && find "$SUBDIR" -type f -mmin +$STALE_MIN -delete 2>/dev/null; }
sub_active() { sub_prune; [ -d "$SUBDIR" ] && [ -n "$(ls -A "$SUBDIR" 2>/dev/null)" ]; }  # 0 = subagents live

# TEMP DEBUG: set a flag file at ${TMPDIR}/wsw-debug to log every invocation.
if [ -n "$WSW_DEBUG" ] || [ -f "${TMPDIR:-/tmp}/wsw-debug" ]; then
  sub_active && act=Y || act=N
  printf '%s tab=%s ev=%-16s tool=%-18s aid=%-18s active=%s\n' \
    "$(date +%H:%M:%S)" "${WAVETERM_TABID:0:8}" "$event" "$(field tool_name)" "$(field agent_id)" "$act" \
    >> "${TMPDIR:-/tmp}/wsw-hook.log" 2>/dev/null
fi

case "$event" in
  SessionStart)
    sub_reset; flag "$GREEN"
    sid="$(field session_id)"
    [ -n "$sid" ] && wsh setmeta -b this "claude:resume=$sid" >/dev/null 2>&1
    ;;
  SessionEnd)       wsh setmeta -b this "claude:resume=" >/dev/null 2>&1 ;;
  UserPromptSubmit) sub_active && flag "$PURPLE" || flag "$BLUE" ;;   # keep prior live subagents
  SubStart)         sub_add "$(field agent_id)"; flag "$PURPLE" ;;    # a subagent started
  SubStop)          sub_del "$(field agent_id)"
                    sub_active && flag "$PURPLE" || flag "$GREEN" ;;  # a subagent finished
  Stop)             sub_active && flag "$PURPLE" || flag "$GREEN" ;;
  PostTool)         sub_active && flag "$PURPLE" || flag "$BLUE" ;;
  NeedsInput)       flag "$GOLD"; "$here/wave-notify.sh" input    >/dev/null 2>&1 ;;
  Question)         flag "$GOLD"; "$here/wave-notify.sh" question >/dev/null 2>&1 ;;
esac
exit 0
