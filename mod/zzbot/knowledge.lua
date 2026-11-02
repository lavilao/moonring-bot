-- zzbot.knowledge — learned threat weights from past deaths (P8).
--
-- Pure module: no LÖVE, no game state. A tiny Beta-count ledger per
-- (enemy kind, player level bucket): deaths attributed to a creature raise
-- its danger score, fights we walked away from (and kills) lower it. The bot
-- turns the score into a multiplier on that creature's computed damage, so
-- the Monte Carlo model prices in experience the raw game numbers cannot
-- capture: ranged tricks, pack tactics, status chains, or enemies that turn
-- out to be paper tigers in practice.
--
-- Everything is bounded: with no data (or a missing module) the multiplier
-- is exactly 1.0 and the bot plays stock. Weights can never leave
-- [W_MIN, W_MAX], so one bad streak cannot send the bot off a cliff.

local M = {}

-- Tunables (injectable via M.init for tests).
M.C = {
  MIN_AB = 5,    -- observations a key needs before it may modulate anything
  K      = 15,   -- gain: danger-rate deviation to multiplier
  P0     = 0.05, -- neutral per-encounter death rate (baseline for a fight)
  W_MIN  = 0.5, -- how much bolder experience may make us
  W_MAX  = 4.0, -- how much more careful experience may make us
}

function M.init(opts)
  opts = opts or {}
  M.path = opts.path
  M.rng = opts.rng or math.random -- reserved for exploration logic
  for k in pairs(M.C) do
    if opts[k] ~= nil then M.C[k] = opts[k] end
  end
  M.data = { version = 1, deaths = 0, kills = 0, threat = {} }
  return M
end

-- "The Grey Wolf-2" -> "grey_wolf_2". Both message names and actorType ids
-- go through this, so lookups survive spelling differences.
function M.norm(name)
  local s = tostring(name or "?"):lower()
  s = (s:gsub("[^%w]+", "_"))
  s = (s:gsub("^_+", "")):gsub("_+$", "")
  if s == "" then s = "?" end
  return s
end

-- A wolf at level 1 is not a wolf at level 15: danger is learned per bucket.
function M.levelBucket(level)
  local lv = tonumber(level) or 1
  if lv <= 2 then return 1
  elseif lv <= 4 then return 3
  elseif lv <= 9 then return 5
  elseif lv <= 14 then return 10 end
  return 15
end

local function keyFor(name, level)
  return M.norm(name) .. "@" .. M.levelBucket(level)
end

-- Message vocabulary. Moonring tells us who hurt us and who died in plain
-- text; these patterns are deliberately narrow (anchored, with a heal-verb
-- blocklist) so a wrong attribution can never enter the ledger.
local HEAL_VERB = { heal = true, heals = true, restore = true, restores = true,
  regain = true, regains = true, replenish = true, replenishes = true }

function M.noteText(text)
  local s = tostring(text or ""):lower()
  local name = s:match("^you kill the (.+)")
        or s:match("^the (.+) dies")
  if name then return "kill", M.norm(name) end
  local who, verb = s:match("^the (.+) (%a+) you for %d+")
  if who and verb and not HEAL_VERB[verb] then
    return "hit", M.norm(who)
  end
  return nil
end

-- Newest-first scan of the last messages for something that hit us.
function M.parseKiller(texts)
  if type(texts) ~= "table" then return nil end
  for i = #texts, 1, -1 do
    local kind, name = M.noteText(texts[i])
    if kind == "hit" then return name end
  end
  return nil
end

local function bump(name, level, field)
  local k = keyFor(name, level)
  local e = M.data.threat[k]
  if not e then
    e = { a = 0, b = 0 }
    M.data.threat[k] = e
  end
  e[field] = e[field] + 1
  return e
end

-- We died and `name` is the best attribution we have. a += 1, auto-save.
function M.recordDeath(name, level)
  if not name then return false end
  bump(name, level, "a")
  M.data.deaths = M.data.deaths + 1
  return M.save()
end

-- A fight against `name` ended and we are still standing. b += 1.
function M.recordSurvived(name, level)
  if not name then return false end
  bump(name, level, "b")
  return M.save()
end

-- We killed it: the strongest "not actually lethal" signal. b += 1.
function M.recordKill(name, level)
  if not name then return false end
  bump(name, level, "b")
  M.data.kills = M.data.kills + 1
  return M.save()
end

-- Multiplier on this creature's incoming damage. 1.0 means "no opinion":
-- not enough observations, or a creature we have never died to. Exact key
-- first, then a substring match inside the same level bucket so message
-- names and actorType ids can differ without breaking the lookup.
function M.threatMult(name, level)
  local nm = M.norm(name)
  local suffix = "@" .. M.levelBucket(level)
  local e = M.data.threat[nm .. suffix]
  if not e then
    for k, v in pairs(M.data.threat) do
      if k:sub(-#suffix) == suffix then
        local kn = k:sub(1, #k - #suffix)
        if kn ~= "" and (kn:find(nm, 1, true) or nm:find(kn, 1, true)) then
          e = v
          break
        end
      end
    end
  end
  if not e then return 1.0 end
  if (e.a + e.b) < M.C.MIN_AB then return 1.0 end
  local p = e.a / (e.a + e.b)
  local m = 1 + M.C.K * (p - M.C.P0)
  if m < M.C.W_MIN then m = M.C.W_MIN elseif m > M.C.W_MAX then m = M.C.W_MAX end
  return m
end

-- ---------------------------------------------------------------------------
-- Persistence: a tiny Lua-source file next to the metrics log. Written
-- atomically (tmp + rename), read with pcall; anything corrupt falls back
-- to a fresh ledger rather than poisoning the bot.

local function sortedKeys(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys
end

function M.save()
  if not M.path then return false end
  local parts = {
    "-- zzbot knowledge ledger (auto-written; hand edits will be overwritten)",
    "return {",
    string.format("deaths = %d,", M.data.deaths),
    string.format("kills = %d,", M.data.kills),
    "threat = {",
  }
  for _, k in ipairs(sortedKeys(M.data.threat)) do
    local e = M.data.threat[k]
    parts[#parts + 1] = string.format("  [%q] = { a = %.4f, b = %.4f },",
      k, e.a, e.b)
  end
  parts[#parts + 1] = "},"
  parts[#parts + 1] = "}"
  local body = table.concat(parts, "\n") .. "\n"
  local tmp = M.path .. ".tmp"
  local f = io.open(tmp, "w")
  if f then
    f:write(body)
    f:close()
    os.remove(M.path)
    if os.rename(tmp, M.path) then return true end
  end
  f = io.open(M.path, "w")
  if not f then return false end
  f:write(body)
  f:close()
  return true
end

function M.load()
  if not M.path then return false end
  local f = io.open(M.path, "r")
  if not f then return false end
  local body = f:read("*a")
  f:close()
  local fn = (loadstring or load)(body)
  if not fn then return false end
  local ok, data = pcall(fn)
  if not ok or type(data) ~= "table" or type(data.threat) ~= "table" then
    return false
  end
  -- Strict: one malformed entry rejects the whole file. Half-corrupt ledgers
  -- must not quietly reshape the bot's behaviour.
  local clean = {
    version = 1,
    deaths = tonumber(data.deaths) or 0,
    kills = tonumber(data.kills) or 0,
    threat = {},
  }
  for k, v in pairs(data.threat) do
    if type(k) ~= "string" or type(v) ~= "table"
      or not tonumber(v.a) or not tonumber(v.b) then
      return false
    end
    clean.threat[k] = { a = tonumber(v.a), b = tonumber(v.b) }
  end
  M.data = clean
  return true
end

function M.reset()
  M.data = { version = 1, deaths = 0, kills = 0, threat = {} }
  return M.save()
end

function M.stats()
  local n = 0
  for _ in pairs(M.data.threat) do n = n + 1 end
  return { deaths = M.data.deaths, kills = M.data.kills, kinds = n, path = M.path }
end

return M
