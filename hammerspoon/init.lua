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
--   4. murmur, relay — independent apps.
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

-- Snag (EquipFlow bug capture → verified GitHub issue).
loadApp("snag", function() require("snag").start() end)

-- Unsub (Caps+U: unsubscribe from the selected Apple Mail message).
loadApp("unsub", function() require("unsub").start() end)

-- Palette (Caps+K searchable shortcut menu) — last, so it sees every module.
loadApp("palette", function() require("palette").start() end,
  "Palette menu failed to load")

initLog.info("reload finished")
