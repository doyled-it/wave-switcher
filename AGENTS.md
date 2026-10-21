# AGENTS.md

Guidance for AI coding agents (Claude Code, Cursor, Copilot, Codex, and others)
working in this repository. `CLAUDE.md` points here so the same guidance applies
across tools.

## What this is

WaveSwitcher is a Hammerspoon **Spoon** (a macOS automation plugin) that gives
[Wave Terminal](https://waveterm.dev) a `Ctrl+K` work-stream switcher: a popup
palette of tabs grouped by workspace, with live status dots and a Claude usage
footer. There is no compiler or package manager. The deliverable is
the `WaveSwitcher.spoon/` directory, installed by copying it into
`~/.hammerspoon/Spoons/`.

## Working on it

Edit, then reload Hammerspoon to pick up changes:

```sh
hs -c 'hs.reload()'                              # reload the running config
./tests/hook_status_test.sh                      # unit-test the hook's status/color decisions
python3 -m unittest discover -s tests            # Codex adapter, install/migration, and resume
./WaveSwitcher.spoon/wave-sessions.sh | python3 -m json.tool   # inspect the listing JSON
./WaveSwitcher.spoon/wave-usage.sh              # inspect the usage JSON
./install.sh                                     # local install (copies Spoon, wires hooks, reloads)
./install.sh --no-claude                         # install the switcher only, skip Claude integration
```

`tests/hook_status_test.sh` stubs `wsh` on `PATH` and feeds fixture hook payloads
to `wave-claude-hook.sh`, asserting the flag color it would set. The Python suite
exercises the Codex adapter, installer, and resume against temporary files and a
stub `wsh`. Both suites should stay green.

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
subagents live -> purple; else a background *command* still running -> teal;
else green. `bg_shell_active()` does the JSON parse in python (only at settle
time, not per tool, so the cost is fine).

Verified shape (`Stop` payload): a `run_in_background` Bash appears as
`{"type":"shell","status":"running","command":...}`; real subagents appear as
`{"type":"subagent",...,"agent_type":"..."}`; and non-command tasks (an
artifact-update `monitor` armed on publish, a live `mcp` task, a `workflow`)
carry neither. **Count only tasks with a `command` field** -- that is the signal
for a real background command. Keying off "command" (not "not agent_type") is
deliberate: an armed artifact monitor or MCP task must NOT turn an idle session
teal, since it isn't a shell.

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

### Theme matching

The popup chrome adopts the user's Wave terminal theme when one is set.
`readWaveTheme` reads `~/.config/waveterm/settings.json` for `term:theme`; if it's
a non-empty string, it looks the key up in the bundled `wave-termthemes.json`
(a snapshot of Wave's term palettes, ported from wavecrest) and derives a chrome
palette (bg/text/muted/accent, with border/sel as derived rgba). `themeCss`
turns that into a `:root` override string injected at the `/*__THEME__*/`
placeholder in the HTML; because it comes after the defaults in the same `:root`,
it wins the cascade. If `term:theme` is unset, the theme file is missing, or the
key isn't in the snapshot, `themeCss` returns `""` and the hand-tuned default
palette stands. **Only chrome is themed; the status colors stay fixed** (they map
to the Wave flag colors in the contract above). Matching only covers the themes in
the bundled snapshot; expand `wave-termthemes.json` to add more.

### Session metadata: git branch + activity time

Each row can show the session's **git branch** (with a `⎇` glyph for worktrees)
and **time in its current state**.

- **cwd**: `wave-sessions.sh` finds each tab's terminal working directory by
  joining `db_block` on `parentoref = 'tab:'||tabid` and reading `cmd:cwd`.
- **branch/worktree**: resolved by `wave-gitinfo.sh` (reads newline-separated
  cwds on stdin, emits `[{cwd,branch,worktree}]` for real repos only). Git is too
  slow for the open path, so `refreshGit` runs it **async** via `hs.task` and
  re-renders when results land; they're cached in `gitCache` keyed by cwd so a
  reopen paints instantly. Worktree = `git-dir != git-common-dir`. Multi-repo
  parent dirs (not themselves repos) show no branch.
- **activity**: the hook's `flag()` stamps `waveswitcher:activity` (epoch seconds)
  on the tab in the *same* `wsh setmeta` call as the flag color, so every status
  change records a timestamp at no extra cost. `wave-sessions.sh` returns it and
  the JS `elapsed()` renders a compact "time in current state" (now/s/m/h/d).

Row layout (JS `setData`): `[dot] [flag?] <lead: name · branch chip · note> <right:
time + status pill>`. The branch chip and note live in a `min-width:0` flex lead so
the name ellipsizes; time + pill are pinned right. Branch and note are searchable.

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
  macOS); the scripts also use `python3` and its standard library for JSON and
  settings merges. Do not add third-party Python packages.
- Scripts that `wsh` or touch Wave metadata assume they run **inside a Wave
  block** (env vars `WAVETERM_TABID`, `WAVETERM_WORKSPACEID`, `WAVETERM_BLOCKID`).
  Code running in Hammerspoon's context does not have these.
- Bump `obj.version` in `init.lua` for releases.

### Codex CLI integration

`wave-codex-hook.sh` translates Codex's raw lifecycle event names to the existing
status handler in `wave-claude-hook.sh`, setting `WSW_AGENT=codex`. It does nothing
without Wave tab/block environment variables, so global Codex hooks are safe in
ordinary terminals and the desktop app. The shared handler owns the color
constants; do not duplicate them in the Codex adapter.

Codex `PermissionRequest` maps to `NeedsInput`; `PreToolUse` detects
`request_user_input` (including its `functions.` name) as `Question` and otherwise
returns to running. `PostToolUse`, subagents, compaction, Stop, and Interrupt map
to the same states. `SessionStart` with source `compact` resumes working without
resetting the subagent set. Codex markers use `wsw-codex-subs-<tabid>.d`, separate
from Claude. Resume metadata is `codex:resume`, never `claude:resume`; starting
either provider clears the other provider's stale block resume marker.
The shared handler holds a native zsh lock per block around ownership checks and
status writes for both providers. Only SessionStart can replace the owner; other
events must match that block's current provider resume marker. The Codex adapter
maps compaction SessionStart to PostCompact, preserving ownership. Keep the lock
file in place (unlinking it could give concurrent hooks different lock inodes).
The Codex resume snippet uses the same lock when consuming metadata and releases
it before launching the CLI so its SessionStart can acquire it.

`install-codex-hooks.py` merges `${CODEX_HOME:-~/.codex}/hooks.json` and migrates
only the WaveSwitcher commands at the installed path. Preserve unrelated
handlers even in mixed matcher groups. Malformed settings must fail without
overwriting the file; changed files get a backup. Quote executable paths for
homes with spaces. `--no-codex` skips setup independently of `--no-claude`.
The sourced `codex-resume.zsh` runs `codex resume <id>` in fresh interactive Wave
shells and consumes its markers before launching. `codex:home` stores the
effective absolute `CODEX_HOME` at SessionStart; restore it for the resume
command so a per-command account/session home survives Wave restarting.

Codex 0.163.0 requires users to review/trust hooks through `/hooks`; never
silently bypass trust or rewrite its trust state. Its documented Stop payload
does not expose `background_tasks`, so shell status is not promised for Codex.
The usage footer remains Claude-only. Notifications accept an optional provider
argument (`notify(wsId, tabId, kind, agent)`); omitted provider means Claude.

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
