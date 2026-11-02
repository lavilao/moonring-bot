-- zzbot.trace — decision trace ring (Claude-plan Layer 0, P9).
--
-- Pure module, no LÖVE. A bounded ring of the last combat decision ticks:
-- state features (hp, poise, enemy counts), the action the bot chose and —
-- when the Monte Carlo model ran — what the model predicted (pDeath,
-- pDeathUpper). On death the bot dumps the ring to a text file next to the
-- metrics log, so tools/postmortem.lua can answer "why did we die" and, in
-- aggregate, "does the model's risk estimate match reality" (calibration).
--
-- Wins are recorded too (the ring resets on every dump only): the dump is
-- explicitly a death artifact; surviving runs simply roll over. Negative
-- examples for learning come from the EV| events of surviving runs.

local M = {}

M.CAPACITY = 60

function M.init(opts)
  opts = opts or {}
  M.capacity = tonumber(opts.capacity) or M.CAPACITY
  M.ring = {}
  M.seq = 0
  M.dropped = 0
  return M
end

local SCALARS = {
  turn = "n", hp = "n", maxHP = "n", poise = "n",
  nAdj = "n", nNear = "n", deadEnd = "b", fleeWanted = "b", emergency = "b",
  action = "s", label = "s", reason = "s", phase = "s", world = "s",
  pDeath = "n", pDeathUpper = "n", alpha = "n", policy = "s",
}

function M.push(entry)
  if type(entry) ~= "table" then return false end
  local clean = { seq = M.seq + 1 }
  for k, kind in pairs(SCALARS) do
    local v = entry[k]
    if v ~= nil then
      if kind == "n" then v = tonumber(v)
      elseif kind == "b" then v = (v == true or v == 1 or v == "1")
      else v = tostring(v) end
      clean[k] = v
    end
  end
  M.seq = M.seq + 1
  clean.seq = M.seq
  M.ring[#M.ring + 1] = clean
  while #M.ring > M.capacity do
    table.remove(M.ring, 1)
    M.dropped = M.dropped + 1
  end
  return true
end

-- One compact line per tick, pipe separated, postmortem-readable.
function M.serialize()
  local parts = {}
  for _, e in ipairs(M.ring) do
    parts[#parts + 1] = string.format(
      "%d|turn=%s|hp=%s|maxHP=%s|poise=%s|adj=%s|near=%s|phase=%s|world=%s|action=%s|pDeath=%s|pDeathUpper=%s|reason=%s|policy=%s",
      e.seq,
      e.turn or "?", e.hp or "?", e.maxHP or "?", e.poise or "?",
      e.nAdj or "?", e.nNear or "?",
      e.phase or "?", e.world or "?",
      e.action or e.label or "?",
      e.pDeath and string.format("%.3f", e.pDeath) or "-",
      e.pDeathUpper and string.format("%.3f", e.pDeathUpper) or "-",
      e.reason or "-", e.policy or "-")
  end
  return table.concat(parts, "\n") .. (M.ring[1] and "\n" or "")
end

function M.reset()
  M.ring = {}
  M.dropped = 0
  return true
end

function M.stats()
  return { n = #M.ring, seq = M.seq, dropped = M.dropped, capacity = M.capacity }
end

return M
