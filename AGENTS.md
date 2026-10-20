# AGENTS.md

Guidance for AI coding agents (Claude Code, Cursor, Copilot, Codex, and others)
working in this repository. `CLAUDE.md` points here so the same guidance applies
across tools.

## What this is

WaveSwitcher is a Hammerspoon **Spoon** (a macOS automation plugin) that gives
[Wave Terminal](https://waveterm.dev) a `Ctrl+K` work-stream switcher: a popup
palette of tabs grouped by workspace, with live status dots and a Claude usage
footer. There is no compiler, package manager, or test suite. The deliverable is
the `WaveSwitcher.spoon/` directory, installed by copying it into
`~/.hammerspoon/Spoons/`.

## Working on it

Edit, then reload Hammerspoon to pick up changes:

```sh
hs -c 'hs.reload()'                              # reload the running config
./tests/hook_status_test.sh                      # unit-test the hook's status/color decisions
./WaveSwitcher.spoon/wave-sessions.sh | python3 -m json.tool   # inspect the listing JSON
./WaveSwitcher.spoon/wave-usage.sh              # inspect the usage JSON
./install.sh                                     # local install (copies Spoon, wires hooks, reloads)
./install.sh --no-claude                         # install the switcher only, skip Claude integration
```

`tests/hook_status_test.sh` stubs `wsh` on `PATH` and feeds fixture hook payloads
to `wave-claude-hook.sh`, asserting the flag color it would set. No Wave or
Hammerspoon needed; it is the one automated test and should stay green.

Debug the Claude hook: `export WSW_DEBUG=1` (or `touch "$TMPDIR/wsw-debug"`),
then watch `"$TMPDIR/wsw-hook.log"`. It logs every hook invocation with the tab,
event, tool, agent id, and whether subagents are active.

The installer runs from either a **local clone** or a `curl | sh` download; when
editing it, keep both paths working (`fetch()` branches on `$LOCAL`). Hook and
`~/.zshrc` wiring must stay **idempotent** (re-running `install.sh` must not
duplicate entries).

## Architecture

Two cooperating halves, talking through Wave's own state:

1. **The picker** (`init.lua`), a pure Lua Spoon. Reads Wave's SQLite DB
   read-only for the tab list (`wave-sessions.sh`), renders an `hs.webview`, and
   drives selection with an `hs.eventtap` key tap. Jumping selects the target
   **workspace by name** via Wave's *Workspace* app menu, then the **tab by
   number** via Wave's native `Cmd+<n>`.
2. **The Claude Code integration** (`wave-claude-hook.sh` plus `wave-notify.sh`
   and `resume.zsh`), wired into `~/.claude/settings.json` by the installer. It
   writes each tab's **Wave flag color** so the picker can show live status, posts
   notifications, and records session ids for restart-resume.

The two halves never call each other directly. They communicate through Wave's
per-tab **flag color** (the hook writes it with `wsh setmeta`; the picker reads
it from SQLite). This makes the flag color a cross-file contract (see below).

### The status-color contract (change all four places together)

A tab's status is encoded entirely as its Wave flag color. The same color
constants appear in **four** places and must stay in sync:

| Status      | Color     | `wave-claude-hook.sh` | `wave-sessions.sh` | `init.lua` CSS vars | `init.lua` JS `STATUS` |
|-------------|-----------|-----------------------|--------------------|---------------------|------------------------|
| idle / done | `#58c142` | `GREEN`               | `WHEN '#58c142'`   | `--idle`            | (default)              |
| running     | `#4a9eff` | `BLUE`                | `WHEN '#4a9eff'`   | `--run`             | `running`              |
| subagents   | `#a970ff` | `PURPLE`              | `WHEN '#a970ff'`   | `--sub`             | `subagents`            |
| shell       | `#20c4b0` | `TEAL`                | `WHEN '#20c4b0'`   | `--shell`           | `shell`                |
| compacting  | `#e86f9e` | `COMPACT`             | `WHEN '#e86f9e'`   | `--compact`         | `compacting`           |
| needs input | `#e0b956` | `GOLD`                | `WHEN '#e0b956'`   | `--need`            | `needs`                |

Adding or recoloring a status means editing the hook constant, the SQL `CASE` in
`wave-sessions.sh`, the CSS custom properties, and the JS `STATUS` map. Then run
`./tests/hook_status_test.sh`, which asserts the color the hook picks per event.

### The `shell` state (idle, but a background task is still running)

"Idle" (green) means ready for the next message. The `shell` state (teal)
distinguishes "the turn ended, but a script/dev-server Claude launched is still
running, so you're really waiting on *that*." It is detected entirely in the
hook: Claude's `Stop` (and `SubagentStop`) payload carries a `background_tasks`
array of in-flight work. `settle_idle()` picks the color when a turn settles:
subagents live -> purple; else a non-subagent background task present -> teal;
else green. Subagent tasks (they carry `agent_type`) are excluded because they
are already the purple state. `bg_shell_active()` does the JSON parse in python
(only at settle time, not per tool, so the cost is fine).

Verified shape (`Stop` payload): a `run_in_background` Bash appears as
`{"type":"shell","status":"running","command":...}` with no `agent_type`; real
subagents appear as `{"type":"subagent",...,"agent_type":"..."}`. So "exclude
anything with `agent_type`" is the correct filter, and counting any remaining
task (shell/mcp/monitor/workflow) as "busy" is intentional.

Flip-back: when a background task *finishes*, Claude re-invokes the session to
process the result (a fresh turn, so `UserPromptSubmit` -> blue, then `Stop`
re-evaluates `background_tasks` -> green once none remain). So teal clears on its
own without a dedicated completion hook. The only stale window is a task that
finishes while you never return to the session; it clears on your next
interaction.

### Non-obvious constraints (do not "simplify" these)

- **The webview must never take keyboard focus.** It is a render-only
  `hs.webview` (no `allowTextEntry`), so Wave stays the key window, which
  `Cmd+<n>` tab switching requires. All input goes through the event tap, which
  consumes every key while the picker is open.
- **Never call `evaluateJavaScript` inside the key-tap callback.** It corrupts the
  WKWebView JS bridge and macOS can auto-disable the tap. The tap only sets
  `P.dirty`; a separate repeating `renderTimer` (clean context) does the render.
  `togglePin` is the exception: it runs via `hs.timer.doAfter(0, ...)`, outside
  the tap.
- **Pins and follow-up flags live in JSON files** (`waveswitcher-pins.json`,
  `waveswitcher-followups.json` under `hs.configdir`), not Wave metadata, because
  Hammerspoon has no `WAVETERM_JWT` and so cannot use `wsh`. Both are keyed by tab
  id and share `readJsonMap`/`writeJsonMap`. Pins map `tabId -> true` and float to
  the PINNED group; follow-ups map `tabId -> note` (`""` = flagged, no note), do
  NOT reorder the list (inline amber flag marker only), and auto-clear when you
  jump to the session. Because `P.filtered` holds the same entry tables as
  `P.entries`, a flag toggle mutates the entry in place and just re-renders.
- **Follow-up note entry is a sub-mode of the key tap.** `Ctrl+F` on an unflagged
  row flags it and sets `P.noteMode`; while that is true, `handleKey` routes
  keystrokes into `P.noteText` (not the search query) until `Enter` (save) or
  `Esc` (keep flag, drop the text). `setData(rows, sel, query, noteMode, noteText)`
  renders the note-input line when `noteMode` is set.
- **Subagents are tracked as a set of marker files**, one per `agent_id`, not a
  counter (`$TMPDIR/wsw-subs-<tabid>.d/`). This is deliberate: counters desynced
  when `SubagentStop` double-fired or fired for an unseen start. The set is reset
  only at `SessionStart`, not per prompt, so detached Workflow/SDD subagents can
  outlive the turn; a time-based prune clears markers whose stop was missed.
- **Same-workspace jumps skip the menu.** `switchTo(..., sameWs)` sends the tab
  key with a tiny delay; cross-workspace jumps activate Wave, pick the workspace
  from the menu, then wait ~0.15s for the new tab bar before the key.
- **The usage endpoint is undocumented** (`GET api.anthropic.com/api/oauth/usage`,
  token from the `Claude Code-credentials` Keychain entry). The `User-Agent:
  claude-code/...` and `anthropic-beta` headers are **required**: without the
  claude-code UA the endpoint 429s. Failures degrade to a blank footer, never an
  error. The token is read locally and sent only to `api.anthropic.com`.

### Hook event mapping

The installer maps Claude Code events to `wave-claude-hook.sh <arg>` (see the
`wanted` list in `install.sh`). Notable: `Notification` with matcher
`permission_prompt`/`elicitation_dialog` -> `NeedsInput`; `PreToolUse` with matcher
`AskUserQuestion` -> `Question`; `PreCompact`/`PostCompact` -> the compacting color
then back to work. The hook's own `case "$event"` arms (`SubStart`, `SubStop`,
`PostTool`, ...) are these args, not the raw Claude event names, so the two lists
must agree.

## Conventions

- **No `jq` or extra dependencies.** The hard requirement is `sqlite3` (built into
  macOS); `python3` is used only for JSON parsing in the usage/install scripts.
  Keep it that way.
- Scripts that `wsh` or touch Wave metadata assume they run **inside a Wave
  block** (env vars `WAVETERM_TABID`, `WAVETERM_WORKSPACEID`, `WAVETERM_BLOCKID`).
  Code running in Hammerspoon's context does not have these.
- Bump `obj.version` in `init.lua` for releases.

## Known-blocked ideas

- **"Draft" status (user has typed an unsent prompt).** Not buildable with
  current mechanisms, do not re-investigate from scratch. Claude Code exposes no
  pre-submit/draft/keystroke hook and no way to read the input buffer (only
  `UserPromptSubmit`, which fires *on* submit). Reading it from the terminal is
  also blocked: `wsh termscrollback` returns `no route for "feblock:..."` from
  the hook/tool-shell context (it needs the front-end block, unreachable there),
  Hammerspoon has no `wsh`/JWT access at all, and Wave renders the terminal to a
  canvas (xterm.js), so there is no accessible text/attributes to scrape. The
  distinguishing signal *would* be color (Claude draws the ghost autosuggestion
  dim/see-through vs. normal typed text), so this becomes feasible only if Claude
  Code adds a draft hook, or Wave adds a screen-read-with-attributes API.
