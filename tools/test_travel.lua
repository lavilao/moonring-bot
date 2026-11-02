-- Standalone tests for mod/zzbot/travel.lua.
local script = (arg and arg[0]) or "tools/test_travel.lua"
local dir = script:match("^(.*)[/\\][^/\\]+$") or "."
local T = dofile(dir .. "/../mod/zzbot/travel.lua")

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

local function kinds(legs)
  local out = {}
  for _, l in ipairs(legs) do out[#out + 1] = l.kind end
  return table.concat(out, ",")
end

run("same world plans nothing", function()
  local legs = T.plan({ world = "Yarrow", inTown = true },
    { world = "Yarrow" })
  check(#legs == 0, "same-world plan: " .. kinds(legs))
end)

run("town to town walks out, crosses and walks in", function()
  local legs = T.plan({ world = "Yarrow", inTown = true },
    { world = "Harrowdus" })
  check(kinds(legs) == "town_exit,overworld,town_enter",
    "land route: " .. kinds(legs))
end)

run("the verified ferry crossing replaces the overworld leg", function()
  local legs = T.plan({ world = "Moon-upon-Thoss", inTown = true },
    { world = "Barrow-Linn" })
  check(kinds(legs) == "town_exit,ferry,town_enter",
    "ferry route: " .. kinds(legs))
  check(not T.blocked(legs), "verified ferry reported blocked")
end)

run("a target that needs a ship blocks without stalling", function()
  local legs = T.plan({ world = "Hearthaven", inTown = true },
    { world = "Kenner Island", needsShip = true })
  local why, leg = T.blocked(legs)
  check(why == "no ship", "wrong blocker: " .. tostring(why))
  check(leg.kind == "sea", "blocker is not the sea leg")
end)

run("a dungeon target appends the entry leg", function()
  local legs = T.plan({ world = "Yarrow", inTown = true },
    { world = "Yarrow", dungeon = "firstDungeon-01" })
  check(kinds(legs) == "dungeon_entry", "dungeon plan: " .. kinds(legs))
end)

run("starting already outdoors skips the town exit", function()
  local legs = T.plan({ world = "Overworld", inTown = false },
    { world = "Harrowdus" })
  check(kinds(legs) == "overworld,town_enter", "outdoor plan: " .. kinds(legs))
end)

run("an empty target plans nothing", function()
  check(#T.plan({ world = "Yarrow" }, {}) == 0, "phantom legs")
end)

run("the sea spike lists its open questions", function()
  check(#T.SEA_SPIKE >= 4, "spike too thin")
  check(T.FERRY_ROUTES["Moon-upon-Thoss|Barrow-Linn"], "verified ferry missing")
end)

if failures > 0 then
  print(("%d test(s) failed"):format(failures))
  os.exit(1)
end
print("all tests passed")
