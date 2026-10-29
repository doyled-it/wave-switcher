-- Pure-logic tests for the status overlay. Run via tests/overlay_test.sh
-- under standalone lua (never the live Hammerspoon). WSW_SPOON_INIT = init.lua path.
hs = { configdir = os.getenv("HOME") .. "/.hammerspoon" }
local loaded, obj = pcall(dofile, os.getenv("WSW_SPOON_INIT"))
if not loaded then
  print("FAIL - could not load init.lua: " .. tostring(obj))
  os.exit(1)
end
local T = obj._test
local ok, bad = 0, 0

local function deepEq(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do if not deepEq(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

local function show(v)
  if type(v) ~= "table" then return tostring(v) end
  local parts = {}
  for k, x in pairs(v) do parts[#parts + 1] = tostring(k) .. "=" .. show(x) end
  table.sort(parts)
  return "{" .. table.concat(parts, ",") .. "}"
end

local function eq(name, got, want)
  if deepEq(got, want) then ok = ok + 1
  else bad = bad + 1; print("FAIL - " .. name .. ": got " .. show(got) .. " want " .. show(want)) end
end

local function ids(list)
  local out = {}
  for i, e in ipairs(list) do out[i] = e.tabId end
  return out
end

if not T then
  print("FAIL - obj._test is not defined")
else
  -- pinSet
  eq("pinSet on",  T.pinSet({}, "t1", true),  { t1 = true })
  eq("pinSet off", T.pinSet({ t1 = true }, "t1", false), {})
  eq("pinSet stale off no-op", T.pinSet({}, "gone", false), {})
  -- flagSet / flagClear
  eq("flagSet note", T.flagSet({}, "t1", "later"), { t1 = "later" })
  eq("flagSet empty", T.flagSet({}, "t1", nil), { t1 = "" })
  eq("flagClear", T.flagClear({ t1 = "x" }, "t1"), {})
  eq("flagClear stale no-op", T.flagClear({}, "gone"), {})
  -- view ordering
  eq("statusRank order", T.statusRank("needs input") < T.statusRank("idle"), true)
  eq("orderWorkspace empty", T.orderWorkspace({}), {})
  local es = { {tabId="a",ws="1",pinned=false}, {tabId="b",ws="2",pinned=true} }
  eq("orderWorkspace pinned-first ids", ids(T.orderWorkspace(es)), { "b", "a" })
  local ts = { {tabId="i",status="idle"}, {tabId="r",status="running"} }
  eq("orderTriage by rank", ids(T.orderTriage(ts)), { "r", "i" })
  local us = { {tabId="u",status="—"}, {tabId="r",status="running"} }
  eq("orderTriage unknown last", ids(T.orderTriage(us)), { "r", "u" })
  local st = { {tabId="1",status="idle"}, {tabId="2",status="idle"}, {tabId="3",status="idle"}, {tabId="4",status="idle"}, {tabId="5",status="idle"}, {tabId="6",status="idle"}, {tabId="7",status="idle"}, {tabId="8",status="idle"}, {tabId="9",status="idle"}, {tabId="10",status="idle"}, {tabId="11",status="idle"}, {tabId="12",status="idle"}, {tabId="13",status="idle"}, {tabId="14",status="idle"}, {tabId="15",status="idle"}, {tabId="16",status="idle"}, {tabId="17",status="idle"}, {tabId="18",status="idle"} }
  local want = {}
  for i, e in ipairs(st) do want[i] = e.tabId end
  eq("orderTriage stable ties", ids(T.orderTriage(st)), want)
  local ps = { {tabId="a",pinned=true}, {tabId="b"}, {tabId="c",pinned=true}, {tabId="d"} }
  eq("orderWorkspace stable", ids(T.orderWorkspace(ps)), { "a", "c", "b", "d" })
  local ss = { {tabId="cur",ws="9",current=true}, {tabId="x",ws="9"}, {tabId="y",ws="3"} }
  eq("sameWs true",  T.sameWs(ss, "x"), true)
  eq("sameWs false", T.sameWs(ss, "y"), false)
  eq("sameWs stale", T.sameWs(ss, "gone"), false)
  -- canonical status colors
  eq("STATUS_COLORS running", T.STATUS_COLORS["running"], "#4a9eff")
  eq("STATUS_COLORS subagents", T.STATUS_COLORS["subagents"], "#a970ff")
  eq("STATUS_COLORS shell", T.STATUS_COLORS["shell"], "#20c4b0")
  eq("STATUS_COLORS compacting", T.STATUS_COLORS["compacting"], "#e86f9e")
  eq("STATUS_COLORS needs input", T.STATUS_COLORS["needs input"], "#e0b956")
  eq("STATUS_COLORS idle", T.STATUS_COLORS["idle"], "#58c142")
  local css = T.statusVarsCss()
  for _, d in ipairs({
    "--run:#4a9eff;", "--run-bg:rgba(74,158,255,.15);",
    "--sub:#a970ff;", "--sub-bg:rgba(169,112,255,.16);",
    "--shell:#20c4b0;", "--shell-bg:rgba(32,196,176,.16);",
    "--compact:#e86f9e;", "--compact-bg:rgba(232,111,158,.16);",
    "--need:#e0b956;", "--need-bg:rgba(224,185,86,.16);",
    "--idle:#58c142;", "--idle-bg:rgba(88,193,66,.16);",
    "--none:#6b7280;", "--none-bg:rgba(120,130,140,.14);",
  }) do
    eq("statusVarsCss has " .. d, css:find(d, 1, true) ~= nil, true)
  end
end

do
  local L = { {tabId="t1",pinned=false,flagged=false} }
  T.applyPinList(L, "t1", true);   eq("applyPinList sets", L[1].pinned, true)
  T.applyPinList(L, "gone", true); eq("applyPinList stale no-op", #L, 1)
  T.applyFlagList(L, "t1", "n");   eq("applyFlagList flagged", L[1].flagged, true)
  eq("applyFlagList note", L[1].note, "n")
  T.applyFlagList(L, "gone", "x"); eq("applyFlagList stale no-op", L[1].note, "n")
  T.clearFlagList(L, "t1");        eq("clearFlagList flagged", L[1].flagged, false)
  eq("clearFlagList note", L[1].note, nil)
  T.clearFlagList(L, "gone");      eq("clearFlagList stale no-op", #L, 1)
end

do
  eq("clampHeight within range", T.clampHeight(400, 1000), 400)
  eq("clampHeight capped at 70% of screen", T.clampHeight(900, 1000), 700)
  eq("clampHeight floor", T.clampHeight(50, 1000), 160)
  eq("clampHeight tiny screen keeps floor", T.clampHeight(500, 100), 160)
  eq("clampHeight non-number content", T.clampHeight(nil, 1000), 160)
end

do
  local d = T.overlaySettings(nil)
  eq("overlaySettings nil -> defaults", d,
    { showBranch = true, showTime = true, showUsage = true, showPill = true, compact = false })
  eq("overlaySettings partial override", T.overlaySettings({ compact = true, showTime = false }),
    { showBranch = true, showTime = false, showUsage = true, showPill = true, compact = true })
  eq("overlaySettings explicit false kept", T.overlaySettings({ showBranch = false }).showBranch, false)
  eq("overlaySettings ignores unknown/non-boolean",
    T.overlaySettings({ bogus = true, showPill = "yes" }),
    { showBranch = true, showTime = true, showUsage = true, showPill = true, compact = false })
end

if bad == 0 and T then print("ALL PASS") end
