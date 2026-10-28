-- Pure-logic tests for the status overlay. Run via tests/overlay_test.sh
-- (needs Hammerspoon Lua; global WSW_SPOON_INIT = path to init.lua).
-- hs is a separate process, so the path arrives as a Lua global, not an env var.
local obj = dofile(WSW_SPOON_INIT)
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
_ = ids

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
end

if bad == 0 and T then print("ALL PASS") end
