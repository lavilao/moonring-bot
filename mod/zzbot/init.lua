-- zzbot: autonomous explorer for Moonring.
-- Goal: start a fresh game, walk from Yarrow to Yarrow Cave, get the master
-- key, then leave the dungeon through its entrance.
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
  model     = (os.getenv("ZZBOT_MODEL") ~= "0"),
  modelN    = tonumber(os.getenv("ZZBOT_MODEL_N")) or 64,
  alpha     = tonumber(os.getenv("ZZBOT_ALPHA")) or 0.08,
  horizon   = tonumber(os.getenv("ZZBOT_HORIZON")) or 480,
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
            if not seen[nk] and cellWalkable(cellAt(map, nx, ny))
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

  return search(S.avoidDanger) or search(nil)
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
local function summonerProfile(data)
  local found, cooldown = false, nil
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
          local cd = ad and tonumber(ad.cooldown) or nil
          if cd and cd > 0 then
            cooldown = math.min(cooldown or cd, cd)
          end
        end
      end
    end
  end
  return found, cooldown or 200
end

local function enemyWeight(game, a, prof)
  local data = a.actorData or {}
  local summoner, summonCooldown = summonerProfile(data)
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
        local score = cd - nearest * 2
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
  if not cell then return false end
  local steps = travelSteps(game, player, cell.x, cell.y, true, true)
  if not (steps and steps[1]) then return false end
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
  }
end

local function buildPack(near)
  local pack = {}
  for i, w in ipairs(near) do
    pack[i] = {
      hp = w.hp,
      maxHP = math.max(w.hp, w.maxHP or w.hp),
      hit = w.hit,
      maxHit = math.max(w.hit, w.maxHit or w.hit),
      attackTime = w.attackTime,
      speed = w.speed,
      dist = w.dist,
      ourHit = w.ourHit,
      aware = w.aware,
      summoner = w.summoner,
      summonCooldown = w.summonCooldown,
      poisonDps = w.poisonDps,
      poisonDuration = w.poisonDuration,
      ref = w,
      id = i,
    }
  end
  return pack
end

local function copyPack(pack)
  local out = {}
  for i, t in ipairs(pack) do
    out[i] = {
      hp = t.hp, maxHP = t.maxHP, hit = t.hit, maxHit = t.maxHit,
      attackTime = t.attackTime, speed = t.speed, dist = t.dist,
      ourHit = t.ourHit, aware = t.aware, summoner = t.summoner,
      summonCooldown = t.summonCooldown,
      poisonDps = t.poisonDps, poisonDuration = t.poisonDuration,
      ref = t.ref, id = t.id,
    }
  end
  return out
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
                                  nPot, bestPot, wand, charges)
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
  if lsReady then
    local Gp = math.min(math.floor(maxhp * CC.LS_FRAC), missing)
    actions[#actions + 1] = {
      kind = "heal", item = "lifestone", healAmount = Gp,
      enemyHeals = adjacentHealMap(pack, player, Gp), time = CC.C_LS,
      label = "lifestone", resourceCost = 0.32 * val,
    }
  end

  if #adj > 0 then
    local cell, fsteps = S.modelFleeCell, S.modelFleeSteps
    if S.modelFleeTurn ~= (gGameTurn or 0) then
      cell = findFleeCell(game, player)
      fsteps = cell and travelSteps(game, player, cell.x, cell.y, true, true) or nil
      S.modelFleeCell, S.modelFleeSteps, S.modelFleeTurn = cell, fsteps, gGameTurn or 0
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
          kind = "choke", cell = ch, time = step,
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

local function modelChoose(game, player, prof, adj, near, deadEnd, nPot, bestPot,
                           wand, charges, emergency)
  if not Model then return nil end
  local pack = buildPack(near)
  if #pack == 0 then return nil end
  local actions = buildCombatOptions(game, player, prof, adj, near, pack, deadEnd,
    nPot, bestPot, wand, charges)
  if #actions == 0 then return nil end
  local state = modelState(game, player)
  local opts = {
    N = CFG.modelN,
    horizon = CFG.horizon,
    seed = (gGameTurn or 0) + 1,
  }
  local evals = {}
  for _, a in ipairs(actions) do
    local ok, ev = pcall(Model.evaluate, a, state, copyPack(pack), prof, opts)
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
  if Model and CFG.model and (S.modelErrors or 0) < 5 then
    local chosen, evals, reason = modelChoose(game, player, prof, adj, near,
      deadEnd, nPot, bestPot, wand, charges, emergency)
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

  -- 4. Go/no-go for the pack, counting potions and clean heal windows.
  local reserve = S.hasKey and 0 or CC.LS_RESERVE
  local v = verdict(near, player.health + poise, nPot,
    math.max(0, charges - reserve), prof, deadEnd)

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
  return game.triggerData:findTriggerXYOnLevelWithActionAndData(name, "playerStart", "Yarrow")
end

local function keyChestXY(game)
  local list = game.triggerData:getAllTriggersOnLevelWithActionName(
    game.currentWorldName, "exitKey")
  if not list or #list == 0 then return nil end
  local t = list[1]
  return t.x, t.y
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

-- Nearest known door plus the nav steps to a cell next to it. Empty steps mean
-- the player is already adjacent and can bump it immediately.
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
        if isBumpableDoorName(cellTypeName(neighbour)) then
          checked = checked + 1
          if checked > 24 then return nil end
          if cx == sx and cy == sy then
            return nx, ny, {}
          end
          local steps = navSteps(game, player, cx, cy)
          if steps and steps[1] then
            return nx, ny, steps
          end
        elseif cellWalkable(neighbour) and not seen[ckey(nx, ny)] then
          seen[ckey(nx, ny)] = true
          queue[#queue + 1] = { nx, ny }
        end
      end
    end
  end
  return nil
end

local function tryOpenDoor(game, player)
  local dx, dy, steps = findRoutableDoor(game, player)
  if not dx then return false end
  local px, py = playerPos(player)
  if #steps == 0 then
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

local function findActionTrigger(game, action, data)
  local list = game.triggerData:getAllTriggersOnLevelWithActionName(
    game.currentWorldName, action) or {}
  for _, t in ipairs(list) do
    if data == nil or t.data == data then return t end
  end
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

local function handleDialogs(game)
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

local function tickWorld(game, player)
  local name = game.currentWorldName
  local data = game.currentWorldData

  if name ~= S.world then
    S.world = name
    S.known = {}
    S.knownCount = 0
    S.knownPX, S.knownPY = nil, nil
    log("world changed: %s", tostring(name))
    dumpMap(game, "enter")
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

  -- Town: Yarrow's opening errand is a small key chain. Get the chest key from
  -- the floor, open the locked chest to get the farm gate key, unlock the gate
  -- around the cave stairs, then enter the dungeon.
  if data and data.isTown then
    local px, py = playerPos(player)
    local chestKey = hasItem(player, "farm_chest_key")
    local gateKey = hasItem(player, "farm_gate_key")
    local keyObject = findActionTrigger(game, "object", "farm_chest_key")
    local chest = findActionTrigger(game, "locked_chest", "farm_chest_key")
    local gate = findActionTrigger(game, "locked_door", "farm_gate_key")
    local gateKeyContainer = findActionTrigger(game, "container", "farm_gate_key")

    if townSupplyStep(game, player) then
      S.phase = "town-supplies"
      return
    end

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

    local sx, sy = game.triggerData:findTriggerXYOnLevelWithActionAndData(
      name, "playerStart", "firstDungeon-01")
    S.phase = "to-dungeon"
    if not sx then
      if now() - (S.nopathT or 0) > 5 then
        S.nopathT = now()
        log("no firstDungeon-01 playerStart in %s", tostring(name))
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
        log("town stuck at %d,%d (chestKey=%s gateKey=%s chest=%s gate=%s)",
          px, py, tostring(chestKey), tostring(gateKey),
          tostring(chest ~= nil), tostring(gate ~= nil))
      end
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
  if fx then
    S.phase = "explore"
    pressDelta(steps[1].x, steps[1].y)
    S.stuckSince = nil
    return
  end

  if tryOpenDoor(game, player) then
    S.phase = "open-door"
    S.stuckSince = nil
    return
  end

  S.phase = "stuck"
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
      log("starting fresh game as %s", CFG.name)
      G_stateTitleScreen:startFreshGame(CFG.name)
    end
    return
  end

  local game = G_stateGame
  if not game or not game.actorManager or not game.actorManager.player then return end
  local player = game.actorManager.player
  ensureTextHook(game)

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

  if S.entered and game.currentWorldData and game.currentWorldData.isTown
    and player:findInventoryObjectWithName("key_master") == nil then
    S.success = true
    S.successAt = t
    S.finished = true
    S.done = true
    dumpMap(game, "success")
    log("SUCCESS: back in %s at %d,%d after %ds (turn %s)",
      tostring(game.currentWorldName), player.position.x, player.position.y,
      math.floor(S.activeTime), tostring(gGameTurn))
    if CFG.quit then
      -- give the achievement UI a moment before closing the game
    else
      S.active = false
    end
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
