# WaveSwitcher

A **Ctrl+K work-stream switcher** for [Wave Terminal](https://waveterm.dev) on macOS.

Press `Ctrl+K` anywhere in Wave to pop up a fast, searchable palette of your tabs
grouped by workspace (project), each with a live status dot. Pick one and it jumps
straight to that workspace and tab — muscle memory borrowed from tools like
Spotlight, Raycast, and `agent-view`.

```
┌────────────────────────────────────────────┐
│ 🔍  bus|                                     │
├────────────────────────────────────────────┤
│  MAIN                                        │
│    ● wave changes                  running   │
│    ● misc.                            idle   │
│  BUSTA                                       │
│    ● 4.6 review                 needs input  │
├────────────────────────────────────────────┤
│  ↵ jump      ↑↓ / j k move      esc close    │
└────────────────────────────────────────────┘
```

- **Search** — type to fuzzy-filter across projects and tabs.
- **Navigate** — `↑`/`↓`, `Ctrl+n`/`Ctrl+p`, or `j`/`k` (when the search box is empty).
- **Jump** — `Enter`. **Dismiss** — `Esc` or click outside.
- **Live status** — each tab shows `running` / `needs input` / `idle` from its
  Wave flag color (see [Live status](#live-status-optional)).

## Requirements

- **macOS**
- **[Wave Terminal](https://waveterm.dev)**
- **[Hammerspoon](https://www.hammerspoon.org)** — the automation runtime this plugs into
  (`brew install --cask hammerspoon`)
- `sqlite3` — already built into macOS (no `jq` or other dependencies)

## Install

Clone and run the installer (works with your existing gitlab.mitre.org SSH access):

```sh
git clone git@gitlab.mitre.org:mdoyle/wave-switcher.git
cd wave-switcher
./install.sh
```

The installer copies the Spoon into `~/.hammerspoon/Spoons/`, adds three lines to
your `~/.hammerspoon/init.lua`, and reloads Hammerspoon. It won't touch anything
if Hammerspoon isn't installed (`brew install --cask hammerspoon`).

<details>
<summary>One-line <code>curl | sh</code> install</summary>

```sh
curl -fsSL https://gitlab.mitre.org/mdoyle/wave-switcher/-/raw/main/install.sh | sh
```

This only works if you can fetch the repo's raw files unauthenticated — i.e. the
project is **public**. For an **internal** project an unauthenticated `curl` is
redirected to the login page, so use the clone method above instead.
</details>

Then, **once**:

1. Grant Hammerspoon Accessibility permission (needed to send keystrokes):
   **System Settings → Privacy & Security → Accessibility → enable Hammerspoon**.
2. Focus Wave Terminal and press **`Ctrl+K`**.

### Manual install

Copy `WaveSwitcher.spoon` into `~/.hammerspoon/Spoons/`, then add to `~/.hammerspoon/init.lua`:

```lua
hs.loadSpoon("WaveSwitcher")
spoon.WaveSwitcher:bindHotkeys({ open = {{"ctrl"}, "k"} })
spoon.WaveSwitcher:start()
```

Reload Hammerspoon (menu-bar icon → *Reload Config*).

## Configuration

Change the hotkey by editing the `bindHotkeys` line, e.g. `Cmd+K`:

```lua
spoon.WaveSwitcher:bindHotkeys({ open = {{"cmd"}, "k"} })
```

## Live status (optional)

The status dot/pill for each tab is read from that tab's **Wave flag color**
(`tab:flagcolor`). WaveSwitcher maps:

| Flag color | Status        |
|------------|---------------|
| `#4a9eff`  | running       |
| `#e0b956`  | needs input   |
| `#58c142`  | idle          |
| (none)     | — (no status) |

Any workflow that sets those flags will light up the picker. If you run
[Claude Code](https://claude.com/claude-code) in Wave, add these hooks to
`~/.claude/settings.json` to keep the flags in sync automatically (requires
Wave's `wsh` CLI on your `PATH`):

```json
{
  "hooks": {
    "SessionStart":     [{ "matcher": "", "hooks": [{ "type": "command", "command": "wsh setmeta -b tab \"tab:flagcolor=#58c142\"" }] }],
    "UserPromptSubmit": [{ "matcher": "", "hooks": [{ "type": "command", "command": "wsh setmeta -b tab \"tab:flagcolor=#4a9eff\"" }] }],
    "Stop":             [{ "matcher": "", "hooks": [{ "type": "command", "command": "wsh setmeta -b tab \"tab:flagcolor=#58c142\"" }] }],
    "Notification": [
      { "matcher": "permission_prompt", "hooks": [{ "type": "command", "command": "wsh setmeta -b tab \"tab:flagcolor=#e0b956\"" }] },
      { "matcher": "elicitation_dialog", "hooks": [{ "type": "command", "command": "wsh setmeta -b tab \"tab:flagcolor=#e0b956\"" }] }
    ],
    "PreToolUse": [
      { "matcher": "AskUserQuestion", "hooks": [{ "type": "command", "command": "wsh setmeta -b tab \"tab:flagcolor=#e0b956\"" }] }
    ]
  }
}
```

## How it works

- **Listing** — `wave-sessions.sh` reads Wave's own SQLite state DB
  (`~/Library/Application Support/waveterm/db/waveterm.db`) **read-only** and emits
  the workspaces and their tabs as JSON. Pure `sqlite3`; nothing is written.
- **Jumping** — the target **workspace is selected by name** through Wave's
  *Workspace* application menu (robust, and not limited to 9), then the **tab is
  selected with Wave's native `Cmd+<n>`** shortcut.
- **Focus** — the popup is a render-only `hs.webview` that never takes keyboard
  focus, so Wave stays the key window (required for `Cmd+<n>` to register). Input
  is handled by a Hammerspoon event-tap.

## Limitations

- macOS only (it drives Wave's macOS app menu and native shortcuts).
- Tab switching uses `Cmd+1..9`, so the 10th+ tab in a single workspace isn't
  directly reachable. Workspaces have no such limit (selected by name).
- Status reflects Wave flag colors; without a workflow that sets them, tabs show `—`.

## Uninstall

```sh
rm -rf ~/.hammerspoon/Spoons/WaveSwitcher.spoon
```

Then remove the three `WaveSwitcher` lines from `~/.hammerspoon/init.lua` and
reload Hammerspoon.

## License

[MIT](LICENSE)
