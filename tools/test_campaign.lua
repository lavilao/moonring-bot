-- Standalone tests for mod/zzbot/campaign.lua (with campaign_data shape).
local script = (arg and arg[0]) or "tools/test_campaign.lua"
local dir = script:match("^(.*)[/\\][^/\\]+$") or "."
local C = dofile(dir .. "/../mod/zzbot/campaign.lua")
local Data = dofile(dir .. "/../mod/zzbot/campaign_data.lua")

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

-- A fake predicate evaluator over a props table.
local function fakeState(props, extra)
  local s = extra or {}
  s.props = props or {}
  s.eval = function(desc)
    if desc.prop then return (s.props[desc.prop] or 0) ~= 0 end
    if desc.relics then
      local n = 0
      for k, v in pairs(s.props) do
        if k:find("relic", 1, true) == 1 and v then n = n + 1 end
      end
      return n >= desc.relics
    end
    return false
  end
  return s
end

run("the data table is well formed", function()
  local seen = {}
  for _, obj in ipairs(Data.objectives) do
    check(obj.id and not seen[obj.id], "duplicate or missing id")
    seen[obj.id] = true
    check(obj.done, "objective without a done predicate: " .. tostring(obj.id))
  end
  check(seen.jest and seen.tether and seen.archon, "key objectives missing")
end)

run("a fresh campaign starts at the jest", function()
  local obj = C.pick(Data.objectives, fakeState({}))
  check(obj and obj.id == "jest", "wrong first objective")
end)

run("done objectives are skipped (resume re-evaluates)", function()
  local state = fakeState({ relic_2 = 1 })
  local obj = C.pick(Data.objectives, state)
  check(obj and obj.id == "garden", "resume did not advance: "
    .. tostring(obj and obj.id))
end)

run("requires gate an objective", function()
  -- four relics only: lament and tether require five, tower is still open
  local state = fakeState({ relic_2 = 1, relic_garden = 1,
    relic_repository = 1, relic_necropolis = 1 })
  local ready = C.ready(Data.objectives, state)
  check(#ready == 1 and ready[1].id == "tower",
    "ready set wrong with four relics: " .. tostring(#ready))
end)

run("five relics unlock the tether, never the archon", function()
  local props = { relic_2 = 1, relic_garden = 1, relic_repository = 1,
    relic_necropolis = 1, relic_tower = 1, relic_lament = 1 }
  local obj = C.pick(Data.objectives, fakeState(props), { strength = 10 })
  check(obj and obj.id == "tether", "tether not planned: "
    .. tostring(obj and obj.id))
end)

run("the archon is unplannable before killedGods", function()
  local props = { relic_2 = 1, relic_garden = 1, relic_repository = 1,
    relic_necropolis = 1, relic_tower = 1, relic_lament = 1,
    killedGods = 0 }
  -- tether not done yet (killedGods=0) but difficulty 9 vs strength 10 ->
  -- planner may pick tether; the archon must not appear anywhere in ready.
  for _, o in ipairs(C.ready(Data.objectives, fakeState(props))) do
    check(o.id ~= "archon", "archon planned before the kill")
  end
  -- after the kill, the archon becomes the only ready objective
  props.killedGods = 1
  local state = fakeState(props)
  local obj = C.pick(Data.objectives, state)
  check(obj and obj.id == "archon", "archon not planned after the kill: "
    .. tostring(obj and obj.id))
end)

run("readiness gate asks for preparation", function()
  local state = fakeState({})
  local obj, why = C.pick(Data.objectives, state, { strength = 1, slack = 1 })
  check(obj == nil and why:find("not ready", 1, true), "planned above strength")
  local ok = C.pick(Data.objectives, state, { strength = 9, slack = 1 })
  check(ok and ok.id == "jest", "jest refused at high strength")
end)

run("blocked objectives step aside without stalling the rest", function()
  local state = fakeState({})
  check(not C.fail(state, "jest", 3), "blocked on the first failure")
  C.fail(state, "jest", 3)
  check(C.fail(state, "jest", 3), "third failure should block")
  local ready = C.ready(Data.objectives, state)
  check(ready[1] and ready[1].id == "garden",
    "blocked jest still first: " .. tostring(ready[1] and ready[1].id))
  C.markUnblocked(state, "jest")
  check(C.ready(Data.objectives, state)[1].id == "jest", "unblock failed")
end)

run("a missing evaluator fails closed", function()
  local ready = C.ready(Data.objectives, { props = {} })
  check(#ready == 0, "planned without an evaluator")
end)

if failures > 0 then
  print(("%d test(s) failed"):format(failures))
  os.exit(1)
end
print("all tests passed")
