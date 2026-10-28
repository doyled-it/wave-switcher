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
end

if bad == 0 and T then print("ALL PASS") end
