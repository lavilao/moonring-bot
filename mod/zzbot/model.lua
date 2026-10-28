-- Pure Monte Carlo model of Moonring's combat clock. No Love/game globals.
local M = {}

M.C = {
  BASE_TICK = 1,
  MAX_POISE = 200,
  WAIT_TIME = 12,
  USE_TIME = 12,
  POISON_DURATION = 240,
  POISE_FRACTION_PER_TICK = 0.0125,
  POISE_REGEN_DELAY = 36,
  BITE_CV = 0.34,
  Z95 = 1.96,
  DEFAULT_N = 96,
  DEFAULT_HORIZON = 600,
  DEFAULT_ENEMY_ATTACK_TIME = 24,
  DEFAULT_SUMMON_COOLDOWN = 200,
  DEFAULT_SUMMON_ATTACK_TIME = 24,
  DEFAULT_SUMMON_LAG = 24,
}

local MOD = 2147483647
local MULT = 48271
local EPS = 1e-9

local function num(v, d)
  if type(v) == "number" and v == v then return v end
  return d
end

local function clamp(v, lo, hi)
  if v < lo then return lo elseif v > hi then return hi end
  return v
end

local function mixSeed(base, trial, index)
  local s = math.floor(num(base, 1)) % (MOD - 1)
  s = (s + trial * 7919 + index * 104729 + 12345) % (MOD - 1)
  if s <= 0 then s = MOD - 1 end
  return s
end

function M.rng(seed)
  local s = math.floor(num(seed, 1)) % MOD
  if s <= 0 then s = s + MOD end
  return function()
    s = (s * MULT) % MOD
    return s / MOD
  end
end

local function sampleBite(rng, mean, maxHit)
  mean = num(mean, 0)
  if mean <= 0 then return 0 end
  local hi = math.max(1, num(maxHit, mean * 2))
  local u = rng() + rng() + rng() - 1.5 -- sum of 3 uniforms, sd 0.5
  local v = mean + 2 * M.C.BITE_CV * mean * u
  return clamp(v, 1, hi)
end

local function copyState(state)
  local maxHP = math.max(1, num(state and state.maxHP, 100))
  local maxPoise = math.max(1, num(state and state.maxPoise, M.C.MAX_POISE))
  return {
    hp = num(state and state.hp, maxHP),
    maxHP = maxHP,
    poise = clamp(num(state and state.poise, maxPoise), 0, maxPoise),
    maxPoise = maxPoise,
    injuryAge = math.max(0, num(state and state.injuryAge, 0)),
  }
end

local function copyPack(pack)
  local out = {}
  for i = 1, #(pack or {}) do
    local t = pack[i]
    if type(t) == "table" then
      local e = {}
      for k, v in pairs(t) do e[k] = v end
      e.hp = math.max(0, num(t.hp, 0))
      e.maxHP = math.max(1, num(t.maxHP, e.hp))
      e.hit = math.max(0, num(t.hit, 0))
      e.maxHit = math.max(1, num(t.maxHit, math.max(1, e.hit * 2)))
      e.attackTime = math.max(1, num(t.attackTime, M.C.DEFAULT_ENEMY_ATTACK_TIME))
      e.speed = math.max(0.1, num(t.speed, 1))
      e.moveCost = 8 / e.speed
      e.gap = math.max(0, num(t.dist, 1))
      e.budget = 0
      e.alive = (t.alive ~= false) and e.hp > 0
      e.summoner = t.summoner and true or false
      e.summonCooldown = math.max(1, num(t.summonCooldown, M.C.DEFAULT_SUMMON_COOLDOWN))
      e.nextSummon = e.summonCooldown
      e.poisonDps = math.max(0, num(t.poisonDps, 0))
      e.poisonDuration = math.max(1, num(t.poisonDuration, M.C.POISON_DURATION))
      e.rate = e.hit / e.attackTime
      out[i] = e
    end
  end
  return out
end

local function meanPackHit(pack)
  local sum, n = 0, 0
  for i = 1, #pack do
    local e = pack[i]
    if e.alive then sum, n = sum + e.hit, n + 1 end
  end
  return n > 0 and sum / n or 0
end

local function bestTarget(sim)
  local best, bestRate, bestHit
  for i = 1, #sim.enemies do
    local e = sim.enemies[i]
    if e.alive then
      local r = e.rate
      if not best or r > bestRate + EPS
        or (math.abs(r - bestRate) <= EPS and e.hit > bestHit + EPS) then
        best, bestRate, bestHit = i, r, e.hit
      end
    end
  end
  return best
end

local function anyAlive(sim)
  for i = 1, #sim.enemies do
    if sim.enemies[i].alive then return true end
  end
  return false
end

local function anyAdjacent(sim)
  for i = 1, #sim.enemies do
    local e = sim.enemies[i]
    if e.alive and e.gap <= 1 + EPS then return true end
  end
  return #sim.minions > 0
end

local function killEnemy(sim, e)
  if not e.alive then return end
  e.alive = false
  sim.kills = sim.kills + 1
  if sim.chokeFront == e then sim.chokeFront = nil end
end

local function damageEnemy(sim, idx, dmg)
  local e = sim.enemies[idx]
  if not e or not e.alive then return end
  dmg = math.max(0, num(dmg, 0))
  e.hp = e.hp - dmg
  if e.hp <= 0 then
    e.hp = 0
    killEnemy(sim, e)
  end
end

local function healPlayer(sim, amount)
  amount = math.max(0, num(amount, 0))
  if sim.hp <= 0 or amount <= 0 then return end
  local before = sim.hp
  sim.hp = math.min(sim.maxHP, sim.hp + amount)
  sim.healsReceived = sim.healsReceived + (sim.hp - before)
end

local function applyIncoming(sim, dmg)
  dmg = math.max(0, num(dmg, 0))
  if dmg <= 0 then return end
  sim.rawDamage = sim.rawDamage + dmg
  sim.injuryAge = 0
  if sim.poise > 0 then
    sim.poise = math.max(0, sim.poise - dmg) -- no spillover: poise fully absorbs
  else
    sim.hp = sim.hp - dmg
    if sim.hp <= 0 then
      sim.hp = 0
      sim.dead = true
      sim.deathT = sim.t
    end
  end
end

local function bite(sim, e)
  applyIncoming(sim, sampleBite(sim.rng, e.hit, e.maxHit))
  if sim.hp > 0 and e.poisonDps > 0 then
    sim.poisonDps = e.poisonDps
    sim.poisonUntil = sim.t + e.poisonDuration
    sim.injuryAge = 0
  end
end

local function minionBite(sim, m)
  applyIncoming(sim, sampleBite(sim.rng, sim.summonHit, sim.summonMaxHit))
end

local function enemyPhase(sim, dt)
  dt = math.max(0, num(dt, 0))
  if dt <= 0 then return end
  for i = 1, #sim.enemies do
    local e = sim.enemies[i]
    if e.alive then
      if sim.choke then
        if not sim.chokeFront or not sim.chokeFront.alive then
          sim.chokeFront = sim.enemies[bestTarget(sim)]
        end
        e.budget = (e == sim.chokeFront) and (e.budget + dt) or 0
      else
        e.budget = e.budget + dt
      end
    end
  end
  for i = 1, #sim.enemies do
    local e = sim.enemies[i]
    if e.alive and (not sim.choke or e == sim.chokeFront) then
      while e.budget > EPS and sim.hp > 0 and e.alive do
        if e.gap <= 1 + EPS then
          e.budget = e.budget - e.attackTime
          bite(sim, e)
        else
          e.budget = e.budget - e.moveCost
          e.gap = math.max(0, e.gap - 1)
        end
      end
    end
  end
end

local function applyPassive(sim, dt)
  if dt <= EPS then return true end
  local startT = sim.t
  local poisoned = sim.poisonDps > 0 and sim.poisonUntil > startT + EPS
  if poisoned then
    local pd = math.min(dt, sim.poisonUntil - startT)
    local dmg = sim.poisonDps * pd
    local lost = math.min(dmg, sim.hp)
    sim.rawDamage = sim.rawDamage + lost
    sim.hp = sim.hp - dmg
    sim.injuryAge = 0
    if sim.hp <= 0 then
      local dieOff = (lost / sim.poisonDps)
      sim.hp = 0
      sim.dead = true
      sim.deathT = startT + dieOff
      sim.t = sim.deathT
      return false
    end
    sim.poisonUntil = math.max(sim.poisonUntil, startT + pd)
    sim.injuryAge = 0
    return true
  end
  if not anyAdjacent(sim) then
    local delay = math.max(0, M.C.POISE_REGEN_DELAY - sim.injuryAge)
    local regenTime = math.max(0, dt - delay)
    if regenTime > 0 then
      sim.poise = math.min(sim.maxPoise,
        sim.poise + M.C.POISE_FRACTION_PER_TICK * sim.maxPoise * regenTime)
    end
  end
  sim.injuryAge = sim.injuryAge + dt
  return true
end

local function spawnDue(sim)
  for i = 1, #sim.enemies do
    local e = sim.enemies[i]
    if e.alive and e.summoner then
      while e.nextSummon <= sim.t + EPS do
        sim.summons = sim.summons + 1
        sim.minions[#sim.minions + 1] = {
          nextBite = e.nextSummon + sim.summonLag,
          attackTime = sim.summonAttack,
        }
        e.nextSummon = e.nextSummon + e.summonCooldown
      end
    end
  end
end

local function minionBitesDue(sim)
  for i = 1, #sim.minions do
    local m = sim.minions[i]
    while sim.hp > 0 and m.nextBite <= sim.t + EPS do
      minionBite(sim, m)
      m.nextBite = m.nextBite + m.attackTime
    end
  end
end

local function advanceTo(sim, target)
  target = math.min(num(target, sim.horizon), sim.horizon)
  while sim.hp > 0 and sim.t < target - EPS do
    local nextT = target
    for i = 1, #sim.minions do
      local n = sim.minions[i].nextBite
      if n > sim.t + EPS and n < nextT - EPS then nextT = n end
    end
    for i = 1, #sim.enemies do
      local e = sim.enemies[i]
      if e.alive and e.summoner and e.nextSummon > sim.t + EPS
        and e.nextSummon < nextT - EPS then
        nextT = e.nextSummon
      end
    end
    local dt = nextT - sim.t
    if dt > EPS then
      if not applyPassive(sim, dt) then return end
      sim.t = nextT
    end
    spawnDue(sim)
    minionBitesDue(sim)
    if nextT >= target - EPS then break end
  end
end

local function stepGap(sim)
  for i = 1, #sim.enemies do
    local e = sim.enemies[i]
    if e.alive then e.gap = e.gap + 1 end
  end
end

local function allOutrun(sim, step)
  if #sim.minions > 0 then return false end
  for i = 1, #sim.enemies do
    local e = sim.enemies[i]
    if e.alive then
      if e.gap <= 1 + EPS then return false end
      if step / e.moveCost > 1 + EPS then return false end
    end
  end
  return true
end

local function runMovement(sim, action, kind)
  local steps = math.max(0, math.floor(num(action.moveSteps, 1)))
  local step = num(sim.prof.step, 8 / math.max(0.1, num(sim.prof.speed, 1)))
  if step <= 0 then step = 8 end
  for s = 1, steps do
    if sim.hp <= 0 or sim.t >= sim.horizon - EPS then break end
    local t0 = sim.t
    stepGap(sim)
    enemyPhase(sim, step)
    advanceTo(sim, t0 + step)
    if kind == "flee" and s >= 1 and allOutrun(sim, step) then break end
  end
  if action.terminal and (kind == "flee" or kind == "move") then
    sim.escaped = true
  end
end

local function firstAction(sim, action)
  local kind = action.kind or "wait"
  local prof = sim.prof
  if kind == "choke" or action.choke then sim.choke = true end

  if kind == "attack" or kind == "choke" then
    local idx = action.target
    if not (idx and sim.enemies[idx] and sim.enemies[idx].alive) then
      idx = bestTarget(sim)
    end
    if sim.choke and idx then sim.chokeFront = sim.enemies[idx] end
    if idx then damageEnemy(sim, idx, prof.hit) end
    local T = math.max(0, num(action.time, prof.attackTime))
    local t0 = sim.t
    enemyPhase(sim, T)
    if sim.hp > 0 then advanceTo(sim, t0 + T) end
  elseif kind == "heal" then
    healPlayer(sim, action.healAmount or action.amount)
    if type(action.enemyHeals) == "table" then
      for idx, amount in pairs(action.enemyHeals) do
        local e = sim.enemies[idx]
        if e and e.alive and num(amount, 0) > 0 then
          e.hp = math.min(e.maxHP, e.hp + amount)
        end
      end
    end
    local T = math.max(0, num(action.time, M.C.USE_TIME))
    local t0 = sim.t
    enemyPhase(sim, T)
    if sim.hp > 0 then advanceTo(sim, t0 + T) end
  elseif kind == "move" or kind == "flee" then
    runMovement(sim, action, kind)
  else
    local T = math.max(0, num(action.time, M.C.WAIT_TIME))
    local t0 = sim.t
    enemyPhase(sim, T)
    if sim.hp > 0 then advanceTo(sim, t0 + T) end
  end
end

local function referenceRollout(sim)
  local at = math.max(1, num(sim.prof.attackTime, 15))
  while sim.hp > 0 and sim.t < sim.horizon - EPS do
    if not anyAlive(sim) then
      if #sim.minions > 0 then advanceTo(sim, sim.horizon) end
      break
    end
    local idx = sim.choke and sim.chokeFront and sim.chokeFront.alive
      and (function()
        for i = 1, #sim.enemies do
          if sim.enemies[i] == sim.chokeFront then return i end
        end
      end)() or bestTarget(sim)
    if idx then damageEnemy(sim, idx, sim.prof.hit) end
    if not anyAlive(sim) and #sim.minions == 0 then break end
    enemyPhase(sim, at)
    if sim.hp <= 0 then break end
    advanceTo(sim, sim.t + at)
  end
end

local function simulate(action, state, pack, prof, opts, index)
  local maxHP = math.max(1, num(state and state.maxHP, 100))
  local maxPoise = math.max(1, num(state and state.maxPoise, M.C.MAX_POISE))
  local enemies = copyPack(pack)
  local summonHit = num(opts and opts.summonHit,
    meanPackHit(enemies) * 0.5)
  local sim = {
    hp = num(state and state.hp, maxHP),
    maxHP = maxHP,
    poise = clamp(num(state and state.poise, maxPoise), 0, maxPoise),
    maxPoise = maxPoise,
    injuryAge = math.max(0, num(state and state.injuryAge, 0)),
    enemies = enemies,
    prof = {
      attackTime = math.max(1, num(prof and prof.attackTime, 15)),
      step = num(prof and prof.step, 8 / math.max(0.1, num(prof and prof.speed, 1))),
      hit = math.max(0, num(prof and prof.hit, 0)),
      speed = math.max(0.1, num(prof and prof.speed, 1)),
    },
    rng = M.rng(mixSeed(num(opts and opts.seed, 1), 1, index)),
    horizon = math.max(0, num(opts and opts.horizon, M.C.DEFAULT_HORIZON)),
    t = 0,
    rawDamage = 0,
    kills = 0,
    summons = 0,
    healsReceived = 0,
    poisonDps = 0,
    poisonUntil = 0,
    minions = {},
    summonHit = math.max(0, summonHit),
    summonMaxHit = math.max(1, num(opts and opts.summonMaxHit, math.max(1, summonHit * 2))),
    summonAttack = math.max(1, num(opts and opts.summonAttackTime, M.C.DEFAULT_SUMMON_ATTACK_TIME)),
    summonLag = math.max(0, num(opts and opts.summonLag, M.C.DEFAULT_SUMMON_LAG)),
    choke = false,
    chokeFront = nil,
    dead = false,
    deathT = nil,
    escaped = false,
  }
  sim.hp = math.max(0, sim.hp)
  if sim.hp <= 0 then sim.dead = true; sim.deathT = 0 end
  if not sim.dead then
    firstAction(sim, action or {})
    if not sim.escaped then referenceRollout(sim) end
  end
  local endT = sim.dead and (sim.deathT or sim.t) or math.min(sim.t, sim.horizon)
  return {
    hp = sim.dead and 0 or sim.hp,
    poise = sim.poise,
    damage = sim.rawDamage,
    duration = endT,
    kills = sim.kills,
    summons = sim.summons,
    heals = sim.healsReceived,
    death = sim.dead and 1 or 0,
  }
end

local function wilsonUpper(k, n, z)
  if n <= 0 then return 1 end
  local p = k / n
  local z2 = z * z
  local denom = 1 + z2 / n
  local center = (p + z2 / (2 * n)) / denom
  local half = z * math.sqrt((p * (1 - p) + z2 / (4 * n)) / n) / denom
  return clamp(center + half, 0, 1)
end

local function evaluateAt(action, state, pack, prof, opts, index)
  opts = opts or {}
  local N = math.max(1, math.floor(num(opts.N, M.C.DEFAULT_N)))
  local baseSeed = num(opts.seed, 1)
  local horizon = math.max(0, num(opts.horizon, M.C.DEFAULT_HORIZON))
  local localOpts = {
    seed = baseSeed, horizon = horizon, N = N,
    summonHit = opts.summonHit, summonMaxHit = opts.summonMaxHit,
    summonAttackTime = opts.summonAttackTime, summonLag = opts.summonLag,
  }
  local hps, aliveHps = {}, {}
  local deaths, sumHP, sumAlive, sumPoise, sumDamage = 0, 0, 0, 0, 0
  local sumDur, sumKills, sumSummons, sumHeals = 0, 0, 0, 0
  local aliveCount = 0
  for trial = 1, N do
    local r = simulate(action, state, pack, prof, localOpts, index)
    hps[trial] = r.hp
    sumHP = sumHP + r.hp
    if r.death == 0 then
      aliveCount = aliveCount + 1
      sumAlive = sumAlive + r.hp
      aliveHps[#aliveHps + 1] = r.hp
    else
      deaths = deaths + 1
    end
    sumPoise = sumPoise + r.poise
    sumDamage = sumDamage + r.damage
    sumDur = sumDur + r.duration
    sumKills = sumKills + r.kills
    sumSummons = sumSummons + r.summons
    sumHeals = sumHeals + r.heals
  end
  table.sort(hps)
  local p10idx = math.max(1, math.ceil(0.10 * N))
  local p10 = hps[p10idx] or 0
  return {
    pDeath = deaths / N,
    pDeathUpper = wilsonUpper(deaths, N, M.C.Z95),
    meanHP = sumHP / N,
    p10HP = p10,
    meanHPAlive = aliveCount > 0 and (sumAlive / aliveCount) or 0,
    meanPoise = sumPoise / N,
    meanDamage = sumDamage / N,
    meanDuration = sumDur / N,
    meanKills = sumKills / N,
    meanSummons = sumSummons / N,
    meanHealsReceived = sumHeals / N,
    n = N,
    seed = baseSeed,
  }
end

function M.evaluate(action, state, pack, prof, opts)
  local index = num(action and action.index, num(opts and opts.actionIndex, 0))
  return evaluateAt(action, state, pack, prof, opts, index)
end

function M.evaluateAll(actions, state, pack, prof, opts)
  local out = {}
  for i = 1, #(actions or {}) do
    local ev = evaluateAt(actions[i], state, pack, prof, opts, i - 1)
    ev.action = actions[i]
    out[i] = ev
  end
  return out
end

local function resourceCost(ev)
  if ev.action and type(ev.action.resourceCost) == "number" then
    return ev.action.resourceCost
  end
  return num(ev.resourceCost, 0)
end

function M.rank(evals)
  local order = {}
  for i = 1, #(evals or {}) do order[i] = { ev = evals[i], i = i } end
  table.sort(order, function(a, b)
    local x, y = a.ev, b.ev
    if x.pDeathUpper ~= y.pDeathUpper then
      return x.pDeathUpper < y.pDeathUpper
    end
    if x.meanHP ~= y.meanHP then return x.meanHP > y.meanHP end
    local cx, cy = resourceCost(x), resourceCost(y)
    if cx ~= cy then return cx < cy end
    if x.meanDuration ~= y.meanDuration then
      return x.meanDuration < y.meanDuration
    end
    return a.i < b.i
  end)
  local out = {}
  for i = 1, #order do out[i] = order[i].ev end
  return out
end

return M
