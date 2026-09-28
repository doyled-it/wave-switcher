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
--- Homepage: https://gitlab.mitre.org/mdoyle/wave-switcher

local obj = {}
obj.__index = obj

-- Metadata
obj.name = "WaveSwitcher"
obj.version = "1.0.0"
obj.author = "mdoyle"
obj.homepage = "https://gitlab.mitre.org/mdoyle/wave-switcher"
obj.license = "MIT - https://opensource.org/licenses/MIT"

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------
local WAVE_BUNDLE = "dev.commandline.waveterm"

-- Resolve the data script that sits next to this file inside the Spoon.
local scriptDir = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local LIST_SCRIPT = scriptDir .. "wave-sessions.sh"

-- Query one scalar from Wave's SQLite state DB (read-only). Callers only pass
-- UUIDs into the query, so no escaping is needed.
local DB_PATH = os.getenv("HOME") .. "/Library/Application Support/waveterm/db/waveterm.db"
local WSH = os.getenv("HOME") .. "/Library/Application Support/waveterm/bin/wsh"
local function sqlite1(query)
  local out = hs.execute("/usr/bin/sqlite3 'file:" .. DB_PATH .. "?mode=ro' \"" .. query .. "\"")
  if not out then return nil end
  out = out:gsub("%s+$", "")
  return out ~= "" and out or nil
end

-- Layout metrics (points)
local CARD_W   = 620
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
local function loadEntries()
  local out, ok = hs.execute("'" .. LIST_SCRIPT .. "'", true) -- login shell (PATH)
  if not ok or not out or out == "" then return {} end
  local data = hs.json.decode(out)
  if type(data) ~= "table" then return {} end
  local entries = {}
  for _, e in ipairs(data) do
    entries[#entries + 1] = {
      ws = e.ws, tab = e.tab,
      wsName = e.wsName or "?",
      tabName = e.tabName or "?",
      status = e.status or "—",
      color = e.color or "#888888",
      current = e.current == 1,
      tabId = e.tabId,
      pinned = e.pinned == 1,
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
<style>
  :root{
    color-scheme: dark;
    --bg:#181a1e; --text:#f2f3f5; --muted:#9aa1ac; --dim:#dfe2e7;
    --border:rgba(255,255,255,.10); --accent:#4a9eff; --sel:rgba(74,158,255,.16);
    --run:#4a9eff; --sub:#a970ff; --need:#e0b956; --idle:#58c142; --none:#6b7280;
    --run-bg:rgba(74,158,255,.15); --sub-bg:rgba(169,112,255,.16); --need-bg:rgba(224,185,86,.16);
    --idle-bg:rgba(88,193,66,.16); --none-bg:rgba(120,130,140,.14);
    --shadow:0 24px 70px rgba(0,0,0,.55), 0 2px 8px rgba(0,0,0,.4);
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
  .row{display:flex;align-items:center;gap:11px;height:42px;padding:0 12px 0 24px;
    border-radius:10px;position:relative;}
  .row .bar{position:absolute;left:6px;top:50%;transform:translateY(-50%);width:3px;height:0;
    border-radius:2px;background:var(--accent);transition:height .12s ease;}
  .row.sel{background:var(--sel);}
  .row.sel .bar{height:56%;}
  .dot{width:10px;height:10px;border-radius:50%;flex:none;}
  .name{flex:1;min-width:0;font-size:14.5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}
  .pill{flex:none;font-size:10.5px;font-weight:700;letter-spacing:.4px;text-transform:uppercase;
    padding:3px 9px;border-radius:999px;}
  .empty{padding:26px 18px;text-align:center;color:var(--muted);font-size:13px;}
  .footer{flex:none;display:flex;gap:16px;align-items:center;padding:0 18px;height:42px;
    border-top:1px solid var(--border);color:var(--muted);font-size:11px;}
  .footer .k{display:inline-flex;gap:5px;align-items:center;}
  kbd{font-family:inherit;font-size:10.5px;color:var(--dim);background:rgba(255,255,255,.07);
    border:1px solid var(--border);border-radius:5px;padding:1px 6px;min-width:16px;text-align:center;}
  .st-running{color:var(--run);background:var(--run-bg)} .dot.running{background:var(--run)}
  .st-sub{color:var(--sub);background:var(--sub-bg)} .dot.sub{background:var(--sub)}
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
      <span class="k"><kbd>esc</kbd> close</span>
    </div>
  </div>
<script>
  var listEl = document.getElementById('list');
  var qEl = document.getElementById('q');
  var STATUS = {
    "running":     {cls:"running", pill:"st-running", label:"running"},
    "subagents":   {cls:"sub",     pill:"st-sub",     label:"subagents"},
    "needs input": {cls:"needs",   pill:"st-needs",   label:"needs input"},
    "idle":        {cls:"idle",    pill:"st-idle",    label:"idle"},
  };
  function statusOf(s){ return STATUS[s] || {cls:"none", pill:"st-none", label:s||"—"}; }
  function esc(s){ return String(s).replace(/[&<>"]/g, function(c){
    return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]; }); }

  // Called from Hammerspoon on every keystroke. rows: filtered list; sel: 0-based.
  window.setData = function(rows, sel, query){
    qEl.innerHTML = (query && query.length)
      ? esc(query) + '<span class="caret"></span>'
      : '<span class="ph">Jump to a work stream…</span><span class="caret"></span>';
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
      var label = e.pinned ? (esc(e.wsName)+' <span class="sep">›</span> '+esc(e.tabName)) : esc(e.tabName);
      html += '<div class="row'+(ri===sel?' sel':'')+'" data-r="'+ri+'"><span class="bar"></span>'
            +   '<span class="dot '+st.cls+'"></span>'
            +   '<span class="name">'+label+'</span>'
            +   '<span class="pill '+st.pill+'">'+esc(st.label)+'</span></div>';
      ri++;
    }
    listEl.innerHTML = html;
    var s = listEl.querySelector('.row.sel');
    if(s) s.scrollIntoView({block:'nearest'});
  };
  // First paint from embedded data, so it shows before any JS is injected.
  var DATA = /*__DATA__*/[];
  window.setData(DATA, /*__SEL__*/0, "");
</script>
</body></html>
]==]

--------------------------------------------------------------------------------
-- Picker state + lifecycle
--------------------------------------------------------------------------------
local webview, keyTap, mouseTap, renderTimer
local hotkey, watcher
local P = { entries = {}, filtered = {}, query = "", sel = 1, dirty = false }
local close, selectCurrent, open, togglePin -- forward decls

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
                        status = e.status, color = e.color, pinned = e.pinned }
  end
  return hs.json.encode(rows)
end

local function refilter()
  local q = P.query:lower()
  -- Partition into pinned-first, preserving data order within each group, so the
  -- Lua selection index matches the display order (pinned shown first).
  local pinned, rest = {}, {}
  for _, e in ipairs(P.entries) do
    if q == "" or (e.wsName .. " " .. e.tabName .. " " .. e.status):lower():find(q, 1, true) then
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
  local js = "window.setData(" .. rowsJson(P.filtered) .. "," .. (P.sel - 1)
           .. "," .. jsStr(P.query) .. ")"
  webview:evaluateJavaScript(js, function() end)
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
  -- Persist to Wave (survives restarts) ...
  hs.execute("'" .. WSH .. "' setmeta -b " .. e.tabId ..
             " 'waveswitcher:pin=" .. (newPinned and "1" or "") .. "'")
  -- ... and update in memory immediately so the reorder is instant.
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

local function handleKey(e)
  local flags = e:getFlags()
  local key = hs.keycodes.map[e:getKeyCode()]

  if key == "escape" or (flags.ctrl and key == "k") then
    hs.timer.doAfter(0, close); return true
  end
  if key == "return" or key == "padenter" then
    hs.timer.doAfter(0, selectCurrent); return true
  end
  if key == "down" or (flags.ctrl and key == "n") then moveSel(1); return true end
  if key == "up" or (flags.ctrl and key == "p") then moveSel(-1); return true end
  if key == "tab" then hs.timer.doAfter(0, togglePin); return true end
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
    { title = title, subTitle = sub, withdrawAfter = 0 }):send()
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
