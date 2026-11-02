-- Standalone tests for mod/zzbot/powers.lua.
local script = (arg and arg[0]) or "tools/test_powers.lua"
local dir = script:match("^(.*)[/\\][^/\\]+$") or "."
local P = dofile(dir .. "/../mod/zzbot/powers.lua")

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

run("energy and cooldown gate every power", function()
  local p = { tags = { damage = true }, energyCost = 30 }
  local ok, why = P.shouldFire(p, { energy = 10, enemies = 1 })
  check(not ok and why == "energy", "low energy fired")
  local ok2, why2 = P.shouldFire(p, { energy = 50, cooldownLeft = 4, enemies = 1 })
  check(not ok2 and why2 == "cooldown", "cooldown ignored")
  local ok3 = P.shouldFire(p, { energy = 50, enemies = 1 })
  check(ok3, "healthy power refused")
end)

run("damage powers need a target, aoe needs a pack", function()
  local dmg = { tags = { damage = true }, energyCost = 0 }
  local aoe = { tags = { aoe = true }, energyCost = 0 }
  check(not P.shouldFire(dmg, { energy = 99, enemies = 0 }), "fired at nothing")
  check(P.shouldFire(dmg, { energy = 99, enemies = 1 }), "single target refused")
  check(not P.shouldFire(aoe, { energy = 99, enemies = 2 }), "aoe on a pair")
  check(P.shouldFire(aoe, { energy = 99, enemies = 3 }), "aoe refused on a pack")
end)

run("heal fires only when wounded, buff only once and only for a fight", function()
  local heal = { tags = { heal = true }, energyCost = 0 }
  check(not P.shouldFire(heal, { energy = 9, missingHP = 50 }), "healed a scratch")
  check(P.shouldFire(heal, { energy = 9, missingHP = 150 }), "refused a wound")
  local buff = { tags = { buff = true }, energyCost = 0 }
  check(not P.shouldFire(buff, { energy = 9, enemies = 1, buffed = true }),
    "double buff")
  check(not P.shouldFire(buff, { energy = 9, enemies = 0 }), "buffed in peace")
  check(P.shouldFire(buff, { energy = 9, enemies = 2 }), "refused a real buff")
end)

run("escape fires only when the verdict says fleeing fails", function()
  local esc = { tags = { escape = true }, energyCost = 0 }
  check(not P.shouldFire(esc, { energy = 9, lost = false }), "escaped while fine")
  check(P.shouldFire(esc, { energy = 9, lost = true }), "refused the escape")
end)

run("best target respects distance and mode", function()
  local origin = { x = 0, y = 0 }
  local enemies = {
    { x = 2, y = 0, threat = 5 },
    { x = 4, y = 0, threat = 50 },
  }
  local near = P.bestTarget(origin, enemies, { distance = 3 })
  check(near and near.x == 2, "distance ignored")
  local none = P.bestTarget(origin, enemies, { distance = 1 })
  check(none == nil, "out-of-range target chosen")
  local danger = P.bestTarget(origin, enemies, { distance = 10, mode = "danger" })
  check(danger and danger.x == 4, "danger mode ignored threat")
end)

run("direction solver never points at allies", function()
  local origin = { x = 0, y = 0 }
  local enemies = { { x = 1, y = 0 } }
  local allies = { { x = 0, y = -1 } }
  local dir, delta, score = P.bestDirection(origin, enemies, allies, 1)
  check(delta and delta[1] == 1 and delta[2] == 0,
    "chose the ally direction: " .. tostring(dir))
  check(score == 10, "score should be a single clean hit, got " .. tostring(score))
end)

run("direction solver prefers the double line", function()
  local origin = { x = 0, y = 0 }
  local enemies = { { x = 1, y = 0 }, { x = 2, y = 0 } }
  local dir, delta = P.bestDirection(origin, enemies, {}, 2)
  check(delta[1] == 1 and delta[2] == 0, "did not take the eastern line")
end)

run("location solver packs the radius and avoids allies", function()
  local origin = { x = 0, y = 0 }
  local enemies = { { x = 3, y = 0 }, { x = 4, y = 0 } }
  local x, y, score = P.bestLocation(origin, enemies, {}, 1, 4)
  check(score == 2, "should cover the whole pack, got " .. tostring(score))
  local hits = 0
  for _, e in ipairs(enemies) do
    if math.max(math.abs(e.x - x), math.abs(e.y - y)) <= 1 then hits = hits + 1 end
  end
  check(hits == 2, ("returned cell %s,%s misses the pack"):format(
    tostring(x), tostring(y)))
end)

run("location solver refuses to blast an ally", function()
  local origin = { x = 0, y = 0 }
  local enemies = { { x = 3, y = 0 } }
  local allies = { { x = 3, y = 1 } }
  local x, y, score = P.bestLocation(origin, enemies, allies, 1, 4)
  check(score >= 1, "best cell was punished: " .. tostring(score))
  check(math.max(math.abs(x - 3), math.abs(y - 1)) > 1,
    ("blast at %s,%s covers the ally"):format(tostring(x), tostring(y)))
end)

run("descriptor keeps only the fields the game had", function()
  local d = P.descriptor("smite", { energyCost = "12", targetingType = "location",
    radius = "2" }, { aoe = true })
  check(d.energyCost == 12 and d.targeting == "location" and d.radius == 2,
    "descriptor lost fields")
  check(d.cooldown == nil, "phantom cooldown")
end)

if failures > 0 then
  print(("%d test(s) failed"):format(failures))
  os.exit(1)
end
print("all tests passed")
