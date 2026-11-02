-- Gear scoring, equip planning and burden policy (PLAN.md §3.2, P2).
--
-- Pure and game-free: init.lua adapts game objects into plain descriptor
-- records (missing game fields are simply absent) and this module scores and
-- plans without knowing where the numbers came from. tools/test_gear.lua
-- exercises every rule here.
--
-- Record shape (all fields optional unless noted):
--   ID (required), category (required), objectType,
--   damage, might, timeCost,        -- melee damage model
--   defense, burden,                -- armour model
--   block, hands,                   -- shield model
--   range, ammo,                    -- ranged needs ammunition
--   weight, price,                  -- drop ladder economics
--   identified (bool)

local M = {}

local MELEE = { melee = true }
local ARMOUR = { head = true, body = true, hands = true, feet = true,
  neck = true, cloak = true }

-- Might bonus mirrors the combat model's strength curve (init.lua:
-- raw = dmg * (1 + min(1, might/35))). Melee value is expected damage per
-- time unit, so a slow heavy blade must actually out-damage a fast pin.
function M.meleeScore(desc)
  if not desc or not desc.damage or desc.damage <= 0 then return 0 end
  local might = 1 + math.min(1, (desc.might or 0) / 35)
  local time = math.max(1, desc.timeCost or 15)
  return (desc.damage * might) / time
end

-- Ranged only counts with ammunition in the bag; a bow without arrows is a
-- club with extra steps.
function M.rangedScore(desc)
  if not desc or not desc.damage or desc.damage <= 0 then return 0 end
  if not desc.ammo or desc.ammo <= 0 then return 0 end
  local time = math.max(1, desc.timeCost or 20)
  return desc.damage / time
end

-- Armour value is defense per unit of burden: mobility is the resource the
-- tick multiplier and the kite distance both depend on.
function M.armorScore(desc)
  if not desc or not desc.defense or desc.defense <= 0 then return 0 end
  return desc.defense / math.max(1, desc.burden or 1)
end

-- A shield trades hands for block fraction; two-handed shields must beat two
-- one-hand alternatives per freed hand, not per item.
function M.shieldScore(desc)
  if not desc or not desc.block or desc.block <= 0 then return 0 end
  return desc.block / math.max(1, desc.hands or 1)
end

function M.score(desc)
  if not desc then return 0 end
  local cat = desc.category
  if MELEE[cat] then return M.meleeScore(desc) end
  if cat == "ranged" then return M.rangedScore(desc) end
  if cat == "shield" then return M.shieldScore(desc) end
  if ARMOUR[cat] then return M.armorScore(desc) end
  return 0
end

-- Best record per wearable slot. Items with no computable score (missing
-- objectData columns) still win an empty slot with score 0 so the planner can
-- see them, but never displace a scored item.
function M.bestPerSlot(records)
  local best = {}
  for _, r in ipairs(records or {}) do
    local s = M.score(r)
    local cur = best[r.category]
    if not cur or s > M.score(cur) then best[r.category] = r end
  end
  return best
end

-- Equip swaps: every slot gets its best *allowed* candidate; a swap happens
-- only when the candidate has a computable score and beats the worn item by
-- minGain (a 15% default that keeps marginal churn and unidentified gambles
-- out). Unscored candidates never displace anything; an empty slot takes any
-- scored item. allowed(record) returns nil or a reason string; vetoed records
-- are excluded from the plan and returned in the skip list for logging.
function M.planEquip(records, opts)
  opts = opts or {}
  local minGain = opts.minGain or 1.15
  local vetoed = {}
  local skipped = {}
  for _, r in ipairs(records or {}) do
    local reason = opts.allowed and opts.allowed(r)
    if reason then
      vetoed[r] = true
      skipped[#skipped + 1] = { id = r.ID, slot = r.category, reason = reason }
    end
  end
  local best = {}
  for _, r in ipairs(records or {}) do
    if not vetoed[r] then
      local s = M.score(r)
      local cur = best[r.category]
      if not cur or s > M.score(cur) then best[r.category] = r end
    end
  end
  local plan = {}
  for slot, cand in pairs(best) do
    local cur = opts.worn and opts.worn[slot]
    if not (cur and cur.ID == cand.ID) then
      local cs = M.score(cand)
      local bs = cur and M.score(cur) or 0
      if cs > 0 and cs > bs * minGain then
        plan[#plan + 1] = { slot = slot, from = cur and cur.ID or nil,
          to = cand.ID, gain = cs - bs,
          unidentified = cand.identified == false }
      end
    end
  end
  table.sort(plan, function(a, b) return a.gain > b.gain end)
  return plan, skipped
end

-- The protected set: selling loot must never discard the equipped items, the
-- best candidate per slot for the active build, or quest-critical categories
-- (keys, deeds, lamps, artifacts, relics).
function M.protectedSet(records, worn, opts)
  opts = opts or {}
  local keep = {}
  for _, r in ipairs(records or {}) do
    if opts.keepCategory and opts.keepCategory[r.category] then
      keep[r.ID] = true
    end
  end
  for _, r in pairs(worn or {}) do keep[r.ID] = true end
  for _, r in pairs(M.bestPerSlot(records)) do keep[r.ID] = true end
  return keep
end

-- Burden drop ladder (PLAN §3.2): above the threshold, rank unprotected
-- records by value-per-weight ascending and return drops until the predicted
-- burden fraction falls under the target. Records without weight are skipped
-- (they cannot be reasoned about) and protected IDs are never dropped.
-- opts: { threshold = 0.8, target = 0.7, protected = {[id]=true},
--         keepType = {[objectType]=true} }
function M.dropLadder(records, burdenFrac, maxBurden, opts)
  opts = opts or {}
  local threshold = opts.threshold or 0.8
  local target = opts.target or 0.7
  if not burdenFrac or burdenFrac <= threshold then return {} end
  local protected = opts.protected or {}
  local pool, drops = {}, {}
  for _, r in ipairs(records or {}) do
    if not protected[r.ID] and not (opts.keepType and opts.keepType[r.objectType])
        and r.weight and r.weight > 0 then
      local value = (r.price or 0) / r.weight
      pool[#pool + 1] = { id = r.ID, weight = r.weight, vpw = value }
    end
  end
  table.sort(pool, function(a, b)
    if a.vpw ~= b.vpw then return a.vpw < b.vpw end
    return a.id < b.id
  end)
  local excess = (burdenFrac - target) * (maxBurden or 0)
  for _, c in ipairs(pool) do
    -- 1e-9 absorbs the float residue of (0.9 - 0.7) * 100 so an exact
    -- target does not spill into one extra drop.
    if excess <= 1e-9 then break end
    drops[#drops + 1] = c.id
    excess = excess - c.weight
  end
  return drops
end

-- Lamp/amber policy (PLAN §3.9): burn fuel only where amber matters (the
-- world flag allowAmber), keep a reserve so the lamp never dies mid-delve,
-- and ask for supplies before the reserve is breached.
-- state = { allowAmber, hasLamp, fuel, lampOn, inDark }
-- returns { toggle = true|false } or { supply = true } or nil
function M.lampPlan(state)
  state = state or {}
  if not state.allowAmber or not state.hasLamp then return nil end
  local fuel = state.fuel or 0
  local reserve = state.reserve or 2
  if fuel <= 0 then return { toggle = not not state.lampOn } end
  if fuel <= reserve then return { supply = true } end
  if state.inDark and not state.lampOn then return { toggle = true } end
  if not state.inDark and state.lampOn then return { toggle = true } end
  return nil
end

return M
