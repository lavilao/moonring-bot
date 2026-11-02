-- Standalone tests for mod/zzbot/trace.lua (Lua 5.1+ compatible).
local script = (arg and arg[0]) or "tools/test_trace.lua"
local dir = script:match("^(.*)[/\\][^/\\]+$") or "."
local T = dofile(dir .. "/../mod/zzbot/trace.lua")

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

run("push stores scalars, coerces types and numbers the sequence", function()
  T.init{ capacity = 10 }
  T.push({ hp = "42", maxHP = 100.5, nAdj = 2, action = "hit",
    pDeath = 0.021, world = "dungeon1-01" })
  T.push({ hp = 41, nNear = 3 })
  local st = T.stats()
  check(st.n == 2, "ring size " .. tostring(st.n))
  check(st.seq == 2, "seq")
  check(T.ring[1].hp == 42, "numeric string not coerced")
  check(T.ring[1].pDeath == 0.021, "pDeath")
  check(T.ring[1].maxHP == 100.5, "maxHP")
  check(T.ring[2].action == nil, "missing action should stay nil")
end)

run("ring drops the oldest beyond capacity and counts it", function()
  T.init{ capacity = 3 }
  for i = 1, 5 do T.push({ hp = i }) end
  local st = T.stats()
  check(st.n == 3, "capacity not enforced: " .. tostring(st.n))
  check(st.dropped == 2, "dropped counter")
  check(T.ring[1].hp == 3, "oldest entries should be gone")
  check(T.ring[3].hp == 5, "newest should stay")
end)

run("garbage pushes are rejected", function()
  T.init{ capacity = 4 }
  check(T.push(nil) == false, "nil")
  check(T.push("wolf") == false, "string")
  check(T.stats().n == 0, "nothing stored")
end)

run("serialize renders one pipe line per tick with dash placeholders", function()
  T.init{ capacity = 10 }
  T.push({ turn = 120, hp = 90, maxHP = 300, poise = 200, nAdj = 1, nNear = 2,
    phase = "combat", world = "dungeon1-01", action = "hit",
    pDeath = 0.01, pDeathUpper = 0.05, reason = "model", policy = "cautious" })
  T.push({ hp = 88, action = nil })
  local s = T.serialize()
  check(s:find("hp=90|maxHP=300", 1, true), "hp fields missing")
  check(s:find("pDeath=0.010|pDeathUpper=0.050", 1, true), "predictions missing")
  check(s:find("action=hit", 1, true), "action missing")
  check(s:find("policy=cautious", 1, true), "policy missing")
  check(s:find("action=%?", 1, false) or s:find("action=?|", 1, true),
    "missing action should render as ?")
  check(s:find("pDeath=%-", 1, false) or s:find("pDeath=-|", 1, true),
    "missing prediction should render as dash")
end)

run("reset clears the ring but keeps capacity", function()
  T.init{ capacity = 5 }
  T.push({ hp = 1 })
  T.reset()
  check(T.stats().n == 0, "ring not cleared")
  check(T.stats().capacity == 5, "capacity lost")
end)

run("default capacity is 60", function()
  T.init{}
  check(T.stats().capacity == 60, "capacity default")
end)

print("")
if failures > 0 then
  print("FAILURES: " .. failures)
  os.exit(1)
else
  print("ALL PASS")
end
