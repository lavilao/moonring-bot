-- tools/postmortem.lua — death analyst over zzbot logs and traces (P9).
--
-- Layer 0 consumer: turns the EV| death events plus the decision-trace files
-- the bot dumps on death into a human-readable report. Useful even with no
-- learning at all: paste the report into an issue and it says who killed us,
-- whether the model saw it coming (calibration) and what the bot did in its
-- last ticks.
--
--   lua tools/postmortem.lua logs/zzbot.log [logs]
--
-- Pure Lua 5.1, read-only.

local M = {}

-- Parse EV| lines (tools/check_log.lua format) into structured records.
function M.parseLog(text)
  local out = { deaths = {}, timeouts = {}, traces = {}, wins = {}, policies = {} }
  if type(text) ~= "string" then return out end
  for line in text:gmatch("[^\r\n]+") do
    if line:find("|kind=", 1, true) then
      local fields = {}
      for k, v in line:gmatch("|([%w_]+)=([^|]*)") do
        fields[k] = v
      end
      local kind = line:match("|kind=([%w_]+)")
      if kind == "death" then
        out.deaths[#out.deaths + 1] = {
          t = fields.t, world = fields.world, x = fields.x, y = fields.y,
          turn = fields.turn, by = fields.by, policy = fields.policy,
          last = fields.last,
        }
      elseif kind == "timeout" then
        out.timeouts[#out.timeouts + 1] = { world = fields.world,
          policy = fields.policy, turn = fields.turn }
      elseif kind == "death_trace" then
        out.traces[#out.traces + 1] = { file = fields.file,
          ticks = tonumber(fields.ticks), world = fields.world,
          policy = fields.policy }
      elseif kind == "policy" then
        out.policies[fields.policy] = (out.policies[fields.policy] or 0) + 1
      elseif kind == "dungeon_done" or kind == "campaign_done" then
        out.wins[kind] = (out.wins[kind] or 0) + 1
      end
    end
  end
  return out
end

-- Read a trace file written by the bot on death.
function M.readTrace(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local first = f:read("*l") or ""
  local header = {}
  for k, v in first:gmatch("([%w_]+)=([^|]*)") do header[k] = v end
  local entries = {}
  for line in f:lines() do
    if line:find("^%d+|") then
      local e = { seq = tonumber(line:match("^(%d+)|")) }
      for k, v in line:gmatch("|([%w_]+)=([^|]*)") do
        if k == "hp" or k == "maxHP" or k == "poise" or k == "pDeath"
          or k == "pDeathUpper" or k == "alpha" then
          e[k] = tonumber(v)
        elseif k == "adj" or k == "near" then
          e[k] = tonumber(v)
        else
          e[k] = v
        end
      end
      entries[#entries + 1] = e
    end
  end
  f:close()
  if #entries == 0 then return nil end
  return { header = header, entries = entries }
end

-- What does the trace say about this death?
function M.analyzeTrace(trace)
  local e = trace.entries
  local alpha = tonumber(trace.header.alpha) or 0.08
  local a = {
    ticks = #e,
    hpStart = e[1].hp, hpEnd = e[#e].hp,
    lastAction = nil, lastPDeathUpper = nil, sawDanger = 0,
    ignoredWarnings = 0, worstDrop = 0,
  }
  local lastDecision
  for _, t in ipairs(e) do
    if t.action and t.action ~= "?" then lastDecision = t end
    if t.pDeathUpper and t.pDeathUpper > alpha then a.sawDanger = a.sawDanger + 1 end
    if t.pDeathUpper and t.pDeathUpper > alpha and t.action
      and t.action ~= "flee" and t.action ~= "retreat" then
      a.ignoredWarnings = a.ignoredWarnings + 1
    end
    if t.hp and type(t.hp) == "number" then
      for _, prev in ipairs(e) do
        if prev.seq < t.seq and t.seq - prev.seq <= 3 and prev.hp
          and type(prev.hp) == "number" then
          local drop = prev.hp - t.hp
          if drop > a.worstDrop then a.worstDrop = drop end
        end
      end
    end
  end
  if lastDecision then
    a.lastAction = lastDecision.action
    a.lastPDeathUpper = lastDecision.pDeathUpper
  end
  -- Surprise: we died while doing something the model priced as safe.
  a.surprise = (a.lastAction ~= nil and a.lastAction ~= "flee"
    and a.lastAction ~= "retreat"
    and a.lastPDeathUpper ~= nil and a.lastPDeathUpper <= alpha)
  return a
end

local function fmtN(v)
  return type(v) == "number" and string.format("%.0f", v) or tostring(v or "?")
end

local function bump(t, key)
  t[key] = (t[key] or 0) + 1
end

-- Full report: per-death breakdown plus aggregates. traceDir is optional;
-- without it only log-level facts are reported.
function M.report(logText, traceDir)
  local data = M.parseLog(logText)
  local b = {}
  local function add(s) b[#b + 1] = s end

  add(string.format("== postmortem: %d death(s), %d timeout(s)",
    #data.deaths, #data.timeouts))
  local pol = {}
  for p, n in pairs(data.policies) do pol[#pol + 1] = p .. " x" .. n end
  table.sort(pol)
  add("policies seen: " .. (#pol > 0 and table.concat(pol, ", ") or "none"))
  add(string.format("wins: %d dungeon(s), %d campaign(s)",
    data.wins.dungeon_done or 0, data.wins.campaign_done or 0))
  add("")

  local byKiller, byWorld, byPolicy = {}, {}, {}
  local surprises, warned = 0, 0
  for i, d in ipairs(data.deaths) do
    bump(byKiller, d.by or "unknown")
    bump(byWorld, d.world or "?")
    bump(byPolicy, d.policy or "?")
    add(string.format("-- death %d: %s at %s,%s (turn %s, policy %s)",
      i, d.world or "?", d.x or "?", d.y or "?", d.turn or "?", d.policy or "?"))
    add("   killer: " .. (d.by or "unknown"))
    if d.last and d.last ~= "" then
      add("   last messages: " .. d.last)
    end
    -- Attach the decision trace, if the dump file is still around.
    if traceDir then
      local link
      for _, t in ipairs(data.traces) do
        if t.world == d.world and not t.used then link = t break end
      end
      if link and link.file then
        link.used = true
        local trace = M.readTrace(traceDir .. "/" .. link.file)
        if trace then
          local a = M.analyzeTrace(trace)
          add(string.format("   trace: %d ticks, hp %s -> %s (worst 3-tick drop %s)",
            a.ticks, fmtN(a.hpStart), fmtN(a.hpEnd), fmtN(a.worstDrop)))
          if a.lastAction then
            add(string.format("   last decision: %s (model said pDeathUpper %.1f%%)",
              a.lastAction, 100 * (a.lastPDeathUpper or 0)))
          end
          if a.surprise then
            surprises = surprises + 1
            add("   >> SURPRISE: died doing something the model priced as safe")
          elseif (a.sawDanger or 0) > 0 then
            warned = warned + 1
            add(string.format(
              "   >> model saw danger %d tick(s); ignored %d time(s) before dying",
              a.sawDanger, a.ignoredWarnings))
          end
        end
      end
    end
  end
  add("")

  local function agg(name, t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(x, y) return t[x] > t[y] end)
    if #keys == 0 then return end
    local parts = {}
    for _, k in ipairs(keys) do
      parts[#parts + 1] = string.format("%s x%d", k, t[k])
    end
    add(name .. ": " .. table.concat(parts, " | "))
  end
  agg("by killer", byKiller)
  agg("by world", byWorld)
  agg("by policy", byPolicy)
  if traceDir and #data.deaths > 0 then
    add(string.format("calibration: %d surprise death(s) (model said safe), %d warned death(s)",
      surprises, warned))
  end
  return table.concat(b, "\n")
end

if arg and arg[0] and arg[0]:match("postmortem%.lua$") then
  local logpath, traceDir = arg[1], arg[2]
  if not logpath then
    print("usage: lua tools/postmortem.lua <zzbot.log> [traceDir]")
    os.exit(2)
  end
  local f = io.open(logpath, "r")
  if not f then
    print("cannot read " .. logpath)
    os.exit(1)
  end
  local text = f:read("*a")
  f:close()
  io.write(M.report(text, traceDir), "\n")
  os.exit(0)
end

return M
