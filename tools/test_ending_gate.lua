-- Standalone tests for mod/zzbot/ending_gate.lua (Lua 5.1+ compatible).
local script = (arg and arg[0]) or "tools/test_ending_gate.lua"
local dir = script:match("^(.*)[/\\][^/\\]+$") or "."
local G = dofile(dir .. "/../mod/zzbot/ending_gate.lua")

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

run("towns and ordinary dungeons are never gated", function()
  for _, w in ipairs({ "yarrowTown-01", "firstDungeon-01", "dungeon6-06",
                       "dungeon2-01", "Overworld" }) do
    check(not G.isEndingWorld(w), w .. " wrongly looks like an ending world")
    check(not G.blocked(w, {}), w .. " was gated")
  end
end)

run("nil or empty world names are never gated", function()
  check(not G.blocked(nil, {}), "nil world was gated")
  check(not G.blocked("", {}), "empty world was gated")
  check(not G.blocked(nil), "missing opts broke the gate")
end)

run("the archon world is gated before the tether dies", function()
  check(G.isEndingWorld("archonDungeon-01"), "archon world not detected")
  check(G.blocked("archonDungeon-01", {}), "archon world was not gated")
  check(G.blocked("ARCHONDUNGEON-02", {}), "case sensitivity leaked through")
end)

run("the endgame world is gated too", function()
  check(G.blocked("endgameWorld-01", {}), "endgame world was not gated")
end)

run("a dead tether lifts the gate", function()
  check(not G.blocked("archonDungeon-01", { killedTether = true }),
    "killed_tether property ignored")
  check(not G.blocked("archonDungeon-01", { killedGods = true }),
    "killedGods ignored")
  check(not G.blocked("archonDungeon-01",
      { dungeonDone = { ["dungeon6-06"] = true } }),
    "cleared tether ledger ignored")
end)

run("an unreadable property keeps the gate closed", function()
  -- The caller pcalls the property read; a failed read arrives as false.
  check(G.blocked("archonDungeon-01", { killedTether = false }),
    "unreadable property opened the gate")
  check(G.blocked("archonDungeon-01", { dungeonDone = {} }),
    "empty ledger opened the gate")
end)

run("an ending world with an unrelated ledger stays gated", function()
  check(G.blocked("archonDungeon-01",
      { dungeonDone = { ["firstDungeon-01"] = true } }),
    "an unrelated cleared dungeon opened the gate")
end)

if failures > 0 then
  print(("%d test(s) failed"):format(failures))
  os.exit(1)
end
print("all tests passed")
