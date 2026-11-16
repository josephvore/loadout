-- settings_overlay.lua — merge a Loadout app's saved settings over its
-- in-file config defaults. Values are written by lib/settings/loadout-settings
-- (Caps+K → an app → Settings) to ~/.hammerspoon/settings/<app>.json. Only keys
-- that already exist in the config table, with a value of the same type, are
-- applied, so a stale or hand-edited file can't add or retype config.
-- Usage (first line of an app's start()):
--   pcall(function() require("settings_overlay").apply("murmur", config) end)

local M = {}

function M.path(app)
  return hs.configdir .. "/settings/" .. app .. ".json"
end

function M.apply(app, config)
  local f = io.open(M.path(app), "r")
  if not f then return config end
  local raw = f:read("*a")
  f:close()
  local ok, overlay = pcall(hs.json.decode, raw)
  if not ok or type(overlay) ~= "table" then return config end
  for k, v in pairs(overlay) do
    if config[k] ~= nil and type(config[k]) == type(v) then config[k] = v end
  end
  return config
end

return M
