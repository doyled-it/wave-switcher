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
./WaveSwitcher.spoon/wave-sessions.sh | python3 -m json.tool   # inspect the listing JSON
./WaveSwitcher.spoon/wave-usage.sh              # inspect the usage JSON
./install.sh                                     # local install (copies Spoon, wires hooks, reloads)
./install.sh --no-claude                         # install the switcher only, skip Claude integration
```

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
| needs input | `#e0b956` | `GOLD`                | `WHEN '#e0b956'`   | `--need`            | `needs`                |

Adding or recoloring a status means editing the hook constant, the SQL `CASE` in
`wave-sessions.sh`, the CSS custom properties, and the JS `STATUS` map.

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
- **Pins live in a JSON file** (`~/.hammerspoon/waveswitcher-pins.json`), not Wave
  metadata, because Hammerspoon has no `WAVETERM_JWT` and so cannot use `wsh`.
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
`AskUserQuestion` -> `Question`. The hook's own `case "$event"` arms (`SubStart`,
`SubStop`, `PostTool`, ...) are these args, not the raw Claude event names, so the
two lists must agree.

## Conventions

- **No `jq` or extra dependencies.** The hard requirement is `sqlite3` (built into
  macOS); `python3` is used only for JSON parsing in the usage/install scripts.
  Keep it that way.
- Scripts that `wsh` or touch Wave metadata assume they run **inside a Wave
  block** (env vars `WAVETERM_TABID`, `WAVETERM_WORKSPACEID`, `WAVETERM_BLOCKID`).
  Code running in Hammerspoon's context does not have these.
- Bump `obj.version` in `init.lua` for releases.
