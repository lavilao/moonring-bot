-- Pure Monte Carlo model of Moonring's combat clock. No Love/game globals.
-- Damage, poise, poison and summons follow the numbers in actor.lua,
-- actions.lua and the CSV data tables; see docs/mechanics.md.
local M = {}

M.C = {
  MAX_POISE = 200,
  WAIT_TIME = 12,
  USE_TIME = 12,
  POISE_FRACTION_PER_TICK = 0.0125,
  POISE_REGEN_DELAY = 36,
  POISON_DECAY_PER_TICK = 0.00125,
  POISON_DECAY_DELAY = 10,
  POISON_BURST_FRACTION = 0.5,
  BITE_CV = 0.34,
  Z95 = 1.96,
  DEFAULT_N = 96,
  DEFAULT_HORIZON = 600,
  DEFAULT_ENEMY_ATTACK_TIME = 24,
  DEFAULT_SUMMON_LAG = 6,
  DEFAULT_SUMMON_FIRST = 12,
  DEFAULT_SUMMON_COOLDOWN = 4000,
  DEFAULT_SUMMON_COUNT_MIN = 2,
  DEFAULT_SUMMON_COUNT_MAX = 4,
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

local function mixSeed(base, trial)
  local s = math.floor(num(base, 1)) % (MOD - 1)
  s = (s + trial * 7919 + 12345) % (MOD - 1)
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

-- Consecutive LCG outputs lie on a lattice, so summing three of them badly
-- under-represents the tails. One uniform through the exact Bates(3) inverse
-- CDF (the distribution of the sum of three uniforms) fixes the per-bite law.
local BATES_INV
do
  local K = 512
  BATES_INV = {}
  local function cdf(x)
    if x <= 0 then return 0 end
    if x >= 3 then return 1 end
    local v = x * x * x
    if x > 1 then v = v - 3 * (x - 1) ^ 3 end
    if x > 2 then v = v + 3 * (x - 2) ^ 3 end
    return v / 6
  end
  for i = 0, K do
    local r, lo, hi = i / K, 0, 3
    for _ = 1, 36 do
      local mid = (lo + hi) * 0.5
      if cdf(mid) < r then lo = mid else hi = mid end
    end
    BATES_INV[i] = (lo + hi) * 0.5
  end
end
local BATES_K = #BATES_INV - 1

local function bates3(r)
  if r <= 0 then return 0 end
  if r >= 1 then return 3 end
  local f = r * BATES_K
  local i = math.floor(f)
  local frac = f - i
  return BATES_INV[i] + (BATES_INV[i + 1] - BATES_INV[i]) * frac
end

local function sampleBite(rng, mean, maxHit)
  mean = num(mean, 0)
  if mean <= 0 then return 0 end
  local hi = math.max(1, num(maxHit, mean * 2))
  local v = mean * (1 + 2 * M.C.BITE_CV * (bates3(rng()) - 1.5))
  return clamp(v, 1, hi)
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
      e.ourHit = type(t.ourHit) == "number" and math.max(0, t.ourHit) or nil
      e.poisonPerHit = math.max(0, num(t.poisonPerHit, 0))
      e.budget = 0
      e.alive = (t.alive ~= false) and e.hp > 0
      e.summoner = t.summoner and true or false
      e.summonCooldown = math.max(1, num(t.summonCooldown, M.C.DEFAULT_SUMMON_COOLDOWN))
      e.nextSummon = math.max(0, num(t.summonFirst, M.C.DEFAULT_SUMMON_FIRST))
      e.rate = (e.hit + 16 * e.poisonPerHit) / e.attackTime
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

local function anyAdjacent(sim)
  for i = 1, #sim.enemies do
    local e = sim.enemies[i]
    if e.alive and e.gap <= 1 + EPS then return true end
  end
  for i = 1, #sim.minions do
    local m = sim.minions[i]
    if m.alive and m.gap <= 1 + EPS then return true end
  end
  return false
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
  e.hp = e.hp - math.max(0, num(dmg, 0))
  if e.hp <= 0 then
    e.hp = 0
    killEnemy(sim, e)
  end
end

local function damageMinion(sim, m, dmg)
  if not m or not m.alive then return end
  m.hp = m.hp - math.max(0, num(dmg, 0))
  if m.hp <= 0 then
    m.hp = 0
    m.alive = false
    sim.kills = sim.kills + 1
  end
end

local function hitOn(sim, e)
  if type(e.ourHit) == "number" then return e.ourHit end
  return math.max(0, num(sim.prof.hit, 0))
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

-- Poison is not a damage-over-time: when the meter reaches 1 it instantly
-- removes half of current health, bypasses poise, can never kill (clamped to
-- 1 hp) and resets the meter (actor.lua:4058-4066, actor.lua:8515).
local function applyPoisonHit(sim, e)
  local p = num(e and e.poisonPerHit, 0)
  if p <= 0 or sim.hp <= 0 then return end
  sim.poison = sim.poison + p
  sim.lastPoisonT = sim.t
  if sim.poison >= 1 - EPS then
    local lost = math.ceil(sim.hp * M.C.POISON_BURST_FRACTION)
    sim.hp = math.max(1, sim.hp - lost)
    sim.rawDamage = sim.rawDamage + lost
    sim.poisonBursts = sim.poisonBursts + 1
    sim.poison = 0
    sim.injuryAge = 0
  end
end

local function bite(sim, e)
  applyIncoming(sim, sampleBite(sim.rng, e.hit, e.maxHit))
  if sim.hp > 0 then applyPoisonHit(sim, e) end
end

local function nearestPackIndex(sim)
  local best, bestGap
  for i = 1, #sim.enemies do
    local e = sim.enemies[i]
    if e.alive and (not best or e.gap < bestGap) then best, bestGap = i, e.gap end
  end
  return best
end

local function enemyPhase(sim, dt)
  dt = math.max(0, num(dt, 0))
  if dt <= 0 then return end
  for i = 1, #sim.enemies do
    local e = sim.enemies[i]
    if e.alive then
      if sim.choke then
        if not sim.chokeFront or not sim.chokeFront.alive then
          sim.chokeFront = sim.enemies[nearestPackIndex(sim)]
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
  if sim.poison > 0 then
    local since = sim.t - sim.lastPoisonT
    local delay = math.max(0, M.C.POISON_DECAY_DELAY - since)
    local decayT = math.max(0, dt - delay)
    if decayT > 0 then
      sim.poison = math.max(0, sim.poison - M.C.POISON_DECAY_PER_TICK * decayT)
    end
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

local function minionSpec(sim, queen)
  local s = queen and sim.queen or sim.normal
  return {
    hp = math.max(1, num(s.hp, 50)),
    hit = math.max(0, num(s.hit, 0)),
    maxHit = math.max(1, num(s.maxHit, math.max(1, num(s.hit, 0) * 2))),
    attackTime = math.max(1, num(s.attackTime, M.C.DEFAULT_ENEMY_ATTACK_TIME)),
    speed = math.max(0.1, num(s.speed, 1.5)),
    poisonPerHit = math.max(0, num(s.poisonPerHit, 0)),
    ourHit = type(s.ourHit) == "number" and s.ourHit or nil,
  }
end

local function spawnDue(sim)
  for i = 1, #sim.enemies do
    local e = sim.enemies[i]
    if e.alive and e.summoner then
      while e.nextSummon <= sim.t + EPS do
        local lo = math.max(1, math.floor(num(sim.summonCountMin, 2)))
        local hi = math.max(lo, math.floor(num(sim.summonCountMax, 4)))
        local count = lo + math.floor(sim.rng() * (hi - lo + 1))
        for _ = 1, count do
          local queen = sim.rng() < sim.queenChance
          local spec = minionSpec(sim, queen)
          sim.minions[#sim.minions + 1] = {
            hp = spec.hp,
            maxHP = spec.hp,
            hit = spec.hit,
            maxHit = spec.maxHit,
            attackTime = spec.attackTime,
            speed = spec.speed,
            moveCost = 8 / spec.speed,
            poisonPerHit = spec.poisonPerHit,
            ourHit = spec.ourHit,
            gap = math.max(1, e.gap),
            alive = true,
            nextAct = sim.t + sim.summonLag,
          }
        end
        sim.summons = sim.summons + 1
        e.nextSummon = e.nextSummon + e.summonCooldown
      end
    end
  end
end

local function minionStep(sim)
  for i = 1, #sim.minions do
    local m = sim.minions[i]
    while m.alive and sim.hp > 0 and m.nextAct <= sim.t + EPS do
      if m.gap > 1 + EPS then
        m.gap = m.gap - 1
        m.nextAct = m.nextAct + m.moveCost
      else
        applyIncoming(sim, sampleBite(sim.rng, m.hit, m.maxHit))
        if sim.hp > 0 then applyPoisonHit(sim, m) end
        m.nextAct = m.nextAct + m.attackTime
      end
    end
  end
end

local function advanceTo(sim, target)
  target = math.min(num(target, sim.horizon), sim.horizon)
  while sim.hp > 0 and sim.t < target - EPS do
    local nextT = target
    for i = 1, #sim.minions do
      local m = sim.minions[i]
      if m.alive and m.nextAct > sim.t + EPS and m.nextAct < nextT - EPS then
        nextT = m.nextAct
      end
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
      applyPassive(sim, dt)
      sim.t = nextT
    end
    if sim.hp <= 0 then return end
    spawnDue(sim)
    minionStep(sim)
    if nextT >= target - EPS then break end
  end
end

local function stepGap(sim)
  for i = 1, #sim.enemies do
    local e = sim.enemies[i]
    if e.alive then e.gap = e.gap + 1 end
  end
  for i = 1, #sim.minions do
    local m = sim.minions[i]
    if m.alive then m.gap = m.gap + 1 end
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
  for _ = 1, steps do
    if sim.hp <= 0 or sim.t >= sim.horizon - EPS then break end
    local t0 = sim.t
    stepGap(sim)
    enemyPhase(sim, step)
    advanceTo(sim, t0 + step)
    if kind == "flee" and allOutrun(sim, step) then
      sim.escaped = true
      break
    end
  end
  if action.terminal and (kind == "flee" or kind == "move") then
    sim.escaped = true
  end
end

-- The player's own attacks only reach adjacent enemies; standing still and
-- swinging at something five tiles away would make every option look safe.
local function adjacentEnemyIndex(sim)
  local best, bestRate
  for i = 1, #sim.enemies do
    local e = sim.enemies[i]
    if e.alive and e.gap <= 1 + EPS
      and (not sim.choke or e == sim.chokeFront) then
      if e.summoner then return i end
      local r = e.rate
      if not best or r > bestRate + EPS then best, bestRate = i, r end
    end
  end
  return best
end

local function adjacentMinion(sim)
  local best, bestRate
  for i = 1, #sim.minions do
    local m = sim.minions[i]
    if m.alive and m.gap <= 1 + EPS then
      local r = m.hit / m.attackTime
      if not best or r > bestRate + EPS then best, bestRate = m, r end
    end
  end
  return best
end

local function nearestThreat(sim)
  local best, bestGap
  for i = 1, #sim.enemies do
    local e = sim.enemies[i]
    if e.alive and (not best or e.gap < bestGap) then best, bestGap = e, e.gap end
  end
  for i = 1, #sim.minions do
    local m = sim.minions[i]
    if m.alive and (not best or m.gap < bestGap) then best, bestGap = m, m.gap end
  end
  return best
end

local function referenceRollout(sim)
  local at = math.max(1, num(sim.prof.attackTime, 15))
  local step = math.max(1, num(sim.prof.step, 8))
  while sim.hp > 0 and sim.t < sim.horizon - EPS do
    local alivePack = false
    for i = 1, #sim.enemies do
      if sim.enemies[i].alive then alivePack = true break end
    end
    local aliveMinion = false
    for i = 1, #sim.minions do
      if sim.minions[i].alive then aliveMinion = true break end
    end
    if not alivePack and not aliveMinion then break end

    local idx = adjacentEnemyIndex(sim)
    local minion = adjacentMinion(sim)
    local target
    if idx then
      damageEnemy(sim, idx, hitOn(sim, sim.enemies[idx]))
      target = at
    elseif minion then
      damageMinion(sim, minion, hitOn(sim, minion))
      target = at
    else
      local t = nearestThreat(sim)
      if sim.choke then
        target = at
      elseif t then
        -- close one tile toward the nearest threat, then let enemies act
        t.gap = math.max(0, t.gap - 1)
        target = step
      else
        target = at
      end
    end
    enemyPhase(sim, target)
    if sim.hp <= 0 then break end
    advanceTo(sim, sim.t + target)
  end
end

local function firstAction(sim, action)
  local kind = action.kind or "wait"
  local prof = sim.prof

  if kind == "attack" then
    local idx = action.target
    if not (idx and sim.enemies[idx] and sim.enemies[idx].alive
            and sim.enemies[idx].gap <= 1 + EPS) then
      idx = adjacentEnemyIndex(sim)
    end
    if idx then damageEnemy(sim, idx, hitOn(sim, sim.enemies[idx])) end
    local T = math.max(0, num(action.time, prof.attackTime))
    local t0 = sim.t
    enemyPhase(sim, T)
    if sim.hp > 0 then advanceTo(sim, t0 + T) end
  elseif kind == "choke" then
    -- one step toward the choke, then the reference holds the funnel
    runMovement(sim, { moveSteps = 1 }, "move")
    if sim.hp > 0 then
      sim.choke = true
      local i = nearestPackIndex(sim)
      sim.chokeFront = i and sim.enemies[i] or nil
    end
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

local function simulate(action, state, pack, prof, opts, trial)
  local maxHP = math.max(1, num(state and state.maxHP, 100))
  local maxPoise = math.max(1, num(state and state.maxPoise, M.C.MAX_POISE))
  local enemies = copyPack(pack)
  local summon = opts and opts.summon
  local normal = (summon and summon.normal) or {
    hit = meanPackHit(enemies) * 0.5,
    maxHit = math.max(1, meanPackHit(enemies)),
    attackTime = M.C.DEFAULT_ENEMY_ATTACK_TIME,
    speed = 1.5,
    hp = 50,
    poisonPerHit = 0,
  }
  local sim = {
    hp = math.max(0, num(state and state.hp, maxHP)),
    maxHP = maxHP,
    poise = clamp(num(state and state.poise, maxPoise), 0, maxPoise),
    maxPoise = maxPoise,
    injuryAge = math.max(0, num(state and state.injuryAge, 0)),
    poison = clamp(num(state and state.poison, 0), 0, 1),
    lastPoisonT = -M.C.POISON_DECAY_DELAY,
    enemies = enemies,
    prof = {
      attackTime = math.max(1, num(prof and prof.attackTime, 15)),
      step = num(prof and prof.step, 8 / math.max(0.1, num(prof and prof.speed, 1))),
      hit = math.max(0, num(prof and prof.hit, 0)),
      speed = math.max(0.1, num(prof and prof.speed, 1)),
    },
    rng = M.rng(mixSeed(num(opts and opts.seed, 1), trial)),
    horizon = math.max(0, num(opts and opts.horizon, M.C.DEFAULT_HORIZON)),
    t = 0,
    rawDamage = 0,
    kills = 0,
    summons = 0,
    healsReceived = 0,
    poisonBursts = 0,
    minions = {},
    normal = normal,
    queen = (summon and summon.queen) or normal,
    queenChance = clamp(num(summon and summon.queenChance, 0), 0, 1),
    summonCountMin = num(summon and summon.countMin, M.C.DEFAULT_SUMMON_COUNT_MIN),
    summonCountMax = num(summon and summon.countMax, M.C.DEFAULT_SUMMON_COUNT_MAX),
    summonLag = math.max(0, num(summon and summon.lag, M.C.DEFAULT_SUMMON_LAG)),
    choke = false,
    chokeFront = nil,
    dead = false,
    deathT = nil,
    escaped = false,
  }
  if sim.hp <= 0 then
    sim.dead = true
    sim.deathT = 0
  else
    firstAction(sim, action or {})
    if not sim.escaped and sim.hp > 0 then referenceRollout(sim) end
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
    poisonBursts = sim.poisonBursts,
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
    summon = opts.summon,
  }
  local hps, aliveHps = {}, {}
  local deaths, sumHP, sumAlive, sumPoise, sumDamage = 0, 0, 0, 0, 0
  local sumDur, sumKills, sumSummons, sumHeals, sumBursts = 0, 0, 0, 0, 0
  local aliveCount = 0
  for trial = 1, N do
    local r = simulate(action, state, pack, prof, localOpts, trial)
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
    sumBursts = sumBursts + r.poisonBursts
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
    meanPoisonBursts = sumBursts / N,
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
