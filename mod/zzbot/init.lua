-- zzbot: autonomous campaign runner for Moonring.
-- Clears each town's dungeon in guide order, loots before leaving, and travels
-- the overworld to the next town.
--
-- All work happens on an isolated save (XDG_DATA_HOME is set by tools/run.sh).

local GameState = require("library.gamestate")
local Model
-- The combat model lives in its own module so it can be simulated and tested
-- without the game. Missing module degrades to the old heuristic path.
pcall(function() Model = require("zzbot.model") end)

local CFG = {
  name      = os.getenv("ZZBOT_NAME") or "QwBot",
  speed     = tonumber(os.getenv("ZZBOT_SPEED")) or 4,
  timeout   = tonumber(os.getenv("ZZBOT_TIMEOUT")) or 1800,
  logpath   = os.getenv("ZZBOT_LOG"),
  quit      = (os.getenv("ZZBOT_QUIT") == "1"),
  autostart = (os.getenv("ZZBOT_AUTOSTART") == "1"),
  startOn   = (os.getenv("ZZBOT_START_ON") == "1"),
  toggleKey = os.getenv("ZZBOT_TOGGLE") or "f9",
  model     = (os.getenv("ZZBOT_MODEL") == "1"),
  modelN    = tonumber(os.getenv("ZZBOT_MODEL_N")) or 64,
  alpha     = tonumber(os.getenv("ZZBOT_ALPHA")) or 0.08,
  horizon   = tonumber(os.getenv("ZZBOT_HORIZON")) or 480,
  startTown = tonumber(os.getenv("ZZBOT_START_TOWN")),
  shotEvery = tonumber(os.getenv("ZZBOT_SHOT_INTERVAL")),
  god       = os.getenv("ZZBOT_GOD") or "deathsHarlequin",
  tour      = (os.getenv("ZZBOT_TOUR") ~= "0"),
  moneyReserve = tonumber(os.getenv("ZZBOT_MONEY_RESERVE")) or 150,
  sellHold  = tonumber(os.getenv("ZZBOT_SELL_HOLD")) or 0.95,
  trade     = (os.getenv("ZZBOT_TRADE") ~= "0"),
  tradeMargin = tonumber(os.getenv("ZZBOT_TRADE_MARGIN")) or 1.20,
  tradeTake = tonumber(os.getenv("ZZBOT_TRADE_TAKE")) or 1.10,
  tradeDebug = (os.getenv("ZZBOT_TRADE_DEBUG") == "1"),
}

local S = {
  started = false,
  entered = false,
  success = false,
  dead = false,
  done = false,
  finished = false,
  active = CFG.startOn,
  activeTime = 0,
  toggleHeld = false,
  t0 = love.timer.getTime(),
  world = nil,
  dungeonName = nil,
  known = {},
  knownCount = 0,
  knownPX = nil,
  knownPY = nil,
  knownAt = 0,
  lastHealTurn = -1000,
  lastLSTurn = -1000,
  hasKey = false,
  masterKeyLogged = false,
  townIndex = CFG.startTown or 1,
  nextTown = nil,
  dungeonDone = {},
  lastHP = nil,
  stuckSince = nil,
  lastBeat = 0,
  errors = 0,
  errLogged = false,
  wrapped = false,
  phase = "boot",
}

local logFile
local function log(fmt, ...)
  local msg = string.format(fmt, ...)
  print("[zzbot] " .. msg)
  if CFG.logpath then
    logFile = logFile or io.open(CFG.logpath, "a")
    if logFile then
      logFile:write(string.format("%s %s\n", os.date("%H:%M:%S"), msg))
      logFile:flush()
    end
  end
end

local function now()
  return love.timer.getTime()
end

-- Headless video drivers (offscreen/dummy) cannot create mouse cursors.
-- The game creates one during love.load, so degrade gracefully instead of
-- aborting the whole run.
if love.mouse and love.mouse.newCursor then
  local origNewCursor = love.mouse.newCursor
  love.mouse.newCursor = function(...)
    local ok, cursor = pcall(origNewCursor, ...)
    if ok then return cursor end
    return nil
  end
  local origSetCursor = love.mouse.setCursor
  love.mouse.setCursor = function(cursor)
    if cursor and origSetCursor then
      pcall(origSetCursor, cursor)
    end
  end
  local origSetVisible = love.mouse.setVisible
  love.mouse.setVisible = function(visible)
    if origSetVisible then pcall(origSetVisible, visible) end
  end
end

local function ckey(x, y)
  return y * 10000 + x
end

local DIRS = {
  { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 },
}

local function pressDelta(dx, dy)
  local kbd = G_Keyboard
  if not kbd or not kbd.currentKeyPressDictionary or not kbd.justPressedDictionary then
    return false
  end
  local key
  if dx == 0 and dy == -1 then key = "up"
  elseif dx == 0 and dy == 1 then key = "down"
  elseif dx == -1 and dy == 0 then key = "left"
  elseif dx == 1 and dy == 0 then key = "right"
  end
  if not key then return false end
  kbd.currentKeyPressDictionary[key] = true
  kbd.justPressedDictionary[key] = true
  return true
end

local function pressKey(key)
  local kbd = G_Keyboard
  if not kbd or not kbd.currentKeyPressDictionary or not kbd.justPressedDictionary then
    return
  end
  kbd.currentKeyPressDictionary[key] = true
  kbd.justPressedDictionary[key] = true
end

local function cellAt(map, x, y)
  return map.cells[y + 1] and map.cells[y + 1][x + 1]
end

-- The overworld is drawn as a 96x96 chunk viewport around the camera, so map
-- coordinates there are camera-relative; everywhere else map == world coords.
local function toMapXY(game, x, y)
  if game:isWorldOutside() then
    return game.map:convertWorldXYToMapXYZeroIndexed(x, y)
  end
  return x, y
end

local function toWorldXY(game, x, y)
  if game:isWorldOutside() then
    return game.map:convertMapXYToWorldXY(x, y)
  end
  return x, y
end

local function cellWalkable(cell)
  if not cell then return false end
  local data = CCellData and CCellData.cellTypeArray[cell.typeIndex]
  return data ~= nil and data.isWalkable == true
end

local function inBounds(map, x, y)
  return map:isPositionInMapXYZeroIndexed(x, y)
end

local function cellTypeName(cell)
  if not cell then return nil end
  local data = CCellData and CCellData.cellTypeArray[cell.typeIndex]
  return data and data.name
end

-- Navigation maps treat closed doors and containers as walls. The bot plans
-- across them and bumps them open as it walks into them.
local function isBumpableDoorName(name)
  if not name then return false end
  if CCellData.cellIsSecretDoor[name] then return true end
  return CCellData.cellIsDoor[name] == true and CCellData.cellChange[name] ~= nil
end

local BREAKABLE_OBSTACLES = {
  crateClosed = true, crateOpen = true,
  barrelClosed = true, barrelOpen = true,
}

local function isBumpableObstacleName(name)
  return isBumpableDoorName(name) or BREAKABLE_OBSTACLES[name] == true
end

local function isPassableForPath(cell)
  return cellWalkable(cell) or isBumpableObstacleName(cellTypeName(cell))
end

-- One movement delta toward world (wx, wy) on the overworld. The BFS runs over
-- the chunk viewport in map coordinates and aims for the reachable cell closest
-- to the target, so a target outside the viewport still yields progress while
-- rivers and mountains inside the viewport are routed around.
local function outsideStep(game, player, wx, wy)
  if not game:isWorldOutside() then return nil end
  local map = game.map
  local sx, sy = toMapXY(game, player.position.x, player.position.y)
  if not map:isPositionInMapXYZeroIndexed(sx, sy) then return nil end
  local startK = ckey(sx, sy)
  local queue = { startK }
  local parent = { [startK] = false }
  local head = 1
  local bestK, bestD = nil, math.huge
  while head <= #queue do
    local k = queue[head]
    head = head + 1
    local cx, cy = k % 10000, math.floor(k / 10000)
    local cxw, cyw = toWorldXY(game, cx, cy)
    local d = math.max(math.abs(cxw - wx), math.abs(cyw - wy))
    if d < bestD then bestD, bestK = d, k end
    if d == 0 then break end
    for _, dir in ipairs(DIRS) do
      local nx, ny = cx + dir[1], cy + dir[2]
      if map:isPositionInMapXYZeroIndexed(nx, ny) then
        local nk = ckey(nx, ny)
        if parent[nk] == nil and isPassableForPath(cellAt(map, nx, ny)) then
          parent[nk] = k
          queue[#queue + 1] = nk
        end
      end
    end
  end
  if not bestK or bestK == startK then return nil end
  local k = bestK
  local prev = parent[k]
  while prev and prev ~= startK do
    k = prev
    prev = parent[k]
  end
  local nx, ny = k % 10000, math.floor(k / 10000)
  return nx - sx, ny - sy
end

-- Stepping onto an actor is an attack, and killing an overworld_enemy marker
-- spawns the whole Zoom battle group behind it. Travel must never walk into
-- one; go around when there is room.
local function actorAtWorldXY(game, player, x, y)
  for _, a in ipairs(game.actorManager.actorArray) do
    if a.ID ~= player.ID and not a.isCorpse and a.isAway ~= true
      and a.position.x == x and a.position.y == y then
      return a
    end
  end
end

local function walkAroundStep(game, player, wx, wy)
  local map = game.map
  local sx, sy = toMapXY(game, player.position.x, player.position.y)
  local best, bestD
  for _, dir in ipairs(DIRS) do
    local mx, my = sx + dir[1], sy + dir[2]
    if map:isPositionInMapXYZeroIndexed(mx, my)
      and isPassableForPath(cellAt(map, mx, my)) then
      local nwx, nwy = toWorldXY(game, mx, my)
      if not actorAtWorldXY(game, player, nwx, nwy) then
        local d = math.abs(nwx - wx) + math.abs(nwy - wy)
        if not bestD or d < bestD then best, bestD = dir, d end
      end
    end
  end
  if best then return best[1], best[2] end
end

-- Breadth-first path over the real map. Doors count as passable so the bot can
-- plan through them; pressing into one opens it and a later tick walks through.
-- Returns relative steps or nil.
local function visibleHostileCells(game, player)
  local blocked = {}
  for _, a in ipairs(game.actorManager.actorArray) do
    if a.ID ~= player.ID and not a.isCorpse and a.fallingTime == 0
      and a.isAway ~= true and a:isKillable() and player:isEnemy(a)
      and a:getIsVisibleToPlayer() then
      blocked[ckey(a.position.x, a.position.y)] = true
    end
  end
  return blocked
end

-- Every cell within `radius` steps of a visible hostile. Routing around this
-- keeps a wounded, out-of-consumables bot from being dragged into a fight it
-- cannot survive.
local function hostileDangerCells(game, player, radius)
  local danger = {}
  for _, a in ipairs(game.actorManager.actorArray) do
    if a.ID ~= player.ID and not a.isCorpse and a.fallingTime == 0
      and a.isAway ~= true and a:isKillable() and player:isEnemy(a)
      and a:getIsVisibleToPlayer() then
      local ax, ay = a.position.x, a.position.y
      for dy = -radius, radius do
        local span = radius - math.abs(dy)
        for dx = -span, span do
          danger[ckey(ax + dx, ay + dy)] = true
        end
      end
    end
  end
  danger[ckey(player.position.x, player.position.y)] = nil
  return danger
end

local function navSteps(game, player, tx, ty, avoidActors, avoidWeb)
  local map = game.map
  if not inBounds(map, tx, ty) then return nil end
  local sx, sy = player.position.x, player.position.y
  if sx == tx and sy == ty then return {} end

  local blocked = avoidActors and visibleHostileCells(game, player) or nil
  local startK = ckey(sx, sy)
  local targetK = ckey(tx, ty)

  -- When there is no way left to recover health, prefer a route that never
  -- enters the neighbourhood of a visible hostile. If no such route exists,
  -- fall back to the ordinary path rather than refusing to move.
  local function bfs(danger)
    local queue = { startK }
    local parent = { [startK] = false }
    local head = 1
    while head <= #queue do
      local k = queue[head]
      head = head + 1
      if k == targetK then return parent end
      local cx, cy = k % 10000, math.floor(k / 10000)
      for _, d in ipairs(DIRS) do
        local nx, ny = cx + d[1], cy + d[2]
        if inBounds(map, nx, ny) then
          local nk = ckey(nx, ny)
          local cell = cellAt(map, nx, ny)
          if parent[nk] == nil and isPassableForPath(cell)
            and not (avoidWeb and cellTypeName(cell) == "web")
            and not (blocked and blocked[nk] and not (nx == tx and ny == ty))
            and not (danger and danger[nk] and not (nx == tx and ny == ty)) then
            parent[nk] = k
            queue[#queue + 1] = nk
          end
        end
      end
    end
    return nil
  end

  local parent = bfs(S.avoidDanger)
  if parent == nil and S.avoidDanger then parent = bfs(nil) end

  if parent == nil or parent[targetK] == nil then return nil end

  local steps = {}
  local k = targetK
  while true do
    local pk = parent[k]
    if pk == nil or pk == false then break end
    local x, y = k % 10000, math.floor(k / 10000)
    local px, py = pk % 10000, math.floor(pk / 10000)
    table.insert(steps, 1, { x = x - px, y = y - py })
    k = pk
  end
  if #steps == 0 then return nil end
  return steps
end

-- Soft danger map for travel. Every woken creature turns the cells it can
-- sense into expensive ones, so a route prefers to skirt a pack instead of
-- crossing its detection bubble. Smell is Euclidean and ignores walls, sight
-- needs line of sight (approximated by a smaller bubble); using the creature's
-- own data keeps this generic across every dungeon and monster.
local function travelDangerMap(game, player)
  local turn = gGameTurn or 0
  if S.travelDanger and S.travelDangerTurn == turn then return S.travelDanger end
  local pen = {}
  local aggro = 4
  pcall(function() aggro = game.tileScreenManager:getAggroRange() or aggro end)
  for _, a in ipairs(game.actorManager.actorArray) do
    if a.ID ~= player.ID and not a.isCorpse and a.fallingTime == 0
      and a.isAway ~= true and a:isKillable() and player:isEnemy(a)
      and a:getIsVisibleToPlayer() then
      local data = a.actorData or {}
      local smell = math.max(0, data.smellDistance or 0)
      local sight = math.max(1, math.min(data.sightDistance or 0, aggro + 1))
      local r = math.max(smell, sight)
      local ax, ay = a.position.x, a.position.y
      local base = (smell > 0) and 8 or 4
      for dy = -r, r do
        for dx = -r, r do
          local d2 = dx * dx + dy * dy
          if d2 <= r * r then
            local k = ckey(ax + dx, ay + dy)
            local cost = d2 <= 9 and base * 2 or base
            pen[k] = (pen[k] or 0) + cost
          end
        end
      end
    end
  end
  S.travelDanger, S.travelDangerTurn = pen, turn
  return pen
end

-- Dijkstra over the same grid as navSteps, but danger is a price, not a wall:
-- crossing an enemy's bubble is allowed when the detour would be worse. Web is
-- priced at its real movement cost (roughly six normal steps) instead of being
-- treated as impassable.
local function weightedSteps(game, player, tx, ty, opts)
  opts = opts or {}
  local map = game.map
  if not inBounds(map, tx, ty) then return nil end
  local sx, sy = player.position.x, player.position.y
  if sx == tx and sy == ty then return {} end
  local blocked = opts.avoidActors and visibleHostileCells(game, player) or nil
  local pen = opts.penalty
  local startK, targetK = ckey(sx, sy), ckey(tx, ty)
  local dist = { [startK] = 0 }
  local parent = { [startK] = false }
  local buckets = {}
  local function push(c, k)
    local b = buckets[c]
    if not b then b = {}; buckets[c] = b end
    b[#b + 1] = k
  end
  push(0, startK)
  local done = {}
  local found = false
  local c = 0
  while c <= 4000 and not found do
    local b = buckets[c]
    if b then
      for i = 1, #b do
        local k = b[i]
        if not done[k] then
          done[k] = true
          if k == targetK then
            found = true
            break
          end
          if c <= (dist[k] or math.huge) then
            local cx, cy = k % 10000, math.floor(k / 10000)
            for _, d in ipairs(DIRS) do
              local nx, ny = cx + d[1], cy + d[2]
              if inBounds(map, nx, ny) then
                local nk = ckey(nx, ny)
                local cell = cellAt(map, nx, ny)
                local isTarget = nk == targetK
                if isPassableForPath(cell)
                  and not (blocked and blocked[nk] and not isTarget)
                  and (isTarget or not (S.avoidDanger and S.avoidDanger[nk])) then
                  local stepCost = 1
                  if pen and not isTarget then stepCost = stepCost + (pen[nk] or 0) end
                  if opts.avoidWeb and cellTypeName(cell) == "web" then
                    stepCost = stepCost + 6
                  end
                  local nd = c + stepCost
                  if nd < (dist[nk] or math.huge) then
                    dist[nk] = nd
                    parent[nk] = k
                    push(nd, nk)
                  end
                end
              end
            end
          end
        end
      end
    end
    c = c + 1
  end
  if not found or parent[targetK] == nil then return nil end
  local steps = {}
  local k = targetK
  while true do
    local pk = parent[k]
    if pk == nil or pk == false then break end
    local x, y = k % 10000, math.floor(k / 10000)
    local px, py = pk % 10000, math.floor(pk / 10000)
    table.insert(steps, 1, { x = x - px, y = y - py })
    k = pk
  end
  if #steps == 0 then return nil end
  return steps
end

local function playerPos(player)
  return player.position.x, player.position.y
end

-- Locked doors are not opened by bumping: the game needs a lockpick (or a
-- pressure plate / unlock event). doorLocked2 is explicitly unpickable.
local LOCKED_DOOR_CELLS = { doorLocked = true, gateLocked = true }

local function tryPickLock(game, player, x, y)
  local item = player:findInventoryObjectWithName("lockpick")
  if not item or (item.durability or 0) <= 0 then return false end
  local dx, dy = x - player.position.x, y - player.position.y
  if math.abs(dx) + math.abs(dy) ~= 1 then return false end
  log("lockpick on door at %d,%d (durability %s)", x, y, tostring(item.durability))
  player.targetDirection:set(dx, dy)
  player:performActionWithNameAndTargets("pickLock", {}, nil, item)
  return true
end

-- Remember every cell we have ever seen. Fog of war clears isRemembered as the
-- player looks away, so keeping our own set avoids re-exploring old rooms.
local function updateKnown(game, player)
  local map = game.map
  for y = 1, map.height do
    local row = map.cells[y]
    for x = 1, map.width do
      if row[x].isVisible then
        local k = ckey(x - 1, y - 1)
        if not S.known[k] then
          S.known[k] = true
          S.knownCount = S.knownCount + 1
        end
      end
    end
  end
  S.knownPX, S.knownPY = playerPos(player)
  S.knownAt = now()
end

local function isKnown(x, y)
  return S.known[ckey(x, y)] == true
end

-- Nearest known walkable cell that borders something we have never seen.
-- Returns the target plus the nav steps that reach it, or nil.
local function findFrontier(game, player)
  local map = game.map
  local sx, sy = playerPos(player)

  local function search(danger)
    local queue = { { sx, sy } }
    local seen = { [ckey(sx, sy)] = true }
    local head = 1
    local checked = 0

    while head <= #queue do
      local cx, cy = queue[head][1], queue[head][2]
      head = head + 1

      local isFrontier = false
      for _, d in ipairs(DIRS) do
        local nx, ny = cx + d[1], cy + d[2]
        if inBounds(map, nx, ny) then
          if not isKnown(nx, ny) then
            isFrontier = true
          else
            local nk = ckey(nx, ny)
            -- Crates and barrels are not walkable but can be broken by
            -- bumping, and secret doors look like walls until touched. They
            -- must count as passable or whole rooms behind them are invisible
            -- to the frontier search.
            if not seen[nk] and isPassableForPath(cellAt(map, nx, ny))
              and not (danger and danger[nk]) then
              seen[nk] = true
              queue[#queue + 1] = { nx, ny }
            end
          end
        end
      end

      if isFrontier and not (cx == sx and cy == sy) then
        checked = checked + 1
        local steps = navSteps(game, player, cx, cy)
        if steps and steps[1] then
          return cx, cy, steps
        end
        if checked >= 24 then break end
      end
    end
  end

  local fx, fy, steps = search(S.avoidDanger)
  if fx then return fx, fy, steps end
  return search(nil)
end

local function travelSteps(game, player, tx, ty, avoidActors, avoidWeb)
  local steps = weightedSteps(game, player, tx, ty, {
    penalty = travelDangerMap(game, player),
    avoidActors = avoidActors ~= false,
    avoidWeb = avoidWeb,
  })
  if steps and steps[1] then return steps end
  return navSteps(game, player, tx, ty, avoidActors, avoidWeb)
end

local function moveToward(game, player, tx, ty)
  local px, py = playerPos(player)
  if px == tx and py == ty then return "arrived" end
  -- Prefer routes that skirt the detection bubbles of visible enemies; fall
  -- back to the direct route when a creature blocks the only corridor.
  local steps = travelSteps(game, player, tx, ty, true)
    or travelSteps(game, player, tx, ty, false)
  if steps and steps[1] then
    local nx, ny = px + steps[1].x, py + steps[1].y
    if LOCKED_DOOR_CELLS[cellTypeName(cellAt(game.map, nx, ny))]
      and tryPickLock(game, player, nx, ny) then
      return "moving"
    end
    pressDelta(steps[1].x, steps[1].y)
    return "moving"
  end
  return "nopath"
end

local function nearestVisibleEnemy(game, player, maxDist)
  local best, bestD
  for _, a in ipairs(game.actorManager.actorArray) do
    if a.ID ~= player.ID
      and not a.isCorpse
      and a.fallingTime == 0
      and a.isAway ~= true
      and a:isKillable()
      and player:isEnemy(a)
      and a:getIsVisibleToPlayer()
    then
      local dx, dy = a.position.x - player.position.x, a.position.y - player.position.y
      local d = math.max(math.abs(dx), math.abs(dy))
      if d <= maxDist and (bestD == nil or d < bestD) then
        best, bestD = a, d
      end
    end
  end
  return best, bestD
end

local function findHealPotion(player)
  local minor = player:findInventoryObjectWithName("potion_heal")
  local major = player:findInventoryObjectWithName("potion_heal_major")
  if minor and (minor.count or 0) <= 0 then minor = nil end
  if major and (major.count or 0) <= 0 then major = nil end
  return minor, major
end

local function findLifestone(player)
  local wand = player:findInventoryObjectWithUseFX("healing_stone")
  if wand and (wand.durability or 0) > 0 then return wand end
end

-- Durability is spent at rotPerUse per activation (2 for the Lifestone), so a
-- fresh stone gives five heals, not ten. All budgets are tracked in heals.
local function lsUses(wand)
  if not wand then return 0 end
  local rot = 2
  pcall(function() rot = math.max(1, wand.objectData.rotPerUse or rot) end)
  return math.floor((wand.durability or 0) / rot)
end

local function useHealItem(game, player, item)
  log("healing with %s (hp %d/%d, count=%s)",
    tostring(item.objectType), player.health, player.maxHealth, tostring(item.count))
  game:useItemWithInventoryIndex(item.ID)
  S.lastHealTurn = gGameTurn or 0
  return true
end

local function drinkPotion(game, player)
  local minor, major = findHealPotion(player)
  local missing = player.maxHealth - player.health
  -- A minor potion (225) fully covers a small gap; save the major for deep
  -- holes so its 450 healing is not wasted on the health cap.
  local item
  if missing > 225 and major then
    item = major
  elseif minor then
    item = minor
  elseif major then
    item = major
  end
  if item then return useHealItem(game, player, item) end
  return false
end

-- Health the Lifestone would actually restore to adjacent enemies: the heal is
-- capped at maxHealth, so a bruiser at nearly full health barely benefits.
local function adjacentHealTotal(game, player)
  local total = 0
  for _, d in ipairs(tools.aroundNESW) do
    local a = game.actorManager:getKillableActorAtWorldXY(
      player.position.x + d[1], player.position.y + d[2])
    if a and a:isKillable() and player:isEnemy(a) then
      local maxhp = a.maxHealth or 0
      local missing = math.max(0, maxhp - (a.health or maxhp))
      total = total + math.min(math.floor(maxhp * 0.75), missing)
    end
  end
  return total
end

-- Per-enemy effective Lifestone heal, aligned with the model's pack order.
local function adjacentHealMap(pack, player, heal)
  local map = {}
  for i, t in ipairs(pack) do
    local w = t.ref or t
    local ax, ay = w.actor.position.x, w.actor.position.y
    if math.abs(ax - player.position.x) + math.abs(ay - player.position.y) == 1 then
      local maxhp = w.maxHP or w.hp
      map[i] = math.min(heal, math.max(0, maxhp - w.hp))
    end
  end
  return map
end

local function carriesChestKey(a)
  local c = a.carryingObject
  if type(c) == "string" then return c == "chest_key" end
  if type(c) == "table" then
    for _, v in ipairs(c) do
      if v == "chest_key" or (type(v) == "table" and v.objectType == "chest_key") then
        return true
      end
    end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- Threat weighting (qw-style)
--
-- Every hostile is reduced to the damage it deals per unit of game time, using
-- the same numbers the game uses: weapon damage curved by the creature's might,
-- reduced by our armour and dodge, multiplied by crit chance, plus a penalty
-- for status weapons (poison halves current health, stuns cost whole turns).
-- Time is measured in the game's own action-time units (dagger swing 15, wolf
-- bite 24, one tile of movement 8), so damage rates and kill times compare
-- directly.
local function isHostile(player, a)
  return a ~= nil and a.ID ~= player.ID and not a.isCorpse
    and a.fallingTime == 0 and a.isAway ~= true and a:isKillable()
    and player:isEnemy(a) and a:getIsVisibleToPlayer()
end

local function statusDanger(wd)
  local m = 1
  local poison = wd.poisonMelee or 0
  if poison > 0 then m = m + poison * 3 end       -- a 0.2 poison bite ≈ +60%
  if (wd.stunMelee or 0) > 0 then m = m + 1.5 end -- losing whole turns is brutal
  if (wd.torporMelee or 0) > 0 then m = m + 0.5 end
  if (wd.flameMelee or 0) > 0 then m = m + 0.4 end
  if (wd.bleedMelee or 0) > 0 then m = m + 0.25 end
  return m
end

-- Our own numbers this turn: how hard we hit, how often, and how much of an
-- incoming attack we avoid or absorb. Cached per game turn, so tryHeal and
-- combatStep share one inventory scan.
local function playerProfile(game, player)
  local turn = gGameTurn or 0
  if S.prof and S.profTurn == turn then return S.prof end
  local prof = {
    attackTime = 15, hit = 30, dps = 2.2,
    physHit = 30, magHit = 0,
    physFrac = 1, magFrac = 1, dodge = 0, speed = 1,
  }
  local wd
  pcall(function() wd = player:getMeleeWeaponData() end)
  if wd and wd.weaponTimeCost then prof.attackTime = wd.weaponTimeCost end

  pcall(function()
    local p, m, var = game:getTotalPlayerMeleeAttackStatsAfterEquipmentDegradation(nil, false)
    p, m = player:getMeleeDamageModifiedByPlayerStats(
      p, m, game:getPlayerCurrentAttributes())
    local mult = 1 - math.min(var or 0, 0.9) * 0.5
    local crit = player:getFinalMeleeCrit(nil, false) or 0
    local critMult = 1 + crit * (G_Globals.critDamageMultiplier - 1)
    prof.physHit, prof.magHit = (p or 0) * mult * critMult, (m or 0) * mult * critMult
    prof.hit = prof.physHit + prof.magHit
  end)
  prof.dps = prof.hit / math.max(1, prof.attackTime)

  pcall(function()
    local pdef, mdef = player:getAllDefStats()
    local ac = game.actorManager.actionClass
    prof.physFrac = ac.getDefenceValueAsFractionOfDamage(pdef or 0)
    prof.magFrac = ac.getDefenceValueAsFractionOfDamage(mdef or 0)
  end)
  pcall(function() prof.dodge = math.min(0.9, game:getPlayerDodge() or 0) end)
  pcall(function()
    local _, _, _, _, _, _, _, pd = player:getAllStatusEffectDefStats()
    prof.poisonResist = math.min(1, math.max(0, (pd or 0) / 100))
  end)
  pcall(function()
    prof.speed = (player.actorData.moveSpeed or 1)
      / math.max(0.1, game:getPlayerTickCostMultiplier() or 1)
  end)

  S.prof, S.profTurn = prof, turn
  return prof
end

-- Poise only starts regenerating after this many ut without a wound, and any
-- damage (even a hit fully absorbed by poise) resets the timer.
local function injuryAge(game)
  local age = 0
  pcall(function()
    age = game:getPlayerCurrentAttributes().timeSinceLastInjured or 0
  end)
  return age
end

-- One hostile's contribution. Incoming damage follows the same numbers the
-- game uses; outgoing damage is reduced by the creature's own armour (the
-- shield bug's 15/15 costs us 30% of every hit) and by its dodge chance, so
-- time-to-kill is per enemy rather than one global player DPS.
-- Creatures that can call reinforcements keep feeding the fight, so the
-- spawner is worth killing even when its own damage is negligible.
local function summonerProfile(a, data)
  local found, interval, ready = false, nil, true
  for _, key in ipairs({ "offensiveActions", "supportActions" }) do
    local list = data[key]
    if type(list) == "table" then
      for _, n in ipairs(list) do
        if type(n) == "string" and string.find(string.lower(n), "summon", 1, true) then
          found = true
          local ad
          pcall(function()
            ad = (CActions.static and CActions.static.data[n]) or CActions.data[n]
          end)
          if ad then
            local cd = tonumber(ad.cooldown) or 0
            local ec = tonumber(ad.energyCost) or 0
            local en = tonumber(data.energy) or 0
            -- Energy, not the action cooldown, is the real limiter: enemies
            -- regain 0.00025*maxEnergy per ut (actor_manager.lua:1322), so a
            -- 100-energy summon needs ~4000 ut to recharge.
            local need = (ec > 0 and en > 0) and ec / (en * 0.00025) or 0
            local iv = math.max(cd, need, 1)
            interval = math.min(interval or iv, iv)
            if ec > 0 and a and a.energy and a.energy < ec then ready = false end
          end
        end
      end
    end
  end
  return found, interval or 200, ready
end

local function enemyWeight(game, a, prof)
  local data = a.actorData or {}
  local summoner, summonCooldown, summonReady = summonerProfile(a, data)
  local w = {
    actor = a,
    actorType = a.actorType or data.actorType,
    hp = a.health or data.health or 0,
    maxHP = a.maxHealth or data.health or 0,
    speed = data.moveSpeed or 1,
    fast = false,
    carrier = carriesChestKey(a),
    summoner = summoner,
    summonCooldown = summonCooldown,
    summonReady = summonReady,
    dodge = data.dodge or 0,
    dist = math.huge,
    maxHit = 0,
    aware = true,
  }
  pcall(function() w.aware = not a:isUnaware() end)
  pcall(function() w.fast = a:isFast() and true or false end)
  -- Fold isFast into effective speed exactly like the action system does
  -- (it halves movement time).
  if w.fast then w.speed = w.speed * 2 end

  local wd
  pcall(function() wd = a:getMeleeWeaponData() end)
  w.weapon = wd and wd.objectType or nil
  w.poison = wd and (wd.poisonMelee or 0) > 0 or false
  w.dps, w.hit, w.attackTime = 0, 0, 24
  if wd and wd.weaponTimeCost then
    w.attackTime = wd.weaponTimeCost
    if w.fast then w.attackTime = math.max(1, w.attackTime * 0.5) end
    local pd, md = 0, 0
    pcall(function()
      pd = a:applyCurveToDamage(wd.physicalMeleeDam or 0, a.might or data.might or 0)
      md = a:applyCurveToDamage(wd.magicalMeleeDam or 0, a.magic or data.magic or 0)
    end)
    local variance = math.min(wd.meleeVariance or 0, 0.9)
    local hit = (pd * prof.physFrac + md * prof.magFrac) * (1 - variance * 0.5)
    local crit = 0
    pcall(function()
      crit = game.actorManager.actionClass.getCritChanceWithWeapon(a, wd) or 0
    end)
    local critMult = math.max(1, G_Globals.critDamageMultiplier or 1)
    hit = hit * (1 + crit * (critMult - 1))
    hit = hit * (1 - prof.dodge) * statusDanger(wd)
    w.hit = hit
    w.dps = hit / math.max(1, w.attackTime)
    -- Worst single blow this creature can roll: maximum variance roll and a
    -- critical. `hit` is the mean, so undo its mean factors and reapply the
    -- top of the range; this is what decides whether one swing is lethal.
    local meanFactor = (1 - variance * 0.5) * (1 + crit * (critMult - 1))
    w.maxHit = hit / math.max(1e-6, meanFactor) * critMult
  end

  -- The model simulates poison explicitly (it bypasses poise and halves
  -- current health), so strip the legacy heuristic multiplier from the
  -- damage it sees while keeping it for the heuristic fallback.
  w.poisonPerHit, w.modelHit, w.modelMaxHit = 0, w.hit, w.maxHit
  if wd and (wd.poisonMelee or 0) > 0 then
    w.poisonPerHit = wd.poisonMelee * (1 - (prof.dodge or 0))
      * (1 - (prof.poisonResist or 0))
    local pm = 1 + wd.poisonMelee * 3
    w.modelHit = w.hit / pm
    w.modelMaxHit = w.maxHit / pm
  end

  local defFrac = 1
  pcall(function()
    local ac = game.actorManager.actionClass
    local pf = ac.getDefenceValueAsFractionOfDamage(a.physicalDef or data.physicalDef or 0)
    local mf = ac.getDefenceValueAsFractionOfDamage(a.magicalDef or data.magicalDef or 0)
    local total = prof.physHit + prof.magHit
    if total > 0 then
      defFrac = (prof.physHit * pf + prof.magHit * mf) / total
    end
  end)
  w.defFrac = defFrac
  w.ourHit = prof.hit * (1 - math.min(w.dodge, 0.9)) * defFrac
  w.ourDps = w.ourHit / math.max(1, prof.attackTime)
  w.ttk = w.hp / math.max(0.05, w.ourDps)
  w.n = math.max(1, math.ceil(w.ttk / math.max(1, prof.attackTime)))
  w.cost = w.dps * (w.n - 1) * prof.attackTime
  return w
end

-- Every visible hostile within reach of the current fight, nearest first.
-- Distance is Manhattan, because movement and melee are four-directional: a
-- creature on a diagonal is two steps away, not "adjacent".
local THREAT_RADIUS = 9
local function threatList(game, player, prof)
  local list = {}
  for _, a in ipairs(game.actorManager.actorArray) do
    if isHostile(player, a) then
      local dx = a.position.x - player.position.x
      local dy = a.position.y - player.position.y
      local dist = math.abs(dx) + math.abs(dy)
      local cheb = math.max(math.abs(dx), math.abs(dy))
      if cheb <= THREAT_RADIUS then
        local w = enemyWeight(game, a, prof)
        w.dist = dist
        list[#list + 1] = w
      end
    end
  end
  table.sort(list, function(lhs, rhs) return lhs.dist < rhs.dist end)
  return list
end

-- ---------------------------------------------------------------------------
-- Fight valuation (Claude's model, calibrated against the game's numbers)
--
-- All times are Moonring action-time units. An enemy pays its action cost
-- *after* acting, so an adjacent enemy is charged a bite at t=0; moving to a
-- non-adjacent cell is immune as long as our step is shorter than its step.
-- `use` and `wait` cost 12 ut (actions.lua), a dagger swing 15, and a wolf
-- bite 24. Constants below were checked against those sources.
local CC = {
  CV = 0.34, Z99 = 2.33, Z95 = 1.65,   -- damage spread, 99%/95% survival z
  C_LS = 12, C_POT = 12, LS_CD = 4,    -- heal action cost / anti-spam window
  LS_FRAC = 0.75, LS_WINDOW = 200, LS_RESERVE = 1,
  POT_MAJOR = 450, POT_MINOR = 225, POT_EFF = 250, POT_PRICE = 250,
  DM_PEACE = 150, MIN_GE_HEAL = 100,   -- minimum value to spend a charge
  OUT_MARGIN = 0.5, POSTKEY_HP = 300,
  WEB = true,                          -- never retreat through an unbroken web
}

local function playerStep(prof)
  return 8 / math.max(0.1, prof.speed)
end

-- Time the enemy needs to cross one tile. isFast is already folded into speed.
local function enemyStep(t)
  return 8 / math.max(0.05, t.speed)
end

local function canOutrun(t, step)
  return enemyStep(t) > step + CC.OUT_MARGIN
end

-- Player steps needed to open a two-tile gap on something we can outrun.
local function kGap(t, step)
  local c = enemyStep(t)
  if c <= step then return 0 end
  return math.ceil(c / (c - step))
end

-- Steps before a faster enemy closes the gap entirely.
local function kMax(t, dist, step)
  local r = step / enemyStep(t)
  if r <= 1 then return math.huge end
  return math.floor((dist - 1) / (r - 1))
end

-- Health needed to survive W ut of actions with 99% confidence. The lead
-- term lets distant enemies arrive late; adjacent ones are assumed to bite
-- immediately (worst case, pay-after).
local function Hreq(list, W, prof)
  local mu, var = 0, 0
  for _, t in ipairs(list) do
    local lead = (t.dist <= 1) and 0 or (t.dist * enemyStep(t))
    local b = math.max(0, math.ceil((W - lead) / t.attackTime))
    local m = t.hit
    mu = mu + b * m
    var = var + b * (CC.CV * m) ^ 2
  end
  return mu + CC.Z99 * math.sqrt(var)
end

-- Worst-case damage arriving within W ut: each creature at its maximum roll
-- with a critical. If health is under this, one lucky swing ends the run, so
-- healing stops being a value calculation and becomes mandatory.
local function lethalBound(list, W)
  local worst = 0
  for _, t in ipairs(list) do
    local lead = (t.dist <= 1) and 0 or (t.dist * enemyStep(t))
    if lead <= W then worst = worst + t.maxHit end
  end
  return worst
end

-- Sequential kill order (Smith: highest damage per swing first); a dead enemy
-- stops biting, so its bite count is capped at the time it takes to kill it.
local function packCost(pack, choke, prof)
  local l = {}
  for _, t in ipairs(pack) do l[#l + 1] = t end
  table.sort(l, function(a, b)
    local sa = a.dps / math.max(1, a.n)
    local sb = b.dps / math.max(1, b.n)
    if sa ~= sb then return sa > sb end
    return a.dist < b.dist
  end)
  local elapsed, cost, var = 0, 0, 0
  for _, t in ipairs(l) do
    local own = (t.n - 1) * prof.attackTime
    local alive = choke and own or (elapsed + own)
    cost = cost + t.dps * alive
    var = var + (alive / t.attackTime) * (CC.CV * t.hit) ^ 2
    elapsed = elapsed + t.n * prof.attackTime
  end
  return cost, math.sqrt(var)
end

local function potionInfo(player)
  local minor, major = findHealPotion(player)
  local n, best = 0, 0
  if minor and (minor.count or 0) > 0 then
    n = n + minor.count
    best = math.max(best, CC.POT_MINOR)
  end
  if major and (major.count or 0) > 0 then
    n = n + major.count
    best = math.max(best, CC.POT_MAJOR)
  end
  return n, best
end

-- Can this pack be fought with the health and consumables we have? One enemy
-- is always fought where we stand; two or more only in a choke, because the
-- open-ground cost is far higher than the sequential choke cost.
local function verdict(pack, hp, nPot, lsAvail, prof, deadEnd)
  local function need(choke)
    local cost, sigma = packCost(pack, choke, prof)
    local D = 0
    for _, t in ipairs(pack) do
      D = choke and math.max(D, t.dps) or (D + t.dps)
    end
    return cost + CC.Z95 * sigma + (#pack + 1) * D * CC.C_LS
  end
  local res = hp + nPot * CC.POT_EFF
    + math.min(math.max(#pack - 1, 0), math.max(0, lsAvail)) * CC.LS_WINDOW
  local chokeNeed = need(true)
  if #pack == 1 then
    return chokeNeed <= res and "open" or "avoid", chokeNeed, res
  end
  -- The choke cost above assumes only one creature can reach us at a time.
  -- In open ground every one of them bites while we swing, so a pack is only
  -- fought at that price from a dead end.
  if deadEnd and chokeNeed <= res then return "choke", chokeNeed, res end
  local openNeed = need(false)
  if openNeed <= res then return "open", openNeed, res end
  return "avoid", openNeed, res
end

-- Nearest cell not orthogonally adjacent to any visible enemy. One step of
-- separation is enough: the Lifestone only heals creatures in the four cells
-- around us, and the heal lands instantly, before a chaser moves again.
local function findFleeCell(game, player)
  local blocked = visibleHostileCells(game, player)
  local threats = {}
  for k in pairs(blocked) do
    threats[#threats + 1] = { x = k % 10000, y = math.floor(k / 10000) }
  end
  local sx, sy = playerPos(player)
  local queue = { { sx, sy, 0 } }
  local seen = { [ckey(sx, sy)] = true }
  local head = 1
  local best, bestScore
  while head <= #queue do
    local cx, cy, cd = queue[head][1], queue[head][2], queue[head][3]
    head = head + 1
    if cd > 0 then
      local nearest = 999
      for _, t in ipairs(threats) do
        local d = math.max(math.abs(t.x - cx), math.abs(t.y - cy))
        if d < nearest then nearest = d end
      end
      if nearest >= 2 then
        -- Prefer explored ground: fleeing into unseen rooms is how test25
        -- kited one wolf straight into the wasp nest. Each unknown neighbour
        -- adds a step of cost, so known-safe cells win when they exist.
        local unknown = 0
        for _, d in ipairs(DIRS) do
          local ux, uy = cx + d[1], cy + d[2]
          if inBounds(game.map, ux, uy) and not isKnown(ux, uy) then
            unknown = unknown + 1
          end
        end
        local score = cd - nearest * 2 + unknown * 4
        if bestScore == nil or score < bestScore then
          best, bestScore = { x = cx, y = cy }, score
        end
      end
    end
    if cd < 11 then
      for _, d in ipairs(DIRS) do
        local nx, ny = cx + d[1], cy + d[2]
        if inBounds(game.map, nx, ny) then
          local nk = ckey(nx, ny)
          local cell = cellAt(game.map, nx, ny)
          if not seen[nk] and not blocked[nk]
            and not (CC.WEB and cellTypeName(cell) == "web")
            and isPassableForPath(cell) then
            seen[nk] = true
            queue[#queue + 1] = { nx, ny, cd + 1 }
          end
        end
      end
    end
  end
  return best
end

-- findFleeCell needs a cell two tiles clear of every threat, which can be
-- impossible in a short dead end. The fallback picks the passable neighbour
-- farthest (chebyshev) from any visible hostile, so retreat always exists as
-- an option and the model can price it against swinging back.
local function desperateEscapeCell(game, player)
  local blocked = visibleHostileCells(game, player)
  local px, py = playerPos(player)
  local best, bestScore
  for _, d in ipairs(DIRS) do
    local nx, ny = px + d[1], py + d[2]
    if inBounds(game.map, nx, ny) then
      local nk = ckey(nx, ny)
      local cell = cellAt(game.map, nx, ny)
      if not blocked[nk]
        and not (CC.WEB and cellTypeName(cell) == "web")
        and isPassableForPath(cell) then
        local nearest = 999
        for key in pairs(blocked) do
          local tx, ty = key % 10000, math.floor(key / 10000)
          local dd = math.max(math.abs(tx - nx), math.abs(ty - ny))
          if dd < nearest then nearest = dd end
        end
        if bestScore == nil or nearest > bestScore then
          best, bestScore = { x = nx, y = ny }, nearest
        end
      end
    end
  end
  return best
end

local function passableNeighbourCount(game, x, y)
  local n = 0
  for _, d in ipairs(DIRS) do
    local nx, ny = x + d[1], y + d[2]
    if inBounds(game.map, nx, ny) and isPassableForPath(cellAt(game.map, nx, ny)) then
      n = n + 1
    end
  end
  return n
end

local function useLS(game, player, wand, why)
  log("lifestone [%s] hp=%d/%d charges=%s",
    why, player.health, player.maxHealth, tostring(wand.durability))
  S.lastLSTurn = gGameTurn or 0
  return useHealItem(game, player, wand)
end

-- Healing is a trade: the Lifestone also heals every creature in the four
-- cells around us, so its real value is the health we gain minus the extra
-- health we must chew through (at our DPS) and the damage taken during the
-- 12 ut the use action costs. Potions never help the enemy, but are finite.
local function tryHeal(game, player)
  if player.maxHealth <= 0 or player.health <= 0 then return false end
  local prof = playerProfile(game, player)
  local hp, maxhp = player.health, player.maxHealth
  local missing = maxhp - hp
  if missing < 50 then return false end

  local threats = threatList(game, player, prof)
  local adj, near = {}, {}
  for _, w in ipairs(threats) do
    if w.dist <= 1 then adj[#adj + 1] = w end
    if w.dist <= 6 then near[#near + 1] = w end
  end

  local wand = findLifestone(player)
  local charges = lsUses(wand)
  local nPot, bestPot = potionInfo(player)
  local reserve = S.hasKey and 0 or CC.LS_RESERVE
  local lsReady = charges > 0
    and ((gGameTurn or 0) - (S.lastLSTurn or -1000)) >= CC.LS_CD

  local Gp = math.min(math.floor(maxhp * CC.LS_FRAC), missing)
  local Ge = (#adj > 0) and adjacentHealTotal(game, player) or 0
  local D, lamMax, mNear = 0, 0, 0
  for _, w in ipairs(adj) do
    D = D + w.dps
    lamMax = math.max(lamMax, w.dps / math.max(0.1, w.ourDps))
  end
  for _, w in ipairs(near) do mNear = math.max(mNear, w.hit) end

  local dM_ls = Gp - lamMax * Ge - D * CC.C_LS
  local dM_pot = math.min(bestPot, missing) - D * CC.C_POT
  -- Only what can reach us right now makes this an emergency: enemies still
  -- walking in belong to the pack verdict and travel model, not to a heal
  -- spent while they close the gap for free.
  local poise = math.max(0, player.poise or 0)
  local lethal = poise <= 0 and hp <= lethalBound(adj, CC.C_LS)
  local emergency = #adj > 0
    and ((hp + poise) <= Hreq(adj, CC.C_LS, prof) or lethal)
  local lsOK = lsReady and (charges > reserve or emergency)
  local cdSafe = (#adj == 0)
    or (hp + Gp - D * (CC.C_LS + CC.LS_CD * prof.attackTime)
        >= Hreq(adj, prof.attackTime, prof))

  -- Unless the next bite ends us, killing an attacker that dies to one swing
  -- removes a damage source outright; let the combat branch take that turn.
  if emergency and not lethal then
    for _, w in ipairs(adj) do
      if w.hp <= w.ourHit * 0.9 then return false end
    end
  end

  if not emergency then
    -- After the key the mission is to leave alive: top up to 300 before
    -- moving toward the next objective.
    if S.hasKey and #adj == 0 and hp < CC.POSTKEY_HP then
      if lsReady and charges > 0 then return useLS(game, player, wand, "post-key") end
      if nPot > 0 and missing >= 150 then return drinkPotion(game, player) end
      return false
    end
    -- A clean window (nothing adjacent, or the adjacent creature is at full
    -- health) makes the heal free. No threat at all demands a full half charge.
    local dmMin = (#near > 0) and mNear or CC.DM_PEACE
    if lsOK and Gp >= CC.MIN_GE_HEAL and dM_ls >= dmMin and cdSafe then
      return useLS(game, player, wand, "clean window")
    end
    return false
  end

  -- Emergency: the next action can be fatal. A potion never helps the enemy,
  -- so it goes first. A Lifestone charge is only worth it while the health we
  -- gain still outweighs the health it hands back to the thing in front of us;
  -- healing a nearly-dead wolf back up is how these fights are lost.
  if nPot > 0 and dM_pot > 0 then
    return drinkPotion(game, player)
  end
  if lsOK and dM_ls > 0 then
    return useLS(game, player, wand, "emergency")
  end
  -- If the next blow ends the run, the only question is whether this heal
  -- lifts us above it; what the enemy regains buys it a swing, not the fight.
  if lsOK and lethal and hp + Gp > lethalBound(adj, CC.C_LS) then
    return useLS(game, player, wand, "lethal cover")
  end
  return false
end

-- All enemies but the carrier can be outrun: then taking the carrier down
-- first is safe, and it lets us break contact with the key afterwards.
local function othersOutrunnable(near, step)
  for _, t in ipairs(near) do
    if not t.carrier and not canOutrun(t, step) then return false end
  end
  return true
end

-- Smith ordering: damage per swing first, so the pack stops biting sooner.
-- The key carrier goes first when everything else can be left behind.
local function pickTarget(adj, near, step)
  local othersOK = othersOutrunnable(near, step)
  local best, bs
  for _, t in ipairs(adj) do
    if t.carrier and othersOK then return t end
    local s = t.dps / math.max(1, t.n)
    if t.summoner then s = s + 0.75 end
    if bs == nil or s > bs then best, bs = t, s end
  end
  return best
end

-- Where to go when nobody is adjacent: same ordering, but skip harmless
-- static things (wasp nests) that we should never walk into.
local function approachTarget(near, step)
  local othersOK = othersOutrunnable(near, step)
  local best, bs
  for _, t in ipairs(near) do
    if t.dps > 0.1 or t.dist <= 1 then
      local s = t.dps / math.max(1, t.n)
      if t.carrier and othersOK then s = s + 1000 end
      if t.summoner then s = s + 50 end
      s = s - t.dist * 0.01
      if bs == nil or s > bs then best, bs = t, s end
    end
  end
  return best
end

local function combatDiag(game, player, prof, threats)
  if now() - (S.combatDiagT or 0) < 0.7 then return end
  S.combatDiagT = now()
  local adj, near, parts = {}, {}, {}
  local incoming = 0
  for _, w in ipairs(threats) do
    incoming = incoming + w.dps
    if w.dist <= 1 then adj[#adj + 1] = w end
    if w.dist <= 6 or (w.aware and w.dist <= THREAT_RADIUS) then
      near[#near + 1] = w
    end
    parts[#parts + 1] = string.format("%s@%d,%d hp=%d d=%d dps=%.1f n=%d def=%.2f%s%s",
      tostring(w.actorType), w.actor.position.x, w.actor.position.y,
      math.floor(w.hp + 0.5), w.dist, w.dps, w.n, w.defFrac,
      w.carrier and "*" or "", w.aware and "" or "?")
  end
  local nPot = potionInfo(player)
  local wand = findLifestone(player)
  local lsCharges = lsUses(wand)
  local reserve = S.hasKey and 0 or CC.LS_RESERVE
  local v, need, res = "none", 0, 0
  if #near > 0 then
    local deadEnd = passableNeighbourCount(game, player.position.x, player.position.y) <= 1
    v, need, res = verdict(near, player.health + math.max(0, player.poise or 0), nPot,
      math.max(0, lsCharges - reserve), prof, deadEnd)
  end
  log("combat hp=%d/%d ps=%d step=%.2f ourdps=%.2f hit=%.0f He=%d Hls=%d Hmax=%d in=%.2f v=%s need=%d res=%d [%s]",
    player.health, player.maxHealth, math.floor(player.poise or 0),
    playerStep(prof), prof.dps, prof.hit,
    math.floor(Hreq(near, prof.attackTime, prof)),
    math.floor(Hreq(near, CC.C_LS, prof)),
    math.floor(lethalBound(near, CC.C_LS)),
    incoming, v, math.floor(need), math.floor(res), table.concat(parts, " "))
end

-- A choke is a geometric property, not a dead end: count how many passable
-- neighbours are on the pack's side. With at most one approach side only one
-- attacker can stand next to us at a time, even if a retreat exit remains.
local function chokeInfo(game, x, y, threats)
  local open, approach = 0, 0
  for _, d in ipairs(DIRS) do
    local nx, ny = x + d[1], y + d[2]
    if inBounds(game.map, nx, ny) and isPassableForPath(cellAt(game.map, nx, ny)) then
      open = open + 1
      local side = false
      for _, t in ipairs(threats) do
        local ax, ay = t.actor.position.x, t.actor.position.y
        local here = math.abs(ax - x) + math.abs(ay - y)
        local there = math.abs(ax - nx) + math.abs(ay - ny)
        if there < here then side = true; break end
      end
      if side then approach = approach + 1 end
    end
  end
  return open, approach
end

-- Reachable cell where at most one enemy can reach us at a time. Funnels with
-- an exit are preferred over dead ends; dead ends remain the fallback when the
-- pack surrounds us.
local function findRetreatCell(game, player)
  local blocked = visibleHostileCells(game, player)
  local sx, sy = playerPos(player)
  local threats = {}
  for k in pairs(blocked) do
    threats[#threats + 1] = {
      actor = { position = { x = k % 10000, y = math.floor(k / 10000) } },
    }
  end

  local queue = { { sx, sy, 0 } }
  local seen = { [ckey(sx, sy)] = true }
  local best, bestScore
  local head = 1
  while head <= #queue do
    local cx, cy, cd = queue[head][1], queue[head][2], queue[head][3]
    head = head + 1

    if cd > 0 and cd <= 8 then
      local open, approach = chokeInfo(game, cx, cy, threats)
      if approach <= 1 and open >= 1 and not blocked[ckey(cx, cy)] then
        local nearest = 999
        for _, t in ipairs(threats) do
          local tx, ty = t.actor.position.x, t.actor.position.y
          local d = math.max(math.abs(tx - cx), math.abs(ty - cy))
          if d < nearest then nearest = d end
        end
        local score = cd * 2 + nearest * 4
        if open >= 2 then score = score - 2 end
        if bestScore == nil or score < bestScore then
          best = { x = cx, y = cy, open = open, approach = approach }
          bestScore = score
        end
      end
    end

    if cd < 8 then
      for _, d in ipairs(DIRS) do
        local nx, ny = cx + d[1], cy + d[2]
        if inBounds(game.map, nx, ny) then
          local nk = ckey(nx, ny)
          local cell = cellAt(game.map, nx, ny)
          if not seen[nk] and not blocked[nk]
            and not (CC.WEB and cellTypeName(cell) == "web")
            and isPassableForPath(cell) then
            seen[nk] = true
            queue[#queue + 1] = { nx, ny, cd + 1 }
          end
        end
      end
    end
  end
  return best
end

-- Step toward a cell at least two tiles from every visible enemy. Unbroken
-- web is treated as a wall while retreating: stepping on it costs us ~46 ut,
-- which hands the pack several free bites.
local function doFlee(game, player, cell, why)
  cell = cell or findFleeCell(game, player)
  local steps = cell and travelSteps(game, player, cell.x, cell.y, true, true)
  if not (steps and steps[1]) then
    cell = desperateEscapeCell(game, player)
    if not cell then return false end
    steps = { { x = cell.x, y = cell.y } }
    why = (why and (why .. ", one step")) or "one step"
  end
  pressDelta(steps[1].x, steps[1].y)
  S.phase = "flee"
  if now() - (S.fleeLogT or 0) > 2 then
    S.fleeLogT = now()
    log("fleeing to %d,%d (%s)", cell.x, cell.y, why or "break contact")
  end
  return true
end

-- Kiting a faster creature only works if we can open a two-tile gap: that
-- takes kGap player steps, and the Lifestone must be ready by the end of them.
local function kiteHealOK(game, player, prof, near, step)
  local wand = findLifestone(player)
  if not wand or (wand.durability or 0) <= 0 then return false end
  local need = 0
  for _, t in ipairs(near) do
    if not canOutrun(t, step) then return false end
    need = math.max(need, kGap(t, step))
  end
  if need <= 0 then return false end
  local remaining = math.max(0,
    CC.LS_CD - ((gGameTurn or 0) - (S.lastLSTurn or -1000)))
  if remaining > need then return false end
  local cell = findFleeCell(game, player)
  if not cell then return false end
  local steps = navSteps(game, player, cell.x, cell.y, true, true)
  if not (steps and #steps >= need + 1) then return false end
  S.kiteCell = cell
  return true
end

-- A retreat is only worth starting if we get there before a faster enemy can
-- touch us along the way.
local function retreatPath(game, player, cell, near, step)
  if not cell then return nil end
  local steps = travelSteps(game, player, cell.x, cell.y, true, true)
  if not (steps and steps[1]) then return nil end
  for _, t in ipairs(near) do
    local km = kMax(t, t.dist, step)
    if km < math.huge and #steps > km - 1 then return nil end
  end
  return steps
end

-- ---------------------------------------------------------------------------
-- Risk-based combat choice
--
-- Every legal first action is rolled forward through the same clock model:
-- enemy bites during the action, poise absorption, poison, heals that also
-- heal adjacent enemies, and the health/time cost of the chosen order. The
-- chooser compares death probability first, then end health, then resource
-- value; it never trades a real risk increase for speed.
local function modelState(game, player)
  return {
    hp = player.health,
    maxHP = player.maxHealth,
    poise = math.max(0, player.poise or 0),
    maxPoise = math.max(1, player.maxPoise or 200),
    injuryAge = injuryAge(game),
    poison = math.max(0, math.min(1, player.poison or 0)),
  }
end

local function buildPack(near)
  local pack = {}
  for i, w in ipairs(near) do
    pack[i] = {
      hp = w.hp,
      maxHP = math.max(w.hp, w.maxHP or w.hp),
      hit = w.modelHit or w.hit,
      maxHit = math.max(w.modelHit or w.hit, w.modelMaxHit or w.maxHit),
      attackTime = w.attackTime,
      speed = w.speed,
      dist = w.dist,
      ourHit = w.ourHit,
      aware = w.aware,
      summoner = w.summoner and w.summonReady,
      summonCooldown = w.summonCooldown,
      poisonPerHit = w.poisonPerHit,
      ref = w,
      id = i,
    }
  end
  return pack
end

-- A charge is worth more when no key has been found yet: the remaining
-- incursion still contains the fight for the chest key and the walk out.
local function resourceValue(hasKey)
  return hasKey and 0.4 or 1.0
end

local function poiseWaitTime(game, player)
  local poise = math.max(0, player.poise or 0)
  local maxPoise = math.max(1, player.maxPoise or 200)
  local missing = math.max(0, maxPoise - poise)
  if missing <= 0 then return 0 end
  local delay = math.max(0, 36 - injuryAge(game))
  return delay + missing / (0.0125 * maxPoise)
end

local function buildCombatOptions(game, player, prof, adj, near, pack, deadEnd,
                                  nPot, bestPot, wand, charges, fleeWanted)
  local actions, pidx = {}, {}
  for i, t in ipairs(pack) do pidx[t.ref] = i end
  local step = playerStep(prof)
  local hp = player.health
  local maxhp = player.maxHealth
  local missing = math.max(0, maxhp - hp)
  local val = resourceValue(S.hasKey)

  for _, w in ipairs(adj) do
    actions[#actions + 1] = {
      kind = "attack", target = pidx[w], ref = w,
      time = prof.attackTime, label = "hit:" .. tostring(w.actorType),
      resourceCost = 0,
    }
  end

  if nPot > 0 and missing > 0 then
    actions[#actions + 1] = {
      kind = "heal", item = "potion",
      healAmount = math.min(bestPot, missing), time = CC.C_POT,
      label = "potion", resourceCost = 0.55 * val,
    }
  end

  local lsReady = charges > 0
    and ((gGameTurn or 0) - (S.lastLSTurn or -1000)) >= CC.LS_CD
  -- A heal with nothing to heal still costs a full use turn, so it must never
  -- appear as an option (it was picked five times at full health in test24).
  local Gp = math.min(math.floor(maxhp * CC.LS_FRAC), missing)
  if lsReady and Gp > 0 then
    actions[#actions + 1] = {
      kind = "heal", item = "lifestone", healAmount = Gp,
      enemyHeals = adjacentHealMap(pack, player, Gp), time = CC.C_LS,
      label = "lifestone", resourceCost = 0.32 * val,
    }
  end

  if #adj > 0 then
    -- A single adjacent wolf that we can afford to kill must be killed, not
    -- kited forever: fleeing at full health dragged a whole train of enemies
    -- through the wasp nest in test25. Flee is offered only when the pack
    -- verdict says the fight is unaffordable, we are nearly dead, or the
    -- mission is already complete and disengaging is the goal.
    local cell, fsteps
    if fleeWanted then
      cell, fsteps = S.modelFleeCell, S.modelFleeSteps
      if S.modelFleeTurn ~= (gGameTurn or 0) then
        cell = findFleeCell(game, player)
        fsteps = cell and travelSteps(game, player, cell.x, cell.y, true, true) or nil
        S.modelFleeCell, S.modelFleeSteps, S.modelFleeTurn = cell, fsteps, gGameTurn or 0
      end
    end
    if cell and fsteps and fsteps[1] then
      local outrunnable = true
      for _, t in ipairs(near) do
        if not canOutrun(t, step) then outrunnable = false end
      end
      actions[#actions + 1] = {
        kind = "flee", cell = cell, moveSteps = math.min(#fsteps, 8),
        time = step, terminal = outrunnable,
        label = "flee", resourceCost = 0.01,
      }
    else
      -- Cornered: every reachable cell is next to a threat, but standing to
      -- trade blows must still compete against the safest single step.
      local escape = desperateEscapeCell(game, player)
      if escape then
        actions[#actions + 1] = {
          kind = "flee", cell = escape, moveSteps = 1, terminal = false,
          label = "retreat", resourceCost = 0.02,
        }
      end
    end
  else
    local wait = poiseWaitTime(game, player)
    if wait > 0 then
      actions[#actions + 1] = {
        kind = "wait", time = math.max(12, math.min(wait, 96)),
        label = "wait-poise", resourceCost = 0,
      }
    end
    if #near >= 2 and not deadEnd then
      local ch = findRetreatCell(game, player)
      if ch then
        actions[#actions + 1] = {
          kind = "choke", cell = ch, time = step, moveSteps = 1,
          label = "choke-" .. tostring(ch.open) .. "/" .. tostring(ch.approach),
          resourceCost = 0.02,
        }
      end
    end
  end
  return actions
end

local function betterEval(a, b)
  local au, bu = a.pDeathUpper or 0, b.pDeathUpper or 0
  if math.abs(au - bu) > 0.02 then return au < bu end
  local ad, bd = a.pDeath or 0, b.pDeath or 0
  if math.abs(ad - bd) > 1e-9 then return ad < bd end
  -- All options die in every trial: survival time is the only axis left, and a
  -- retreat that delays death still beats standing to trade blows.
  if ad >= 1 - 1e-9 then
    local at, bt = a.meanDuration or 0, b.meanDuration or 0
    if math.abs(at - bt) > 1 then return at > bt end
  end
  local ah, bh = a.meanHP or 0, b.meanHP or 0
  if math.abs(ah - bh) > 1 then return ah > bh end
  local ac, bc = a.action.resourceCost or 0, b.action.resourceCost or 0
  if math.abs(ac - bc) > 1e-9 then return ac < bc end
  return (a.meanDuration or 0) < (b.meanDuration or 0)
end

local function chooseEval(evals, hasKey, emergency)
  if #evals == 0 then return nil, "no evaluation" end
  table.sort(evals, betterEval)
  local best = evals[1]
  -- After the key, surfacing alive matters more than finishing another fight.
  -- Only override when the escape itself is within the risk budget.
  if hasKey and not emergency and best.action.kind ~= "flee" then
    for _, e in ipairs(evals) do
      if e.action.kind == "flee" and (e.pDeathUpper or 1) <= CFG.alpha * 1.5 then
        return e, "post-key disengage"
      end
    end
  end
  if (best.pDeathUpper or 1) <= CFG.alpha then
    return best, "within risk budget"
  end
  return best, "minimise risk"
end

-- Summoned units are not in the threat list yet, but they are part of the
-- fight's cost. A wasp nest spends its energy once and calls 2-4 hornets (or
-- one queen), which act six ut after appearing.
local function summonOptions(prof, near)
  local hasSummoner = false
  for _, w in ipairs(near) do
    if w.summoner and w.summonReady then hasSummoner = true end
  end
  if not hasSummoner then return nil end
  local armour = (prof.physFrac or 1) * (1 - math.min(0.9, prof.dodge or 0))
  local hitChance = 1 - math.min(0.9, prof.dodge or 0)
  local resist = 1 - (prof.poisonResist or 0)
  local function sting(dmg, might, time, hp, speed, poison)
    local raw = dmg * (1 + math.min(1, (might or 0) / 35))
    return {
      -- mean of the two-roll variance (0.5) with a 10% crit at x2
      hit = raw * 0.75 * 1.1 * armour,
      maxHit = raw * 2 * armour,
      attackTime = time,
      speed = speed,
      hp = hp,
      poisonPerHit = (poison or 0) * hitChance * resist,
      ourHit = prof.hit * 0.8,
    }
  end
  return {
    normal = sting(100, 3, 24, 55, 1.8, 0.15), -- hornets / small_sting
    queen = sting(60, 5, 12, 200, 1.2, 0.15),  -- queen_hornet / normal_sting
    countMin = 2, countMax = 4, queenChance = 1 / 6,
    lag = 6, first = 12,
  }
end

local function modelChoose(game, player, prof, adj, near, deadEnd, nPot, bestPot,
                           wand, charges, emergency, fleeWanted)
  if not Model then return nil end
  local pack = buildPack(near)
  if #pack == 0 then return nil end
  local actions = buildCombatOptions(game, player, prof, adj, near, pack, deadEnd,
    nPot, bestPot, wand, charges, fleeWanted)
  if #actions == 0 then return nil end
  local state = modelState(game, player)
  local opts = {
    N = CFG.modelN,
    horizon = CFG.horizon,
    seed = (gGameTurn or 0) + 1,
    summon = summonOptions(prof, near),
  }
  local evals = {}
  for _, a in ipairs(actions) do
    local ok, ev = pcall(Model.evaluate, a, state, pack, prof, opts)
    if ok and ev then
      ev.action = a
      evals[#evals + 1] = ev
    end
  end
  if #evals == 0 then
    S.modelErrors = (S.modelErrors or 0) + 1
    return nil
  end
  local chosen, reason = chooseEval(evals, S.hasKey, emergency)
  return chosen, evals, reason
end

local function logChoice(chosen, evals, reason)
  if not chosen then return end
  if now() - (S.choiceLogT or 0) < 1 then return end
  S.choiceLogT = now()
  local parts = {}
  for _, e in ipairs(evals) do
    parts[#parts + 1] = string.format("%s d=%.0f%% u=%.0f%% hp=%.0f",
      e.action.label, 100 * (e.pDeath or 0), 100 * (e.pDeathUpper or 0),
      e.meanHP or 0)
  end
  log("choice %s (%s) [%s]", chosen.action.label, reason or "",
    table.concat(parts, " "))
end

local function executeChoice(game, player, prof, chosen, near)
  local a = chosen.action
  local px, py = playerPos(player)
  if a.kind == "attack" then
    local w = a.ref
    if w and w.dist <= 1 then
      pressDelta(w.actor.position.x - px, w.actor.position.y - py)
      S.phase = "combat"
      S.holdSinceTurn = nil
      return true
    end
  elseif a.kind == "heal" then
    if a.item == "lifestone" then
      local wand = findLifestone(player)
      if wand and lsUses(wand) > 0 then
        S.phase = "heal"
        return useLS(game, player, wand, "model")
      end
    elseif a.item == "potion" then
      S.phase = "heal"
      return drinkPotion(game, player)
    end
  elseif a.kind == "wait" then
    pressKey("space")
    S.phase = "wait-poise"
    return true
  elseif a.kind == "flee" then
    return doFlee(game, player, a.cell, "model")
  elseif a.kind == "choke" then
    local steps = retreatPath(game, player, a.cell, near, playerStep(prof))
    if steps and steps[1] then
      pressDelta(steps[1].x, steps[1].y)
      S.retreatTarget = a.cell
      S.phase = "retreat"
      return true
    end
  end
  return false
end

local function combatStep(game, player)
  local prof = playerProfile(game, player)
  local threats = threatList(game, player, prof)
  if #threats == 0 then
    S.retreatTarget = nil
    S.holdSinceTurn = nil
    return false
  end
  combatDiag(game, player, prof, threats)

  local px, py = playerPos(player)
  local adj, near = {}, {}
  for _, w in ipairs(threats) do
    if w.dist <= 1 then adj[#adj + 1] = w end
    -- An awake creature within detection range is coming to us whether we
    -- walk past it or not, so it belongs in the fight's cost, not just in the
    -- threat list. Unaware ones further than six steps are ignored.
    if w.dist <= 6 or (w.aware and w.dist <= THREAT_RADIUS) then
      near[#near + 1] = w
    end
  end
  if #near == 0 then
    S.retreatTarget = nil
    S.holdSinceTurn = nil
    return false
  end

  local step = playerStep(prof)
  local deadEnd = passableNeighbourCount(game, px, py) <= 1
  local allOut = true
  for _, t in ipairs(near) do
    if not canOutrun(t, step) then allOut = false end
  end
  local poise = math.max(0, player.poise or 0)
  local emergency = #adj > 0
    and ((player.health + poise) <= Hreq(adj, CC.C_LS, prof)
      or (poise <= 0 and player.health <= lethalBound(adj, CC.C_LS)))

  local function bump(t)
    pressDelta(t.actor.position.x - px, t.actor.position.y - py)
  end

  -- 1. Grace blow: finish anything one swing away before spending a turn on
  -- healing; a dead attacker stops biting.
  for _, w in ipairs(adj) do
    if w.hp <= w.ourHit * 0.9 then
      bump(w)
      S.phase = "combat"
      return true
    end
  end

  -- 2. Risk choice. Every legal first action (hit any adjacent target, potion,
  -- Lifestone, flee, wait for poise, choke) is rolled through the same clock
  -- model; the winner is the one that best preserves the run, not the one with
  -- the best immediate exchange rate.
  local nPot, bestPot = potionInfo(player)
  local wand = findLifestone(player)
  local charges = lsUses(wand)
  local reserve = S.hasKey and 0 or CC.LS_RESERVE
  local v = verdict(near, player.health + poise, nPot,
    math.max(0, charges - reserve), prof, deadEnd)
  local fleeWanted = S.hasKey or v == "avoid"
    or player.health <= math.floor(player.maxHealth * 0.3)
  -- The model's action set prices contact decisions (hit, heal, flee, wait,
  -- choke); approach and avoidance at range belong to the movement layer
  -- below. Running it with nothing adjacent once made a distant wolf's
  -- approach into an excuse to burn Lifestone charges at full health.
  if Model and CFG.model and (S.modelErrors or 0) < 5 and #adj > 0 then
    local chosen, evals, reason = modelChoose(game, player, prof, adj, near,
      deadEnd, nPot, bestPot, wand, charges, emergency, fleeWanted)
    if chosen then
      logChoice(chosen, evals, reason)
      if executeChoice(game, player, prof, chosen, near) then return true end
    end
  end

  -- 3. Legacy fallback: healing. In an emergency a heal that lands now beats
  -- a kite that only pays off if the gap actually opens; if no heal is worth
  -- taking (it would revive the thing in front of us), try to kite, then run.
  if emergency then
    if tryHeal(game, player) then return true end
    if allOut and kiteHealOK(game, player, prof, near, step) then
      if doFlee(game, player, S.kiteCell, "kite-heal") then return true end
    end
    if allOut and doFlee(game, player, nil, "emergency") then return true end
    local t = pickTarget(adj, near, step)
    if t then
      bump(t)
      S.phase = "combat"
      return true
    end
  else
    if tryHeal(game, player) then return true end
  end

  -- 3. Post-key: do not get dragged into another fight. tryHeal has already
  -- topped us back to 300; break contact and keep moving to the objective.
  if S.hasKey then
    S.retreatTarget = nil
    if #adj == 0 then
      S.holdSinceTurn = nil
      return false
    end
    if allOut then
      if doFlee(game, player, nil, "post-key") then return true end
    end
  end

  -- 4. Go/no-go for the pack (v and reserve were computed before the model so
  -- the flee option only appears when the fight is actually unaffordable).
  local function poisonFast()
    for _, t in ipairs(near) do
      if (t.fast and t.poison) or t.actorType == "albino_beetle" then
        return true
      end
    end
    return false
  end

  -- 5. Avoid. Never trade blows in the open; fast poisoners are outrun
  -- outright, anything else may be met in a dead end if we reach it first.
  if v == "avoid" then
    -- If we can outrun them, one parting bite is cheaper than standing in a
    -- fight the model says we cannot afford, even if they are already on us.
    if allOut and doFlee(game, player, nil, "avoid") then return true end
    if not poisonFast() then
      local cell = S.retreatTarget
      if cell and cell.x == px and cell.y == py then
        cell = nil
        S.retreatTarget = nil
      end
      if not cell then
        cell = findRetreatCell(game, player)
        S.retreatTarget = cell
      end
      local steps = retreatPath(game, player, cell, near, step)
      if steps then
        pressDelta(steps[1].x, steps[1].y)
        S.phase = "retreat"
        return true
      end
    end
    local t = pickTarget(adj, near, step)
    if t then
      bump(t)
      S.phase = "combat"
      return true
    end
    if allOut and doFlee(game, player, nil, "avoid") then return true end
    return false
  end

  -- 6. Two or more: fight only behind a corner. Walk there first; do not
  -- linger in the open while the alternative exists.
  if v == "choke" and #near >= 2 and not deadEnd then
    local cell = S.retreatTarget
    if cell and cell.x == px and cell.y == py then
      cell = nil
      S.retreatTarget = nil
    end
    if not cell then
      cell = findRetreatCell(game, player)
      S.retreatTarget = cell
      if cell then
        local _, openNeed = verdict(near, player.health + math.max(0, player.poise or 0),
          nPot, math.max(0, charges - reserve), prof, false)
        log("retreating to %d,%d (hp=%d need=%d)",
          cell.x, cell.y, player.health, math.floor(openNeed or 0))
      end
    end
    local steps = retreatPath(game, player, cell, near, step)
    if steps then
      pressDelta(steps[1].x, steps[1].y)
      S.phase = "retreat"
      return true
    end
    if #adj == 0 and allOut and doFlee(game, player, nil, "no choke") then
      return true
    end
  else
    S.retreatTarget = nil
  end

  -- 7. Adjacent: hit the target Smith ordering picks.
  local t = pickTarget(adj, near, step)
  if t then
    bump(t)
    S.phase = deadEnd and "hold-choke" or "combat"
    S.holdSinceTurn = nil
    return true
  end

  -- 8. Nobody adjacent. In a choke, wait a bounded number of actions for the
  -- pack to walk in; anywhere else, close in on the chosen enemy.
  if deadEnd or v == "choke" then
    local approachable, maxWait = false, 0
    for _, w in ipairs(near) do
      if w.dist > 1 and w.actor.actorData.brainFunction ~= "brainStatic" then
        approachable = true
        maxWait = math.max(maxWait,
          math.ceil((w.dist * enemyStep(w) + w.attackTime) / 8))
      end
    end
    if approachable then
      S.holdSinceTurn = (S.holdSinceTurn or 0) + 1
      if S.holdSinceTurn <= maxWait then
        pressKey("space")
        S.phase = "hold-choke"
        return true
      end
      S.holdSinceTurn = nil
    end
  end

  local target = approachTarget(near, step)
  if target then
    local ex, ey = target.actor.position.x, target.actor.position.y
    local steps = navSteps(game, player, ex, ey, false, true)
    if steps and steps[1] then
      pressDelta(steps[1].x, steps[1].y)
      S.phase = "combat"
      return true
    end
    for _, d in ipairs(tools.aroundNESW) do
      local nx, ny = ex + d[1], ey + d[2]
      if inBounds(game.map, nx, ny) and cellWalkable(cellAt(game.map, nx, ny)) then
        local approach = navSteps(game, player, nx, ny, false, true)
        if approach and approach[1] then
          pressDelta(approach[1].x, approach[1].y)
          S.phase = "combat"
          return true
        end
      end
    end
    if now() - (S.combatLogT or 0) > 3 then
      S.combatLogT = now()
      log("combat: %s at %d,%d dist=%s unreachable from %d,%d",
        tostring(target.actorType), ex, ey, tostring(target.dist), px, py)
    end
  end
  return false
end

local function dungeonExitXY(game)
  local name = game.currentWorldName
  local x, y = game.triggerData:findTriggerXYOnLevelWithAction(name, "fnUp")
  if x then return x, y end
  local wd = game:getWorldDataWithName(name)
  local entrance = wd and wd.entrance or "Yarrow"
  return game.triggerData:findTriggerXYOnLevelWithActionAndData(name, "playerStart", entrance)
end

local function keyChestXY(game)
  local list = game.triggerData:getAllTriggersOnLevelWithActionName(
    game.currentWorldName, "exitKey")
  if not list or #list == 0 then return nil end
  local t = list[1]
  return t.x, t.y
end

-- ---------------------------------------------------------------------------
-- Campaign progression (guide order). Each town owns the dungeon in its
-- leadsTo field; clearing that dungeon returns us to the town, and the next
-- entry in this order becomes the travel target on the overworld.
local TOWN_ORDER = {
  "Yarrow", "Moon-upon-Thoss", "Barrow-Linn", "Harrowdus",
  "Hearthaven", "Wintersholl", "The_Red_Grove",
}

local function townIndex(name)
  for i, n in ipairs(TOWN_ORDER) do
    if n == name then return i end
  end
  return nil
end

-- Each god pays +2 devotion the first time the player enters its home town.
-- That is the only steady source of devotion before Relic Dungeons, and the
-- stat Gifts it buys are the difference against the Keep's constructs. The
-- tour visits every god town once, filtered against the achievements stored in
-- the save, so a restart never repeats a paid visit.
local TOUR_TOWNS = {
  { town = "Barrow-Linn",   ach = "homeTown3" },  -- lordsOfDust
  { town = "Harrowdus",     ach = "homeTown2" },  -- deathsHarlequin
  { town = "Hearthaven",    ach = "homeTown5" },  -- blindAngels
  { town = "Wintersholl",   ach = "homeTown1" },  -- greatForestWolf
  { town = "The_Red_Grove", ach = "homeTown4" },  -- ladyOfTheSanguineMoon
}

local function tourPending(game)
  if not CFG.tour then return nil end
  if S.tourPending == nil then
    S.tourPending = {}
    for _, t in ipairs(TOUR_TOWNS) do
      local done = false
      pcall(function()
        local ach = game:getAchievements()
        done = ach and ach.done and ach.done[t.ach] == true
      end)
      if not done then S.tourPending[#S.tourPending + 1] = t.town end
    end
    log("tour: god towns pending [%s]", table.concat(S.tourPending, ", "))
  end
  return #S.tourPending > 0 and S.tourPending or nil
end

local function tourRemove(name)
  if not S.tourPending then return false end
  for i, n in ipairs(S.tourPending) do
    if n == name then
      table.remove(S.tourPending, i)
      log("tour: %s visited (+2 devotion), %d god towns left", name, #S.tourPending)
      return true
    end
  end
  return false
end

-- Nearest walkable cell past the town's zoom bounds. Moving into that zone
-- makes the game call zoomOut() by itself (hasWalkedOffMapEdge), which drops
-- us back onto the overworld at the town's entrance.
local function fleeZoneCell(game, player)
  local map = game.map
  local sx, sy = playerPos(player)
  local queue = { { sx, sy, 0 } }
  local seen = { [ckey(sx, sy)] = true }
  local head = 1
  while head <= #queue do
    local cx, cy, cd = queue[head][1], queue[head][2], queue[head][3]
    head = head + 1
    if cd > 0 and game:isXYInFleeZone(cx, cy) then
      return { x = cx, y = cy }
    end
    if cd < 80 then
      for _, d in ipairs(DIRS) do
        local nx, ny = cx + d[1], cy + d[2]
        if inBounds(map, nx, ny) and not seen[ckey(nx, ny)]
          and cellWalkable(cellAt(map, nx, ny)) then
          seen[ckey(nx, ny)] = true
          queue[#queue + 1] = { nx, ny, cd + 1 }
        end
      end
    end
  end
end

-- Walk toward a named town's entrance trigger on the overworld. Stepping onto
-- the trigger cell makes the game zoom into the town on its own.
local overRoute = { grid = nil, w = 0, h = 0, entries = nil,
  failTarget = nil, failWorld = nil }

-- The game keeps only a 96x96 window of the 512x512 overworld in memory, so a
-- window-local BFS dead-ends behind terrain it cannot see around. The whole map
-- is in data/save/Overworld.png (tile index packed in R+G, same encoding as
-- tools.convertRGToTileIndex); decode it once and path over the full world,
-- stepping one cell at a time so every move stays inside the loaded window.
local function overworldEntrySet(game)
  if overRoute.entries then return overRoute.entries end
  local set = {}
  local ok, list = pcall(function() return game.triggerData.overworldEntryPoints end)
  if ok and type(list) == "table" then
    for _, t in ipairs(list) do
      if t.x and t.y then set[ckey(t.x, t.y)] = true end
    end
  end
  overRoute.entries = set
  return set
end

local function overworldWalkGrid()
  if overRoute.grid then return overRoute.grid end
  local ok, img = pcall(love.image.newImageData, "data/save/Overworld.png")
  if not ok or not img then
    log("travel: cannot read Overworld.png (%s)", tostring(img))
    return nil
  end
  local CellData = require("cell_data")
  local w, h = img:getDimensions()
  local bytes = img:getString()
  local grid = {}
  local b = 1
  local walked = 0
  for y = 0, h - 1 do
    local row = {}
    grid[y] = row
    for x = 0, w - 1 do
      local r, g = string.byte(bytes, b, b + 1)
      local data = CellData.getCellDataWithIndex(r + g * 256)
      row[x] = data ~= nil and data.isWalkable == true
      if row[x] then walked = walked + 1 end
      b = b + 4
    end
  end
  overRoute.grid, overRoute.w, overRoute.h = grid, w, h
  log("travel: decoded overworld walk grid %dx%d (%d walkable)", w, h, walked)
  return grid
end

local function overworldPath(game, sx, sy, tx, ty)
  local grid = overworldWalkGrid()
  if not grid then return nil end
  local w, h = overRoute.w, overRoute.h
  if tx < 0 or ty < 0 or tx >= w or ty >= h then return nil end
  local entries = overworldEntrySet(game)
  local startK = sy * 4096 + sx
  local targetK = ty * 4096 + tx
  local parent = { [startK] = false }
  local queue = { startK }
  local head = 1
  local found = startK == targetK
  while head <= #queue and not found do
    local k = queue[head]
    head = head + 1
    local cx, cy = k % 4096, math.floor(k / 4096)
    for _, d in ipairs(DIRS) do
      local nx, ny = cx + d[1], cy + d[2]
      if nx >= 0 and ny >= 0 and nx < w and ny < h then
        local nk = ny * 4096 + nx
        if parent[nk] == nil then
          local isTarget = nx == tx and ny == ty
          local entry = entries[ckey(nx, ny)]
          if grid[ny][nx] and (isTarget or not entry) then
            parent[nk] = k
            if isTarget then found = true; break end
            queue[#queue + 1] = nk
          end
        end
      end
    end
  end
  if not found then
    overRoute.failTarget, overRoute.failWorld = S.nextTown, game.currentWorldName
    if now() - (S.pathFailLogT or 0) > 5 then
      S.pathFailLogT = now()
      log("travel: no global route from %d,%d to %d,%d", sx, sy, tx, ty)
    end
    return nil
  end
  local path = {}
  local k = targetK
  while k and k ~= startK do
    path[#path + 1] = { x = k % 4096, y = math.floor(k / 4096) }
    k = parent[k]
  end
  for i = 1, math.floor(#path / 2) do
    path[i], path[#path - i + 1] = path[#path - i + 1], path[i]
  end
  return path
end

-- Derive the next cell from the player's actual position instead of consuming
-- an index. The game drops injected keys while other actors spend time, so the
-- same step gets requested for several ticks in a row and must stay valid.
local function pathStepFrom(path, px, py)
  for i = 1, #path do
    if path[i].x == px and path[i].y == py then
      return path[i + 1]
    end
  end
  local first = path[1]
  if first and math.abs(first.x - px) + math.abs(first.y - py) == 1 then
    return first
  end
end

-- First step of the cached global route, recomputed whenever the player is not
-- standing where the route expects or the target changed.
local function globalOverworldStep(game, player, wx, wy)
  -- Retrying a BFS that already proved the target unreachable just burns
  -- frames; the ferry leg handles the crossing from here.
  if overRoute.failTarget == S.nextTown and overRoute.failWorld == game.currentWorldName then
    return nil
  end
  local px, py = playerPos(player)
  local path = overRoute.path
  if not (path and overRoute.target == S.nextTown and overRoute.endX == wx
    and overRoute.endY == wy) then
    path = overworldPath(game, px, py, wx, wy)
    if not path or #path == 0 then
      overRoute.path = nil
      return nil
    end
    overRoute.path = path
    overRoute.target, overRoute.endX, overRoute.endY = S.nextTown, wx, wy
    log("travel: global route to %s is %d steps", tostring(S.nextTown), #path)
  end
  local step = pathStepFrom(path, px, py)
  if not step then
    overRoute.path = nil
    return nil
  end
  return step.x - px, step.y - py
end

-- The overworld is an archipelago and the only sea link joins Moon-upon-Thoss
-- (the mainland gate) with the little dock town beside Barrow-Linn. When no
-- land route exists, walk to the gate for the outbound crossing or to the dock
-- for the free return, and press Return there to enter the town that sails.
local FERRY_DOCK = { x = 192, y = 292 }
local FERRY_GATE = { x = 248, y = 244 }
local ferryRoute = { target = nil, world = nil, goal = nil, path = nil,
  failed = false }

local function ferryLegStep(game, player, target)
  local px, py = playerPos(player)
  if ferryRoute.target ~= target or ferryRoute.world ~= game.currentWorldName then
    ferryRoute.target, ferryRoute.world = target, game.currentWorldName
    ferryRoute.goal, ferryRoute.path = nil, nil
    ferryRoute.failed = false
  end
  if ferryRoute.failed then return nil end
  if not (ferryRoute.goal and ferryRoute.path) then
    ferryRoute.goal, ferryRoute.path = nil, nil
    local dock = overworldPath(game, px, py, FERRY_DOCK.x, FERRY_DOCK.y)
    if dock then
      ferryRoute.goal, ferryRoute.path = FERRY_DOCK, dock
      log("travel: ferry leg to the Barrow-Linn dock (%d steps)", #dock)
    elseif target == "Barrow-Linn" then
      local gate = overworldPath(game, px, py, FERRY_GATE.x, FERRY_GATE.y)
      if gate then
        ferryRoute.goal, ferryRoute.path = FERRY_GATE, gate
        log("travel: ferry leg to the Moon-upon-Thoss gate (%d steps)", #gate)
      end
    end
    if not ferryRoute.path then
      ferryRoute.failed = true
      log("travel: no ferry leg from %d,%d for %s", px, py, tostring(target))
      return nil
    end
  end
  if px == ferryRoute.goal.x and py == ferryRoute.goal.y then
    pressKey("return")
    S.phase = "ferry-board"
    return true
  end
  local step = pathStepFrom(ferryRoute.path, px, py)
  if not step then
    -- Combat nudged us off the route: rebuild from here next tick.
    ferryRoute.path = nil
    return nil
  end
  return step.x - px, step.y - py
end

local function overworldTravelStep(game, player, target)
  local ok, wx, wy = pcall(game.getPositionOfNamedLocationInOverworld, game, target)
  if not ok or not wx or not wy then
    if now() - (S.travelLogT or 0) > 5 then
      S.travelLogT = now()
      log("travel: no overworld coords for %s", tostring(target))
    end
    return false
  end
  local px, py = playerPos(player)
  if px == wx and py == wy then
    pressKey("return")
    S.phase = "enter:" .. target
    return true
  end
  local dx, dy
  local landRouteGone = overRoute.failTarget == S.nextTown
    and overRoute.failWorld == game.currentWorldName
  if not landRouteGone then
    dx, dy = globalOverworldStep(game, player, wx, wy)
    if not dx and overRoute.failTarget ~= S.nextTown then
      dx, dy = outsideStep(game, player, wx, wy)
    end
  end
  if not dx then
    local fdx, fdy = ferryLegStep(game, player, target)
    if fdx == true then return true end -- Return pressed at the gate/dock
    dx, dy = fdx, fdy
  end
  if dx then
    local bx, by = px + dx, py + dy
    local blocker = actorAtWorldXY(game, player, bx, by)
    if blocker then
      dx, dy = walkAroundStep(game, player, wx, wy)
      if not dx then
        pressKey("space")
        S.phase = "travel-blocked"
        if now() - (S.blockLogT or 0) > 5 then
          S.blockLogT = now()
          log("travel: %s blocks %d,%d from %d,%d",
            tostring(blocker.actorType), bx, by, px, py)
        end
        return true
      end
    end
    pressDelta(dx, dy)
    S.phase = "travel:" .. target
    return true
  end
  if now() - (S.travelLogT or 0) > 5 then
    S.travelLogT = now()
    log("travel: no route to %s at %d,%d from %d,%d",
      target, wx, wy, px, py)
  end
  return false
end

local function approachCell(game, player, tx, ty)
  local px, py = playerPos(player)
  local dx, dy = tx - px, ty - py
  if math.abs(dx) + math.abs(dy) == 1 then
    pressDelta(dx, dy)
    return true
  end

  local map = game.map
  local best
  for _, d in ipairs(tools.aroundNESW) do
    local nx, ny = tx + d[1], ty + d[2]
    if inBounds(map, nx, ny) and cellWalkable(cellAt(map, nx, ny)) then
      local steps = travelSteps(game, player, nx, ny)
      if steps and steps[1] and (best == nil or #steps < #best) then
        best = steps
      end
    end
  end
  if best then
    pressDelta(best[1].x, best[1].y)
    return true
  end
  return false
end

-- Locked doors carry their requirement in a locked_door trigger: string data
-- is the item name, a positive number is a pressure-plate code, and 0 means a
-- magically sealed door that only the master key opens. A doorLocked with no
-- trigger needs a lockpick; doorLocked2 is unpickable.
local function doorTriggerAt(game, x, y, action)
  local wx, wy = game.map:convertMapXYToWorldXY(x, y)
  return game.triggerData:getFirstTriggerOnLevelWithActionNameAtXYZeroIndexed(
    game.currentWorldName, wx, wy, action)
end

local LOCKED_DOOR_NAMES = { doorLocked = true, gateLocked = true, doorLocked2 = true }

local function lockedDoorPlan(game, player, x, y)
  local name = cellTypeName(cellAt(game.map, x, y))
  if not LOCKED_DOOR_NAMES[name] then return nil end
  if player:findInventoryObjectWithName("key_master") then return nil end
  local t = doorTriggerAt(game, x, y, "locked_door")
  if not t then
    if name == "doorLocked2" then return "sealed" end
    return "pick"
  end
  local data = t.data
  if data == 0 then return "sealed" end
  if type(data) == "number" then return "plate:" .. tostring(data) end
  if type(data) == "string" and data ~= "" then
    if player:findInventoryObjectWithName(data) then return nil end
    return "key:" .. data
  end
  return "pick"
end

-- Nearest known door plus the nav steps to a cell next to it. Empty steps mean
-- the player is already adjacent and can bump it immediately. Doors that
-- cannot currently be opened are skipped so the bot does not bounce off them
-- forever; doorObjectiveStep goes after their key or plate instead.
local function findRoutableDoor(game, player)
  local map = game.map
  local sx, sy = playerPos(player)
  local queue = { { sx, sy } }
  local seen = { [ckey(sx, sy)] = true }
  local head = 1
  local checked = 0

  while head <= #queue do
    local cx, cy = queue[head][1], queue[head][2]
    head = head + 1

    for _, d in ipairs(DIRS) do
      local nx, ny = cx + d[1], cy + d[2]
      if inBounds(map, nx, ny) and isKnown(nx, ny) then
        local neighbour = cellAt(map, nx, ny)
        local nname = cellTypeName(neighbour)
        if isBumpableDoorName(nname) then
          local plan = lockedDoorPlan(game, player, nx, ny)
          if plan == nil or plan == "pick" then
            checked = checked + 1
            if checked > 24 then return nil end
            if cx == sx and cy == sy then
              return nx, ny, {}, plan
            end
            local steps = navSteps(game, player, cx, cy)
            if steps and steps[1] then
              return nx, ny, steps, plan
            end
          end
        elseif isPassableForPath(neighbour) and not seen[ckey(nx, ny)] then
          seen[ckey(nx, ny)] = true
          queue[#queue + 1] = { nx, ny }
        end
      end
    end
  end
  return nil
end

-- Secret doors look like walls until bumped. The game raises
-- game.gotFeelingAboutSecretDoor when the player stands next to one, so when
-- exploration stalls we sweep the neighbouring walls (a few per second).
local DANGEROUS_BUMP = {
  lava = true, staticFire = true, fire = true, void = true,
  sea = true, deepSea = true, water = true, deepWater = true,
}

local function trySecretDoorSweep(game, player)
  if not game.gotFeelingAboutSecretDoor then return false end
  local px, py = playerPos(player)
  for _, d in ipairs(DIRS) do
    local nx, ny = px + d[1], py + d[2]
    if inBounds(game.map, nx, ny) then
      local cell = cellAt(game.map, nx, ny)
      local name = cellTypeName(cell)
      if name and not cellWalkable(cell) and not isBumpableObstacleName(name)
        and not DANGEROUS_BUMP[name] then
        local k = ckey(nx, ny)
        local t = now()
        if t - (S.sweptAt[k] or -100) > 3 then
          S.sweptAt[k] = t
          log("secret-door sweep: bumping %s at %d,%d", name, nx, ny)
          pressDelta(d[1], d[2])
          return true
        end
      end
    end
  end
  return false
end

local function tryOpenDoor(game, player)
  local dx, dy, steps, plan = findRoutableDoor(game, player)
  if not dx then return false end
  local px, py = playerPos(player)
  if #steps == 0 then
    if plan == "pick" then return tryPickLock(game, player, dx, dy) end
    pressDelta(dx - px, dy - py)
  else
    pressDelta(steps[1].x, steps[1].y)
  end
  return true
end

local function navigateOrOpenDoor(game, player, tx, ty)
  local result = moveToward(game, player, tx, ty)
  if result == "moving" or result == "arrived" then return result end
  if tryOpenDoor(game, player) then return "door" end
  return result
end

local function approachOrOpenDoor(game, player, tx, ty)
  if approachCell(game, player, tx, ty) then return true end
  return tryOpenDoor(game, player)
end

local function hasItem(player, name)
  return player:findInventoryObjectWithName(name) ~= nil
end

-- Dungeon chests generated by placeWeightedPrizeDictionaryInChest have no
-- locked_chest trigger at all: the game throws the lock data away and simply
-- turns the cell into chestLocked. Opening one requires "chest_key" (carried by
-- a miniboss or hidden in a container) or the dungeon "key_master". Bumping a
-- locked chest without either key only prints "Locked! Needs chest key!".
-- These helpers find where that key lives.
local function actorCarries(a, name)
  local c = a.carryingObject
  if type(c) == "string" then return c == name end
  if type(c) == "table" then
    for _, v in ipairs(c) do
      if v == name or (type(v) == "table" and v.objectType == name) then
        return true
      end
    end
  end
  return false
end

local function keyCarriers(game, player, name)
  local list = {}
  for _, a in ipairs(game.actorManager.actorArray) do
    if a.ID ~= player.ID
      and not a.isCorpse
      and a.fallingTime == 0
      and a.isAway ~= true
      and actorCarries(a, name)
    then
      local dx = a.position.x - player.position.x
      local dy = a.position.y - player.position.y
      list[#list + 1] = { actor = a, dist = math.max(math.abs(dx), math.abs(dy)) }
    end
  end
  table.sort(list, function(lhs, rhs) return lhs.dist < rhs.dist end)
  return list
end

local function moveToActor(game, player, a)
  local ax, ay = a.position.x, a.position.y
  local px, py = playerPos(player)
  if math.abs(ax - px) + math.abs(ay - py) == 1 then
    pressDelta(ax - px, ay - py)
    return true
  end
  local steps = travelSteps(game, player, ax, ay)
  if steps and steps[1] then
    pressDelta(steps[1].x, steps[1].y)
    return true
  end
  return false
end

-- Walk to the nearest carrier that is actually reachable. Returns true on a
-- step taken, plus the chosen actor for logging.
local function approachKeyCarrier(game, player, name)
  local list = keyCarriers(game, player, name)
  for _, entry in ipairs(list) do
    if moveToActor(game, player, entry.actor) then
      return true, entry.actor
    end
  end
  return false, list[1] and list[1].actor or nil
end

local function keyContainerXY(game, name)
  for _, action in ipairs({ "container", "object" }) do
    local list = game.triggerData:getAllTriggersOnLevelWithActionName(
      game.currentWorldName, action) or {}
    for _, t in ipairs(list) do
      if t.data == name and t.x and t.y then return t.x, t.y end
    end
  end
end

-- Locked doors that bumping cannot open. Numeric data waits for a floor plate
-- with the same code; string data waits for an item carried by a creature or
-- hidden in a container. Route to whichever is missing.
local function doorObjectiveStep(game, player)
  local doors = game.triggerData:getAllTriggersOnLevelWithActionName(
    game.currentWorldName, "locked_door") or {}
  local codes, items = {}, {}
  for _, d in ipairs(doors) do
    local data = d.data
    if type(data) == "number" and data > 0 then
      codes[data] = true
    elseif type(data) == "string" and data ~= ""
      and not player:findInventoryObjectWithName(data) then
      items[data] = true
    end
  end

  for code in pairs(codes) do
    local px, py = game.triggerData:findTriggerXYOnLevelWithActionAndData(
      game.currentWorldName, "fnUnlockWithPlate", code)
    if px then
      local mx, my = game.map:convertWorldXYToMapXYZeroIndexed(px, py)
      if navigateOrOpenDoor(game, player, mx, my) ~= "nopath" then
        log("door objective: step on plate %s at %d,%d", tostring(code), mx, my)
        return true
      end
    end
  end

  for item in pairs(items) do
    local moved, carrier = approachKeyCarrier(game, player, item)
    if moved then
      log("door objective: key %s carried by %s", item,
        tostring(carrier and carrier.actorType))
      return true
    end
    local kx, ky = keyContainerXY(game, item)
    if kx then
      local mx, my = game.map:convertWorldXYToMapXYZeroIndexed(kx, ky)
      if cellWalkable(cellAt(game.map, mx, my)) then
        if moveToward(game, player, mx, my) ~= "nopath" then return true end
      elseif approachOrOpenDoor(game, player, mx, my) then
        return true
      end
    end
  end
  return false
end

local function findActionTrigger(game, action, data)
  local list = game.triggerData:getAllTriggersOnLevelWithActionName(
    game.currentWorldName, action) or {}
  for _, t in ipairs(list) do
    if data == nil or t.data == data then return t end
  end
end

-- Gods: the gods screen is game.skillTree, and every purchase the UI makes is
-- activateCellForGridFactionAtXY(x, y). We call the same method, but first
-- check the devotion cost, because it lives in a local table of the installed
-- skill_tree.lua and must be parsed from the game source.
local function skillCostMap()
  if S.skillCosts then return S.skillCosts end
  local costs = {}
  local src = love.filesystem and love.filesystem.read
    and love.filesystem.read("skill_tree.lua")
  if src then
    for name, cost in src:gmatch('skillTileData%["([^"]+)"%]%s*=%s*{cost%s*=%s*(%d+)') do
      costs[name] = tonumber(cost)
    end
  end
  S.skillCosts = costs
  return costs
end

local function godIndex(name)
  for i, v in ipairs(G_Globals.skillFactions) do
    if v == name then return i end
  end
  return 1
end

-- Buy one affordable Gift per call. Column 1 is the dedication tile, column 2
-- a spacer; Gifts start at column 3. updateMinCosts has already marked every
-- reachable cell through cell.isAvailable / cell.isBlocked.
local function buyGiftStep(game, player)
  local tree = game.skillTree
  if not tree or not tree.cells or not tree.gridWidth then return false end
  local costs = skillCostMap()
  for y = 1, #G_Globals.skillFactions do
    local god = G_Globals.skillFactions[y]
    local dev = game:getDevotion(god)
    if dev and dev > 0 and not game:isCursedByGod(god) then
      for x = 3, tree.gridWidth do
        local cell = tree.cells[y] and tree.cells[y][x]
        if cell and cell.isAvailable and not cell.isBlocked and not cell.isOpen then
          local cost = costs[cell.tileDataName]
          if cost and dev >= cost then
            tree:activateCellForGridFactionAtXY(x, y)
            log("god: bought %s for %s (cost %d, devotion left %d)",
              tostring(cell.tileDataName), god, cost, game:getDevotion(god))
            return true
          end
        end
      end
    end
  end
  return false
end

-- In a safe town: offer any Devotional Tear (opens a god-choice box that
-- handleDialogs answers), spend devotion on Gifts, and dedicate to CFG.god for
-- the free boon and the full heal it grants.
local function godStep(game, player)
  if game:isWorldDungeon() then return false end
  if game:isEnemyPresent() then return false end
  if game.sellPanel and game.sellPanel.isOpen then return false end
  if game.confirmBox and game.confirmBox.isOpen then return false end
  if game.multiChoiceBox and game.multiChoiceBox.isOpen then return false end
  if not player:isFreeToMove() then return false end

  local tear = player:findInventoryObjectWithName("devotional_tear")
  if tear and not S.tearPending then
    S.tearPending = true
    S.tearID = tear.ID
    game:startShatteringTear(tear.ID)
    log("god: offering a Devotional Tear to %s", tostring(CFG.god))
    return true
  end

  if buyGiftStep(game, player) then return true end

  -- Dedication curses every other god, which would lock their Gifts. Spend
  -- the tour's devotion everywhere first, and only then pick a patron.
  if CFG.god and G_Globals.godData[CFG.god] and not game:getCurrentGod()
    and not game:isCursedByGod(CFG.god)
    and not (S.tourPending and #S.tourPending > 0) then
    if now() - (S.dedicateTriedAt or -100) > 10 then
      S.dedicateTriedAt = now()
      log("god: dedicating to %s", CFG.god)
      game:devoteToGod(CFG.god)
      return true
    end
  end
  return false
end

-- Yarrow has two Large Healing Potions lying around (a crate at 34,64 and an
-- object at 31,45). They are the difference between losing and winning the
-- silverwolf fight, so grab them before heading to the cave.
local TOWN_SUPPLIES = { "potion_heal_major", "potion_heal" }

local function townSupplyStep(game, player)
  for _, name in ipairs(TOWN_SUPPLIES) do
    local list = game.triggerData:getAllTriggersOnLevelWithActionName(
      game.currentWorldName, "object") or {}
    for _, t in ipairs(list) do
      if t.data == name and t.x and t.y then
        if navigateOrOpenDoor(game, player, t.x, t.y) ~= "nopath" then
          return true
        end
      end
    end
  end
  for _, name in ipairs(TOWN_SUPPLIES) do
    local list = game.triggerData:getAllTriggersOnLevelWithActionName(
      game.currentWorldName, "container") or {}
    for _, t in ipairs(list) do
      if t.data == name and t.x and t.y then
        if approachOrOpenDoor(game, player, t.x, t.y) then return true end
      end
    end
  end
  return false
end

-- Sleep at an inn when wounded before entering a dungeon. Stepping on an
-- inn_bed trigger and pressing return opens the Rest choice; handleDialogs
-- pays for it, and the sleep both heals and feeds the character.
local function innRestStep(game, player)
  if player.health >= player.maxHealth then return false end
  if game.isSleeping then return true end
  if game.speechArea and game.speechArea:isPropertyNonZero("killed_tether") then
    return false
  end
  local beds = game.triggerData:getAllTriggersOnLevelWithActionName(
    game.currentWorldName, "inn_bed") or {}
  local best, bestLen
  for _, b in ipairs(beds) do
    local mx, my = game.map:convertWorldXYToMapXYZeroIndexed(b.x, b.y)
    local steps = travelSteps(game, player, mx, my)
    if steps and (bestLen == nil or #steps < bestLen) then
      best, bestLen = steps, #steps
    end
  end
  if not best then return false end
  if bestLen == 0 then
    pressKey("return")
    log("resting at inn (hp %d/%d)", player.health, player.maxHealth)
  else
    pressDelta(best[1].x, best[1].y)
  end
  return true
end

-- Ferry: attemptToPayFerryman opens the one-option "Sail" box that
-- handleDialogs confirms, then the game runs the whole crossing (zoom out,
-- teleport, fade). Moon-upon-Thoss is the gate to the Barrow-Linn isle; the
-- dock town beside Barrow-Linn sails back for free.
local function playerMoney(game)
  local money = 0
  pcall(function() money = game:getPlayerStats().money or 0 end)
  return money
end

local function ferryFare(game)
  local price = 150
  pcall(function()
    price = game.economy:getNonObjectActualPrice(G_Globals.ferryCost)
  end)
  return price, playerMoney(game)
end

local function ferryStep(game, player)
  if game.isOnFerry or game.isSleeping then return false end
  if not player:isFreeToMove() then return false end
  if game.confirmBox and game.confirmBox.isOpen then return false end
  if game.multiChoiceBox and game.multiChoiceBox.isOpen then return false end
  if game.speechArea and game.speechArea.isOpen then return false end
  local name = game.currentWorldName
  if name == "Moon-upon-Thoss" then
    if S.nextTown ~= "Barrow-Linn" then return false end
    local price, money = ferryFare(game)
    if money < price then
      if now() - (S.ferryPoorT or 0) > 10 then
        S.ferryPoorT = now()
        log("ferry: fare %d unaffordable (money %d)", price, money)
      end
      return false
    end
  elseif name ~= "Barrow-Linn-Ferry" then
    return false
  end
  if now() - (S.ferryTriedAt or -100) < 3 then return false end
  S.ferryTriedAt = now()
  local ok, err = pcall(game.attemptToPayFerryman, game)
  if not ok then
    log("ferry: attempt failed: %s", tostring(err))
    return false
  end
  log("ferry: boarding at %s for %s", name,
    name == "Moon-upon-Thoss" and "Barrow-Linn" or "Moon-upon-Thoss")
  return true
end

-- ---------------------------------------------------------------------------
-- Economy. Each town prices every object with a demand offset (0.7-1.5) and
-- each shopkeeper has a limited purse, so surplus loot goes to the richest
-- shop. Keep the best gear and a consumable reserve; once the purse is
-- comfortable, hold goods this town dislikes so a later stop pays more for
-- them (the same demand mechanic that makes local prices swing 2x).
local SELL_KEEP_CATEGORY = { key = true, quest = true, deed = true, lamp = true,
  scroll = true, wand = true, artifact = true }
local WEAR_SLOTS = { melee = true, ranged = true, head = true, body = true,
  hands = true, feet = true, neck = true, cloak = true, shield = true }
local SELL_RESERVE = {
  potion_heal_major = 2, potion_heal = 2, potion_cureall = 1,
  potion_oil = 1, kindling = 3,
}
local CATEGORY_RESERVE = { food = 3, potion = 2, ointment = 2, medicine = 2, oil = 1 }
-- Never restock the bag with things the combat layer will consume or that
-- sellPlan keeps forever: the unit cost tag would leak or the money is lost.
local TRADE_SKIP = {
  potion_heal = true, potion_heal_major = true,
  camp_kit = true, wand_of_healing = true,
}

local function objBasePrice(game, o)
  local def
  pcall(function() def = game:getObjectDataWithObjectType(o.objectType) end)
  return def and tonumber(def.price) or 0
end

local function objSellValue(game, o)
  local v = 0
  pcall(function() v = game.economy:getActualSellValue(o) end)
  return v or 0
end

local function townDemand(game, o)
  local d = 1
  pcall(function()
    local loc = game.economy:getLocalEconomyLocationName()
    d = game.economy.townEconomies[loc].demandOffsetDictionary[o.objectType] or 1
  end)
  return d
end

local function isWorn(game, o)
  local worn = false
  pcall(function() worn = game:isObjectWornOrWielded(o) end)
  return worn
end

-- What a town would pay for the object right now. Buying pays base x demand
-- while selling pays base x demand x 0.65, so only a demand above ~1.55x the
-- purchase town beats the markdown; buy low, sell high is the whole game.
local function sellValueInTown(game, town, o)
  local def
  pcall(function() def = game:getObjectDataWithObjectType(o.objectType) end)
  local price = def and tonumber(def.price) or 0
  if price <= 0 then return 0 end
  local mult = 1
  pcall(function()
    local econ = game.economy.townEconomies[town]
    mult = econ and econ.demandOffsetDictionary[o.objectType] or 1
    -- Towns discount whatever they produce, but that axe cuts both ways:
    -- local goods also resell low while we stand in the town that makes them.
    for _, use in ipairs(CEconomy.discountArray[town] or {}) do
      if def.use == use then
        mult = mult * G_Globals.iceToEskimosPriceMultiplier
        break
      end
    end
    mult = math.clamp(mult, G_Globals.minPriceFluctuation, G_Globals.maxPriceFluctuation)
  end)
  return math.floor(price * mult * G_Globals.sellMarkdownFraction)
end

-- Trade goods bought cheap are tagged with their unit cost; sellPlan only
-- parts with them where the local sell value clears that cost with a margin.
local function tradeTag(o)
  local tag = S.tradeTags and S.tradeTags[o.objectType]
  if not tag then return nil end
  if (S.worldChanges or 0) - (tag.trip or 0) > 12 then
    S.tradeTags[o.objectType] = nil
    return nil
  end
  return tag
end

-- One item per wearable slot stays in the bag: selling spare loot must never
-- discard the best weapon or armour the equipment layer may want later.
local function bestGearIDs(game, inv)
  local best, ids = {}, {}
  for _, o in pairs(inv or {}) do
    if WEAR_SLOTS[o.category] then
      local value = objBasePrice(game, o)
      if value > 0 and (not best[o.category] or value > best[o.category]) then
        best[o.category] = value
        ids[o.category] = o.ID
      end
    end
  end
  local keep = {}
  for _, id in pairs(ids) do keep[id] = true end
  return keep
end

local function hasRangedWeapon(inv)
  for _, o in pairs(inv or {}) do
    if o.category == "ranged" then return true end
  end
  return false
end

-- How many units of this object the bot is willing to part with right now.
local function sellPlan(game, o, money, gearIDs, rangedOwned)
  if SELL_KEEP_CATEGORY[o.category] then return false end
  if o.objectType == "wand_of_healing" or o.objectType == "camp_kit" then
    return false
  end
  if isWorn(game, o) then return false end
  local value = objSellValue(game, o)
  if value <= 0 then return false end
  local tag = tradeTag(o)
  if tag then
    -- Trade stock is not loot: it stays until a town pays the target margin.
    if value >= math.ceil(tag.cost * CFG.tradeTake) then
      return true, o.count or 1
    end
    return false
  end
  local count = o.count or 1
  local sellable
  if WEAR_SLOTS[o.category] then
    if gearIDs[o.ID] then return false end
    sellable = count
  elseif o.category == "ammo" then
    if rangedOwned then return false end
    sellable = count
  elseif o.category == "tool" then
    local reserve = SELL_RESERVE[o.objectType]
    if not reserve then return false end
    sellable = count - reserve
  elseif o.category == "trade" or o.category == "reagent"
    or o.category == "base" or o.category == "alchemy" then
    sellable = count
  else
    sellable = count - (SELL_RESERVE[o.objectType] or CATEGORY_RESERVE[o.category] or 0)
  end
  if sellable <= 0 then return false end
  -- Demand exploit: with money in the purse, wait for a town that wants the
  -- good instead of dumping it at a below-average price.
  if money >= CFG.moneyReserve and townDemand(game, o) < CFG.sellHold then
    return false
  end
  return true, math.min(sellable, count)
end

local function shopRoles()
  local list = {}
  for role, _ in pairs(CEconomy and CEconomy.shopTypes or {}) do
    list[#list + 1] = role
  end
  table.sort(list)
  return list
end

local function shopFunds(game, role)
  local f = 0
  pcall(function() f = game.economy:getFundsForShopType(role) or 0 end)
  return f
end

local function vendorForRole(game, role)
  local a
  pcall(function() a = game.actorManager:getActorWithRole(role) end)
  if a and (a.isCorpse or a.isAway == true) then return nil end
  return a
end

local function bestVendor(game)
  local best, bestFunds, bestActor
  for _, role in ipairs(shopRoles()) do
    local a = vendorForRole(game, role)
    local f = shopFunds(game, role)
    if a and f > 0 and (not bestFunds or f > bestFunds) then
      best, bestFunds, bestActor = role, f, a
    end
  end
  return best, bestFunds, bestActor
end

local function walkNextToActor(game, player, actor)
  local map = game.map
  local ax, ay = actor.position.x, actor.position.y
  local best, bestLen
  for _, d in ipairs(DIRS) do
    local nx, ny = ax + d[1], ay + d[2]
    if inBounds(map, nx, ny) and cellWalkable(cellAt(map, nx, ny)) then
      local steps = travelSteps(game, player, nx, ny)
      if steps and steps[1] and (bestLen == nil or #steps < bestLen) then
        best, bestLen = steps, #steps
      end
    end
  end
  if not best then return false end
  pressDelta(best[1].x, best[1].y)
  return true
end

-- Sell items until the shop's funds run dry, then close the panel.
local function sellSessionStep(game, player, panel)
  S.phase = "selling"
  local role = S.sellRole or panel.vendorRole
  local total, sales = 0, 0
  for _ = 1, 25 do
    local funds = shopFunds(game, role)
    if funds <= 0 then break end
    panel.categoryIndex = 1
    local list = panel:getSortedInventory() or {}
    local inv = game:getPlayerInventory() or {}
    local money = playerMoney(game)
    local gearIDs = bestGearIDs(game, inv)
    local rangedOwned = hasRangedWeapon(inv)
    local pick, pickCount, pickGain
    for i, o in ipairs(list) do
      local ok, n = sellPlan(game, o, money, gearIDs, rangedOwned)
      local value = objSellValue(game, o)
      if ok and value > 0 and value <= funds then
        n = math.min(n, math.floor(funds / value))
        if n > 0 and (not pickGain or value * n > pickGain) then
          pick, pickCount, pickGain = i, n, value * n
        end
      end
    end
    if not pick then break end
    panel.sortedInventory = list
    panel.cursorPosition = pick
    local obj = list[pick]
    local demand = townDemand(game, obj)
    local ok, err = pcall(panel.sell, panel, pickCount)
    if not ok then
      log("shop: sell failed: %s", tostring(err))
      break
    end
    total = total + pickGain
    sales = sales + pickCount
    log("shop: sold %dx %s for %d (demand %.2f, money %d)",
      pickCount, tostring(obj.objectType), pickGain, demand, playerMoney(game))
    if S.tradeTags and S.tradeTags[obj.objectType] then
      local still = false
      for _, it in pairs(game:getPlayerInventory() or {}) do
        if it.objectType == obj.objectType then still = true; break end
      end
      if not still then
        S.tradeTags[obj.objectType] = nil
        log("trade: %s sold out", tostring(obj.objectType))
      end
    end
  end
  pcall(function() panel:setIsOpen(false, role) end)
  player.target = nil
  S.sellActive = nil
  S.sellRole = nil
  if sales > 0 then
    log("shop: closed, sold %d items for %d (money %d)",
      sales, total, playerMoney(game))
  else
    log("shop: nothing affordable to sell (money %d)", playerMoney(game))
  end
  return true
end

local function sellStep(game, player)
  local panel = game.sellPanel
  if not panel then return false end
  if panel.isOpen and not S.sellActive then
    S.sellActive = true
    S.sellRole = panel.vendorRole
  end
  if S.sellActive then
    if not panel.isOpen then
      S.sellActive, S.sellRole = nil, nil
      return false
    end
    return sellSessionStep(game, player, panel)
  end
  if not (game.currentWorldData and game.currentWorldData.isTown) then return false end
  if not player:isFreeToMove() then return false end
  if game:isEnemyPresent() then return false end
  if game.alertBox and game.alertBox.isOpen then return false end
  if game.confirmBox and game.confirmBox.isOpen then return false end
  if game.multiChoiceBox and game.multiChoiceBox.isOpen then return false end
  if game.speechArea and game.speechArea.isOpen then return false end
  local money = playerMoney(game)
  local inv = game:getPlayerInventory() or {}
  local gearIDs = bestGearIDs(game, inv)
  local rangedOwned = hasRangedWeapon(inv)
  local anything = false
  for _, o in pairs(inv) do
    if sellPlan(game, o, money, gearIDs, rangedOwned) then
      anything = true
      break
    end
  end
  if not anything then return false end
  local role, funds, vendor = bestVendor(game)
  if not role then
    if now() - (S.vendorLogT or 0) > 10 then
      S.vendorLogT = now()
      log("shop: no shopkeeper found in %s", tostring(game.currentWorldName))
    end
    return false
  end
  local px, py = playerPos(player)
  local ax, ay = vendor.position.x, vendor.position.y
  if math.abs(ax - px) + math.abs(ay - py) == 1 then
    player.target = vendor
    local ok, err = pcall(function() panel:setIsOpen(true, role) end)
    if not ok then
      player.target = nil
      log("shop: cannot open %s (%s): %s",
        role, tostring(vendor.uniqueName), tostring(err))
      return false
    end
    S.sellActive = true
    S.sellRole = role
    log("shop: selling to %s (%s, funds %d, money %d)",
      tostring(vendor.displayName or vendor.uniqueName), role, funds, money)
    return true
  end
  if walkNextToActor(game, player, vendor) then
    S.phase = "to-shop"
    return true
  end
  if now() - (S.vendorLogT or 0) > 10 then
    S.vendorLogT = now()
    log("shop: %s unreachable at %d,%d", role, ax, ay)
  end
  return false
end

-- ---------------------------------------------------------------------------
-- Arbitrage. Buying costs base x demand; selling pays base x demand x 0.65,
-- and both use the per-town demand offset (0.7-1.5, with local industries at
-- 0.75x). A good bought where demand is floored and sold where it is capped
-- clears cost by up to 39%, so the bot buys cheap stock and only parts with it
-- where sellPlan sees the tagged unit cost multiplied by tradeTake.
local function tradeReserve(game)
  local r = CFG.moneyReserve
  -- Never spend the ferry fare while the route waits on the island crossing.
  if game.currentWorldName == "Moon-upon-Thoss" and S.nextTown == "Barrow-Linn" then
    local fare = ferryFare(game)
    r = math.max(r, fare + 20)
  end
  return r
end

local function tradeCandidates(game)
  local loc = game.currentWorldName
  local money = playerMoney(game)
  local budget = math.floor((money - tradeReserve(game)) * 0.8)
  if budget < 10 then return nil end
  local weight, maxBurden = 0, 0
  pcall(function() weight, maxBurden = game:getRawPlayerBurdenAndMaxBurden(nil, false) end)
  local room = math.max(0, math.floor(maxBurden * 0.85 - weight))
  local cands = {}
  for _, role in ipairs(shopRoles()) do
    local vendor = vendorForRole(game, role)
    local stock
    pcall(function() stock = game.economy.shopStockLevels[loc][role] end)
    if vendor and stock then
      for _, entry in ipairs(stock) do
        if (entry.amount or 0) > 0 then
          local def
          pcall(function() def = game:getObjectDataWithObjectType(entry.ID) end)
          if def and (tonumber(def.price) or 0) > 0
            and not SELL_KEEP_CATEGORY[def.category]
            and not TRADE_SKIP[def.objectType] then
            -- Potions, wands and berries carry no burden at all (weight 0);
            -- they are the best trade goods, so 0 must mean "fits freely".
            local w = tonumber(def.weight) or 0
            if w <= room then
              local buyPrice = 0
              pcall(function() buyPrice = game.economy:getActualBuyValue(def) end)
              if buyPrice > 0 then
                local sellTown, sellPrice
                for _, town in ipairs(TOWN_ORDER) do
                  if town ~= loc then
                    local v = sellValueInTown(game, town, def)
                    if v > 0 and (not sellPrice or v > sellPrice) then
                      sellTown, sellPrice = town, v
                    end
                  end
                end
                if sellPrice and sellPrice >= math.ceil(buyPrice * CFG.tradeMargin) then
                  local fit = w > 0 and math.floor(room / w) or 99
                  local qty = math.min(entry.amount or 0,
                    math.floor(budget / buyPrice), fit, 10)
                  if qty > 0 then
                    cands[#cands + 1] = {
                      role = role, id = entry.ID,
                      buyPrice = buyPrice, sellTown = sellTown, sellPrice = sellPrice,
                      qty = qty, weight = w,
                      score = (sellPrice - buyPrice) * qty,
                    }
                  end
                end
              end
            end
          end
        end
      end
    end
  end
  table.sort(cands, function(a, b) return a.score > b.score end)
  return cands
end

local function tradeSessionStep(game, player, panel)
  S.phase = "trading"
  local role = S.buyRole or panel.vendorRole
  local budget = math.floor((playerMoney(game) - tradeReserve(game)) * 0.8)
  local bought, spent = 0, 0
  for _ = 1, 4 do
    local cands = tradeCandidates(game)
    local pick
    for _, c in ipairs(cands or {}) do
      if c.role == role then pick = c; break end
    end
    if not pick then break end
    panel.categoryIndex = 1
    local list = panel:getSortedInventory() or {}
    local idx
    for i, e in ipairs(list) do
      if e.ID == pick.id and (e.amount or 0) > 0 then idx = i; break end
    end
    if not idx then break end
    local qty = math.min(pick.qty, list[idx].amount or 0,
      math.floor((playerMoney(game) - tradeReserve(game)) / pick.buyPrice),
      math.floor((budget - spent) / pick.buyPrice))
    if qty <= 0 then break end
    panel.sortedInventory = list
    panel.cursorPosition = idx
    local ok, err = pcall(panel.buy, panel, qty)
    if not ok then
      log("trade: buy failed: %s", tostring(err))
      break
    end
    S.tradeTags = S.tradeTags or {}
    S.tradeTags[pick.id] = { cost = pick.buyPrice, trip = S.worldChanges or 0 }
    bought = bought + qty
    spent = spent + qty * pick.buyPrice
    log("trade: bought %dx %s at %d -> %s @ %d (%.2fx, money %d)",
      qty, tostring(pick.id), pick.buyPrice, pick.sellTown, pick.sellPrice,
      pick.sellPrice / pick.buyPrice, playerMoney(game))
  end
  pcall(function() panel:setIsOpen(false, role) end)
  player.target = nil
  S.buyActive, S.buyRole = nil, nil
  S.tradeCoolT, S.tradeCoolTown = now() + 15, game.currentWorldName
  if bought > 0 then
    log("trade: closed, bought %d items for %d (money %d)",
      bought, spent, playerMoney(game))
  end
  return true
end

-- Opt-in (ZZBOT_TRADE_DEBUG=1): once per town, dump the best cross-town
-- spreads in stock so the margin knobs can be tuned against real data.
local function tradeDump(game)
  local loc = game.currentWorldName
  local offers = {}
  for _, role in ipairs(shopRoles()) do
    local vendor = vendorForRole(game, role)
    local stock
    pcall(function() stock = game.economy.shopStockLevels[loc][role] end)
    if vendor and stock then
      for _, entry in ipairs(stock) do
        if (entry.amount or 0) > 0 then
          local def
          pcall(function() def = game:getObjectDataWithObjectType(entry.ID) end)
          if def and (tonumber(def.price) or 0) > 0 then
            local buyPrice = 0
            pcall(function() buyPrice = game.economy:getActualBuyValue(def) end)
            if buyPrice > 0 then
              local sellTown, sellPrice
              for _, town in ipairs(TOWN_ORDER) do
                if town ~= loc then
                  local v = sellValueInTown(game, town, def)
                  if v > 0 and (not sellPrice or v > sellPrice) then
                    sellTown, sellPrice = town, v
                  end
                end
              end
              if sellTown and sellPrice / buyPrice >= 1.05 then
                offers[#offers + 1] = {
                  id = entry.ID, role = role, buy = buyPrice, town = sellTown,
                  sell = sellPrice, ratio = sellPrice / buyPrice,
                  amount = entry.amount, weight = tonumber(def.weight) or 0,
                }
              end
            end
          end
        end
      end
    end
  end
  table.sort(offers, function(a, b) return a.ratio > b.ratio end)
  log("trade-dbg: %s money=%d offers(>=1.05x)=%d", loc, playerMoney(game), #offers)
  for i = 1, math.min(8, #offers) do
    local o = offers[i]
    log("trade-dbg: %s/%s buy=%d -> %s sell=%d (%.2fx) stock=%d w=%s",
      tostring(o.role), tostring(o.id), o.buy, o.town, o.sell, o.ratio,
      o.amount, tostring(o.weight))
  end
end

local function tradeBuyStep(game, player)
  if not CFG.trade then return false end
  local panel = game.buyPanel
  if not panel then return false end
  if panel.isOpen and not S.buyActive then
    S.buyActive, S.buyRole = true, panel.vendorRole
  end
  if S.buyActive then
    if not panel.isOpen then
      S.buyActive, S.buyRole = nil, nil
      return false
    end
    return tradeSessionStep(game, player, panel)
  end
  if not (game.currentWorldData and game.currentWorldData.isTown) then return false end
  if not player:isFreeToMove() then return false end
  if game:isEnemyPresent() then return false end
  if game.alertBox and game.alertBox.isOpen then return false end
  if game.confirmBox and game.confirmBox.isOpen then return false end
  if game.multiChoiceBox and game.multiChoiceBox.isOpen then return false end
  if game.speechArea and game.speechArea.isOpen then return false end
  if game.sellPanel and game.sellPanel.isOpen then return false end
  if S.tradeCoolTown == game.currentWorldName and now() < (S.tradeCoolT or 0) then
    return false
  end
  if CFG.tradeDebug and S.tradeDumpTown ~= game.currentWorldName then
    S.tradeDumpTown = game.currentWorldName
    tradeDump(game)
  end
  local cands = tradeCandidates(game)
  if not cands or #cands == 0 then return false end
  local pick = cands[1]
  local vendor = vendorForRole(game, pick.role)
  if not vendor then return false end
  local px, py = playerPos(player)
  local ax, ay = vendor.position.x, vendor.position.y
  if math.abs(ax - px) + math.abs(ay - py) == 1 then
    player.target = vendor
    panel.categoryIndex = 1
    local ok, err = pcall(function() panel:setIsOpen(true, pick.role) end)
    if not ok then
      player.target = nil
      log("trade: cannot open %s: %s", pick.role, tostring(err))
      return false
    end
    S.buyActive, S.buyRole = true, pick.role
    log("trade: best deal %s %d -> %s %d (%.2fx, weight %s)",
      tostring(pick.id), pick.buyPrice, pick.sellTown, pick.sellPrice,
      pick.sellPrice / pick.buyPrice, tostring(pick.weight))
    return true
  end
  if walkNextToActor(game, player, vendor) then
    S.phase = "to-trade"
    return true
  end
  return false
end


local function handleDialogs(game)
  if S.tearPending and game.multiChoiceBox and game.multiChoiceBox.isOpen then
    S.tearPending = false
    local ok, err = pcall(game.finishShattering, game, godIndex(CFG.god), "", S.tearID)
    if not ok then log("god: tear offering failed: %s", tostring(err)) end
    return true
  end
  if game.alertBox and game.alertBox.isOpen then
    pressKey("return")
    return true
  end
  if game.confirmBox and game.confirmBox.isOpen then
    game.confirmBox.confirm = true
    pressKey("return")
    return true
  end
  if game.tutorialBox and game.tutorialBox.isOpen then
    local tb = game.tutorialBox
    if (tb.fraction or 1) >= 1 and (tb.time or 1) >= 0.5 then
      pressKey("space")
    end
    return true
  end
  if game.speechArea and game.speechArea.isOpen then
    pressKey("return")
    return true
  end
  if game.multiChoiceBox and game.multiChoiceBox.isOpen then
    -- setActive hilights the "Close" choice when one is appended, and Return
    -- there only dismisses the box (the ferry, inn and god prompts all want
    -- their first real option).
    local box = game.multiChoiceBox
    if box.isLastChoiceClose and box.cursorPosition == #box.choices then
      box.cursorPosition = 1
    end
    pressKey("return")
    return true
  end
  return false
end

-- Opt-in diagnostics: append an ASCII snapshot of the level to ZZBOT_MAPDUMP.
-- @/W/B/b/h/N/Q/* are the player and hostile creatures (carrier is '*').
local function dumpMap(game, tag)
  local path = os.getenv("ZZBOT_MAPDUMP")
  if not path then return end
  local map = game.map
  local player = game.actorManager.player
  local marks = {}
  for _, a in ipairs(game.actorManager.actorArray) do
    if a.ID ~= player.ID and not a.isCorpse then
      local c = tostring(a.actorType)
      if c == "silverwolf" then c = "W"
      elseif c == "large_beetle" then c = "B"
      elseif c == "beetle" then c = "b"
      elseif c == "hornets" then c = "h"
      elseif c == "wasp_nest" then c = "N"
      elseif c == "queen_hornet" then c = "Q"
      else c = "?" end
      if a.carryingObject == "chest_key" then c = "*" end
      marks[ckey(a.position.x, a.position.y)] = c
    end
  end
  local f = io.open(path, "a")
  if not f then return end
  f:write(string.format("== %s %s %s player=%d,%d turn=%s hp=%d/%d known=%d\n",
    os.date("%H:%M:%S"), tag, tostring(game.currentWorldName),
    player.position.x, player.position.y, tostring(gGameTurn),
    player.health, player.maxHealth, S.knownCount))
  for y = 0, map.height - 1 do
    local row = {}
    for x = 0, map.width - 1 do
      local ch
      if x == player.position.x and y == player.position.y then
        ch = "@"
      elseif marks[ckey(x, y)] then
        ch = marks[ckey(x, y)]
      else
        local cell = cellAt(map, x, y)
        local name = cellTypeName(cell)
        if name == "chestLocked" then ch = "C"
        elseif name and isBumpableObstacleName(name) then ch = "+"
        elseif cellWalkable(cell) then ch = isKnown(x, y) and "." or ","
        else ch = name == "wall" and "#" or " " end
      end
      row[#row + 1] = ch
    end
    f:write(table.concat(row), "\n")
  end
  f:close()
end

local function campaignComplete(reason)
  S.success = true
  S.successAt = now()
  S.finished = true
  S.done = true
  log("CAMPAIGN COMPLETE: %s", reason)
  if not CFG.quit then
    S.active = false
  end
end

-- The master key is consumed by the door out of a run dungeon, so returning
-- to the entrance town without it is the completion signal. Mark the dungeon
-- done, reset the per-run flags and point the campaign at the next town.
local function markDungeonComplete(game, dungeonName)
  if not dungeonName then return end
  S.dungeonDone[dungeonName] = true
  S.entered = false
  S.hasKey = false
  S.masterKeyLogged = false
  S.modelFleeTurn = nil
  local wd = game:getWorldDataWithName(dungeonName)
  local entrance = wd and wd.entrance
  log("DUNGEON COMPLETE: %s (entrance %s)", tostring(dungeonName), tostring(entrance))
  local idx = entrance and townIndex(entrance) or S.townIndex
  S.townIndex = math.max(S.townIndex or 1, (idx or 1) + 1)
  if S.townIndex > #TOWN_ORDER then
    campaignComplete("every town visited")
  else
    local pending = tourPending(game)
    S.nextTown = (pending and pending[1]) or TOWN_ORDER[S.townIndex]
    log("CAMPAIGN: next target %s", S.nextTown)
  end
end

local function tickWorld(game, player)
  local name = game.currentWorldName
  local data = game.currentWorldData

  if name ~= S.world then
    S.world = name
    S.known = {}
    S.knownCount = 0
    S.knownPX, S.knownPY = nil, nil
    S.zoomExit = nil
    S.sellActive, S.sellRole = nil, nil
    S.buyActive, S.buyRole = nil, nil
    S.worldChanges = (S.worldChanges or 0) + 1
    overRoute.path, overRoute.failTarget, overRoute.failWorld = nil, nil, nil
    ferryRoute.goal, ferryRoute.path, ferryRoute.failed = nil, nil, false
    log("world changed: %s", tostring(name))
    dumpMap(game, "enter")
  end

  -- The game owns the player for the whole ferry cutscene; just wait it out.
  if game.isOnFerry then
    S.wasOnFerry = true
    S.phase = "ferry"
    return
  elseif S.wasOnFerry then
    S.wasOnFerry = false
    overRoute.path, overRoute.failTarget, overRoute.failWorld = nil, nil, nil
    ferryRoute.target, ferryRoute.goal, ferryRoute.path, ferryRoute.failed =
      nil, nil, nil, false
    S.ferryTriedAt = nil
    log("ferry: landed in %s at %d,%d", tostring(name),
      player.position.x, player.position.y)
  end

  if data and data.dungeonType and not S.entered then
    S.entered = true
    S.dungeonName = name
    S.phase = "dungeon"
    local wd
    pcall(function() wd = player:getMeleeWeaponData() end)
    local inv = {}
    pcall(function()
      for _, o in pairs(game:getPlayerInventory() or {}) do
        inv[#inv + 1] = string.format("%s x%s", tostring(o.objectType), tostring(o.count or 1))
      end
    end)
    log("entered dungeon %s (%s) weapon=%s inv=[%s] poise=%s/%s",
      tostring(name), tostring(data.dungeonType),
      tostring(wd and wd.objectType or "none"), table.concat(inv, ", "),
      tostring(player.poise), tostring(player.maxPoise))
  end

  if player.position.x ~= S.knownPX or player.position.y ~= S.knownPY
    or now() - S.knownAt > 2 then
    updateKnown(game, player)
  end

  if not player:isFreeToMove() then return end

  -- Region view ("Zoom"): walk out of the map edge to return to the overworld.
  if name == "Zoom" then
    if combatStep(game, player) then return end
    if tryHeal(game, player) then return end
    local px, py = playerPos(player)
    local cell = S.zoomExit or fleeZoneCell(game, player)
    S.zoomExit = cell
    S.phase = "leave-zoom"
    if not cell then
      if now() - (S.nopathT or 0) > 5 then
        S.nopathT = now()
        log("no zoom edge from %d,%d", px, py)
      end
      return
    end
    if px == cell.x and py == cell.y then return end
    if navigateOrOpenDoor(game, player, cell.x, cell.y) ~= "moving" then
      if now() - (S.nopathT or 0) > 5 then
        S.nopathT = now()
        log("zoom edge stuck at %d,%d (edge %d,%d)", px, py, cell.x, cell.y)
      end
    end
    return
  end

  -- Town: every town owns the dungeon named in its leadsTo field. Yarrow's
  -- opening dungeon adds a small key chain before the stairs. Towns without a
  -- dungeon (or whose dungeon is done) are transit stops on the route: walk to
  -- the Overworld exit trigger and continue on the next world.
  if data and data.isTown then
    local px, py = playerPos(player)
    local tourActive = tourPending(game) ~= nil
    if S.nextTown == name then
      S.nextTown = nil
      log("CAMPAIGN: arrived in %s", name)
      if tourRemove(name) then tourActive = true end
    end

    -- Boons first: offerings, Gifts and dedication only happen in safe towns.
    if godStep(game, player) then return end

    -- Sell surplus loot before leaving town; the ferry purse depends on it.
    if sellStep(game, player) then return end

    -- Then reload the bag with goods this town prices low: the next towns on
    -- the route pay up to twice as much once their own demand is factored in.
    if tradeBuyStep(game, player) then return end

    -- The ferry is the only way on or off the Barrow-Linn isle. Sail from the
    -- Moon-upon-Thoss gate when the route points at Barrow-Linn, and from the
    -- dock town when the route points anywhere else.
    local wantSail = (name == "Moon-upon-Thoss" and S.nextTown == "Barrow-Linn")
      or (name == "Barrow-Linn-Ferry" and S.nextTown ~= "Barrow-Linn")
    if wantSail then
      if innRestStep(game, player) then
        S.phase = "ferry-inn"
        return
      end
      if ferryStep(game, player) then
        S.phase = "ferry"
        return
      end
    end

    -- Without the fare the bot bounces through the town gate forever: the
    -- overworld leg walks back onto the entrance, Return re-enters town, and
    -- the transit branch leaves again. Stay here until money is available
    -- (selling loot is still pending); Gifts and the inn run above.
    if name == "Moon-upon-Thoss" and S.nextTown == "Barrow-Linn" then
      local price, money = ferryFare(game)
      if money < price then
        S.phase = "ferry-poor"
        if now() - (S.ferryPoorT or 0) > 10 then
          S.ferryPoorT = now()
          log("ferry: waiting in town, fare %d but money is %d", price, money)
        end
        return
      end
    end

    -- Tour stops are transit-only: visit the god's home for the Devotional
    -- Task, rest if hurt, and move on without touching the dungeon here.
    if tourActive then
      if innRestStep(game, player) then
        S.phase = "tour-inn"
        return
      end
    end

    local target = data.leadsTo
    local delve = target and not S.dungeonDone[target] and not tourActive

    if delve and target == "firstDungeon-01" then
      local chestKey = hasItem(player, "farm_chest_key")
      local gateKey = hasItem(player, "farm_gate_key")
      local keyObject = findActionTrigger(game, "object", "farm_chest_key")
      local chest = findActionTrigger(game, "locked_chest", "farm_chest_key")
      local gate = findActionTrigger(game, "locked_door", "farm_gate_key")
      local gateKeyContainer = findActionTrigger(game, "container", "farm_gate_key")

      if not chestKey and not gateKey and keyObject then
        S.phase = "town-key"
        navigateOrOpenDoor(game, player, keyObject.x, keyObject.y)
        return
      end

      if chestKey and chest then
        S.phase = "town-chest"
        approachOrOpenDoor(game, player, chest.x, chest.y)
        return
      end

      if not gateKey and not chestKey and not chest and gateKeyContainer then
        S.phase = "town-chest-loot"
        approachOrOpenDoor(game, player, gateKeyContainer.x, gateKeyContainer.y)
        return
      end

      if gateKey and gate then
        S.phase = "town-gate"
        approachOrOpenDoor(game, player, gate.x, gate.y)
        return
      end
    end

    if delve then
      if innRestStep(game, player) then
        S.phase = "inn-rest"
        return
      end
      if townSupplyStep(game, player) then
        S.phase = "town-supplies"
        return
      end
      local sx, sy = game.triggerData:findTriggerXYOnLevelWithActionAndData(
        name, "playerStart", target)
      S.phase = "to-dungeon"
      if not sx then
        if now() - (S.nopathT or 0) > 5 then
          S.nopathT = now()
          log("no %s playerStart in %s", tostring(target), tostring(name))
        end
        return
      end
      if px == sx and py == sy then
        pressKey("return")
        return
      end
      if navigateOrOpenDoor(game, player, sx, sy) ~= "moving" then
        if now() - (S.nopathT or 0) > 5 then
          S.nopathT = now()
          log("town stuck at %d,%d heading to %s", px, py, tostring(target))
        end
      elseif os.getenv("ZZBOT_DEBUG_MOVE") == "1"
        and now() - (S.moveLogT or 0) > 1 then
        S.moveLogT = now()
        local route = travelSteps(game, player, sx, sy, true)
          or travelSteps(game, player, sx, sy, false)
        local names = {}
        if route then
          for k = 1, math.min(#route, 3) do
            local nx, ny = px + route[k].x, py + route[k].y
            names[#names + 1] = string.format("%d,%d:%s",
              route[k].x, route[k].y, tostring(cellTypeName(cellAt(game.map, nx, ny))))
          end
        end
        log("move dbg at %d,%d -> %d,%d route=[%s]", px, py, sx, sy,
          table.concat(names, " "))
      end
      return
    end

    -- Nothing left to delve here: advance the route and step onto the town exit.
    if tourActive then
      S.phase = "tour-town"
    else
      -- The ferry dock is not a campaign town; passing through it must not
      -- advance the route past the next real town.
      local idx = townIndex(name)
      if idx and (S.townIndex or 1) <= idx then
        S.townIndex = idx + 1
        if S.townIndex > #TOWN_ORDER then
          campaignComplete("visited every town")
          return
        end
        S.nextTown = TOWN_ORDER[S.townIndex]
        log("CAMPAIGN: leaving %s, next target %s", name, S.nextTown)
      end
      S.phase = "leave-town"
    end
    local ex, ey = game.triggerData:findTriggerXYOnLevelWithActionAndData(
      name, "playerStart", "Overworld")
    if not ex then
      local cell = fleeZoneCell(game, player)
      ex, ey = cell and cell.x, cell and cell.y
    end
    if not ex then
      if now() - (S.nopathT or 0) > 5 then
        S.nopathT = now()
        log("no way out of %s at %d,%d", tostring(name), px, py)
      end
      return
    end
    if px == ex and py == ey then
      -- Standing on the exit trigger: interact with it to zoom out.
      pressKey("return")
      return
    end
    if navigateOrOpenDoor(game, player, ex, ey) ~= "moving" then
      if now() - (S.nopathT or 0) > 5 then
        S.nopathT = now()
        log("town exit stuck at %d,%d (exit %d,%d)", px, py, ex, ey)
      end
    end
    return
  end

  -- Overworld: travel toward the next town's entrance trigger. Stepping onto
  -- it makes the game zoom into the town by itself.
  if data and data.isOverworld then
    if not S.nextTown then
      local pending = tourPending(game)
      S.nextTown = (pending and pending[1]) or TOWN_ORDER[S.townIndex or 1]
      log("CAMPAIGN: resuming route at %s", tostring(S.nextTown))
    end
    -- Overworld "enemies" are only markers: contact turns into a Zoom battle
    -- with a whole monster group, so stopping to fight or choke on one is how
    -- the bot got caught. Keep walking the route and let pursuers trail.
    if tryHeal(game, player) then return end
    if S.nextTown and overworldTravelStep(game, player, S.nextTown) then return end
    S.phase = "overworld"
    if now() - (S.travelLogT or 0) > 5 then
      S.travelLogT = now()
      log("overworld idle at %d,%d nextTown=%s",
        player.position.x, player.position.y, tostring(S.nextTown))
    end
    return
  end

  -- Dungeon.
  local px, py = playerPos(player)
  local hasMasterKey = hasItem(player, "key_master")
  local hasChestKey = hasItem(player, "chest_key")
  if hasMasterKey and not S.masterKeyLogged then
    S.masterKeyLogged = true
    log("MASTER KEY acquired at %d,%d (turn %s)", px, py, tostring(gGameTurn))
  end
  -- The dangerous milestone is the chest key: it is carried by the pack that
  -- can kill us, and after taking it the plan is to break contact alive.
  S.hasKey = hasMasterKey or hasChestKey

  -- With no potion and no Lifestone charge left, health cannot be recovered
  -- this run: route around danger instead of walking into it.
  local noRecovery = lsUses(findLifestone(player)) == 0
    and potionInfo(player) == 0
  S.avoidDanger = (noRecovery and player.health <= math.floor(player.maxHealth * 0.35))
    and hostileDangerCells(game, player, 3) or nil

  if hasMasterKey then
    S.phase = "to-exit"
    if nearestVisibleEnemy(game, player, 3) and combatStep(game, player) then
      return
    end
    -- The key opens the way out but does not finish the run: sweep the rest
    -- of the level first so loot and unexplored rooms are not left behind.
    -- Only while there is healing left to survive the detour; a wounded run
    -- with no potions and no Lifestone charge goes straight for the exit.
    local canSweep = player.health > player.maxHealth * 0.6
      and (potionInfo(player) > 0 or lsUses(findLifestone(player)) > 0)
    if canSweep then
      local fx, fy, steps = findFrontier(game, player)
      if fx and steps and steps[1] then
        S.phase = "exit-explore"
        pressDelta(steps[1].x, steps[1].y)
        return
      end
    end
    local ex, ey = dungeonExitXY(game)
    if ex then
      if px == ex and py == ey then
        pressKey("return")
      else
        navigateOrOpenDoor(game, player, ex, ey)
      end
      return
    end
    log("master key found but no exit stairs trigger")
    return
  end

  -- Resolve contact first (grace blow, emergency heal, kite, flee, fight).
  -- Healing out of contact only happens once the fight decision is settled.
  if combatStep(game, player) then return end
  if tryHeal(game, player) then return end

  local cx, cy = keyChestXY(game)
  local chestUnlocked = false
  if cx then
    -- The exit chest only needs the chest key while it is still chestLocked.
    -- If we already unlocked it (key consumed) bump it again to loot it.
    chestUnlocked = cellTypeName(cellAt(game.map, cx, cy)) ~= "chestLocked"
  end

  if cx and (hasChestKey or chestUnlocked) then
    S.phase = "to-key"
    if approachOrOpenDoor(game, player, cx, cy) then return end
  end

  if cx and not hasChestKey and not chestUnlocked then
    -- Find the chest key first: a miniboss/key goblin carries it, or it sits
    -- inside a non-chest container somewhere on the level.
    local moved, carrier = approachKeyCarrier(game, player, "chest_key")
    if moved then
      S.phase = "key-carrier"
      return
    end

    local kx, ky = keyContainerXY(game, "chest_key")
    if kx then
      S.phase = "key-container"
      if cellWalkable(cellAt(game.map, kx, ky)) then
        if moveToward(game, player, kx, ky) ~= "nopath" then return end
      elseif approachOrOpenDoor(game, player, kx, ky) then
        return
      end
    end

    if now() - (S.keyWaitLog or 0) > 5 then
      S.keyWaitLog = now()
      log("exit chest at %d,%d needs chest_key (carrier=%s container=%s)",
        cx, cy,
        carrier and string.format("%s at %d,%d",
          tostring(carrier.actorType), carrier.position.x, carrier.position.y) or "none",
        kx and string.format("%d,%d", kx, ky) or "none")
    end
  end

  local fx, fy, steps = findFrontier(game, player)
  if fx and steps and steps[1] then
    S.phase = "explore"
    pressDelta(steps[1].x, steps[1].y)
    S.stuckSince = nil
    return
  end

  if trySecretDoorSweep(game, player) then
    S.phase = "secret-door"
    S.stuckSince = nil
    return
  end

  if tryOpenDoor(game, player) then
    S.phase = "open-door"
    S.stuckSince = nil
    return
  end

  if doorObjectiveStep(game, player) then
    S.phase = "objective"
    S.stuckSince = nil
    return
  end

  S.phase = "stuck"
  if not S.stuckShot and love.graphics and love.graphics.captureScreenshot then
    S.stuckShot = true
    pcall(love.graphics.captureScreenshot, "zzshot-stuck.png")
    log("stuck screenshot saved as zzshot-stuck.png (%s at %d,%d)",
      tostring(game.currentWorldName), px, py)
  end
  local t = now()
  S.stuckSince = S.stuckSince or t
  if t - (S.stuckLoggedAt or 0) > 10 then
    S.stuckLoggedAt = t
    log("no frontier and no key at %d,%d (known %d, stuck %ds)",
      px, py, S.knownCount, math.floor(t - S.stuckSince))
  end
end

local function tick(game)
  if S.done then return end
  if not game or not game.actorManager or not game.actorManager.player then return end
  local player = game.actorManager.player

  if now() - (S.dbgT or 0) > 2 then
    S.dbgT = now()
    local box = function(b) return b and b.isOpen and "open" or "closed" end
    log("dbg %s pos=%s,%s cell=%s free=%s moveFrac=%s alert=%s confirm=%s tutorial=%s speech=%s multi=%s uiBlock=%s anim=%s busy=%s phase=%s",
      tostring(game.currentWorldName), tostring(player.position.x), tostring(player.position.y),
      tostring(cellTypeName(cellAt(game.map, player.position.x, player.position.y))),
      tostring(player:isFreeToMove()), tostring(player.moveFraction),
      box(game.alertBox), box(game.confirmBox), box(game.tutorialBox),
      box(game.speechArea), box(game.multiChoiceBox),
      tostring(game:isUIBlockingPlayerMovement()), tostring(game.isAnimationBlocking),
      tostring(game.actorManager:isAnyNonPlayerActorStillSpendingTime()),
      S.phase)
  end

  if handleDialogs(game) then return end
  if game.isGameOver then return end

  tickWorld(game, player)
end

-- Keep the last game messages so a death can be explained in the log.
local recentTexts = {}
local function ensureTextHook(game)
  if S.textHookedFor == game then return end
  local original = game.addText
  if type(original) ~= "function" then return end
  S.textHookedFor = game
  game.addText = function(self, text, ...)
    recentTexts[#recentTexts + 1] = tostring(text)
    if #recentTexts > 12 then table.remove(recentTexts, 1) end
    return original(self, text, ...)
  end
end

-- Global checks run every rendered frame, independent of the player-input path,
-- so they still fire during zoom animations and cutscenes.
local function checkGlobal()
  if not S.active then return end
  local t = now()

  local current = GameState.current()
  if current == G_stateTitleScreen and not S.started then
    if CFG.autostart and G_stateTitleScreen.time and G_stateTitleScreen.time > 1 then
      S.started = true
      if G_stateTitleScreen.saveGameExists then
        log("continuing existing save")
        G_stateTitleScreen:openStartOptions()
      else
        log("starting fresh game as %s", CFG.name)
        G_stateTitleScreen:startFreshGame(CFG.name)
      end
    end
    return
  end

  local game = G_stateGame
  if not game or not game.actorManager or not game.actorManager.player then return end
  local player = game.actorManager.player
  ensureTextHook(game)

  if CFG.shotEvery and CFG.shotEvery > 0
    and love.graphics and love.graphics.captureScreenshot then
    if t - (S.lastShotT or 0) >= CFG.shotEvery then
      S.lastShotT = t
      S.shotN = (S.shotN or 0) + 1
      local name = string.format("zzshot-%03d.png", S.shotN)
      pcall(love.graphics.captureScreenshot, name)
      log("screenshot %s (%s at %d,%d)", name,
        tostring(game.currentWorldName), player.position.x, player.position.y)
    end
  end

  if S.success then
    if CFG.quit and t - (S.successAt or t) > 2 then
      S.done = true
      love.event.quit(0)
    end
    return
  end

  if S.finished then return end

  if game.isGameOver and not S.dead then
    S.dead = true
    S.finished = true
    S.done = true
    dumpMap(game, "death")
    local dc = cellAt(game.map, player.position.x, player.position.y)
    log("FAIL: player died at %s %d,%d (turn %s, cell=%s, flame=%s)",
      tostring(game.currentWorldName), player.position.x, player.position.y,
      tostring(gGameTurn), tostring(cellTypeName(dc)), tostring(player.isAflame))
    log("last messages: %s", table.concat(recentTexts, " | "))
    if CFG.quit then
      love.event.quit(1)
    else
      S.active = false
    end
    return
  end

  -- Back in a town while a dungeon is still flagged as entered: that run is
  -- over. Mark it done and let the campaign route decide what is next.
  if S.entered and S.dungeonName and game.currentWorldData
    and game.currentWorldData.isTown then
    dumpMap(game, "dungeon-done")
    log("SUCCESS: back in %s at %d,%d after %ds (turn %s)",
      tostring(game.currentWorldName), player.position.x, player.position.y,
      math.floor(S.activeTime), tostring(gGameTurn))
    markDungeonComplete(game, S.dungeonName)
    return
  end

  if S.activeTime > CFG.timeout then
    S.finished = true
    S.done = true
    log("FAIL: timeout after %ds in %s at %d,%d (turn %s)",
      CFG.timeout, tostring(game.currentWorldName), player.position.x,
      player.position.y, tostring(gGameTurn))
    if CFG.quit then
      love.event.quit(3)
    else
      S.active = false
    end
    return
  end

  if t - S.lastBeat > 20 then
    S.lastBeat = t
    local key = player:findInventoryObjectWithName("key_master") ~= nil
    local cx, cy = keyChestXY(game)
    local chestCell = cx and cellTypeName(cellAt(game.map, cx, cy)) or nil
    local minor, major = findHealPotion(player)
    local stone = findLifestone(player)
    log("beat t=%ds %s turn=%s pos=%d,%d hp=%s/%s key=%s chestKey=%s chest=%s@%s,%s pot=%s/%s stone=%s phase=%s known=%d",
      math.floor(S.activeTime), tostring(game.currentWorldName), tostring(gGameTurn),
      player.position.x, player.position.y, tostring(player.health),
      tostring(player.maxHealth), tostring(key),
      tostring(hasItem(player, "chest_key")), tostring(chestCell),
      tostring(cx), tostring(cy),
      tostring(minor and minor.count or 0), tostring(major and major.count or 0),
      tostring(stone and stone.durability or 0), S.phase, S.knownCount)
    pcall(function()
      local ps = game:getPlayerStats()
      local devs = {}
      for _, g in ipairs(G_Globals.skillFactions) do
        devs[#devs + 1] = string.format("%s=%s", g, tostring(game:getDevotion(g)))
      end
      log("stats money=%s str=%s fin=%s int=%s per=%s end=%s dev=[%s] following=%s",
        tostring(ps.money), tostring(ps.strength), tostring(ps.finesse),
        tostring(ps.intellect), tostring(ps.perception), tostring(ps.endurance),
        table.concat(devs, " "), tostring(game:getCurrentGod()))
    end)
    dumpMap(game, "beat")
  end
end

local function ensurePlayerInputWrapped()
  if S.wrapped then return end
  if not G_stateGame or type(G_stateGame.getPlayerInput) ~= "function" then return end
  S.wrapped = true
  local original = G_stateGame.getPlayerInput
  G_stateGame.getPlayerInput = function(self, ...)
    if S.active and not S.done and not S.finished then
      local ok, err = pcall(tick, self)
      if not ok then
        S.errors = S.errors + 1
        if not S.errLogged then
          S.errLogged = true
          log("ERROR in bot tick: %s\n%s", tostring(err), debug.traceback())
        end
      end
    end
    return original(self, ...)
  end
  log("player input hook installed")
end

local originalUpdate = love.update
local SPEED = math.max(1, math.floor(CFG.speed))

local function pollToggle()
  if not love.keyboard then return end
  local down = love.keyboard.isDown(CFG.toggleKey)
  if down and not S.toggleHeld then
    S.active = not S.active
    if S.active then
      S.activeTime = 0
      S.finished = false
      S.success = false
      S.successAt = nil
      S.dead = false
      S.done = false
      S.entered = false
      S.masterKeyLogged = false
      S.stuckShot = nil
      log("bot ENABLED (toggle=%s speed=%d)", CFG.toggleKey, SPEED)
    else
      log("bot DISABLED")
    end
  end
  S.toggleHeld = down
end

love.update = function(dt)
  pollToggle()
  local ok, err = pcall(checkGlobal)
  if not ok and not S.errLogged then
    S.errLogged = true
    log("ERROR in checkGlobal: %s\n%s", tostring(err), debug.traceback())
  end
  ensurePlayerInputWrapped()

  if S.active then
    S.activeTime = S.activeTime + (dt or 0)
    for _ = 1, SPEED do
      originalUpdate(1 / 40)
    end
  else
    originalUpdate(dt)
  end
end

log("loaded (name=%s speed=%d timeout=%ds toggle=%s active=%s autostart=%s)",
  CFG.name, SPEED, CFG.timeout, CFG.toggleKey,
  tostring(S.active), tostring(CFG.autostart))
