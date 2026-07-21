-- litelog.lua -- small per-app file logger for Hammerspoon modules.
--
-- Logs live in ~/.hammerspoon/logs/*.log so agents can inspect local app
-- behavior without opening the Hammerspoon console. The directory is created
-- on first write.

local M = {}

local HOME = os.getenv("HOME") or ""
local DEFAULT_DIR = (hs and hs.configdir and (hs.configdir .. "/logs"))
  or (HOME .. "/.hammerspoon/logs")
local DEFAULT_MAX_BYTES = 1024 * 1024
local DEFAULT_MAX_ARCHIVES = 4
local unpackArgs = table.unpack or unpack

local function shellQuote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function ensureDir(dir)
  if not dir or dir == "" then return end
  os.execute("/bin/mkdir -p " .. shellQuote(dir))
end

local function safeName(name)
  return tostring(name or "hammerspoon"):gsub("[^%w._-]", "_")
end

local function fileSize(path)
  if hs and hs.fs and hs.fs.attributes then
    local ok, attrs = pcall(hs.fs.attributes, path)
    if ok and attrs and attrs.size then return attrs.size end
  end

  local f = io.open(path, "r")
  if not f then return 0 end
  local size = f:seek("end") or 0
  f:close()
  return size
end

local function rotateIfNeeded(path, maxBytes, maxArchives)
  if fileSize(path) < maxBytes then return end
  for i = maxArchives - 1, 1, -1 do
    os.rename(path .. "." .. tostring(i), path .. "." .. tostring(i + 1))
  end
  os.rename(path, path .. ".1")
end

local function encodeTable(value)
  if hs and hs.json and hs.json.encode then
    local ok, encoded = pcall(hs.json.encode, value)
    if ok and encoded then return encoded end
  end

  local parts = {}
  for k, v in pairs(value) do
    parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
  end
  table.sort(parts)
  return "{" .. table.concat(parts, ",") .. "}"
end

local function valueString(value)
  local t = type(value)
  if t == "table" then return encodeTable(value) end
  if t == "boolean" then return value and "true" or "false" end
  return tostring(value)
end

local function clean(value)
  return valueString(value)
    :gsub("\r", "\\r")
    :gsub("\n", "\\n")
    :gsub("\t", "\\t")
end

local function formatFields(fields)
  if type(fields) ~= "table" then return "" end
  local keys = {}
  for key in pairs(fields) do keys[#keys + 1] = key end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

  local parts = {}
  for _, key in ipairs(keys) do
    local value = fields[key]
    if value ~= nil then
      parts[#parts + 1] = tostring(key) .. "=" .. clean(value)
    end
  end
  if #parts == 0 then return "" end
  return " " .. table.concat(parts, " ")
end

local function write(logger, level, message, fields)
  ensureDir(logger.dir)
  rotateIfNeeded(logger.path, logger.maxBytes, logger.maxArchives)

  local f = io.open(logger.path, "a")
  if not f then return false end
  f:write(
    os.date("%Y-%m-%d %H:%M:%S%z"),
    " ",
    level,
    " ",
    clean(message or ""),
    formatFields(fields),
    "\n"
  )
  f:close()
  return true
end

function M.new(appName, opts)
  opts = opts or {}
  local logger = {
    appName = safeName(appName),
    dir = opts.dir or DEFAULT_DIR,
    maxBytes = opts.maxBytes or DEFAULT_MAX_BYTES,
    maxArchives = opts.maxArchives or DEFAULT_MAX_ARCHIVES,
  }
  logger.path = logger.dir .. "/" .. logger.appName .. ".log"

  logger.debug = function(message, fields)
    return write(logger, "DEBUG", message, fields)
  end
  logger.info = function(message, fields)
    return write(logger, "INFO", message, fields)
  end
  logger.warn = function(message, fields)
    return write(logger, "WARN", message, fields)
  end
  logger.error = function(message, fields)
    return write(logger, "ERROR", message, fields)
  end

  return logger
end

function M.wrap(appName, label, fn)
  local log = M.new(appName)
  return function(...)
    local args = { ... }
    local ok, result = xpcall(function()
      return fn(unpackArgs(args))
    end, debug.traceback)
    if not ok then
      log.error("callback failed", { label = label, error = result })
      error(result)
    end
    return result
  end
end

M.defaultDir = DEFAULT_DIR

return M
