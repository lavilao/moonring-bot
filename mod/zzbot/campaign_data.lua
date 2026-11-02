-- Campaign objective data (PLAN.md §4.1/§4.3, P6).
--
-- Data only. Every field the game has not confirmed yet is marked in the
-- comments; the planner (zzbot.campaign) runs on this shape and the
-- predicate evaluator is injected, so correcting a field never touches code.
--
-- Objective shape:
--   id, title,
--   order        planning preference (lower first among ready objectives)
--   requires     list of descriptors that must already hold
--   done         descriptor that marks the objective complete
--   dungeon      the dungeon the objective clears (when known)
--   town         the town that leads to it (when known)
--   needsShip    sea legs required (P7 spike)
--   difficulty   rough strength estimate for the readiness gate (0-10)
--   gated        "ending" for the Archon: the planner itself refuses it
--                without killedGods, on top of the runtime ending gate
--
-- Predicate descriptors (evaluated by the injected evaluator):
--   { prop = "relic_2" }        a game property is non-zero
--   { item = "key_clue_final" } the inventory holds the item
--   { objective = "jest" }      another objective is done
--   { relics = 5 }              N relic properties hold
--   { killedGods = true }       the endgame flag

local M = {}

M.objectives = {
  { id = "jest", title = "The Jest", town = "Harrowdus",
    dungeon = "dungeon2-01", order = 1, difficulty = 3,
    done = { prop = "relic_2" } }, -- relic number is (inferred), §4.3
  { id = "garden", title = "The Garden", order = 2, difficulty = 4,
    done = { prop = "relic_garden" } }, -- dungeon id and relic prop unverified
  { id = "repository", title = "The Repository", order = 3, difficulty = 5,
    done = { prop = "relic_repository" } }, -- unverified
  { id = "necropolis", title = "The Necropolis", order = 4, difficulty = 6,
    done = { prop = "relic_necropolis" } }, -- unverified
  { id = "tower", title = "Tower of Veils", order = 5, difficulty = 7,
    needsShip = true, -- ship subsystem is the P7 research spike (§3.10)
    done = { prop = "relic_tower" } }, -- unverified
  { id = "lament", title = "Lament", order = 6, difficulty = 8,
    requires = { { relics = 5 } },
    done = { prop = "relic_lament" } }, -- unverified
  { id = "tether", title = "The Tether", dungeon = "dungeon6-06",
    order = 7, difficulty = 9,
    requires = { { relics = 5 } },
    done = { prop = "killedGods" } },
  { id = "archon", title = "The Archon", order = 8, difficulty = 0,
    gated = "ending",
    requires = { { prop = "killedGods" } },
    done = { prop = "ending_set" } },
}

return M
