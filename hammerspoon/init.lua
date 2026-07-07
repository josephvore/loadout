local logging = require("logging")
local initLog = logging.new("init")

local function loadApp(name, fn, failAlert)
  local appLog = logging.new(name)
  initLog.info("loading app", { app = name })
  appLog.info("loading")
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

-- shortcuts: apply persisted hotkey overrides to each module's config BEFORE
-- any module starts and binds. The Caps+K menu itself starts at the bottom.
loadApp("shortcuts", function() require("shortcuts").applyOverrides() end)

-- BEGIN QuickShots loader (managed by quickshots/install.sh)
-- quickshots.lua is symlinked to /Volumes/Code/quickshots (an internal fixed
-- volume). pcall-wrapped so that if that volume is ever unmounted, the dangling
-- symlink degrades to a visible alert instead of aborting the whole config.
loadApp("quickshots", function() require("quickshots").start() end,
  "QuickShots failed to load (is /Volumes/Code mounted?)")
-- END QuickShots loader

-- flows: quick-launch / voice flows (Obsidian capture, voice Claude Code,
-- Claude Chrome dogfood, Chrome search, start Wispr). pcall so a load error
-- here can never prevent QuickShots from starting.
loadApp("flows", function() require("flows").start() end)

-- refine: OpenAI text refinement — Caps+C refines the clipboard and pastes,
-- Caps+S refines the current selection in place. Binds into QuickShots'
-- Caps tap via registerCapsAction. pcall for the same isolation as above.
loadApp("refine", function() require("refine").start() end,
  "refine failed to load")

-- dictation: on-device dictation, one key — hold Right⌘ and speak, release
-- to paste; or tap Right⌘ for hands-free until you tap it again (Esc =
-- cancel). Runs ~/bin/hs-dictate (Apple SpeechAnalyzer); no cloud.
loadApp("dictation", function() require("dictation").start() end,
  "dictation failed to load")

-- shortcuts: Caps+K — searchable menu of every Hammerspoon shortcut with
-- descriptions, source files, and run / rebind / reset actions.
loadApp("shortcuts", function() require("shortcuts").start() end,
  "shortcuts menu failed to load")

initLog.info("reload finished")
