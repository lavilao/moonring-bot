-- Standalone tests for tools/evolve.lua (Lua 5.1+ compatible).
local script = (arg and arg[0]) or "tools/test_evolve.lua"
local dir = script:match("^(.*)[/\\][^/\\]+$") or "."
local E = dofile(dir .. "/evolve.lua")

local failures = 0
local function run(name, fn)
  local ok, err = pcall(fn)
  if ok then
    print("PASS " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. ": " .. tostring(err))
  end
end

local function check(cond, msg)
  if not cond then error(msg or "assertion failed", 2) end
end

-- Parsing and fitness -------------------------------------------------------

run("parseLog counts EV kinds and ignores everything else", function()
  local counts = E.parseLog([[
12:00:01 [zzbot] EV|t=1.000|kind=bot|state=enabled
12:00:02 [zzbot] EV|t=2.000|kind=dungeon_done|dungeon=dungeon1-01
12:00:03 [zzbot] EV|t=3.000|kind=dungeon_done|dungeon=dungeon1-02
12:00:04 [zzbot] EV|t=4.000|kind=death|world=x|by=wolf
12:00:05 [zzbot] plain log line, no EV marker
]])
  check(counts.bot == 1, "bot")
  check(counts.dungeon_done == 2, "dungeon_done")
  check(counts.death == 1, "death")
  check(counts.timeout == nil, "timeout should be absent")
end)

run("fitness applies the weights; unknown kinds are free", function()
  check(E.fitness({}) == 0, "empty")
  check(E.fitness({ dungeon_done = 2, death = 1 }) == 50 * 2 - 30, "weighted")
  check(E.fitness({ zoom_ready = 99 }) == 0, "unweighted kind leaked")
  check(E.fitness(nil) == 0, "nil counts")
end)

-- Genome --------------------------------------------------------------------

run("clampGenes honors bounds and defaults", function()
  local g = E.clampGenes({ alpha = 9, horizon = -5 })
  check(g.alpha == 0.30, "alpha not clamped high: " .. tostring(g.alpha))
  check(g.horizon == 120, "horizon not clamped low")
  check(g.moneyReserve == 150, "default missing")
  local n = 0
  for _ in pairs(E.clampGenes({})) do n = n + 1 end
  local specN = 0
  for _ in pairs(E.SPEC) do specN = specN + 1 end
  check(n == specN, "gene count mismatch")
end)

run("envLine renders every knob", function()
  local line = E.envLine(E.clampGenes({}))
  check(line:find("ZZBOT_ALPHA=", 1, true), "alpha missing")
  check(line:find("ZZBOT_HORIZON=480", 1, true), "horizon missing")
  check(line:find("ZZBOT_TRADE_TAKE=1.1", 1, true), "tradeTake missing")
end)

-- Population and evolution ---------------------------------------------------

run("seeded population: stock default first, rest in bounds", function()
  local inds = E.seedPopulation(E.rngNew(42))
  check(#inds == E.POP, "pop size")
  local def = E.clampGenes({})
  for k in pairs(E.SPEC) do
    check(inds[1].genes[k] == def[k], "individual 1 is not stock for " .. k)
  end
  for _, i in ipairs(inds) do
    for k, s in pairs(E.SPEC) do
      check(i.genes[k] >= s.min and i.genes[k] <= s.max, "out of bounds: " .. k)
    end
  end
end)

run("evolve keeps elites verbatim and stays in bounds", function()
  local inds = E.seedPopulation(E.rngNew(7))
  for i = 1, #inds do inds[i].fitness = (#inds - i) * 10 end -- descending
  local nextInds, ranked = E.evolve(inds, E.rngNew(7))
  check(#nextInds == E.POP, "next pop size")
  check(ranked[1].fitness == (#inds - 1) * 10, "ranking wrong")
  for k in pairs(E.SPEC) do
    check(nextInds[1].genes[k] == ranked[1].genes[k],
      "elite #1 gene drifted: " .. k)
  end
  for _, i in ipairs(nextInds) do
    check(i.fitness == nil and i.runs == 0, "next gen not reset")
    for k, s in pairs(E.SPEC) do
      check(i.genes[k] >= s.min and i.genes[k] <= s.max, "mutant out of bounds: " .. k)
    end
  end
end)

run("LCG is deterministic", function()
  local a, b = E.rngNew(42), E.rngNew(42)
  for _ = 1, 5 do
    check(E.rng01(a) == E.rng01(b), "sequences diverged")
  end
end)

-- State persistence and the next/record cycle -------------------------------

run("save/load round-trips the population", function()
  local path = os.tmpname()
  local st = { gen = 3, rng = E.rngNew(99), running = 2,
    individuals = E.seedPopulation(E.rngNew(42)) }
  st.individuals[2].fitness = 123.5
  st.individuals[2].runs = 2
  check(E.save(st, path) == true, "save failed")
  local st2 = E.load(path)
  check(st2 ~= nil and st2.gen == 3, "gen lost")
  check(st2.running == 2, "running lost")
  check(st2.individuals[2].fitness == 123.5, "fitness lost")
  check(st2.individuals[2].runs == 2, "runs lost")
  check(st2.individuals[1].fitness == nil, "nil fitness mangled")
  for k in pairs(E.SPEC) do
    check(st2.individuals[1].genes[k] == st.individuals[1].genes[k],
      "genes lost: " .. k)
  end
  os.remove(path)
end)

run("load rejects garbage state", function()
  local path = os.tmpname()
  local f = io.open(path, "w")
  f:write("totally not lua {{{")
  f:close()
  check(E.load(path) == nil, "garbage loaded")
  os.remove(path)
end)

run("next/record cycle scores the marked individual", function()
  local stpath, logpath = os.tmpname(), os.tmpname()
  local f = io.open(logpath, "w")
  f:write("EV|t=1|kind=dungeon_done\nEV|t=2|kind=death\nEV|t=3|kind=level_done\n")
  f:close()
  local st = { gen = 1, rng = E.rngNew(42), running = nil,
    individuals = E.seedPopulation(E.rngNew(42)) }
  E.save(st, stpath)
  check(E.cmdNext(st, stpath) == 0, "next failed")
  check(st.running == 1, "next did not mark individual 1")
  check(E.cmdRecord(st, stpath, logpath) == 0, "record failed")
  check(st.individuals[1].fitness == 50 - 30 + 10, "fitness math wrong: "
    .. tostring(st.individuals[1].fitness))
  check(st.individuals[1].runs == 1 and st.running == nil, "cycle state wrong")
  check(E.cmdRecord(st, stpath, logpath) == 1, "record without running should fail")
  os.remove(stpath)
  os.remove(logpath)
end)

run("full population evaluation triggers evolution", function()
  local stpath, logpath = os.tmpname(), os.tmpname()
  local f = io.open(logpath, "w")
  f:write("EV|t=1|kind=campaign_done\n")
  f:close()
  local st = { gen = 1, rng = E.rngNew(42), running = nil,
    individuals = E.seedPopulation(E.rngNew(42)) }
  -- score everyone but the first by hand
  for i = 2, #st.individuals do
    st.individuals[i].fitness = 5
    st.individuals[i].runs = 1
  end
  st.running = 1
  check(E.cmdRecord(st, stpath, logpath) == 0, "record failed")
  check(st.gen == 2, "generation did not advance: " .. tostring(st.gen))
  check(st.running == nil, "running not cleared")
  check(st.individuals[1].fitness == nil, "next gen not fresh")
  os.remove(stpath)
  os.remove(logpath)
end)

print("")
if failures > 0 then
  print("FAILURES: " .. failures)
  os.exit(1)
else
  print("ALL PASS")
end
