-- shortcuts: apply persisted hotkey overrides to each module's config BEFORE
-- any module starts and binds. The Caps+K menu itself starts at the bottom.
pcall(function() require("shortcuts").applyOverrides() end)

-- BEGIN QuickShots loader (managed by quickshots/install.sh)
-- quickshots.lua is symlinked to /Volumes/Code/quickshots (an internal fixed
-- volume). pcall-wrapped so that if that volume is ever unmounted, the dangling
-- symlink degrades to a visible alert instead of aborting the whole config.
if not pcall(function() require("quickshots").start() end) then
  hs.alert.show("QuickShots failed to load (is /Volumes/Code mounted?)", 5)
end
-- END QuickShots loader

-- flows: quick-launch / voice flows (Obsidian capture, voice Claude Code,
-- Claude Chrome dogfood, Chrome search, start Wispr). pcall so a load error
-- here can never prevent QuickShots from starting.
pcall(function() require("flows").start() end)

-- refine: OpenAI text refinement — Caps+C refines the clipboard and pastes,
-- Caps+S refines the current selection in place. Binds into QuickShots'
-- Caps tap via registerCapsAction. pcall for the same isolation as above.
if not pcall(function() require("refine").start() end) then
  hs.alert.show("refine failed to load", 3)
end

-- shortcuts: Caps+K — searchable menu of every Hammerspoon shortcut with
-- descriptions, source files, and run / rebind / reset actions.
if not pcall(function() require("shortcuts").start() end) then
  hs.alert.show("shortcuts menu failed to load", 3)
end
