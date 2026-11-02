-- Standalone tests for tools/postmortem.lua (Lua 5.1+ compatible).
local script = (arg and arg[0]) or "tools/test_postmortem.lua"
local dir = script:match("^(.*)[/\\][^/\\]+$") or "."
local P = dofile(dir .. "/postmortem.lua")

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

local LOG = [[
12:00:00 [zzbot] EV|t=1.000|kind=policy|policy=cautious|alpha=0.0400
12:01:00 [zzbot] EV|t=60.000|kind=dungeon_done|dungeon=dungeon1-01
12:05:00 [zzbot] FAIL: player died
12:05:00 [zzbot] EV|t=300.000|kind=death|world=dungeon1-01|x=11|y=4|turn=210|cell=floor|by=wolf|policy=cautious|last=The wolf hits you for 4 | You die.
12:05:00 [zzbot] EV|t=300.100|kind=death_trace|file=zzbot-trace-1000.txt|ticks=60|dropped=12|world=dungeon1-01|policy=cautious
12:09:00 [zzbot] EV|t=540.000|kind=timeout|world=Yarrow|policy=base|turn=400
]]

run("parseLog extracts deaths, timeouts, traces, policies and wins", function()
  local d = P.parseLog(LOG)
  check(#d.deaths == 1, "deaths")
  check(d.deaths[1].by == "wolf", "killer")
  check(d.deaths[1].policy == "cautious", "policy tag")
  check(d.deaths[1].last and d.deaths[1].last:find("wolf", 1, true), "last messages")
  check(#d.timeouts == 1 and d.timeouts[1].world == "Yarrow", "timeouts")
  check(#d.traces == 1 and d.traces[1].file == "zzbot-trace-1000.txt", "trace link")
  check(d.traces[1].ticks == 60, "trace ticks")
  -- only the boot line emits kind=policy; timeout lines carry policy but are
  -- counted as timeouts, not policy sightings
  check(d.policies.cautious == 1, "policies seen")
  check(d.wins.dungeon_done == 1, "wins")
end)

run("parseLog tolerates garbage", function()
  local d = P.parseLog(nil)
  check(#d.deaths == 0 and #d.timeouts == 0, "nil text")
  d = P.parseLog("random text without EV lines\n\n")
  check(#d.deaths == 0, "plain text")
end)

local function writeTrace(path, body)
  local f = io.open(path, "w")
  f:write(body)
  f:close()
end

run("readTrace parses the header and numeric fields", function()
  local path = os.tmpname()
  writeTrace(path,
    "death|world=dungeon1-01|turn=210|by=wolf|policy=cautious|alpha=0.0400\n" ..
    "1|turn=205|hp=300|maxHP=300|poise=200|adj=1|near=2|phase=combat|world=dungeon1-01|action=hit|pDeath=0.010|pDeathUpper=0.030|reason=model|policy=cautious\n" ..
    "2|turn=206|hp=250|maxHP=300|poise=200|adj=1|near=2|phase=combat|world=dungeon1-01|action=hit|pDeath=0.020|pDeathUpper=0.040|reason=model|policy=cautious\n" ..
    "3|turn=207|hp=180|maxHP=300|poise=0|adj=1|near=2|phase=combat|world=dungeon1-01|action=hit|pDeath=0.030|pDeathUpper=0.039|reason=model|policy=cautious\n")
  local t = P.readTrace(path)
  check(t ~= nil and t.header.by == "wolf" and t.header.alpha == "0.0400", "header")
  check(#t.entries == 3, "entries")
  check(t.entries[1].hp == 300 and t.entries[3].hp == 180, "hp numbers")
  check(t.entries[3].pDeathUpper == 0.039, "prediction numbers")
  check(t.entries[1].action == "hit", "action string")
  os.remove(path)
end)

run("analyzeTrace flags surprise deaths", function()
  local t = { header = { alpha = "0.0400" }, entries = {
    { seq = 1, hp = 300, action = "hit", pDeathUpper = 0.03 },
    { seq = 2, hp = 120, action = "hit", pDeathUpper = 0.04 },
    { seq = 3, hp = 0, action = "hit", pDeathUpper = 0.039 },
  } }
  local a = P.analyzeTrace(t)
  check(a.surprise == true, "should be a surprise death")
  check(a.hpStart == 300 and a.hpEnd == 0, "hp window")
  check(a.worstDrop == 300, "worst 3-tick drop (300 -> 0), got " .. tostring(a.worstDrop))
  check(a.ignoredWarnings == 0, "no warnings to ignore")
end)

run("analyzeTrace flags warned deaths where fleeing was refused", function()
  local t = { header = { alpha = "0.0400" }, entries = {
    { seq = 1, hp = 300, action = "hit", pDeathUpper = 0.30 },
    { seq = 2, hp = 200, action = "hit", pDeathUpper = 0.50 },
    { seq = 3, hp = 0, action = "flee", pDeathUpper = 0.60 },
  } }
  local a = P.analyzeTrace(t)
  check(a.surprise == false, "not a surprise")
  check(a.sawDanger == 3, "saw danger")
  check(a.ignoredWarnings == 2, "two non-flee decisions ignored the warning, got "
    .. tostring(a.ignoredWarnings))
end)

run("report renders the full breakdown with traces", function()
  local path = os.tmpname()
  writeTrace(path,
    "death|world=dungeon1-01|turn=210|by=wolf|policy=cautious|alpha=0.0400\n" ..
    "1|turn=205|hp=300|maxHP=300|poise=200|adj=1|near=2|phase=combat|world=dungeon1-01|action=hit|pDeath=0.010|pDeathUpper=0.030|reason=model|policy=cautious\n" ..
    "2|turn=207|hp=0|maxHP=300|poise=0|adj=1|near=2|phase=combat|world=dungeon1-01|action=hit|pDeath=0.030|pDeathUpper=0.039|reason=model|policy=cautious\n")
  local traceDir = os.tmpname() -- a writable dir
  os.remove(traceDir)
  os.execute("mkdir " .. traceDir)
  local link = traceDir .. "/zzbot-trace-1000.txt"
  writeTrace(link,
    "death|world=dungeon1-01|turn=210|by=wolf|policy=cautious|alpha=0.0400\n" ..
    "1|turn=205|hp=300|maxHP=300|poise=200|adj=1|near=2|phase=combat|world=dungeon1-01|action=hit|pDeath=0.010|pDeathUpper=0.030|reason=model|policy=cautious\n" ..
    "2|turn=207|hp=0|maxHP=300|poise=0|adj=1|near=2|phase=combat|world=dungeon1-01|action=hit|pDeath=0.030|pDeathUpper=0.039|reason=model|policy=cautious\n")
  local r = P.report(LOG, traceDir)
  check(r:find("== postmortem: 1 death(s), 1 timeout(s)", 1, true), "header")
  check(r:find("killer: wolf", 1, true), "killer line")
  check(r:find("SURPRISE", 1, true), "surprise flag missing")
  check(r:find("by killer: wolf x1", 1, true), "killer aggregate")
  check(r:find("by policy: cautious x1", 1, true), "policy aggregate")
  check(r:find("calibration: 1 surprise", 1, true), "calibration line")
  check(r:find("wins: 1 dungeon", 1, true), "wins line")
  os.remove(link)
  os.remove(traceDir)
  os.remove(path)
end)

run("report without traces still reports the log facts", function()
  local r = P.report(LOG, nil)
  check(r:find("killer: wolf", 1, true), "killer")
  check(not r:find("SURPRISE", 1, true), "no trace, no flags")
  check(r:find("by world: dungeon1-01 x1", 1, true), "world aggregate")
end)

print("")
if failures > 0 then
  print("FAILURES: " .. failures)
  os.exit(1)
else
  print("ALL PASS")
end
