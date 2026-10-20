--- === WaveSwitcher ===
---
--- A Ctrl+K "work-stream switcher" for Wave Terminal (https://waveterm.dev).
---
--- Pops up a searchable, keyboard-driven palette of your Wave tabs grouped by
--- workspace (project), each with a live status dot (running / needs input /
--- idle). Selecting one jumps straight to that workspace + tab.
---
--- How it works: workspaces/tabs are read from Wave's own SQLite state DB
--- (read-only, sqlite3 only). Jumping selects the workspace BY NAME via Wave's
--- "Workspace" app menu, then the tab with Wave's native Cmd+<n> shortcut. The
--- popup never takes keyboard focus, so Wave stays the key window (required for
--- Cmd+<n> to register). The hotkey is only active while Wave is frontmost.
---
--- Status colors come from each tab's Wave "flag color". See the README for an
--- optional Claude Code hook setup that keeps those flags in sync automatically.
---
--- Homepage: https://github.com/doyled-it/wave-switcher

local obj = {}
obj.__index = obj

-- Metadata
obj.name = "WaveSwitcher"
obj.version = "1.1.0"
obj.author = "mdoyle"
obj.homepage = "https://github.com/doyled-it/wave-switcher"
obj.license = "MIT - https://opensource.org/licenses/MIT"

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------
local WAVE_BUNDLE = "dev.commandline.waveterm"

-- Resolve the data script that sits next to this file inside the Spoon.
local scriptDir = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local LIST_SCRIPT = scriptDir .. "wave-sessions.sh"
local USAGE_SCRIPT = scriptDir .. "wave-usage.sh"
local GITINFO_SCRIPT = scriptDir .. "wave-gitinfo.sh"
local THEMES_FILE = scriptDir .. "wave-termthemes.json"
local WAVE_SETTINGS = os.getenv("HOME") .. "/.config/waveterm/settings.json"

-- Query one scalar from Wave's SQLite state DB (read-only). Callers only pass
-- UUIDs into the query, so no escaping is needed.
local DB_PATH = os.getenv("HOME") .. "/Library/Application Support/waveterm/db/waveterm.db"

-- Pins and follow-up flags are switcher concepts, each stored in our own JSON
-- file keyed by tab id. We can't use `wsh` for this: it refuses to run outside a
-- Wave block (no WAVETERM_JWT in Hammerspoon's context). Pins map tabId -> true;
-- follow-ups map tabId -> note string ("" = flagged with no note).
local PIN_FILE      = hs.configdir .. "/waveswitcher-pins.json"
local FOLLOWUP_FILE = hs.configdir .. "/waveswitcher-followups.json"
local function readJsonMap(path)
  local f = io.open(path, "r")
  if not f then return {} end
  local s = f:read("*a"); f:close()
  local ok, t = pcall(hs.json.decode, s)
  return (ok and type(t) == "table") and t or {}
end
local function writeJsonMap(path, t)
  local f = io.open(path, "w")
  if not f then return end
  f:write(hs.json.encode(t)); f:close()
end
local function readPins()        return readJsonMap(PIN_FILE) end
local function writePins(t)      writeJsonMap(PIN_FILE, t) end
local function readFollowups()   return readJsonMap(FOLLOWUP_FILE) end
local function writeFollowups(t) writeJsonMap(FOLLOWUP_FILE, t) end
local function sqlite1(query)
  local out = hs.execute("/usr/bin/sqlite3 'file:" .. DB_PATH .. "?mode=ro' \"" .. query .. "\"")
  if not out then return nil end
  out = out:gsub("%s+$", "")
  return out ~= "" and out or nil
end

--------------------------------------------------------------------------------
-- Theme matching: adopt the user's Wave terminal theme for the popup chrome.
-- Only applies when the user has explicitly set `term:theme` in Wave's settings;
-- otherwise we keep the hand-tuned default palette. Status colors stay fixed
-- (they map to the Wave flag colors). Palette derivation mirrors wavecrest.
--------------------------------------------------------------------------------
local function readFileText(path)
  local f = io.open(path, "r"); if not f then return nil end
  local s = f:read("*a"); f:close(); return s
end
local function hexRgb(h)
  if type(h) ~= "string" then return nil end
  local r, g, b = h:match("^#?(%x%x)(%x%x)(%x%x)$")
  if not r then return nil end
  return tonumber(r, 16), tonumber(g, 16), tonumber(b, 16)
end
local function rgba(h, a)
  local r, g, b = hexRgb(h)
  if not r then return nil end
  return string.format("rgba(%d,%d,%d,%s)", r, g, b, a)
end

-- Returns a chrome palette table, or nil to keep the defaults.
local function readWaveTheme()
  local settings = readFileText(WAVE_SETTINGS)
  if not settings then return nil end
  local okS, s = pcall(hs.json.decode, settings)
  if not okS or type(s) ~= "table" then return nil end
  local key = s["term:theme"]
  if type(key) ~= "string" or key == "" then return nil end -- no explicit theme
  local themesRaw = readFileText(THEMES_FILE)
  if not themesRaw then return nil end
  local okT, themes = pcall(hs.json.decode, themesRaw)
  if not okT or type(themes) ~= "table" then return nil end
  local t = themes[key]
  if type(t) ~= "table" then return nil end
  local bg = t.background
  local fg = t.foreground or t.cmdtext or t.white
  if not (bg and fg) then return nil end
  local accent = t.brightBlue or t.blue or t.cyan or fg
  local muted  = t.gray or t.brightBlack or t.black or fg
  return {
    bg = bg, text = fg, dim = fg, muted = muted, accent = accent,
    border = rgba(fg, "0.14") or "rgba(255,255,255,.10)",
    sel    = rgba(accent, "0.18") or "rgba(74,158,255,.16)",
  }
end

-- CSS `:root` override string for the active Wave theme ("" keeps the defaults).
local function themeCss()
  local p = readWaveTheme()
  if not p then return "" end
  return "--bg:" .. p.bg .. ";--text:" .. p.text .. ";--dim:" .. p.dim
      .. ";--muted:" .. p.muted .. ";--accent:" .. p.accent
      .. ";--border:" .. p.border .. ";--sel:" .. p.sel .. ";"
end

-- Layout metrics (points)
local CARD_W   = 720
local PAD      = 28
local HEADER_H = 58
local FOOTER_H = 42
local ROW_H    = 42
local GROUP_H  = 30
local LIST_PAD = 16
local MAX_ROWS = 9
local TOP_FRAC = 0.15

--------------------------------------------------------------------------------
-- Data
--------------------------------------------------------------------------------
-- Git branch/worktree per cwd, filled asynchronously (git is too slow to run on
-- the open path). Keyed by cwd -> { branch, worktree }. Seeds instant repaints
-- on reopen; refreshed in the background each open.
local gitCache = {}

local function loadEntries()
  local out, ok = hs.execute("'" .. LIST_SCRIPT .. "'", true) -- login shell (PATH)
  if not ok or not out or out == "" then return {} end
  local data = hs.json.decode(out)
  if type(data) ~= "table" then return {} end
  local pins = readPins()
  local followups = readFollowups()
  local entries = {}
  for _, e in ipairs(data) do
    local note = e.tabId ~= nil and followups[e.tabId] or nil
    local git = e.cwd and gitCache[e.cwd] or nil
    entries[#entries + 1] = {
      ws = e.ws, tab = e.tab,
      wsName = e.wsName or "?",
      tabName = e.tabName or "?",
      status = e.status or "—",
      color = e.color or "#888888",
      current = e.current == 1,
      tabId = e.tabId,
      cwd = e.cwd,
      activity = e.activity, -- epoch seconds, or nil
      branch = git and git.branch or nil,
      worktree = git and git.worktree or false,
      pinned = e.tabId ~= nil and pins[e.tabId] == true,
      flagged = note ~= nil,
      note = note,
    }
  end
  return entries
end

--------------------------------------------------------------------------------
-- Switch action: workspace by name (menu), tab by number (native key)
--------------------------------------------------------------------------------
local function switchTo(wsName, tab, sameWs)
  local app = hs.application.get(WAVE_BUNDLE)
  if not app then return end

  local function sendTab()
    if tab and tab >= 1 and tab <= 9 then
      hs.eventtap.keyStroke({ "cmd" }, tostring(tab)) -- default key delay (a 0 gets dropped)
    end
  end

  if sameWs then
    -- Same workspace, and Wave is already the key window (the popup never takes
    -- focus), so just switch the tab — no menu, minimal delay.
    hs.timer.doAfter(0.02, sendTab)
  else
    -- Cross-workspace: select the workspace by name, then let it settle before
    -- the tab key (the new workspace's tab bar needs a moment to be ready).
    app:activate(true)
    if wsName then app:selectMenuItem({ "Workspace", wsName }) end
    hs.timer.doAfter(0.15, sendTab)
  end
end

--------------------------------------------------------------------------------
-- HTML (pure renderer: window.setData(rows, sel, query) draws everything)
--------------------------------------------------------------------------------
local HTML = [==[
<!doctype html>
<html><head><meta charset="utf-8">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Space+Mono:wght@400;700&display=swap">
<style>
  :root{
    color-scheme: dark;
    --bg:#181a1e; --text:#f2f3f5; --muted:#9aa1ac; --dim:#dfe2e7;
    --border:rgba(255,255,255,.10); --accent:#4a9eff; --sel:rgba(74,158,255,.16); --flag:#ffb454;
    --run:#4a9eff; --sub:#a970ff; --shell:#20c4b0; --compact:#e86f9e; --need:#e0b956; --idle:#58c142; --none:#6b7280;
    --run-bg:rgba(74,158,255,.15); --sub-bg:rgba(169,112,255,.16); --shell-bg:rgba(32,196,176,.16);
    --compact-bg:rgba(232,111,158,.16); --need-bg:rgba(224,185,86,.16);
    --idle-bg:rgba(88,193,66,.16); --none-bg:rgba(120,130,140,.14);
    --shadow:0 24px 70px rgba(0,0,0,.55), 0 2px 8px rgba(0,0,0,.4);
    --fun-mono:"Space Mono",ui-monospace,"SF Mono",Menlo,monospace;
    /*__THEME__*/
  }
  *{box-sizing:border-box;margin:0;padding:0}
  html,body{height:100%;background:transparent;
    font-family:-apple-system,"SF Pro Text","Helvetica Neue",Arial,sans-serif;
    -webkit-font-smoothing:antialiased;color:var(--text);}
  body{padding:28px;}
  .card{height:100%;display:flex;flex-direction:column;overflow:hidden;
    background:var(--bg);border:1px solid var(--border);border-radius:16px;
    box-shadow:var(--shadow);animation:pop .13s cubic-bezier(.2,.7,.3,1);}
  @keyframes pop{from{opacity:0;transform:scale(.985) translateY(-6px)}to{opacity:1;transform:none}}
  @media (prefers-reduced-motion:reduce){.card{animation:none}}
  .search{display:flex;align-items:center;gap:11px;padding:0 18px;height:58px;flex:none;}
  .search svg{width:18px;height:18px;color:var(--muted);flex:none;opacity:.85}
  .q{flex:1;font-size:18px;letter-spacing:.1px;white-space:nowrap;overflow:hidden;}
  .q .caret{display:inline-block;width:1.5px;height:20px;background:var(--accent);
    vertical-align:-4px;margin-left:1px;animation:blink 1.1s steps(1) infinite;}
  @keyframes blink{50%{opacity:0}}
  .q .ph{color:var(--muted);}
  .divider{height:1px;background:var(--border);margin:0 14px;flex:none;}
  .list{flex:1;overflow-y:auto;padding:6px 8px 10px;}
  .list::-webkit-scrollbar{width:9px}
  .list::-webkit-scrollbar-thumb{background:rgba(255,255,255,.14);border-radius:5px;border:2px solid transparent;background-clip:content-box}
  .group{display:flex;align-items:center;gap:8px;height:30px;padding:0 12px 0 10px;
    font-size:11px;font-weight:700;letter-spacing:.6px;text-transform:uppercase;color:var(--muted);}
  .group .wsdot{width:8px;height:8px;border-radius:2px;flex:none;}
  .group.pinned{color:var(--accent);}
  .group .pinicon{font-size:11px;line-height:1;}
  .name .sep{color:var(--muted);margin:0 2px;}
  .name .ws{font-weight:600;}
  .flag{color:var(--flag);font-size:13px;line-height:1;flex:none;}
  .noteprompt{color:var(--flag);font-weight:600;}
  .row{display:flex;align-items:center;gap:10px;height:42px;padding:0 12px 0 20px;
    border-radius:10px;position:relative;}
  .row .bar{position:absolute;left:6px;top:50%;transform:translateY(-50%);width:3px;height:0;
    border-radius:2px;background:var(--accent);transition:height .12s ease;}
  .row.sel{background:var(--sel);}
  .row.sel .bar{height:56%;}
  .dot{width:10px;height:10px;border-radius:50%;flex:none;}
  .lead{flex:1;min-width:0;display:flex;align-items:center;gap:7px;overflow:hidden;}
  .name{min-width:0;flex:0 1 auto;font-size:14.5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}
  .note{min-width:0;flex:0 1 auto;color:var(--muted);font-size:12.5px;opacity:.9;font-style:italic;
    white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}
  .chip{flex:none;display:inline-flex;align-items:center;gap:5px;max-width:230px;
    font-family:var(--fun-mono);font-size:11.5px;font-weight:700;letter-spacing:-.2px;color:var(--dim);
    background:rgba(128,128,128,.14);border:1px solid var(--border);border-radius:6px;
    padding:1px 8px 1px 6px;white-space:nowrap;}
  .chip .gi{width:12px;height:12px;flex:none;color:var(--accent);opacity:.95}
  .chip .bn{min-width:0;overflow:hidden;text-overflow:ellipsis}
  .chip.wt{color:var(--shell)}
  .chip.wt .gi{color:var(--shell)}
  .rightmeta{flex:none;display:flex;align-items:center;gap:9px;}
  .time{flex:none;font-family:ui-monospace,"SF Mono",Menlo,monospace;font-size:11px;color:var(--muted);
    opacity:.7;font-variant-numeric:tabular-nums;}
  .pill{flex:none;font-size:10.5px;font-weight:700;letter-spacing:.4px;text-transform:uppercase;
    padding:3px 9px;border-radius:999px;}
  .empty{padding:26px 18px;text-align:center;color:var(--muted);font-size:13px;}
  .footer{flex:none;display:flex;gap:16px;align-items:center;padding:0 18px;height:42px;
    border-top:1px solid var(--border);color:var(--muted);font-size:11px;}
  .footer .k{display:inline-flex;gap:5px;align-items:center;}
  kbd{font-family:inherit;font-size:10.5px;color:var(--dim);background:rgba(255,255,255,.07);
    border:1px solid var(--border);border-radius:5px;padding:1px 6px;min-width:16px;text-align:center;}
  .usage{margin-left:auto;display:flex;align-items:center;gap:7px;font-size:11px;
    color:var(--muted);font-variant-numeric:tabular-nums;}
  .usage .useg{display:inline-flex;gap:4px;} .usage .useg b{font-weight:600;}
  .usage .ok{color:var(--muted);} .usage .warn{color:var(--need);} .usage .crit{color:#ff5f56;}
  .usage .ureset{color:var(--muted);opacity:.7;margin-left:3px;}
  .usage .udot{opacity:.45;}
  .st-running{color:var(--run);background:var(--run-bg)} .dot.running{background:var(--run)}
  .st-sub{color:var(--sub);background:var(--sub-bg)} .dot.sub{background:var(--sub)}
  .st-shell{color:var(--shell);background:var(--shell-bg)} .dot.shell{background:var(--shell)}
  .st-compact{color:var(--compact);background:var(--compact-bg)} .dot.compact{background:var(--compact)}
  .st-needs{color:var(--need);background:var(--need-bg)} .dot.needs{background:var(--need)}
  .st-idle{color:var(--idle);background:var(--idle-bg)} .dot.idle{background:var(--idle)}
  .st-none{color:var(--none);background:var(--none-bg)} .dot.none{background:var(--none)}
</style></head>
<body>
  <div class="card">
    <div class="search">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round">
        <circle cx="11" cy="11" r="7"></circle><line x1="21" y1="21" x2="16.65" y2="16.65"></line>
      </svg>
      <div class="q" id="q"></div>
    </div>
    <div class="divider"></div>
    <div class="list" id="list"></div>
    <div class="footer">
      <span class="k"><kbd>↵</kbd> jump</span>
      <span class="k"><kbd>↑</kbd><kbd>↓</kbd> / <kbd>j</kbd><kbd>k</kbd> move</span>
      <span class="k"><kbd>⇥</kbd> pin</span>
      <span class="k"><kbd>&#8963;F</kbd> flag</span>
      <span class="k"><kbd>esc</kbd> close</span>
      <span class="usage" id="usage"></span>
    </div>
  </div>
<script>
  var listEl = document.getElementById('list');
  var qEl = document.getElementById('q');
  var STATUS = {
    "running":     {cls:"running", pill:"st-running", label:"running"},
    "subagents":   {cls:"sub",     pill:"st-sub",     label:"subagents"},
    "shell":       {cls:"shell",   pill:"st-shell",   label:"shell"},
    "compacting":  {cls:"compact", pill:"st-compact", label:"compacting"},
    "needs input": {cls:"needs",   pill:"st-needs",   label:"needs input"},
    "idle":        {cls:"idle",    pill:"st-idle",    label:"idle"},
  };
  function statusOf(s){ return STATUS[s] || {cls:"none", pill:"st-none", label:s||"—"}; }
  function esc(s){ return String(s).replace(/[&<>"]/g, function(c){
    return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]; }); }
  // Compact "time in current state" from an epoch-seconds activity stamp.
  function elapsed(sec){
    var s = Math.floor(Date.now()/1000) - sec;
    if(s < 10) return 'now';
    if(s < 60) return s+'s';
    if(s < 3600) return Math.floor(s/60)+'m';
    if(s < 86400) return Math.floor(s/3600)+'h';
    return Math.floor(s/86400)+'d';
  }
  var GITICON = '<svg class="gi" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="6" y1="3" x2="6" y2="15"></line><circle cx="18" cy="6" r="3"></circle><circle cx="6" cy="18" r="3"></circle><path d="M18 9a9 9 0 0 1-9 9"></path></svg>';

  // Called from Hammerspoon on every keystroke. rows: filtered list; sel: 0-based.
  // noteMode/noteText drive the follow-up note-entry input line.
  window.setData = function(rows, sel, query, noteMode, noteText){
    if(noteMode){
      qEl.innerHTML = '<span class="noteprompt">&#9873; Note (optional): </span>'
        + esc(noteText || '') + '<span class="caret"></span>';
    } else {
      qEl.innerHTML = (query && query.length)
        ? esc(query) + '<span class="caret"></span>'
        : '<span class="ph">Jump to a work stream…</span><span class="caret"></span>';
    }
    if(!rows || rows.length === 0){
      listEl.innerHTML = '<div class="empty">No matching work streams</div>';
      return;
    }
    // rows are ordered pinned-first (from Lua). Pinned ones go under a single
    // "PINNED" header showing project › tab; the rest are grouped by project.
    var html = '', curWs = null, pinnedHeaderDone = false, ri = 0;
    for(var i=0;i<rows.length;i++){
      var e = rows[i];
      if(e.pinned){
        if(!pinnedHeaderDone){
          html += '<div class="group pinned"><span class="pinicon">★</span>PINNED</div>';
          pinnedHeaderDone = true; curWs = null;
        }
      } else if(e.ws !== curWs){
        curWs = e.ws;
        html += '<div class="group"><span class="wsdot" style="background:'+esc(e.color)+'"></span>'
              + esc(e.wsName)+'</div>';
      }
      var st = statusOf(e.status);
      // Pinned rows aren't under a project header, so tint the project name to
      // separate projects at a glance (plus a workspace-color chip, below).
      var nameHtml = e.pinned
        ? '<span class="ws" style="color:'+esc(e.color)+'">'+esc(e.wsName)+'</span>'
          + ' <span class="sep">›</span> '+esc(e.tabName)
        : esc(e.tabName);
      var flagicon = e.flagged ? '<span class="flag">&#9873;</span>' : '';
      var wschip = e.pinned
        ? '<span class="wsdot" style="background:'+esc(e.color)+'"></span>' : '';
      // git branch chip (filled in async); teal + worktree label marks a worktree.
      var chip = e.branch
        ? '<span class="chip'+(e.worktree?' wt':'')+'" title="'+(e.worktree?'worktree: ':'branch: ')+esc(e.branch)+'">'
          + GITICON + '<span class="bn">'+esc(e.branch)+'</span></span>'
        : '';
      // follow-up note, dim
      var note = (e.flagged && e.note) ? '<span class="note">'+esc(e.note)+'</span>' : '';
      // time in current state (from the activity stamp)
      var time = e.activity ? '<span class="time">'+elapsed(e.activity)+'</span>' : '';
      html += '<div class="row'+(ri===sel?' sel':'')+'" data-r="'+ri+'"><span class="bar"></span>'
            +   '<span class="dot '+st.cls+'"></span>'
            +   wschip + flagicon
            +   '<span class="lead"><span class="name">'+nameHtml+'</span>'+chip+note+'</span>'
            +   '<span class="rightmeta">'+time+'<span class="pill '+st.pill+'">'+esc(st.label)+'</span></span>'
            +   '</div>';
      ri++;
    }
    listEl.innerHTML = html;
    var s = listEl.querySelector('.row.sel');
    if(s) s.scrollIntoView({block:'nearest'});
  };
  // Subscription usage line (5h session + 7d week). Updated async from Hammerspoon.
  window.setUsage = function(u){
    var el = document.getElementById('usage');
    if(!el) return;
    if(!u || !u.session){ el.innerHTML = ''; return; }
    function fmtReset(iso){
      if(!iso) return '';
      var t = new Date(iso).getTime();
      if(isNaN(t)) return '';
      var s = Math.max(0, Math.round((t - Date.now())/1000));
      var d = Math.floor(s/86400), h = Math.floor((s%86400)/3600), m = Math.floor((s%3600)/60);
      if(d > 0) return d+'d'+h+'h';
      if(h > 0) return h+'h'+m+'m';
      if(m > 0) return m+'m';
      return '<1m';
    }
    function clsFor(s){
      if(s.sev) return s.sev==='critical' ? 'crit' : (s.sev==='warning' ? 'warn' : 'ok');
      return s.util>=90 ? 'crit' : (s.util>=70 ? 'warn' : 'ok'); // fallback thresholds
    }
    function seg(label, s){
      if(!s || s.util==null) return '';
      var r = fmtReset(s.resets);
      return '<span class="useg '+clsFor(s)+'">'+label+' <b>'+Math.round(s.util)+'%</b></span>'
           + (r ? '<span class="ureset" title="until reset">'+r+'</span>' : '');
    }
    var parts = [ seg('5h', u.session), seg('7d', u.week),
                  seg('opus', u.opus), seg('sonnet', u.sonnet) ];
    if(u.credits && u.credits.util != null)
      parts.push('<span class="useg ok">credits <b>'+Math.round(u.credits.util)+'%</b></span>');
    el.innerHTML = parts.filter(Boolean).join('<span class="udot">·</span>');
  };

  // First paint from embedded data, so it shows before any JS is injected.
  var DATA = /*__DATA__*/[];
  window.setData(DATA, /*__SEL__*/0, "");
  var USAGE = /*__USAGE__*/null;
  window.setUsage(USAGE);
</script>
</body></html>
]==]

--------------------------------------------------------------------------------
-- Picker state + lifecycle
--------------------------------------------------------------------------------
local webview, keyTap, mouseTap, renderTimer
local hotkey, watcher
local lastUsage = nil -- cached {session, week, sessionResets, weekResets}
local P = { entries = {}, filtered = {}, query = "", sel = 1, dirty = false }
local close, selectCurrent, open, togglePin, toggleFollowup -- forward decls

-- Encode a Lua string as a JS string literal. (hs.json.encode errors on a bare
-- string — it only accepts tables — so we can't use it for the query.)
local function jsStr(s)
  s = tostring(s or "")
  s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "")
  return '"' .. s .. '"'
end

local function rowsJson(list)
  if #list == 0 then return "[]" end -- hs.json.encode({}) yields "{}", not "[]"
  local rows = {}
  for _, e in ipairs(list) do
    rows[#rows + 1] = { ws = e.ws, wsName = e.wsName, tabName = e.tabName,
                        status = e.status, color = e.color, pinned = e.pinned,
                        flagged = e.flagged, note = e.note,
                        branch = e.branch, worktree = e.worktree, activity = e.activity }
  end
  return hs.json.encode(rows)
end

local function refilter()
  local q = P.query:lower()
  -- Partition into pinned-first, preserving data order within each group, so the
  -- Lua selection index matches the display order (pinned shown first).
  local pinned, rest = {}, {}
  for _, e in ipairs(P.entries) do
    if q == "" or (e.wsName .. " " .. e.tabName .. " " .. e.status .. " " .. (e.note or "") .. " " .. (e.branch or "")):lower():find(q, 1, true) then
      if e.pinned then pinned[#pinned + 1] = e else rest[#rest + 1] = e end
    end
  end
  local out = {}
  for _, e in ipairs(pinned) do out[#out + 1] = e end
  for _, e in ipairs(rest) do out[#out + 1] = e end
  P.filtered = out
  if P.sel > #out then P.sel = #out end
  if P.sel < 1 then P.sel = 1 end
end

-- Rendering must NOT happen inside the key-tap callback: calling
-- evaluateJavaScript there corrupts the WKWebView JS bridge and can get the tap
-- auto-disabled by macOS. The tap only flags P.dirty; a repeating timer created
-- in a clean context applies the render.
local function scheduleRender()
  P.dirty = true
end

local function renderNow()
  if not webview then return end
  local noteArgs = P.noteMode and ("true," .. jsStr(P.noteText or "")) or 'false,""'
  local js = "window.setData(" .. rowsJson(P.filtered) .. "," .. (P.sel - 1)
           .. "," .. jsStr(P.query) .. "," .. noteArgs .. ")"
  webview:evaluateJavaScript(js, function() end)
end

-- Subscription usage (5h session + 7d week %), fetched async and cached.
local function pushUsage()
  if not webview then return end
  local js = "window.setUsage(" .. (lastUsage and hs.json.encode(lastUsage) or "null") .. ")"
  webview:evaluateJavaScript(js, function() end)
end

local function refreshUsage()
  hs.task.new("/bin/zsh", function(_, out)
    if out and out ~= "" then
      local ok, u = pcall(hs.json.decode, out)
      if ok and type(u) == "table" then lastUsage = u; pushUsage() end
    end
  end, { "-lc", USAGE_SCRIPT }):start()
end

-- Async: resolve the git branch/worktree for each tab's cwd and fill it in. Runs
-- off the open path (git is slow); results cache in gitCache and re-render when
-- they land. Entries in P.filtered share table identity with P.entries, so
-- mutating the branch here updates both.
local function refreshGit()
  local seen, cwds = {}, {}
  for _, e in ipairs(P.entries) do
    if e.cwd and not seen[e.cwd] then seen[e.cwd] = true; cwds[#cwds + 1] = e.cwd end
  end
  if #cwds == 0 then return end
  local task = hs.task.new(GITINFO_SCRIPT, function(_, out)
    if not out or out == "" then return end
    local ok, arr = pcall(hs.json.decode, out)
    if not ok or type(arr) ~= "table" then return end
    for _, g in ipairs(arr) do
      if g.cwd then gitCache[g.cwd] = { branch = g.branch, worktree = g.worktree == true } end
    end
    for _, e in ipairs(P.entries) do
      local gi = e.cwd and gitCache[e.cwd] or nil
      if gi then e.branch = gi.branch; e.worktree = gi.worktree end
    end
    if webview then renderNow() end
  end)
  if task then task:setInput(table.concat(cwds, "\n") .. "\n"); task:start() end
end

local function moveSel(d)
  local n = #P.filtered
  if n == 0 then return end
  P.sel = P.sel + d
  if P.sel < 1 then P.sel = n end     -- wrap top -> bottom
  if P.sel > n then P.sel = 1 end     -- wrap bottom -> top
  scheduleRender()
end

-- Toggle the pin on the selected tab. Runs OUTSIDE the key tap (wsh + reload are
-- slow); keeps the selection on the same tab after reordering.
togglePin = function()
  local e = P.filtered[P.sel]
  if not (e and e.tabId) then return end
  local newPinned = not e.pinned
  local pins = readPins()
  pins[e.tabId] = newPinned or nil
  writePins(pins)
  for _, ent in ipairs(P.entries) do
    if ent.tabId == e.tabId then ent.pinned = newPinned end
  end
  local keep = e.tabId
  refilter()
  for i, ent in ipairs(P.filtered) do
    if ent.tabId == keep then P.sel = i; break end
  end
  renderNow()
end

-- Toggle the follow-up flag on the selected tab. Flagging a fresh session drops
-- into note-entry mode so you can optionally type a short reminder; flagging an
-- already-flagged one clears it. Follow-ups don't reorder the list (unlike pins),
-- so the entry is mutated in place (P.filtered holds the same tables as P.entries)
-- and we just re-render. Runs OUTSIDE the key tap.
toggleFollowup = function()
  local e = P.filtered[P.sel]
  if not (e and e.tabId) then return end
  local fups = readFollowups()
  if e.flagged then
    fups[e.tabId] = nil; writeFollowups(fups)
    e.flagged = false; e.note = nil
    renderNow()
  else
    fups[e.tabId] = ""; writeFollowups(fups)
    e.flagged = true; e.note = ""
    P.noteMode = true; P.noteTabId = e.tabId; P.noteText = ""
    renderNow()
  end
end

local function handleKey(e)
  local flags = e:getFlags()
  local key = hs.keycodes.map[e:getKeyCode()]

  -- Note-entry mode: keystrokes build the follow-up note for the just-flagged
  -- tab. Enter saves it; Esc keeps the flag but discards the in-progress text.
  if P.noteMode then
    if key == "return" or key == "padenter" then
      local fups = readFollowups()
      if P.noteTabId then fups[P.noteTabId] = P.noteText or "" end
      writeFollowups(fups)
      for _, ent in ipairs(P.entries) do
        if ent.tabId == P.noteTabId then ent.note = P.noteText or "" end
      end
      P.noteMode = false; P.noteTabId = nil; P.noteText = ""
      scheduleRender(); return true
    end
    if key == "escape" then
      P.noteMode = false; P.noteTabId = nil; P.noteText = ""
      scheduleRender(); return true
    end
    if key == "delete" then -- backspace
      P.noteText = (P.noteText or ""):sub(1, -2); scheduleRender(); return true
    end
    if not (flags.cmd or flags.ctrl or flags.alt) then
      local ch = e:getCharacters(true)
      if ch and #ch >= 1 and ch:byte(1) >= 32 then
        P.noteText = (P.noteText or "") .. ch; scheduleRender(); return true
      end
    end
    return true -- consume everything else while entering a note
  end

  if key == "escape" or (flags.ctrl and key == "k") then
    hs.timer.doAfter(0, close); return true
  end
  if key == "return" or key == "padenter" then
    hs.timer.doAfter(0, selectCurrent); return true
  end
  if key == "down" or (flags.ctrl and key == "n") then moveSel(1); return true end
  if key == "up" or (flags.ctrl and key == "p") then moveSel(-1); return true end
  if key == "tab" then hs.timer.doAfter(0, togglePin); return true end
  if flags.ctrl and key == "f" then hs.timer.doAfter(0, toggleFollowup); return true end
  if key == "delete" then -- backspace
    P.query = P.query:sub(1, -2); P.sel = 1; refilter(); scheduleRender(); return true
  end

  local bare = not (flags.cmd or flags.ctrl or flags.alt)
  if bare and P.query == "" and (key == "j" or key == "k") then
    moveSel(key == "j" and 1 or -1); return true
  end
  if bare then
    local ch = e:getCharacters(true)
    if ch and #ch >= 1 and ch:byte(1) >= 32 then
      P.query = P.query .. ch; P.sel = 1; refilter(); scheduleRender(); return true
    end
  end
  return true -- consume everything while the picker is open
end

open = function()
  P.entries = loadEntries()
  if #P.entries == 0 then
    hs.alert.show("No Wave Terminal work streams found")
    return
  end
  P.query = ""; P.sel = 1
  P.activeWs = nil
  P.noteMode = false; P.noteTabId = nil; P.noteText = ""
  refilter()
  -- Pre-select the tab you came from (the active window's active tab), and note
  -- its workspace so a jump within it can skip the (slower) workspace switch.
  for i, e in ipairs(P.filtered) do
    if e.current then P.sel = i; P.activeWs = e.ws; break end
  end

  local groups, seen, anyPinned = 0, {}, false
  for _, e in ipairs(P.entries) do
    if e.pinned then anyPinned = true
    elseif not seen[e.ws] then seen[e.ws] = true; groups = groups + 1 end
  end
  if anyPinned then groups = groups + 1 end -- the "PINNED" header
  local contentH = #P.entries * ROW_H + groups * GROUP_H + LIST_PAD
  local maxListH = MAX_ROWS * ROW_H + 2 * GROUP_H + LIST_PAD
  local listH = math.min(contentH, maxListH)
  local cardH = HEADER_H + 1 + listH + FOOTER_H
  local wvW = CARD_W + 2 * PAD
  local wvH = cardH + 2 * PAD

  local scr = hs.screen.mainScreen():frame()
  local rect = { x = scr.x + (scr.w - wvW) / 2, y = scr.y + scr.h * TOP_FRAC, w = wvW, h = wvH }

  local html = HTML:gsub("/%*__DATA__%*/%[%]", function() return rowsJson(P.filtered) end)
  html = html:gsub("/%*__SEL__%*/0", function() return tostring(P.sel - 1) end)
  html = html:gsub("/%*__USAGE__%*/null",
    function() return lastUsage and hs.json.encode(lastUsage) or "null" end)
  html = html:gsub("/%*__THEME__%*/", function() return themeCss() end)

  -- render-only webview: no allowTextEntry, never focused -> Wave stays key
  webview = hs.webview.new(rect, { developerExtrasEnabled = false })
  webview:windowStyle(hs.webview.windowMasks.borderless)
  webview:level(hs.canvas.windowLevels.popUpMenu)
  webview:transparent(true)
  webview:shadow(false)
  webview:html(html)
  webview:show()

  -- Render pump (clean context). The key tap sets P.dirty; this applies it.
  P.dirty = false
  renderTimer = hs.timer.new(0.03, function()
    if P.dirty and webview then P.dirty = false; renderNow() end
  end)
  renderTimer:start()

  refreshUsage() -- async; updates the footer usage line when it returns
  refreshGit()   -- async; fills in git branch/worktree per row when it returns

  if hotkey then hotkey:disable() end -- key tap owns the hotkey while open

  keyTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(e)
    local ok, res = pcall(handleKey, e)
    if not ok then
      print("[WaveSwitcher] key error: " .. tostring(res))
      hs.timer.doAfter(0, close)
      return true
    end
    return res
  end)
  keyTap:start()

  mouseTap = hs.eventtap.new({ hs.eventtap.event.types.leftMouseDown }, function()
    if not webview then return false end
    local p = hs.mouse.absolutePosition()
    local f = webview:frame()
    local inside = p.x >= f.x and p.x <= f.x + f.w and p.y >= f.y and p.y <= f.y + f.h
    if not inside then
      close()
      return false -- pass the click through to whatever is underneath
    end
    return true -- swallow clicks on the popup so it never grabs key focus
  end)
  mouseTap:start()
end

selectCurrent = function()
  local e = P.filtered[P.sel]
  local sameWs = e and P.activeWs ~= nil and e.ws == P.activeWs
  -- Jumping to a flagged session clears its follow-up: you've returned to it.
  if e and e.flagged and e.tabId then
    local fups = readFollowups()
    fups[e.tabId] = nil
    writeFollowups(fups)
  end
  close()
  if e then switchTo(e.wsName, e.tab, sameWs) end
end

close = function()
  if renderTimer then renderTimer:stop(); renderTimer = nil end
  if keyTap then keyTap:stop(); keyTap = nil end
  if mouseTap then mouseTap:stop(); mouseTap = nil end
  if webview then webview:delete(); webview = nil end
  local front = hs.application.frontmostApplication()
  if hotkey and front and front:bundleID() == WAVE_BUNDLE then hotkey:enable() end
end

-- Enable the hotkey only while Wave Terminal is frontmost.
local function refresh()
  if not hotkey then return end
  if webview then return end -- don't fight the key tap while the picker is open
  local front = hs.application.frontmostApplication()
  if front and front:bundleID() == WAVE_BUNDLE then
    hotkey:enable()
  else
    hotkey:disable()
  end
end

--------------------------------------------------------------------------------
-- Spoon API
--------------------------------------------------------------------------------

--- WaveSwitcher:bindHotkeys(mapping)
--- Method
--- Binds the hotkey that opens the switcher.
---
--- Parameters:
---  * mapping - a table with an `open` key, e.g.
---              `{ open = {{"ctrl"}, "k"} }`
---
--- Returns:
---  * The WaveSwitcher object
function obj:bindHotkeys(mapping)
  if mapping and mapping.open then self._hotkeySpec = mapping.open end
  return self
end

--- WaveSwitcher:start()
--- Method
--- Starts the switcher: registers the hotkey (default Ctrl+K) and the watcher
--- that keeps it active only while Wave Terminal is frontmost.
---
--- Returns:
---  * The WaveSwitcher object
function obj:start()
  if self._started then return self end
  self._started = true
  local spec = self._hotkeySpec or { { "ctrl" }, "k" }
  hotkey = hs.hotkey.new(spec[1], spec[2], function()
    if webview then close() else open() end
  end)
  watcher = hs.application.watcher.new(refresh)
  watcher:start()
  refresh()
  return self
end

--- WaveSwitcher:notify(wsId, tabId, kind)
--- Method
--- Post a clickable "needs input" notification (via Hammerspoon) that names the
--- workspace and tab; clicking it jumps to that tab. Called from the Claude Code
--- hook. `kind` is "question" for AskUserQuestion, otherwise a permission/input.
---
--- Returns:
---  * The WaveSwitcher object
function obj:notify(wsId, tabId, kind)
  if not wsId or not tabId then return self end
  local wsName  = sqlite1("SELECT json_extract(data,'$.name') FROM db_workspace WHERE json_extract(data,'$.oid')='" .. wsId .. "'")
  local tabName = sqlite1("SELECT json_extract(data,'$.name') FROM db_tab WHERE json_extract(data,'$.oid')='" .. tabId .. "'")
  local idx = tonumber(sqlite1(
    "SELECT je.key+1 FROM db_workspace w, json_each(json_extract(w.data,'$.tabids')) je " ..
    "WHERE json_extract(w.data,'$.oid')='" .. wsId .. "' AND je.value='" .. tabId .. "'"))
  local title = (kind == "question") and "Claude has a question" or "Claude needs your input"
  local sub = (wsName or "?") .. "  \226\128\186  " .. (tabName or "?") -- "  ›  "
  hs.notify.new(function() switchTo(wsName, idx, false) end,
    { title = title, subTitle = sub, withdrawAfter = 6 }):send() -- ephemeral (auto-dismiss)
  return self
end

--- WaveSwitcher:stop()
--- Method
--- Stops the switcher and releases the hotkey and watcher.
---
--- Returns:
---  * The WaveSwitcher object
function obj:stop()
  if watcher then watcher:stop(); watcher = nil end
  if hotkey then hotkey:disable(); hotkey = nil end
  close()
  self._started = false
  return self
end

return obj
