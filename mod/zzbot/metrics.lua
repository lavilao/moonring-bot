-- Human log + machine-parseable event lines (PLAN.md §0.3).
--
-- Extracted verbatim from init.lua so tools/test_metrics.lua can verify the
-- EV| format without the game; init.lua keeps an inline fallback that must be
-- kept in sync. The clock is injected because love.timer does not exist in
-- the test environment; inside the game init.lua passes love.timer.getTime.

local M = {}

local logFile
local logpath, t0, clock

function M.init(opts)
  opts = opts or {}
  if opts.logpath ~= logpath then
    logFile = nil -- a new destination must not inherit the old handle
  end
  logpath = opts.logpath
  t0 = opts.t0 or 0
  clock = opts.clock or function() return 0 end
end

local function elapsed()
  return clock() - (t0 or 0)
end

local function write(msg)
  print("[zzbot] " .. msg)
  if logpath then
    logFile = logFile or io.open(logpath, "a")
    if logFile then
      logFile:write(string.format("%s %s\n", os.date("%H:%M:%S"), msg))
      logFile:flush()
    end
  end
end

function M.log(fmt, ...)
  write(string.format(fmt, ...))
end

-- Machine-parseable event line for tools/check_log.lua. Values are sanitized
-- so each line stays a flat key=value list that a shell tool can assert on;
-- keys are sorted so log diffs stay stable across runs.
function M.ev(kind, fields)
  local parts = { string.format("EV|t=%.3f|kind=%s", elapsed(), tostring(kind)) }
  if fields then
    local keys = {}
    for k in pairs(fields) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
      local v = tostring(fields[k]):gsub("[^%w%._%-/:%+,]", "_")
      parts[#parts + 1] = k .. "=" .. v
    end
  end
  write(table.concat(parts, "|"))
end

return M
