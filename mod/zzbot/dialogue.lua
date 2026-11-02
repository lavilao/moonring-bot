-- Speech driver (PLAN.md §3.3, P3).
--
-- A pure state machine over the speechArea states: plain text advances,
-- keyword choices get exhausted one unseen pick at a time, typed prompts pull
-- from an ordered keyword list, and yes/no prompts follow a policy table that
-- defaults to decline. Step caps and exhaustion keep a talkative NPC from
-- soft-locking the run; the caller turns every outcome into keys and events.
--
-- tools/test_dialogue.lua exercises every rule.

local M = {}

local function norm(s)
  return (tostring(s or ""):lower():gsub("%s+", " "):gsub("^%s+", ""):gsub("%s$", ""))
end

-- First choice the bot has not used yet, in the box's own order. Boxes often
-- append a trailing "Close" entry; it is never a keyword.
local CLOSE_WORDS = { close = true, leave = true, bye = true,["good bye"] = true }

function M.selectChoice(choices, seen)
  for _, c in ipairs(choices or {}) do
    local n = norm(c)
    if n ~= "" and not CLOSE_WORDS[n] and not (seen and seen[n]) then
      return c
    end
  end
  return nil
end

-- Next typed keyword from the ordered policy list. Unlike choices, typed
-- input is not offered by the game, so the policy list is the only source;
-- "bye" closes the conversation when the list runs out.
function M.nextTyped(keywords, seen)
  for _, k in ipairs(keywords or {}) do
    local n = norm(k)
    if n ~= "" and not (seen and seen[n]) then
      return k
    end
  end
  return "bye"
end

-- One dialogue decision.
-- speech = { kind = "text"|"choice"|"typed"|"yesno", choices = {...},
--            key = "policy key for yes/no prompts" }
-- ctx    = { seen = {[norm]=true}, keywords = {...},
--            yesno = {[key]=true|false}, cap = 200, steps = n }
-- returns action, reason
--   action = { key = "return"|"escape"|"type", text = "typed input",
--              markSeen = "norm choice", yes = bool }
--   reason = "advanced"|"picked"|"typed"|"policy"|"exhausted"|"cap"
-- A nil action with reason "exhausted"/"cap" means the caller must dismiss
-- (escape) and stop talking; every other action ends with Return or typed
-- input.
function M.step(speech, ctx)
  ctx = ctx or {}
  speech = speech or {}
  local cap = ctx.cap or 200
  if (ctx.steps or 0) >= cap then
    return nil, "cap"
  end
  -- The driver owns the seen set: every pick it returns is also recorded
  -- here, so a caller that forgets to apply markSeen cannot loop forever.
  ctx.seen = ctx.seen or {}
  local function remember(n)
    if n and n ~= "" then ctx.seen[n] = true end
  end

  if speech.kind == "choice" then
    local pick = M.selectChoice(speech.choices, ctx.seen)
    if not pick then return nil, "exhausted" end
    remember(norm(pick))
    return { key = "return", markSeen = norm(pick) }, "picked"
  end

  if speech.kind == "typed" then
    local word = M.nextTyped(ctx.keywords, ctx.seen)
    local n = norm(word)
    if n == "bye" then
      return { key = "type", text = "bye", markSeen = nil }, "bye"
    end
    remember(n)
    return { key = "type", text = word, markSeen = n }, "typed"
  end

  if speech.kind == "yesno" then
    -- The safe default is decline; only explicit policy entries accept.
    local yes = ctx.yesno and ctx.yesno[speech.key or ""] or false
    return { key = "return", yes = yes }, "policy"
  end

  return { key = "return" }, "advanced"
end

-- Bump the per-npc step counter; the caller keeps the table and resets it per
-- world so caps are per visit, not per save.
function M.count(steps, key)
  steps = steps or {}
  steps[key] = (steps[key] or 0) + 1
  return steps[key]
end

return M
