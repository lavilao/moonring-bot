-- Travel leg planner (PLAN.md §4.2 step 3, P7).
--
-- Pure: a GoTo target becomes the ordered legs the bot must walk. The
-- existing executors (overRoute, ferryLegStep in init.lua) own the walking;
-- this module only decides which legs exist and when they are impossible.
--
-- Verified crossings live in M.FERRY_ROUTES; everything else is the sea,
-- which the plan says starts as a research spike (§3.10): a sea leg plans as
-- blocked="no ship" instead of pretending, and the caller skips it without
-- stalling.
--
-- tools/test_travel.lua pins the planner.

local M = {}

-- The one crossing the bot already sails daily (init.lua's ferryStep):
-- Moon-upon-Thoss <-> Barrow-Linn. Key format "from|to", both directions.
M.FERRY_ROUTES = {
  ["Moon-upon-Thoss|Barrow-Linn"] = true,
  ["Barrow-Linn|Moon-upon-Thoss"] = true,
}

-- Legs from a town to another town on the same landmass: walk out, cross the
-- overworld, walk in. A verified ferry crossing replaces the overworld leg.
-- A target that needs a ship (needsShip) plans a blocked sea leg: the ship
-- subsystem (deed, claim, sailing, cannons) is unexplored (§8.16).
--
-- current = { world, inTown } ; target = { world, needsShip, dungeon }
-- returns legs = { { kind, from, to, blocked } }
function M.plan(current, target)
  current = current or {}
  target = target or {}
  local legs = {}
  local from = tostring(current.world or "")
  local to = tostring(target.world or "")
  if from == to or to == "" then
    if target.dungeon and from ~= "" then
      legs[#legs + 1] = { kind = "dungeon_entry", from = from, to = target.dungeon }
    end
    return legs
  end

  local inTown = current.inTown ~= false
  if inTown then
    legs[#legs + 1] = { kind = "town_exit", from = from, to = "overworld" }
  end

  if M.FERRY_ROUTES[from .. "|" .. to] then
    legs[#legs + 1] = { kind = "ferry", from = from, to = to }
  elseif target.needsShip then
    legs[#legs + 1] = { kind = "sea", from = from, to = to,
      blocked = "no ship" }
  else
    legs[#legs + 1] = { kind = "overworld", from = from, to = to }
  end

  legs[#legs + 1] = { kind = "town_enter", from = to, to = to }
  if target.dungeon then
    legs[#legs + 1] = { kind = "dungeon_entry", from = to, to = target.dungeon }
  end
  return legs
end

-- First blocking reason in the leg list, or nil when the plan walks.
function M.blocked(legs)
  for _, leg in ipairs(legs or {}) do
    if leg.blocked then return leg.blocked, leg end
  end
  return nil
end

-- Research spike checklist for the sea subsystem (§3.10): every question the
-- spike must answer before a sea leg can execute. Data, not code, so the
-- answers land next to the questions they replace.
M.SEA_SPIKE = {
  "how a ship deed is obtained (forged container vs dialogue purchase)",
  "how a ship is claimed and whether callShipToXY needs a jetty",
  "the isSailing state: what changes on the overworld while aboard",
  "cannon and telescope: keys, ranges, and whether sea combat is avoidable",
  "whether the Tower of Veils chain needs Yeleba or the ship at all",
}

return M
