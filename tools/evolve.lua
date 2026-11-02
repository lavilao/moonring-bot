-- tools/evolve.lua — offline evolutionary search over the bot's model knobs.
--
-- The death/survival outcome of a run is the verifiable reward; the genome is
-- the handful of env-settable CFG numbers (risk tolerance, horizon, trading
-- reserves). Pure Lua 5.1, no LÖVE, no game: it never launches Moonring. The
-- loop is driven by the operator:
--
--   lua tools/evolve.lua next        -> prints the env line of the next
--                                       individual to evaluate
--   (run the bot overnight with those env vars, e.g. via tools/run.sh)
--   lua tools/evolve.lua record logs/zzbot.log
--                                    -> scores that run into the genome
--   lua tools/evolve.lua status      -> population table
--
-- When the whole population is scored the tool evolves: elites survive,
-- the rest come from tournament selection + uniform crossover + gaussian
-- mutation, clamped to the declared bounds. Genome #1 of every generation is
-- the stock default, so the search can only drift as far as evidence pulls
-- it. State persists in a Lua-source file (EVOLVE_STATE, default
-- work/evolve_state.lua) with a stored LCG seed so runs are reproducible.

local M = {}

-- Genome spec: bounds and stock defaults (mirrors README defaults).
M.SPEC = {
  alpha        = { min = 0.02, max = 0.30, def = 0.08 },
  horizon      = { min = 120,  max = 900,  def = 480 },
  moneyReserve = { min = 50,   max = 400,  def = 150 },
  sellHold     = { min = 0.70, max = 1.10, def = 0.95 },
  tradeMargin  = { min = 1.05, max = 1.60, def = 1.20 },
  tradeTake    = { min = 1.00, max = 1.40, def = 1.10 },
}

-- Fitness weights over EV| events (tools/check_log.lua format).
M.WEIGHTS = {
  campaign_done = 200,
  dungeon_done  = 50,
  level_done    = 10,
  objective     = 3,
  death         = -30,
  timeout       = -15,
}

M.POP = 6
M.SIGMA = 0.15     -- mutation width, as a fraction of the gene range
M.ELITE = 2        -- individuals copied verbatim into the next generation
M.TOURNAMENT = 3

-- Deterministic LCG so an evolution can be replayed from the state file.
function M.rngNew(seed) return { x = seed or 42 } end

function M.rng01(r)
  r.x = (1103515245 * r.x + 12345) % 2147483648
  return r.x / 2147483648
end

function M.gauss(r)
  -- Box-Muller; guard log(0) by rejecting u1 == 0
  local u1 = M.rng01(r)
  while u1 <= 0 do u1 = M.rng01(r) end
  local u2 = M.rng01(r)
  return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2)
end

function M.clampGenes(genes)
  local out = {}
  for k, s in pairs(M.SPEC) do
    local v = tonumber(genes and genes[k]) or s.def
    if v < s.min then v = s.min elseif v > s.max then v = s.max end
    out[k] = v
  end
  return out
end

-- The env line an individual translates to (run the bot with these).
function M.envLine(genes)
  local parts = {}
  local order = { "alpha", "horizon", "moneyReserve", "sellHold", "tradeMargin", "tradeTake" }
  local names = {
    alpha = "ZZBOT_ALPHA", horizon = "ZZBOT_HORIZON",
    moneyReserve = "ZZBOT_MONEY_RESERVE", sellHold = "ZZBOT_SELL_HOLD",
    tradeMargin = "ZZBOT_TRADE_MARGIN", tradeTake = "ZZBOT_TRADE_TAKE",
  }
  for _, k in ipairs(order) do
    parts[#parts + 1] = string.format("%s=%s", names[k], tostring(genes[k]))
  end
  return table.concat(parts, " ")
end

-- Parse the EV| lines of a metrics log into event-kind counts.
function M.parseLog(text)
  local counts = {}
  if type(text) ~= "string" then return counts end
  for line in text:gmatch("[^\r\n]+") do
    local kind = line:match("|kind=([%w_]+)")
    if kind then counts[kind] = (counts[kind] or 0) + 1 end
  end
  return counts
end

-- Score event counts. Aggregates over every run fed into the same genome.
function M.fitness(counts)
  local total = 0
  for kind, n in pairs(counts or {}) do
    local w = M.WEIGHTS[kind]
    if w then total = total + w * n end
  end
  return total
end

-- Fresh population: individual 1 is the stock default, the rest are random
-- draws inside the bounds.
function M.seedPopulation(rng)
  local inds = {
    { genes = M.clampGenes({}), fitness = nil, runs = 0 },
  }
  for _ = 2, M.POP do
    local g = {}
    for k, s in pairs(M.SPEC) do
      g[k] = s.min + M.rng01(rng) * (s.max - s.min)
    end
    inds[#inds + 1] = { genes = M.clampGenes(g), fitness = nil, runs = 0 }
  end
  return inds
end

local function tournament(inds, rng)
  local best = nil
  for _ = 1, M.TOURNAMENT do
    local i = inds[math.floor(M.rng01(rng) * #inds) + 1]
    if not best or (i.fitness or -math.huge) > (best.fitness or -math.huge) then
      best = i
    end
  end
  return best
end

-- Evolve a fully-scored population into the next one.
function M.evolve(inds, rng)
  local ranked = {}
  for _, i in ipairs(inds) do ranked[#ranked + 1] = i end
  table.sort(ranked, function(a, b) return (a.fitness or -math.huge) > (b.fitness or -math.huge) end)
  local next = {}
  for i = 1, math.min(M.ELITE, #ranked) do
    next[#next + 1] = { genes = M.clampGenes(ranked[i].genes),
      fitness = nil, runs = 0 }
  end
  while #next < M.POP do
    local pa, pb = tournament(ranked, rng), tournament(ranked, rng)
    local g = {}
    for k, s in pairs(M.SPEC) do
      local v = (M.rng01(rng) < 0.5) and pa.genes[k] or pb.genes[k]
      if M.rng01(rng) < 0.5 then
        v = v + M.gauss(rng) * M.SIGMA * (s.max - s.min)
      end
      g[k] = v
    end
    next[#next + 1] = { genes = M.clampGenes(g), fitness = nil, runs = 0 }
  end
  return next, ranked
end

-- State persistence (Lua source, same trust model as the knowledge ledger).
local function fmtGenes(g)
  local keys = {}
  for k in pairs(g) do keys[#keys + 1] = k end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    parts[#parts + 1] = string.format("%s = %s,", k, tostring(g[k]))
  end
  return "{ " .. table.concat(parts, " ") .. " }"
end

function M.save(state, path)
  local parts = {
    "-- evolve state (auto-written)",
    "return {",
    string.format("gen = %d,", state.gen),
    string.format("rng = %d,", state.rng.x),
    string.format("running = %s,", tostring(state.running)),
    "individuals = {",
  }
  for _, i in ipairs(state.individuals) do
    parts[#parts + 1] = string.format(
      "{ genes = %s, fitness = %s, runs = %d },",
      fmtGenes(i.genes),
      i.fitness and string.format("%.2f", i.fitness) or "nil",
      i.runs)
  end
  parts[#parts + 1] = "},"
  parts[#parts + 1] = "}"
  local f = io.open(path, "w")
  if not f then return false end
  f:write(table.concat(parts, "\n") .. "\n")
  f:close()
  return true
end

function M.load(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local body = f:read("*a")
  f:close()
  local fn = (loadstring or load)(body)
  if not fn then return nil end
  local ok, st = pcall(fn)
  if not ok or type(st) ~= "table" or type(st.individuals) ~= "table" then
    return nil
  end
  for _, i in ipairs(st.individuals) do
    if type(i) ~= "table" or type(i.genes) ~= "table" then return nil end
    i.genes = M.clampGenes(i.genes)
    i.runs = tonumber(i.runs) or 0
    i.fitness = tonumber(i.fitness)
  end
  st.rng = M.rngNew(tonumber(st.rng) or 42)
  st.gen = tonumber(st.gen) or 1
  st.running = tonumber(st.running)
  return st
end

local function defaultState()
  return {
    gen = 1,
    rng = M.rngNew(42),
    running = nil,
    individuals = M.seedPopulation(M.rngNew(42)),
  }
end

-- CLI ----------------------------------------------------------------------

local function statePath()
  return os.getenv("EVOLVE_STATE") or "work/evolve_state.lua"
end

local function cmdNext(st, path)
  for idx, i in ipairs(st.individuals) do
    if i.fitness == nil and st.running ~= idx then
      st.running = idx
      M.save(st, path)
      print(string.format("gen %d individual %d/%d", st.gen, idx, #st.individuals))
      print(M.envLine(i.genes))
      return 0
    end
  end
  print("population fully evaluated; run: record on every run, then status")
  return 1
end

local function cmdRecord(st, path, logpath)
  if not st.running then
    print("no individual marked running; run `next` first")
    return 1
  end
  local f = io.open(logpath, "r")
  if not f then
    print("cannot read " .. tostring(logpath))
    return 1
  end
  local text = f:read("*a")
  f:close()
  local counts = M.parseLog(text)
  local score = M.fitness(counts)
  local i = st.individuals[st.running]
  i.fitness = (i.fitness or 0) + score
  i.runs = i.runs + 1
  print(string.format("gen %d individual %d: run scored %.1f (now %.1f over %d run(s))",
    st.gen, st.running, score, i.fitness, i.runs))
  for _, kind in ipairs({ "campaign_done", "dungeon_done", "level_done", "death", "timeout" }) do
    if counts[kind] then print(string.format("  %-14s x%d", kind, counts[kind])) end
  end
  -- Whole population scored? Evolve into the next generation.
  local all = true
  for _, j in ipairs(st.individuals) do
    if j.fitness == nil then all = false break end
  end
  if all then
    local nextInds, ranked = M.evolve(st.individuals, st.rng)
    local best = ranked[1]
    print(string.format("-- generation %d complete; best %.1f | evolving to gen %d",
      st.gen, best.fitness or 0, st.gen + 1))
    for r = 1, math.min(3, #ranked) do
      print(string.format("   #%d fitness %.1f genes %s",
        r, ranked[r].fitness or 0, M.envLine(ranked[r].genes)))
    end
    st.individuals = nextInds
    st.gen = st.gen + 1
  end
  st.running = nil
  M.save(st, path)
  return 0
end

local function cmdStatus(st)
  print(string.format("generation %d, running individual: %s",
    st.gen, tostring(st.running)))
  for idx, i in ipairs(st.individuals) do
    print(string.format("  %d. fitness %-8s runs %d  %s",
      idx, i.fitness and string.format("%.1f", i.fitness) or "-", i.runs,
      M.envLine(i.genes)))
  end
  return 0
end

-- Exposed for tools/test_evolve.lua: the CLI commands take the state and
-- path as arguments so the whole cycle is testable without env vars.
M.cmdNext = cmdNext
M.cmdRecord = cmdRecord
M.cmdStatus = cmdStatus

function M.main(argv)
  local cmd = argv and argv[1] or "status"
  local path = statePath()
  local st = M.load(path)
  if not st then
    st = defaultState()
    M.save(st, path)
    print("seeded fresh population in " .. path)
  end
  if cmd == "next" then
    return cmdNext(st, path)
  elseif cmd == "record" then
    return cmdRecord(st, path, argv[2] or os.getenv("ZZBOT_LOG") or "logs/zzbot.log")
  elseif cmd == "status" then
    return cmdStatus(st)
  elseif cmd == "reset" then
    os.remove(path)
    print("state removed: " .. path)
    return 0
  end
  print("usage: evolve.lua next|record <log>|status|reset")
  return 2
end

if arg and arg[0] and arg[0]:match("evolve%.lua$") then
  os.exit(M.main(arg))
end

return M
