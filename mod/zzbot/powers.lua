-- Power catalog, fire policy and targeting solvers (PLAN.md §3.4, P4).
--
-- Pure: the runtime catalog is built game-side from CActions.static.data
-- (adapter in init.lua, behind ZZBOT_POWERS=1) and enriched with hand-authored
-- tags. The policy and the three solvers run without the game so
-- tools/test_powers.lua can pin them.
--
-- Descriptor shape:
--   { id, tags = { damage|aoe|buff|heal|escape|summon|utility },
--     energyCost, cooldown, timeCost, targeting = "target"|"direction"|"location",
--     distance, radius, isViolent }

local M = {}

-- Fire policy: given the descriptor and the fight context, should this power
-- go off this tick? Every rule is a gate the caller can audit.
-- ctx = { energy, cooldownLeft, enemies, allyAdjacent, buffed, missingHP,
--         lost } -- lost: the verdict says fleeing would fail
function M.shouldFire(power, ctx)
  ctx = ctx or {}
  if not power then return false, "no power" end
  if (ctx.energy or 0) < (power.energyCost or 0) then
    return false, "energy"
  end
  if (ctx.cooldownLeft or 0) > 0 then return false, "cooldown" end
  local tags = power.tags or {}
  local enemies = ctx.enemies or 0
  if tags.damage then
    if enemies < 1 then return false, "no target" end
  end
  if tags.aoe then
    if enemies < 3 then return false, "pack too small" end
  end
  if tags.heal then
    if (ctx.missingHP or 0) < 100 then return false, "not wounded" end
  end
  if tags.buff then
    if ctx.buffed then return false, "already buffed" end
    if enemies < 1 then return false, "no fight imminent" end
  end
  if tags.escape then
    if not ctx.lost then return false, "not losing" end
  end
  return true
end

-- target: nearest or most dangerous enemy inside distance. Never mutates the
-- enemy records.
-- enemies = { { x, y, threat } } ; opts = { distance, mode="nearest"|"danger" }
function M.bestTarget(origin, enemies, opts)
  opts = opts or {}
  local danger = opts.mode == "danger"
  local best, bestKey, bestD
  for _, e in ipairs(enemies or {}) do
    local d = math.max(math.abs(e.x - origin.x), math.abs(e.y - origin.y))
    if d <= (opts.distance or math.huge) then
      local key = danger and (e.threat or 0) or d
      local take = not best or key > bestKey
        or (key == bestKey and d < bestD)
      if take then
        best, bestKey, bestD = e, key, d
      end
    end
  end
  return best
end

local DIRS8 = { {0,-1}, {1,-1}, {1,0}, {1,1}, {0,1}, {-1,1}, {-1,0}, {-1,-1} }
M.DIRS8 = DIRS8

-- direction: the 8-way choice that hits the most enemies and the fewest
-- allies (Blind Angels' injustice makes an ally hit a sin, never an option).
-- hits are Chebyshev-distance-1 cells in that direction, up to `reach`.
function M.bestDirection(origin, enemies, allies, reach)
  reach = reach or 1
  local function setOf(list)
    local s = {}
    for _, a in ipairs(list or {}) do s[a.x * 10000 + a.y] = true end
    return s
  end
  local es, as = setOf(enemies), setOf(allies)
  local best, bestScore, bestDir
  for i, d in ipairs(DIRS8) do
    local hits, fouls = 0, 0
    for r = 1, reach do
      local x, y = origin.x + d[1] * r, origin.y + d[2] * r
      local k = x * 10000 + y
      if es[k] then hits = hits + 1 end
      if as[k] then fouls = fouls + 1 end
    end
    local score = hits * 10 - fouls * 100
    if not bestDir or score > bestScore then
      best, bestScore, bestDir = d, score, i
    end
  end
  return bestDir, best, bestScore
end

-- location: the cell within `distance` of origin that packs the most enemies
-- into `radius`, excluding cells adjacent to allies. Returns x, y, score.
function M.bestLocation(origin, enemies, allies, radius, distance)
  local function setOf(list)
    local s = {}
    for _, a in ipairs(list or {}) do s[a.x * 10000 + a.y] = true end
    return s
  end
  local es, as = setOf(enemies), setOf(allies)
  local bx, by, bestScore
  for dx = -(distance or 4), (distance or 4) do
    for dy = -(distance or 4), (distance or 4) do
      local x, y = origin.x + dx, origin.y + dy
      local score = 0
      for k in pairs(es) do
        local ex, ey = math.floor(k / 10000), k % 10000
        local d = math.max(math.abs(ex - x), math.abs(ey - y))
        if d <= (radius or 1) then score = score + 1 end
      end
      for k in pairs(as) do
        local ax, ay = math.floor(k / 10000), k % 10000
        local d = math.max(math.abs(ax - x), math.abs(ay - y))
        if d <= 1 then score = score - 100 end -- never blast an ally
      end
      if not bestScore or score > bestScore then
        bestScore, bx, by = score, x, y
      end
    end
  end
  return bx, by, bestScore
end

-- Build a descriptor row from a CActions entry (game-side adapter calls this
-- through a pcall). Unknown fields stay nil and the policy gates on what it
-- knows.
function M.descriptor(actionID, data, tags)
  data = data or {}
  return {
    id = actionID,
    tags = tags or {},
    energyCost = tonumber(data.energyCost),
    cooldown = tonumber(data.cooldown),
    timeCost = tonumber(data.timeCost),
    targeting = data.targetingType,
    distance = tonumber(data.distance),
    radius = tonumber(data.radius),
    isViolent = data.isViolent,
  }
end

return M
