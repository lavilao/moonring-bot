-- Standalone tests for the model v2 additions (ranged, powers, readiness).
-- Lua 5.1+ compatible; complements tools/test_model.lua.
local script = (arg and arg[0]) or "tools/test_model2.lua"
local dir = script:match("^(.*)[/\\][^/\\]+$") or "."
local M = dofile(dir .. "/../mod/zzbot/model.lua")

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

local state = { hp = 500, maxHP = 500, poise = 200, maxPoise = 200, injuryAge = 36 }
local opts = { N = 4, seed = 31, horizon = 60 }

run("ranged hits an enemy two tiles away", function()
  local pack = { enemy({ hp = 50, maxHP = 50, hit = 0, maxHit = 1, dist = 2,
    speed = 0.01 }) }
  local ev = M.evaluate({ kind = "shoot", damage = 999, range = 5 },
    state, pack, prof(), opts)
  check(ev.meanKills == 1, "shot never landed: " .. tostring(ev.meanKills))
end)

run("ranged whiffs beyond its range and still costs time", function()
  local pack = { enemy({ hit = 0, maxHit = 1, dist = 8, speed = 0.01 }) }
  local ev = M.evaluate({ kind = "shoot", damage = 999, range = 3 },
    state, pack, prof(), opts)
  check(ev.meanKills == 0, "shot reached too far")
  check(ev.meanDuration >= 15, "whiff was free")
end)

run("melee reference cannot strike at range but a shot can", function()
  local pack = { enemy({ hp = 50, maxHP = 50, hit = 0, maxHit = 1, dist = 3,
    speed = 0.01 }) }
  local shot = M.evaluate({ kind = "shoot", damage = 999, range = 5 },
    state, pack, prof(), opts)
  local swing = M.evaluate({ kind = "attack", target = 1 },
    state, pack, prof(), opts)
  check(shot.meanKills == 1, "shot failed")
  check(swing.meanKills < 1, "melee somehow reached three tiles")
end)

run("an aoe power clears a pack inside the radius", function()
  local pack = {
    enemy({ hp = 50, maxHP = 50, hit = 0, maxHit = 1, dist = 1, speed = 0.01 }),
    enemy({ hp = 50, maxHP = 50, hit = 0, maxHit = 1, dist = 2, speed = 0.01 }),
    enemy({ hp = 50, maxHP = 50, hit = 0, maxHit = 1, dist = 3, speed = 0.01 }),
  }
  local ev = M.evaluate({ kind = "power", damage = 999, radius = 3, time = 20 },
    state, pack, prof(), opts)
  check(ev.meanKills == 3, "aoe killed " .. tostring(ev.meanKills))
end)

run("an aoe power spares enemies outside the radius", function()
  local pack = {
    enemy({ hp = 50, maxHP = 50, hit = 0, maxHit = 1, dist = 1, speed = 0.01 }),
    enemy({ hp = 50, maxHP = 50, hit = 0, maxHit = 1, dist = 8, speed = 0.01 }),
  }
  local ev = M.evaluate({ kind = "power", damage = 999, radius = 3, time = 20 },
    state, pack, prof(), opts)
  check(ev.meanKills == 1, "blast reached eight tiles: " .. tostring(ev.meanKills))
end)

run("a heal power restores missing hp when nobody bites", function()
  local hurt = { hp = 440, maxHP = 500, poise = 200, maxPoise = 200,
    injuryAge = 36 }
  local pack = { enemy({ hit = 0, maxHit = 1, dist = 9, speed = 0.01 }) }
  local ev = M.evaluate({ kind = "power", heal = 60, time = 20 },
    hurt, pack, prof(), opts)
  check(ev.meanHP == 500, "healed to " .. tostring(ev.meanHP))
end)

run("rank prefers the pack-wiping power over a single swing", function()
  local pack = {
    enemy({ hp = 50, maxHP = 50, hit = 5, maxHit = 10, dist = 1 }),
    enemy({ hp = 50, maxHP = 50, hit = 5, maxHit = 10, dist = 2 }),
  }
  local evals = M.evaluateAll({
    { kind = "attack", target = 1 },
    { kind = "power", damage = 999, radius = 3, time = 20 },
  }, state, pack, prof(), { N = 12, seed = 41, horizon = 240 })
  local ranked = M.rank(evals)
  check(ranked[1].action.kind == "power",
    "power did not win: " .. tostring(ranked[1].action.kind))
end)

run("readiness demands full hp, poise and heals", function()
  local ok, reasons = M.readiness({ hp = 500, maxHP = 500, poise = 200,
    maxPoise = 200 }, { heals = 2 })
  check(ok and #reasons == 0, "healthy loadout refused")
  local bad1, r1 = M.readiness({ hp = 480, maxHP = 500, poise = 200,
    maxPoise = 200 }, { heals = 2 })
  check(not bad1 and r1[1]:find("hp", 1, true), "wounded passed readiness")
  local bad2, r2 = M.readiness({ hp = 500, maxHP = 500, poise = 10,
    maxPoise = 200 }, { heals = 2 })
  check(not bad2 and r2[1]:find("poise", 1, true), "broken poise passed")
  local bad3, r3 = M.readiness({ hp = 500, maxHP = 500, poise = 200,
    maxPoise = 200 }, { heals = 0 })
  check(not bad3 and r3[1] == "no heals", "empty satchel passed")
end)

if failures > 0 then
  print(("%d test(s) failed"):format(failures))
  os.exit(1)
end
print("all tests passed")
