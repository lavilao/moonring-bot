-- God expert profiles (PLAN.md §3.4, P4).
--
-- Data only: one profile per god with the taboo flags the pure checker in
-- zzbot.taboo consumes. Only what the plan states is encoded; everything the
-- game must confirm (skill cell ids, stat priorities, exact sin values)
-- stays out until verified (§8.7/§8.9). Unknown gods degrade to an empty
-- profile, which forbids nothing.
--
-- Taboo flags:
--   heavyWeapon  Deaths Harlequin: non-pin/dagger/rapier arms are sin
--                (reportUseOfHeavyWeapon; the exact predicate is §8.7)
--   healPotions  Lords of Dust: potions and ointments are sin
--                (potion_water is the only exception)
--   injustice    Blind Angels: striking anything not hostile is sin
--   flee         Great Forest Wolf: fleeing is sin (cowardice)
--   nonBloodFood Lady of the Sanguine Moon: food must be blood

local M = {}

M.profiles = {
  deathsHarlequin = {
    title = "Deaths Harlequin",
    taboo = { heavyWeapon = true },
    -- The plan's §6.3 list, marked inferred there and still unverified.
    lightWeapons = { pin = true, dagger = true, rapier = true },
  },
  lordsOfDust = {
    title = "Lords of Dust",
    taboo = { healPotions = true },
    healExceptions = { potion_water = true },
  },
  blindAngels = {
    title = "Blind Angels",
    taboo = { injustice = true },
  },
  greatForestWolf = {
    title = "Great Forest Wolf",
    taboo = { flee = true },
    -- Cowardice budgets around 0.1 sin per flee; decay unverified (§8.8).
    fleeSinCost = 0.1,
  },
  ladyOfTheSanguineMoon = {
    title = "Lady of the Sanguine Moon",
    taboo = { nonBloodFood = true },
  },
}

function M.get(name)
  return M.profiles[name]
end

function M.taboo(name)
  local p = M.get(name)
  return p and p.taboo or {}
end

function M.allowsFlee(name)
  return not M.taboo(name).flee
end

return M
