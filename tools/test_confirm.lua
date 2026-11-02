-- Standalone tests for mod/zzbot/confirm.lua (Lua 5.1+ compatible).
local script = (arg and arg[0]) or "tools/test_confirm.lua"
local dir = script:match("^(.*)[/\\][^/\\]+$") or "."
local C = dofile(dir .. "/../mod/zzbot/confirm.lua")

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

-- Classification -----------------------------------------------------------

run("steal prompt is classified theft", function()
  check(C.classify("Do you want to steal this item?") == "theft",
    "got " .. tostring(C.classify("Do you want to steal this item?")))
end)

run("classification ignores case", function()
  check(C.classify("DO YOU WANT TO STEAL this?") == "theft", "uppercase failed")
  check(C.classify("  leave this area?  ") == "zoom_leave", "padding failed")
  check(C.classify("Are you sure you wish to enter this place?") == "dungeon_entry",
    "entry prompt misclassified")
end)

run("every dungeon flavor keeps its dungeon_ prefix", function()
  local samples = {
    { "Beware: this tether dungeon is deadly.", "dungeon_tether" },
    { "This path leads to your doom.", "dungeon_doom" },
    { "A relic dungeon. Turn back?", "dungeon_relic" },
    { "The egg waits below. 100 floors.", "dungeon_endless" },
    { "This is a dungeon. Bring the master key.", "dungeon_mini" },
    { "This is a one-way trip. Proceed onward?", "dungeon_arena" },
  }
  for _, s in ipairs(samples) do
    check(C.classify(s[1]) == s[2],
      ("'%s' gave %s, wanted %s"):format(s[1], tostring(C.classify(s[1])), s[2]))
  end
end)

run("irreversible prompts stay declined classes", function()
  for _, text in ipairs({
    "Forsake your old god?", "Quit the game?", "Delete your save?",
    "Leap into the void?", "Sacrifice all your devotion?", "Donation box",
    "Discard this item?", "Repair this equipment?", "Return to the title screen?",
  }) do
    local cls = C.classify(text)
    check(cls ~= "unknown" and cls ~= nil, "unclassified: " .. text)
  end
end)

run("unmatched text stays unknown", function()
  check(C.classify("Something entirely unexpected happened.") == "unknown",
    "random text got a class")
  check(C.classify(nil) == "unknown", "nil text should be unknown")
  check(C.classify("") == "unknown", "empty text should be unknown")
end)

-- Decision -----------------------------------------------------------------

run("zoom leave and dedication are always accepted", function()
  check(C.decide("zoom_leave", {}) == true, "zoom_leave declined")
  check(C.decide("dedicate", {}) == true, "dedicate declined")
  check(C.decide("zoom_leave") == true, "missing ctx broke zoom_leave")
end)

run("theft and irreversible classes are always declined", function()
  for _, cls in ipairs({ "theft", "apostasy", "quit", "delete", "void", "sin",
                         "donate", "discard", "leave" }) do
    check(C.decide(cls, { phase = "to-dungeon", entered = true }) == false,
      cls .. " was accepted")
  end
end)

run("dungeon prompts accept only when the campaign led us here", function()
  check(C.decide("dungeon_entry", { phase = "to-dungeon" }) == true,
    "to-dungeon should accept")
  check(C.decide("dungeon_relic", { phase = "town", entered = true }) == true,
    "entered should accept")
  check(C.decide("dungeon_entry", { phase = "town", entered = false }) == false,
    "town context should decline")
  check(C.decide("dungeon_entry", { phase = "dungeon" }) == false,
    "descended-but-not-entered should decline")
  check(C.decide("dungeon_entry", {}) == false, "no context should decline")
end)

run("unknown defaults to decline in every context", function()
  for _, ctx in ipairs({ {}, { phase = "to-dungeon" }, { entered = true } }) do
    check(C.decide("unknown", ctx) == false, "unknown accepted a prompt")
  end
end)

if failures > 0 then
  print(("%d test(s) failed"):format(failures))
  os.exit(1)
end
print("all tests passed")
