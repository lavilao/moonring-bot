-- Standalone tests for mod/zzbot/gear.lua (Lua 5.1+ compatible).
local script = (arg and arg[0]) or "tools/test_gear.lua"
local dir = script:match("^(.*)[/\\][^/\\]+$") or "."
local G = dofile(dir .. "/../mod/zzbot/gear.lua")

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

local function melee(damage, might, timeCost)
  return { ID = damage * 7 + (might or 0), category = "melee",
    damage = damage, might = might, timeCost = timeCost }
end

-- Scoring ------------------------------------------------------------------

run("melee value is damage per time with the might curve", function()
  local fast = G.meleeScore({ damage = 30, timeCost = 10 })
  local slow = G.meleeScore({ damage = 30, timeCost = 20 })
  check(fast == 3 and slow == 1.5, "damage/time wrong")
  check(G.meleeScore({ damage = 30, might = 35, timeCost = 10 }) == 6,
    "might 35 should double damage")
  check(G.meleeScore({ damage = 30, might = 70, timeCost = 10 }) == 6,
    "might bonus must cap at 100%")
end)

run("ranged without ammo scores zero", function()
  check(G.rangedScore({ damage = 40, timeCost = 20 }) == 0, "no ammo field")
  check(G.rangedScore({ damage = 40, timeCost = 20, ammo = 0 }) == 0, "zero ammo")
  check(G.rangedScore({ damage = 40, timeCost = 20, ammo = 5 }) == 2, "with ammo")
end)

run("armour is defense per burden", function()
  check(G.armorScore({ defense = 12, burden = 4 }) == 3, "12/4 wrong")
  check(G.armorScore({ defense = 12 }) == 12, "no burden defaults to 1")
  check(G.armorScore({ defense = 0 }) == 0, "no defense")
end)

run("shield divides block by hands", function()
  check(G.shieldScore({ block = 30, hands = 1 }) == 30, "one hand")
  check(G.shieldScore({ block = 30, hands = 2 }) == 15, "two hands")
  check(G.shieldScore({ block = 30 }) == 30, "default hands")
end)

run("score dispatches by category", function()
  check(G.score({ category = "melee", damage = 15, timeCost = 15 }) == 1, "melee")
  check(G.score({ category = "body", defense = 6, burden = 2 }) == 3, "body")
  check(G.score({ category = "potion" }) == 0, "non-wearable")
  check(G.score(nil) == 0, "nil record")
end)

-- bestPerSlot --------------------------------------------------------------

run("best per slot ignores unscored items", function()
  local records = {
    { ID = 1, category = "melee", damage = 30, timeCost = 10 },   -- 3.0
    { ID = 2, category = "melee", damage = 45, timeCost = 10 },   -- 4.5
    { ID = 3, category = "melee" },                               -- unscored
    { ID = 4, category = "body", defense = 6, burden = 3 },       -- 2
  }
  local best = G.bestPerSlot(records)
  check(best.melee.ID == 2, "melee winner wrong")
  check(best.body.ID == 4, "body winner wrong")
  local empty = G.bestPerSlot({ { ID = 9, category = "melee" } })
  check(empty.melee and empty.melee.ID == 9, "unscored item should still be visible")
end)

-- planEquip ----------------------------------------------------------------

run("swap only on a real gain over the threshold", function()
  local records = {
    { ID = 1, category = "melee", damage = 30, timeCost = 10 },  -- 3.0
    { ID = 2, category = "melee", damage = 33, timeCost = 10 },  -- 3.3 (+10%)
    { ID = 3, category = "melee", damage = 45, timeCost = 10 },  -- 4.5 (+50%)
  }
  local plan = G.planEquip(records, { worn = { melee = records[1] } })
  check(#plan == 1 and plan[1].to == 3, "should swap only to the 4.5 weapon")

  local plan2 = G.planEquip(records, { worn = { melee = records[3] } })
  check(#plan2 == 0, "must never downgrade")
end)

run("empty slots take any scored candidate, never unscored", function()
  local records = {
    { ID = 5, category = "head", defense = 4, burden = 2 },
    { ID = 6, category = "feet" },
  }
  local plan = G.planEquip(records)
  check(#plan == 1 and plan[1].slot == "head" and plan[1].to == 5,
    "scored candidate should equip")
end)

run("allowed() veto lands in the skip list", function()
  local records = {
    { ID = 1, category = "melee", damage = 90, timeCost = 10 },
    { ID = 2, category = "body", defense = 9, burden = 1 },
  }
  local plan, skipped = G.planEquip(records, {
    allowed = function(r)
      if r.category == "melee" then return "taboo: heavy weapon" end
    end,
  })
  check(#plan == 1 and plan[1].slot == "body", "vetoed slot must not equip")
  check(#skipped == 1 and skipped[1].reason == "taboo: heavy weapon",
    "skip reason lost")
end)

run("unidentified swaps are flagged for conservative handling", function()
  local records = { { ID = 7, category = "neck", defense = 5, burden = 1,
    identified = false } }
  local plan = G.planEquip(records)
  check(#plan == 1 and plan[1].unidentified == true, "unidentified flag lost")
end)

-- protectedSet -------------------------------------------------------------

run("protected set keeps worn, best and quest categories", function()
  local records = {
    { ID = 1, category = "melee", damage = 45, timeCost = 10 },
    { ID = 2, category = "melee", damage = 30, timeCost = 10 },
    { ID = 3, category = "key" },
    { ID = 4, category = "body", defense = 2, burden = 1 },
  }
  local keep = G.protectedSet(records, { body = records[4] },
    { keepCategory = { key = true } })
  check(keep[1] and not keep[2], "spare melee must be sellable")
  check(keep[3], "keys must be protected")
  check(keep[4], "worn items must be protected")
end)

-- dropLadder ---------------------------------------------------------------

run("drop ladder only acts above the threshold", function()
  local drops = G.dropLadder({ { ID = 1, weight = 5, price = 10 } }, 0.79, 100)
  check(#drops == 0, "dropped below threshold")
end)

run("drop ladder drops the cheapest value-per-weight first", function()
  local records = {
    { ID = 1, weight = 10, price = 100, objectType = "trinket" }, -- vpw 10
    { ID = 2, weight = 10, price = 20,  objectType = "junk" },    -- vpw 2
    { ID = 3, weight = 10, price = 500, objectType = "gem" },     -- vpw 50
  }
  local drops = G.dropLadder(records, 0.9, 100, { target = 0.7 })
  check(drops[1] == 2, "junk must go first, got " .. tostring(drops[1]))
  check(drops[2] == 1, "trinket second, got " .. tostring(drops[2]))
  check(#drops == 2, "gem should survive: " .. #drops)
end)

run("drop ladder respects the protected set and keep list", function()
  local records = {
    { ID = 1, weight = 10, price = 1,  objectType = "junk" },
    { ID = 2, weight = 10, price = 2,  objectType = "junk" },
  }
  local a = G.dropLadder(records, 0.9, 100, { protected = { [1] = true } })
  check(#a == 1 and a[1] == 2, "protected item was dropped")
  local b = G.dropLadder(records, 0.9, 100, { keepType = { junk = true } })
  check(#b == 0, "keepType was ignored")
end)

run("drop ladder needs weight data to act", function()
  local drops = G.dropLadder({ { ID = 1, price = 100 } }, 0.95, 100)
  check(#drops == 0, "weightless record dropped")
end)

-- lampPlan -----------------------------------------------------------------

run("lamp policy follows the world flag and the dark", function()
  check(G.lampPlan({ allowAmber = false, hasLamp = true, fuel = 10 }) == nil,
    "lamp planned where amber is banned")
  check(G.lampPlan({ allowAmber = true, hasLamp = false, fuel = 10 }) == nil,
    "lamp planned without a lamp")
  check(G.lampPlan({ allowAmber = true, hasLamp = true, fuel = 10,
    inDark = true, lampOn = false }).toggle == true, "should light up in dark")
  check(G.lampPlan({ allowAmber = true, hasLamp = true, fuel = 10,
    inDark = false, lampOn = true }).toggle == true, "should snuff in light")
  check(G.lampPlan({ allowAmber = true, hasLamp = true, fuel = 10,
    inDark = true, lampOn = true }) == nil, "lit in dark should stay lit")
end)

run("lamp policy keeps a reserve and begs for supply", function()
  check(G.lampPlan({ allowAmber = true, hasLamp = true, fuel = 2,
    inDark = true, lampOn = false }).supply == true, "reserve breached")
  check(G.lampPlan({ allowAmber = true, hasLamp = true, fuel = 0, lampOn = true })
    .toggle == true, "empty lamp must be snuffed")
end)

if failures > 0 then
  print(("%d test(s) failed"):format(failures))
  os.exit(1)
end
print("all tests passed")
