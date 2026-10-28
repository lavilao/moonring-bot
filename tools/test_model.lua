-- Standalone tests for mod/zzbot/model.lua (Lua 5.1+ compatible).
local script = (arg and arg[0]) or "tools/test_model.lua"
local dir = script:match("^(.*)[/\\][^/\\]+$") or "."
local M = dofile(dir .. "/../mod/zzbot/model.lua")

local failures = 0
local function check(cond, msg)
  if not cond then error(msg or "assertion failed", 2) end
end

local function run(name, fn)
  local ok, err = pcall(fn)
  if ok then
    print("PASS " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. ": " .. tostring(err))
  end
end

local function enemy(over)
  local e = {
    hp = 100, maxHP = 100, hit = 10, maxHit = 10, attackTime = 24,
    speed = 1, dist = 1, ourHit = 10, alive = true,
  }
  for k, v in pairs(over or {}) do e[k] = v end
  return e
end

local function prof(over)
  local p = { attackTime = 15, hit = 0, speed = 1, step = 8 }
  for k, v in pairs(over or {}) do p[k] = v end
  return p
end

run("poise fully absorbs oversized bite", function()
  local state = { hp = 100, maxHP = 100, poise = 50, maxPoise = 200, injuryAge = 36 }
  local pack = { enemy({ hit = 300, maxHit = 300, attackTime = 10000 }) }
  local ev = M.evaluate({ kind = "wait" }, state, pack, prof(), { N = 1, seed = 1, horizon = 1 })
  check(ev.meanHP == 100, "hp changed: " .. tostring(ev.meanHP))
  check(ev.meanPoise == 0, "poise not broken")
  check(ev.pDeath == 0, "unexpected death")
end)

run("same seed is deterministic", function()
  local state = { hp = 80, maxHP = 120, poise = 90, maxPoise = 200, injuryAge = 10 }
  local pack = {
    enemy({ hit = 14, maxHit = 30, attackTime = 20, speed = 1.2, dist = 1, poisonDps = 0.3 }),
    enemy({ hit = 9, maxHit = 22, attackTime = 30, speed = 1, dist = 2 }),
  }
  local action = { kind = "attack", target = 1 }
  local a = M.evaluate(action, state, pack, prof({ hit = 17 }), { N = 12, seed = 7, horizon = 240 })
  local b = M.evaluate(action, state, pack, prof({ hit = 17 }), { N = 12, seed = 7, horizon = 240 })
  for k, v in pairs(a) do
    check(b[k] == v, "field differs: " .. k)
  end
end)

run("stronger pack has no lower death upper bound", function()
  local state = { hp = 10, maxHP = 10, poise = 0, maxPoise = 200, injuryAge = 0 }
  local weak = { enemy({ hit = 1, maxHit = 1, attackTime = 100, hp = 1000, maxHP = 1000 }) }
  local strong = { enemy({ hit = 20, maxHit = 20, attackTime = 10, hp = 1000, maxHP = 1000 }) }
  local opts = { N = 96, seed = 3, horizon = 600 }
  local a = M.evaluate({ kind = "wait" }, state, weak, prof(), opts)
  local b = M.evaluate({ kind = "wait" }, state, strong, prof(), opts)
  check(b.pDeathUpper >= a.pDeathUpper,
    ("%s < %s"):format(tostring(b.pDeathUpper), tostring(a.pDeathUpper)))
end)

run("healing beats waiting at low hp", function()
  local state = { hp = 20, maxHP = 100, poise = 0, maxPoise = 200, injuryAge = 0 }
  local pack = { enemy({ hit = 40, maxHit = 40, hp = 1000, maxHP = 1000 }) }
  local opts = { N = 8, seed = 5, horizon = 5 }
  local heal = M.evaluate({ kind = "heal", healAmount = 60 }, state, pack, prof(), opts)
  local wait = M.evaluate({ kind = "wait" }, state, pack, prof(), opts)
  check(heal.meanHP > wait.meanHP,
    ("heal %s <= wait %s"):format(tostring(heal.meanHP), tostring(wait.meanHP)))
end)

run("flee escapes slow enemies but not fast ones", function()
  local state = { hp = 100, maxHP = 100, poise = 0, maxPoise = 200, injuryAge = 0 }
  local p = prof({ step = 4, speed = 2 })
  local slow = { enemy({ hit = 5, maxHit = 5, speed = 1, dist = 2, hp = 10000, maxHP = 10000 }) }
  local fast = { enemy({ hit = 5, maxHit = 5, speed = 4, dist = 2, hp = 10000, maxHP = 10000 }) }
  local opts = { N = 16, seed = 9, horizon = 600 }
  local stand = M.evaluate({ kind = "wait" }, state, slow, p, opts)
  local slowFlee = M.evaluate({ kind = "flee", moveSteps = 6, terminal = true }, state, slow, p, opts)
  local fastFlee = M.evaluate({ kind = "flee", moveSteps = 6, terminal = true }, state, fast, p, opts)
  check(slowFlee.meanDamage < stand.meanDamage, "slow flee did not reduce damage")
  check(slowFlee.meanDamage == 0, "slow flee took damage")
  check(fastFlee.meanDamage > slowFlee.meanDamage, "fast flee escaped too cheaply")
  check(fastFlee.meanDamage > 0, "fast flee took no damage")
end)

run("killing the summoner stops summons", function()
  local state = { hp = 500, maxHP = 500, poise = 0, maxPoise = 200, injuryAge = 0 }
  local pack = {
    enemy({ hp = 10, maxHP = 10, hit = 0, maxHit = 1, dist = 2,
      summoner = true, summonCooldown = 100 }),
    enemy({ hp = 100000, maxHP = 100000, hit = 1, maxHit = 1, dist = 2 }),
  }
  local opts = { N = 4, seed = 11, horizon = 350, summonHit = 0 }
  local kill = M.evaluate({ kind = "attack", target = 1 }, state, pack, prof({ hit = 10 }), opts)
  local leave = M.evaluate({ kind = "attack", target = 2 }, state, pack, prof({ hit = 10 }), opts)
  check(kill.meanSummons < leave.meanSummons,
    ("%s >= %s"):format(tostring(kill.meanSummons), tostring(leave.meanSummons)))
  check(leave.meanSummons > 0, "summoner never summoned")
end)

run("poison bypasses poise and adds damage", function()
  local state = { hp = 10, maxHP = 100, poise = 200, maxPoise = 200, injuryAge = 36 }
  local base = { hit = 1, maxHit = 1, attackTime = 10000, hp = 1000, maxHP = 1000 }
  local poisoned = enemy({ hit = 1, maxHit = 1, attackTime = 10000, hp = 1000, maxHP = 1000,
    poisonDps = 2, poisonDuration = 240 })
  local plain = enemy(base)
  local opts = { N = 8, seed = 13, horizon = 30 }
  local a = M.evaluate({ kind = "wait" }, state, { poisoned }, prof(), opts)
  local b = M.evaluate({ kind = "wait" }, state, { plain }, prof(), opts)
  check(a.meanDamage > b.meanDamage, "poison did not add damage")
  check(a.pDeath > 0, "poison did not kill low-hp player")
  check(a.meanPoise > 0, "poise was not still full")
end)

run("lethal rolls give nonzero death probability", function()
  local state = { hp = 10, maxHP = 10, poise = 0, maxPoise = 200, injuryAge = 0 }
  local pack = { enemy({ hit = 7, maxHit = 14, hp = 1000, maxHP = 1000 }) }
  local ev = M.evaluate({ kind = "wait" }, state, pack, prof(), { N = 96, seed = 17, horizon = 1 })
  check(ev.pDeath > 0, "no deaths observed")
  check(ev.pDeathUpper > ev.pDeath,
    ("upper %s <= p %s"):format(tostring(ev.pDeathUpper), tostring(ev.pDeath)))
end)

if failures > 0 then
  print(("%d test(s) failed"):format(failures))
  os.exit(1)
end
print("all tests passed")
