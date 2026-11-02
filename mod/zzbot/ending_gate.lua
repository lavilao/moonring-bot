-- Ending gate (PLAN.md conflict #3 and risk #6).
--
-- The Archon ends the run: with only relics in hand he triggers the bad
-- ending, and the good path requires the Tether to die first. The campaign
-- never plans a visit, but the bot must also refuse one by accident, so this
-- module is the hard guard checked every tick a speech box is open in an
-- ending world.
--
-- Pure and game-free so tools/test_ending_gate.lua can exercise it.

local M = {}

-- World-name marks that identify the ending places (archonDungeon-01, the
-- endgame world). Substring match, case-insensitive, mirrors the game's
-- loosely named worlds.
local ENDING_MARKS = { "archon", "endgame" }

function M.isEndingWorld(worldName)
  local w = tostring(worldName or ""):lower()
  for _, mark in ipairs(ENDING_MARKS) do
    if w:find(mark, 1, true) then return true end
  end
  return false
end

-- True while advancing speech in worldName would risk an ending. opts:
--   killedTether  bool  the game property killed_tether is set
--   killedGods    bool  the game set the endgame flag
--   dungeonDone   table the bot's ledger; a cleared Tether (dungeon6-06)
--                       lifts the gate even if the property is unreadable
function M.blocked(worldName, opts)
  opts = opts or {}
  if not M.isEndingWorld(worldName) then return false end
  if opts.killedTether or opts.killedGods then return false end
  local done = opts.dungeonDone or {}
  if done["dungeon6-06"] then return false end
  return true
end

return M
