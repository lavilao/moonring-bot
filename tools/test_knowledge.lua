-- Standalone tests for mod/zzbot/knowledge.lua (Lua 5.1+ compatible).
local script = (arg and arg[0]) or "tools/test_knowledge.lua"
local dir = script:match("^(.*)[/\\][^/\\]+$") or "."
local K = dofile(dir .. "/../mod/zzbot/knowledge.lua")

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

local function fresh(opts)
  -- dot call on purpose: the module API is plain functions, M.init(opts)
  return K.init(opts or {})
end

local BASE = { MIN_AB = 5, K = 15, P0 = 0.05, W_MIN = 0.5, W_MAX = 4.0 }
local function withPath(p)
  local o = { path = p }
  for k, v in pairs(BASE) do o[k] = v end
  return o
end

-- Name normalization -------------------------------------------------------

run("norm lowercases, strips punctuation, never returns empty", function()
  check(K.norm("The Grey Wolf") == "the_grey_wolf",
    "got " .. K.norm("The Grey Wolf"))
  check(K.norm("Wolf-2!") == "wolf_2", "got " .. K.norm("Wolf-2!"))
  check(K.norm("  ") == "?", "empty got " .. K.norm("  "))
  check(K.norm(nil) == "?", "nil got " .. tostring(K.norm(nil)))
end)

run("level buckets split early game from late game", function()
  check(K.levelBucket(1) == 1, "1")
  check(K.levelBucket(2) == 1, "2")
  check(K.levelBucket(3) == 3, "3")
  check(K.levelBucket(4) == 3, "4")
  check(K.levelBucket(5) == 5, "5")
  check(K.levelBucket(9) == 5, "9")
  check(K.levelBucket(10) == 10, "10")
  check(K.levelBucket(14) == 10, "14")
  check(K.levelBucket(15) == 15, "15")
  check(K.levelBucket(nil) == 1, "nil")
end)

-- Message parsing ----------------------------------------------------------

run("hit messages attribute the attacker", function()
  local kind, name = K.noteText("The wolf hits you for 4 damage.")
  check(kind == "hit" and name == "wolf", "got " .. tostring(kind) .. "/" .. tostring(name))
  kind, name = K.noteText("The marauder strikes you for 6")
  check(kind == "hit" and name == "marauder", "strikes failed")
end)

run("heal verbs are never mistaken for attacks", function()
  check(K.noteText("The potion heals you for 20.") == nil, "heals leaked")
  check(K.noteText("The shrine restores you for 5.") == nil, "restores leaked")
end)

run("kill messages report the victim", function()
  local kind, name = K.noteText("You kill the wolf.")
  check(kind == "kill" and name == "wolf", "you-kill failed")
  kind, name = K.noteText("The skeleton dies.")
  check(kind == "kill" and name == "skeleton", "dies failed")
end)

run("noteText tolerates garbage", function()
  check(K.noteText(nil) == nil, "nil")
  check(K.noteText("") == nil, "empty")
  check(K.noteText("You feel hungry.") == nil, "unrelated text leaked")
end)

run("parseKiller scans newest first and ignores kills", function()
  -- texts are chronological: the last entry is the newest message
  check(K.parseKiller({ "You feel brave.", "The bat hits you for 1",
    "The wolf hits you for 4" }) == "wolf", "newest-first failed")
  check(K.parseKiller({ "You kill the wolf." }) == nil, "kill leaked as killer")
  check(K.parseKiller(nil) == nil, "nil texts")
end)

-- Threat multipliers --------------------------------------------------------

run("injectable tunables are honored", function()
  fresh({ MIN_AB = 2, K = 10, P0 = 0.1, W_MIN = 0.7, W_MAX = 2.0 })
  K.recordDeath("wolf", 1)
  K.recordDeath("wolf", 1)
  check(K.threatMult("wolf", 1) == 2.0, "custom clamp ignored, got "
    .. tostring(K.threatMult("wolf", 1)))
end)

run("no data means no opinion: multiplier stays 1.0", function()
  fresh(BASE)
  check(K.threatMult("wolf", 1) == 1.0, "unknown enemy moved the needle")
  check(K.threatMult(nil, 1) == 1.0, "nil enemy moved the needle")
end)

run("few observations are ignored (minAB guard)", function()
  fresh(BASE)
  for _ = 1, 4 do K.recordDeath("wolf", 1) end
  check(K.threatMult("wolf", 1) == 1.0, "4 deaths already modulate")
  K.recordDeath("wolf", 1)
  local m = K.threatMult("wolf", 1)
  check(m > 1.0, "5 deaths should raise danger, got " .. tostring(m))
end)

run("deaths raise the multiplier, clamped at wmax", function()
  fresh(BASE)
  for _ = 1, 5 do K.recordDeath("wolf", 1) end
  check(K.threatMult("wolf", 1) == 4.0, "all-death rate should clamp to 4.0")
  for _ = 1, 10 do K.recordSurvived("orc", 1) end
  for _ = 1, 2 do K.recordDeath("orc", 1) end
  local p = 2 / 12
  check(math.abs(K.threatMult("orc", 1) - (1 + 15 * (p - 0.05))) < 1e-6,
    "mid rate should follow the linear gain")
end)

run("survived fights make us bolder, clamped at wmin", function()
  fresh(BASE)
  for _ = 1, 10 do K.recordSurvived("rat", 1) end
  check(K.threatMult("rat", 1) == 0.5, "never-deadly rat should clamp to 0.5")
end)

run("level buckets learn independently", function()
  fresh(BASE)
  for _ = 1, 5 do K.recordDeath("wolf", 1) end
  check(K.threatMult("wolf", 1) == 4.0, "bucket 1 should be hot")
  check(K.threatMult("wolf", 12) == 1.0, "bucket 15 should stay cold")
end)

run("message names match actorType ids by substring", function()
  fresh(BASE)
  for _ = 1, 5 do K.recordDeath("grey_wolf", 3) end
  check(K.threatMult("The Grey Wolf", 3) == 4.0, "actorType->message lookup failed")
  fresh(BASE)
  for _ = 1, 5 do K.recordDeath("The Grey Wolf", 3) end
  check(K.threatMult("grey_wolf", 3) == 4.0, "message->actorType lookup failed")
end)

-- Persistence --------------------------------------------------------------

run("recordDeath auto-saves and a fresh module reads it back", function()
  local path = os.tmpname() .. ".lua"
  K.init(withPath(path))
  for _ = 1, 5 do K.recordDeath("wolf", 1) end
  K.recordKill("rat", 1)
  K.init(withPath(path))
  check(K.load() == true, "load failed")
  local s = K.stats()
  check(s.deaths == 5 and s.kills == 1, "stats lost: " .. tostring(s.deaths) .. "/" .. tostring(s.kills))
  check(K.threatMult("wolf", 1) == 4.0, "threat lost across restart")
  os.remove(path)
end)

run("a corrupt ledger falls back to defaults, never poisons", function()
  local path = os.tmpname() .. ".lua"
  local f = io.open(path, "w")
  f:write("this is not lua at all (((")
  f:close()
  fresh(BASE)
  K.init(withPath(path))
  check(K.load() == false, "corrupt file loaded")
  check(K.threatMult("wolf", 1) == 1.0, "corrupt file moved weights")
  -- valid lua but wrong schema must also be rejected
  f = io.open(path, "w")
  f:write("return { threat = { ['x@1'] = { a = 'oops', b = 1 } } }")
  f:close()
  check(K.load() == false, "bad schema loaded")
  os.remove(path)
end)

run("no path means memory-only operation", function()
  fresh(BASE)
  check(K.save() == false, "save without path should be a no-op")
  check(K.load() == false, "load without path should be a no-op")
  K.recordDeath("wolf", 1)
  K.recordDeath("wolf", 1)
  check(K.stats().deaths == 2, "in-memory ledger broken")
end)

run("recordDeath ignores nil attribution", function()
  fresh(BASE)
  check(K.recordDeath(nil, 1) == false, "nil should be rejected")
  check(K.stats().deaths == 0, "nil death was counted")
end)

print("")
if failures > 0 then
  print("FAILURES: " .. failures)
  os.exit(1)
else
  print("ALL PASS")
end
