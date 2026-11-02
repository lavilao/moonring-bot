-- Campaign planner (PLAN.md §4.2, P6).
--
-- Pure: objectives come from zzbot.campaign_data, predicate descriptors are
-- evaluated by an injected evaluator, and the planner answers "what next?".
-- Rules it enforces:
--   * done objectives are skipped (resume re-evaluates every predicate)
--   * requires must all hold before an objective is ready
--   * blocked objectives (N consecutive failures) wait without stalling the
--     rest of the ready set
--   * the readiness gate compares build strength with the objective's
--     difficulty estimate and tells the caller to prepare instead
--   * an "ending"-gated objective is never planned without its gate flag,
--     independent of the runtime ending gate
--
-- tools/test_campaign.lua pins every rule.

local M = {}

-- Evaluate one descriptor against a state table. The evaluator receives
-- (desc, state) so the game side can read properties, inventory and flags
-- however it must; a missing evaluator fails every predicate closed.
local function evalDesc(desc, state)
  if not desc then return false end
  if not (state and state.eval) then return false end
  local ok, res = pcall(state.eval, desc, state)
  if not ok then return false end
  return res and true or false
end

function M.isDone(obj, state)
  return evalDesc(obj.done, state)
end

function M.requirementsMet(obj, state)
  for _, r in ipairs(obj.requires or {}) do
    if not evalDesc(r, state) then return false end
  end
  return true
end

-- Ready set: not done, requirements met, not blocked, and (for ending-gated
-- objectives) the gate flag holds. Without an evaluator nothing is planable:
-- a bot that cannot verify its own done() predicates must not dive.
function M.ready(objectives, state)
  if not (state and state.eval) then return {} end
  local out = {}
  local blocked = (state and state.blocked) or {}
  for _, obj in ipairs(objectives or {}) do
    if not blocked[obj.id] and not M.isDone(obj, state) then
      if obj.gated == "ending" and not evalDesc({ prop = "killedGods" }, state) then
        -- refuse the ending: no killedGods, no archon
      elseif M.requirementsMet(obj, state) then
        out[#out + 1] = obj
      end
    end
  end
  table.sort(out, function(a, b)
    local ca, cb = (a.order or 99), (b.order or 99)
    if ca ~= cb then return ca < cb end
    return a.id < b.id
  end)
  return out
end

-- The planner's answer: { objective = obj } | { prepare = true, reason } |
-- { wait = true, reason }. opts.strength is the build's estimated strength
-- (0-10, gear/devotion/powers); an objective harder than strength + slack
-- asks for preparation instead of a doomed dive.
function M.pick(objectives, state, opts)
  opts = opts or {}
  local ready = M.ready(objectives, state)
  if #ready == 0 then
    return nil, "nothing ready"
  end
  local obj = ready[1]
  local strength = opts.strength or 5
  local slack = opts.slack or 1
  if (obj.difficulty or 0) > strength + slack then
    return nil, ("not ready for %s (difficulty %d > strength %d)")
      :format(obj.id, obj.difficulty or 0, strength)
  end
  return obj
end

-- Failure bookkeeping: after N consecutive failures an objective is blocked
-- until markUnblocked clears it. Returns true when this failure blocked it.
function M.fail(state, id, maxFailures)
  state = state or {}
  state.failures = state.failures or {}
  state.failures[id] = (state.failures[id] or 0) + 1
  if state.failures[id] >= (maxFailures or 3) then
    state.blocked = state.blocked or {}
    state.blocked[id] = true
    return true
  end
  return false
end

function M.markUnblocked(state, id)
  if state and state.blocked then state.blocked[id] = nil end
  if state and state.failures then state.failures[id] = nil end
end

return M
