-- Standalone tests for mod/zzbot/dialogue.lua (Lua 5.1+ compatible).
local script = (arg and arg[0]) or "tools/test_dialogue.lua"
local dir = script:match("^(.*)[/\\][^/\\]+$") or "."
local D = dofile(dir .. "/../mod/zzbot/dialogue.lua")

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

-- selectChoice --------------------------------------------------------------

run("picks the first unseen keyword in box order", function()
  local seen = { ["the weather"] = true }
  local pick = D.selectChoice({ "The weather", "Your god", "Close" }, seen)
  check(pick == "Your god", "got " .. tostring(pick))
end)

run("close-like entries are never keywords", function()
  local pick = D.selectChoice({ "Close", "Leave", "Bye" }, {})
  check(pick == nil, "picked a close entry: " .. tostring(pick))
end)

run("every choice seen means exhausted", function()
  local seen = { ["a"] = true, ["b"] = true }
  check(D.selectChoice({ "A", " b " }, seen) == nil, "normalization leaked")
end)

run("empty and nil choices never explode", function()
  check(D.selectChoice(nil, {}) == nil, "nil choices")
  check(D.selectChoice({ "", "  " }, {}) == nil, "blank choices")
end)

-- nextTyped -----------------------------------------------------------------

run("typed prompts pull unseen keywords in order", function()
  local seen = { ["hello"] = true }
  check(D.nextTyped({ "hello", "jest", "relic" }, seen) == "jest", "order wrong")
end)

run("typed prompts fall back to bye", function()
  check(D.nextTyped({}, {}) == "bye", "no fallback")
  check(D.nextTyped({ "hello" }, { hello = true }) == "bye", "exhausted fallback")
end)

-- step ----------------------------------------------------------------------

run("plain text advances and never mutates the seen set", function()
  local seen = {}
  local a, why = D.step({ kind = "text", text = "Hello stranger." },
    { seen = seen })
  check(a.key == "return" and why == "advanced", "wrong action")
  check(next(seen) == nil, "seen mutated by plain text")
end)

run("choice pages mark the pick as seen", function()
  local seen = {}
  local a, why = D.step({ kind = "choice", choices = { "Your god", "Close" } },
    { seen = seen })
  check(a.key == "return" and a.markSeen == "your god" and why == "picked",
    "wrong pick")
  check(seen["your god"] == true, "pick not marked")
  local a2, why2 = D.step({ kind = "choice", choices = { "Your god", "Close" } },
    { seen = seen })
  check(a2 == nil and why2 == "exhausted", "exhaustion not reported")
end)

run("typed pages type the keyword and mark it", function()
  local seen = {}
  local a, why = D.step({ kind = "typed" },
    { seen = seen, keywords = { "Death_Has_Dominion_Over_All" } })
  check(a.key == "type" and a.text == "Death_Has_Dominion_Over_All" and
    why == "typed", "wrong typed action")
  check(seen["death_has_dominion_over_all"] == true, "keyword not marked")
end)

run("yes/no defaults to decline without explicit policy", function()
  local a, why = D.step({ kind = "yesno", key = "inn_rest" }, { yesno = {} })
  check(a.yes == false and why == "policy", "unsafe default")
  local b = D.step({ kind = "yesno", key = "ferry" },
    { yesno = { ferry = true } })
  check(b.yes == true, "policy entry ignored")
end)

run("step caps stop a talkative npc", function()
  local a, why = D.step({ kind = "text" }, { steps = 200, cap = 200 })
  check(a == nil and why == "cap", "cap not enforced")
  local b = D.step({ kind = "text" }, { steps = 199, cap = 200 })
  check(b ~= nil, "cap fired early")
end)

run("count is a per-key accumulator", function()
  local steps = {}
  check(D.count(steps, "yarrow") == 1, "first count")
  check(D.count(steps, "yarrow") == 2, "second count")
  check(D.count(steps, "harrowdus") == 1, "keys must not share")
end)

if failures > 0 then
  print(("%d test(s) failed"):format(failures))
  os.exit(1)
end
print("all tests passed")
