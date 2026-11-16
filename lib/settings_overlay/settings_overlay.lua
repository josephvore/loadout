-- settings_overlay.lua — merge a Loadout app's saved settings over its
-- in-file config defaults. The overlay JSON is written by loadout-settings
-- (the ✦ Settings windows) to ~/loadout/settings/<app>.settings.json; only
-- keys that already exist in the config table are applied, so a stale or
-- foreign key can never inject new config. No overlay file = no change.
-- Usage (first line of an app's start()):
--   pcall(function() require("settings_overlay").apply("murmur", config) end)

local M = {}

function M.apply(app, config)
  local path = (os.getenv("HOME") or "") ..
    "/loadout/settings/" .. app .. ".settings.json"
  local f = io.open(path, "r")
  if not f then return config end
  local raw = f:read("*a")
  f:close()
  local ok, overlay = pcall(hs.json.decode, raw)
  if not ok or type(overlay) ~= "table" then return config end
  for k, v in pairs(overlay) do
    if config[k] ~= nil then config[k] = v end
  end
  return config
end

return M
