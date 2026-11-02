-- Standalone tests for mod/zzbot/gods.lua and mod/zzbot/taboo.lua.
local script = (arg and arg[0]) or "tools/test_taboo.lua"
local dir = script:match("^(.*)[/\\][^/\\]+$") or "."
local Gods = dofile(dir .. "/../mod/zzbot/gods.lua")
local Taboo = dofile(dir .. "/../mod/zzbot/taboo.lua")

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

run("all five gods have profiles", function()
  for _, id in ipairs({ "deathsHarlequin", "lordsOfDust", "blindAngels",
                        "greatForestWolf", "ladyOfTheSanguineMoon" }) do
    check(Gods.get(id), "missing profile: " .. id)
    check(Gods.get(id).title, "profile without title: " .. id)
  end
end)

run("unknown gods forbid nothing", function()
  check(Gods.get("nobody") == nil, "phantom profile")
  check(Taboo.check(nil, "flee") == nil, "nil profile must allow")
  check(Taboo.check(Gods.get("nobody") or {}, "flee") == nil,
    "empty profile must allow")
end)

run("the wolf forbids fleeing, the others allow it", function()
  check(not Gods.allowsFlee("greatForestWolf"), "wolf allows flee")
  for _, id in ipairs({ "deathsHarlequin", "lordsOfDust", "blindAngels",
                        "ladyOfTheSanguineMoon" }) do
    check(Gods.allowsFlee(id), id .. " should allow flee")
  end
end)

run("harlequin vetoes heavy weapons and allows the light set", function()
  local p = Gods.get("deathsHarlequin")
  check(Taboo.check(p, "equip", { weaponKind = "sword" }) ~= nil,
    "heavy weapon allowed")
  check(Taboo.check(p, "equip", { weaponKind = "pin" }) == nil, "pin vetoed")
  check(Taboo.check(p, "equip", { weaponKind = "dagger" }) == nil, "dagger vetoed")
  check(Taboo.check(p, "equip", { weaponKind = "rapier" }) == nil, "rapier vetoed")
  -- an unknown class cannot be judged and is allowed (sin never comes from
  -- equipping, only from using; the attack-side check needs the predicate)
  check(Taboo.check(p, "equip", {}) == nil, "unknown class vetoed")
end)

run("lords of dust only drink water", function()
  local p = Gods.get("lordsOfDust")
  check(Taboo.check(p, "heal", { itemType = "potion_heal" }) ~= nil,
    "heal potion allowed")
  check(Taboo.check(p, "heal", { itemType = "potion_oil" }) ~= nil,
    "ointment allowed")
  check(Taboo.check(p, "heal", { itemType = "potion_water" }) == nil,
    "water vetoed")
  check(Taboo.check(p, "heal", { itemType = "lifestone" }) == nil,
    "non-potion heals must stay allowed")
end)

run("blind angels only strike the hostile", function()
  local p = Gods.get("blindAngels")
  check(Taboo.check(p, "attack", { hostile = false }) ~= nil,
    "non-hostile target allowed")
  check(Taboo.check(p, "attack", { hostile = true }) == nil, "hostile vetoed")
  check(Taboo.check(p, "attack", {}) ~= nil, "unknown hostility allowed")
end)

run("the lady eats blood and nothing else", function()
  local p = Gods.get("ladyOfTheSanguineMoon")
  check(Taboo.check(p, "food", { blood = false }) ~= nil, "bread allowed")
  check(Taboo.check(p, "food", { blood = true }) == nil, "blood vetoed")
end)

run("unknown kinds forbid nothing", function()
  local p = Gods.get("deathsHarlequin")
  check(Taboo.check(p, "technology", {}) == nil, "unknown kind vetoed")
end)

if failures > 0 then
  print(("%d test(s) failed"):format(failures))
  os.exit(1)
end
print("all tests passed")
