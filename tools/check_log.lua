-- Assert on the machine-readable EV| events written by mod/zzbot.
-- Usage: luajit tools/check_log.lua LOGFILE SPEC [SPEC...]
--
-- SPEC := [!]KIND[@FIELD=VALUE[,FIELD=VALUE...]][>=N|<=N|==N|>N|<N]
--   KIND     event kind, e.g. level_enter
--   !        forbid: the count must be zero
--   @FIELD   optional exact match on a field (use * for a wildcard)
--   >=N ...  explicit count constraint; default is >=1 (or ==0 with !)
--
-- Examples:
--   luajit tools/check_log.lua log level_enter '!alert_stuck'
--   luajit tools/check_log.lua log 'dungeon_done@dungeon=firstDungeon-01'
--   luajit tools/check_log.lua log 'level_enter>=2' 'death==0'
--
-- Exit codes: 0 all specs satisfied, 1 assertion failure, 2 usage error,
--             3 log missing or no EV lines found.

local path = arg[1]
if not path or path == "-h" or path == "--help" or path == "" then
  io.stderr:write([=[
usage: check_log.lua LOGFILE SPEC [SPEC...]

SPEC := [!]KIND[@FIELD=VALUE[,...]][>=N|<=N|==N|>N|<N]

  level_enter                    at least one level_enter event
  '!alert_stuck'                 no alert_stuck events
  'death==0'                     exactly zero death events
  'dungeon_done@dungeon=x'       dungeon_done whose dungeon field is x
]=])
  os.exit(2)
end

local f = io.open(path, "r")
if not f then
  io.stderr:write("check_log: cannot open " .. path .. "\n")
  os.exit(3)
end

local events = {}
local kinds = {}
for line in f:lines() do
  local at = line:find("EV|", 1, true)
  if at then
    local ev
    for tok in line:sub(at + 3):gmatch("[^|]+") do
      local k, v = tok:match("^([%w_]+)=(.*)$")
      if k then ev = ev or {}; ev[k] = v end
    end
    if ev and ev.kind then
      events[#events + 1] = ev
      kinds[ev.kind] = (kinds[ev.kind] or 0) + 1
    end
  end
end
f:close()

if #events == 0 then
  io.stderr:write("check_log: no EV lines in " .. path .. "\n")
  os.exit(3)
end

local function parseSpec(spec)
  local s = spec
  local neg = false
  if s:sub(1, 1) == "!" then neg = true; s = s:sub(2) end

  local filters = {}
  local at = s:find("@", 1, true)
  if at then
    for kv in s:sub(at + 1):gmatch("[^,]+") do
      local k, v = kv:match("^([%w_]+)=(.*)$")
      if not k then return nil, "bad filter '" .. kv .. "'" end
      filters[#filters + 1] = { k = k, v = v }
    end
    s = s:sub(1, at - 1)
  end

  local kind, op, n = s:match("^([%w_]+)([<>=]+)(%d+)$")
  if not kind then
    kind = s:match("^([%w_]+)$")
    if not kind then return nil, "bad kind in '" .. spec .. "'" end
    if neg then op, n = "==", 0 else op, n = ">=", 1 end
  else
    if op ~= ">=" and op ~= "<=" and op ~= "==" and op ~= ">" and op ~= "<" then
      return nil, "bad operator '" .. op .. "'"
    end
    n = tonumber(n)
  end
  return { kind = kind, op = op, n = n, filters = filters, raw = spec }
end

local function fieldMatches(value, want)
  if not value then return false end
  if want:find("*", 1, true) then
    local pat = want:gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%0")
      :gsub("%*", ".*")
    return value:match("^" .. pat .. "$") ~= nil
  end
  return value == want
end

local function countMatches(spec)
  local n = 0
  for _, ev in ipairs(events) do
    if ev.kind == spec.kind then
      local ok = true
      for _, ft in ipairs(spec.filters) do
        if not fieldMatches(ev[ft.k], ft.v) then ok = false; break end
      end
      if ok then n = n + 1 end
    end
  end
  return n
end

local function satisfied(op, got, want)
  if op == ">=" then return got >= want end
  if op == "<=" then return got <= want end
  if op == "==" then return got == want end
  if op == ">" then return got > want end
  if op == "<" then return got < want end
  return false
end

local failed = 0
local kindList = {}
for k in pairs(kinds) do kindList[#kindList + 1] = k end
table.sort(kindList)
print(string.format("check_log: %d events, %d kinds (%s)",
  #events, #kindList, table.concat(kindList, ",")))

for i = 2, #arg do
  local spec, err = parseSpec(arg[i])
  if not spec then
    io.stderr:write("check_log: " .. tostring(err) .. "\n")
    os.exit(2)
  end
  local got = countMatches(spec)
  if satisfied(spec.op, got, spec.n) then
    print(string.format("PASS %s (%d)", spec.raw, got))
  else
    failed = failed + 1
    print(string.format("FAIL %s: expected %s%d, got %d",
      spec.raw, spec.op, spec.n, got))
  end
end

if failed > 0 then
  print(string.format("check_log: %d spec(s) failed", failed))
  os.exit(1)
end
print("check_log: ok")
