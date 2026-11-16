-- Loadout — canonical Hammerspoon loader.
--
-- Loads whichever Loadout apps are installed in ~/.hammerspoon. Every app is
-- loaded inside a pcall so that one app failing to load (or being absent) can
-- never stop the others. Apps register their own hotkeys when they start.
--
-- Load order matters:
--   1. palette.applyOverrides() — apply persisted hotkey overrides to each
--      module's config BEFORE any module binds.
--   2. quickshots — owns the shared Caps (F18) event tap that hone and palette
--      bind into, so it must start before them.
--   3. hone — text refinement; also Murmur's cleanup engine, so before murmur.
--   4. murmur, relay, unsub — independent apps, then private local apps.
--   5. palette.start() — the Caps+K menu, last, so it sees every module.

local logging = require("litelog")
local initLog = logging.new("init")

local function moduleInstalled(name)
  if package.searchpath then
    return package.searchpath(name, package.path) ~= nil
  end
  return hs.fs.attributes(hs.configdir .. "/" .. name .. ".lua") ~= nil
end

local function loadApp(name, fn, failAlert)
  if not moduleInstalled(name) then
    initLog.info("skipped app", { app = name, reason = "not installed" })
    return false
  end
  local appLog = logging.new(name)
  initLog.info("loading app", { app = name })
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    initLog.info("loaded app", { app = name })
    appLog.info("loaded")
    return true
  end
  initLog.error("app failed to load", { app = name, error = err })
  appLog.error("load failed", { error = err })
  if failAlert then hs.alert.show(failAlert, 3) end
  return false
end

initLog.info("reload started")

-- Personal paths, device choices, and model settings live outside the repo in
-- ~/.hammerspoon/loadout.local.lua. It may return { apps = { "name", ... } } to
-- start private modules of your own (loaded after the built-in apps).
local localApps = {}
local localConfig = hs.configdir .. "/loadout.local.lua"
if hs.fs.attributes(localConfig, "mode") == "file" then
  local ok, res = xpcall(dofile, debug.traceback, localConfig)
  if ok then
    initLog.info("local config loaded")
    if type(res) == "table" and type(res.apps) == "table" then localApps = res.apps end
  else
    initLog.error("local config failed", { error = res })
    hs.alert.show("Loadout local configuration failed to load", 3)
  end
end

-- Apply persisted hotkey overrides before anything binds.
loadApp("palette", function() require("palette").applyOverrides() end)

-- QuickShots owns the shared Caps (F18) tap; start it first. Absent = fine.
loadApp("quickshots", function() require("quickshots").start() end,
  "QuickShots failed to load")

-- Hone (AI text refine) — also Murmur's cleanup engine, so start before Murmur.
loadApp("hone", function() require("hone").start() end)

-- Murmur (on-device dictation).
loadApp("murmur", function() require("murmur").start() end)

-- Relay (quick-launch / voice flows).
loadApp("relay", function() require("relay").start() end)

-- Unsub (Caps+U: unsubscribe from the selected Apple Mail message).
loadApp("unsub", function() require("unsub").start() end)

-- Private apps named by loadout.local.lua.
for _, name in ipairs(localApps) do
  if type(name) == "string" then
    loadApp(name, function() require(name).start() end)
  end
end

-- Palette (Caps+K searchable shortcut menu) — last, so it sees every module.
loadApp("palette", function() require("palette").start() end,
  "Palette menu failed to load")

initLog.info("reload finished")
