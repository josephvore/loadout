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
