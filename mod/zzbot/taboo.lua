-- Taboo guard (PLAN.md §3.4, P4): one checker called at every choke point
-- where an action could report sin.
--
-- Pure: the caller supplies the god profile (zzbot.gods) and a plain payload
-- describing the action. `check` returns nil when the action is clean and a
-- reason string when the god forbids it; a missing profile or an unknown
-- kind forbids nothing, so a partial integration can never brick the bot.
--
-- tools/test_taboo.lua pins every rule.

local M = {}

local LIGHT = { pin = true, dagger = true, rapier = true }

-- payload: { weaponKind = "pin"|"dagger"|"rapier"|"heavy"|..., category }
-- A nil weaponKind cannot be judged and is allowed; the game-side adapter
-- fills it from objectData once the column name is verified (§8.7).
local function checkEquip(profile, payload)
  local t = profile.taboo or {}
  if t.heavyWeapon and payload.weaponKind
      and not (profile.lightWeapons or LIGHT)[payload.weaponKind] then
    return "heavy weapon (" .. tostring(payload.weaponKind) .. ")"
  end
  return nil
end

-- payload: { itemType = "potion_heal"|..., category = "potion"|... }
-- Only potion-like items are sin for the Dust; the Lifestone, resting and
-- other non-potion heals stay lawful. potion_water is always lawful.
local function checkHeal(profile, payload)
  local t = profile.taboo or {}
  if t.healPotions then
    local it = payload.itemType or ""
    local potionLike = payload.category == "potion"
      or it:find("potion_", 1, true) == 1
      or it:find("ointment", 1, true) == 1
    if potionLike then
      local exceptions = profile.healExceptions or { potion_water = true }
      if not exceptions[it] then
        return "potion/ointment use (" .. it .. ")"
      end
    end
  end
  return nil
end

-- payload: { hostile = bool } -- the target's hostility
local function checkAttack(profile, payload)
  if (profile.taboo or {}).injustice and not payload.hostile then
    return "striking a non-hostile"
  end
  return nil
end

local function checkFlee(profile)
  if (profile.taboo or {}).flee then
    return "cowardice"
  end
  return nil
end

-- payload: { blood = bool } -- blood food is the Lady's only meal
local function checkFood(profile, payload)
  if (profile.taboo or {}).nonBloodFood and not payload.blood then
    return "non-blood food"
  end
  return nil
end

function M.check(profile, kind, payload)
  if not profile then return nil end
  payload = payload or {}
  if kind == "equip" then return checkEquip(profile, payload) end
  if kind == "heal" then return checkHeal(profile, payload) end
  if kind == "attack" then return checkAttack(profile, payload) end
  if kind == "flee" then return checkFlee(profile) end
  if kind == "food" then return checkFood(profile, payload) end
  return nil
end

return M
