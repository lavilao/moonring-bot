-- Confirm-box classification and policy (PLAN.md §2.4, conflict #2).
--
-- Confirm boxes carry meaning in their text. The old handler accepted every
-- prompt, which approved theft, donations and irreversible trapdoors alike.
-- The classifier and the decision live here so tools/test_confirm.lua can
-- exercise them without the game; init.lua keeps an inline fallback that must
-- be kept in sync (same degradation pattern as zzbot.model).

local M = {}

-- Map a confirm bodyText to a policy class. Matching is plain-substring on
-- the lowercased text, so game-side reflowing (extra whitespace, wrapping)
-- cannot hide the class.
function M.classify(text)
  local t = tostring(text or ""):lower()
  local function has(s) return t:find(s, 1, true) ~= nil end
  if has("do you want to steal") then return "theft" end
  if has("leave this area") then return "zoom_leave" end
  if has("forsake your old god") then return "apostasy" end
  if has("dedicate yourself") then return "dedicate" end
  if has("tether dungeon") then return "dungeon_tether" end
  if has("leads to your doom") then return "dungeon_doom" end
  if has("relic dungeon") or has("relic guardian") then return "dungeon_relic" end
  if has("the egg") or has("100 floors") or has("final challenge") then
    return "dungeon_endless"
  end
  if has("this is a dungeon") or has("master key") then return "dungeon_mini" end
  if has("one-way trip") or has("proceed onward") then return "dungeon_arena" end
  if has("are you sure you wish to enter") then return "dungeon_entry" end
  if has("return to the surface") or has("title screen") then return "leave" end
  if has("quit the game") then return "quit" end
  if has("delete your save") then return "delete" end
  if has("leap into the void") then return "void" end
  if has("sacrifice all") or has("pray to") then return "sin" end
  if has("donation box") then return "donate" end
  if has("discard") then return "discard" end
  if has("repair") then return "repair" end
  return "unknown"
end

-- Policy per class. ctx = { phase = S.phase, entered = S.entered }.
-- Entry prompts are accepted only when the campaign walked us here: a town's
-- lead sent us to this dungeon (phase to-dungeon), or a descent is already in
-- progress (entered). Anything else (a trapdoor found while exploring, an
-- unknown prompt) declines, and unknown prompts additionally raise the
-- confirm_unknown event in the caller.
function M.decide(class, ctx)
  ctx = ctx or {}
  if class == "zoom_leave" or class == "dedicate" then return true end
  if class:sub(1, 8) == "dungeon_" then
    return ctx.phase == "to-dungeon" or ctx.entered == true
  end
  return false
end

return M
