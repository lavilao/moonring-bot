-- Standalone tests for mod/zzbot/metrics.lua (Lua 5.1+ compatible).
local script = (arg and arg[0]) or "tools/test_metrics.lua"
local dir = script:match("^(.*)[/\\][^/\\]+$") or "."
local M = dofile(dir .. "/../mod/zzbot/metrics.lua")

local failures = 0
local function run(name, fn)
  local ok, err = pcall(fn)
  if ok then
    print("PASS " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. ": " .. tostring(err))
  end
end

local function check(cond, msg)
  if not cond then error(msg or "assertion failed", 2) end
end

-- Capture what the module prints by swapping the global print.
local lines
local function capture()
  lines = {}
  local realPrint = print
  print = function(...)
    local vals = {}
    for i = 1, select("#", ...) do vals[#vals + 1] = tostring(select(i, ...)) end
    lines[#lines + 1] = table.concat(vals, "\t")
  end
  return realPrint
end

local function evLine()
  for _, l in ipairs(lines) do
    if l:find("EV|", 1, true) then return l end
  end
  return nil
end

run("ev lines carry the elapsed clock and the kind", function()
  local realPrint = capture()
  M.init({ t0 = 100, clock = function() return 105 end })
  M.ev("death", {})
  print = realPrint
  local line = evLine()
  check(line == "[zzbot] EV|t=5.000|kind=death",
    "got: " .. tostring(line))
end)

run("fields are sorted, flat and sanitized", function()
  local realPrint = capture()
  M.init({ t0 = 0, clock = function() return 0 end })
  M.ev("confirm", { world = "yarrow town", text = "a b|c", class = "theft" })
  print = realPrint
  local line = evLine()
  check(line:find("|class=theft|text=a_b_c|world=yarrow_town", 1, true) ~= nil,
    "got: " .. tostring(line))
end)

run("nil fields omit the key list", function()
  local realPrint = capture()
  M.init({ t0 = 0, clock = function() return 0 end })
  M.ev("level_enter", nil)
  print = realPrint
  check(evLine() == "[zzbot] EV|t=0.000|kind=level_enter",
    "got: " .. tostring(evLine()))
end)

run("log lines keep the [zzbot] prefix", function()
  local realPrint = capture()
  M.init({ t0 = 0, clock = function() return 0 end })
  M.log("hello %s (%d)", "world", 42)
  print = realPrint
  check(lines[1] == "[zzbot] hello world (42)",
    "got: " .. tostring(lines[1]))
end)

run("ev appends to the log file", function()
  local realPrint = capture()
  local path = os.tmpname()
  M.init({ t0 = 10, clock = function() return 13.25 end, logpath = path })
  M.ev("stuck", { source = "no-progress", idle = 21 })
  M.log("plain message")
  print = realPrint
  local f = io.open(path, "r")
  local body = f and f:read("*a") or ""
  if f then f:close() end
  os.remove(path)
  check(body:find("EV|t=3%.250|kind=stuck|idle=21|source=no%-progress", 1, false) ~= nil,
    "ev line missing in file:\n" .. body)
  check(body:find("plain message", 1, true) ~= nil, "log line missing in file")
  check(body:find("%d%d:%d%d:%d%d ") ~= nil, "timestamp missing in file:\n" .. body)
end)

run("reinit keeps appending to the same log file", function()
  local realPrint = capture()
  local path = os.tmpname()
  M.init({ t0 = 0, clock = function() return 1 end, logpath = path })
  M.ev("a", {})
  M.init({ t0 = 0, clock = function() return 2 end, logpath = path })
  M.ev("b", {})
  print = realPrint
  local f = io.open(path, "r")
  local body = f and f:read("*a") or ""
  if f then f:close() end
  os.remove(path)
  check(body:find("kind=a", 1, true) ~= nil and body:find("kind=b", 1, true) ~= nil,
    "second init lost the log file:\n" .. body)
end)

run("a changed logpath reopens the destination", function()
  local realPrint = capture()
  local p1, p2 = os.tmpname(), os.tmpname()
  M.init({ t0 = 0, clock = function() return 1 end, logpath = p1 })
  M.ev("first", {})
  M.init({ t0 = 0, clock = function() return 2 end, logpath = p2 })
  M.ev("second", {})
  print = realPrint
  local read = function(p)
    local f = io.open(p, "r")
    local b = f and f:read("*a") or ""
    if f then f:close() end
    os.remove(p)
    return b
  end
  local b1, b2 = read(p1), read(p2)
  check(b1:find("kind=first", 1, true) ~= nil, "first file lost its line:\n" .. b1)
  check(b2:find("kind=second", 1, true) ~= nil,
    "new logpath inherited the old handle:\n" .. b2)
end)

if failures > 0 then
  print(("%d test(s) failed"):format(failures))
  os.exit(1)
end
print("all tests passed")
