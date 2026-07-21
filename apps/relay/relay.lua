-- relay.lua — quick-launch / voice flows for Hammerspoon.
-- Load from ~/.hammerspoon/init.lua with: pcall(function() require("relay").start() end)
--
-- IMPORTANT: QuickShots owns the F18 (Caps Lock) event tap and consumes it,
-- so this module uses ordinary triple-modifier global hotkeys instead of
-- Caps-based bindings. Triple-modifier (ctrl+alt+cmd) combos are collision-free
-- because apps essentially never bind them.

local M = {}
local log = require("litelog").new("relay")

----------------------------------------------------------------
-- CONFIG — edit hotkeys and paths here.
----------------------------------------------------------------
local config = {
  -- Hotkeys. Each is { mods, key }. ctrl+alt+cmd = collision-free.
  hotkeys = {
    obsidian = { { "ctrl", "alt", "cmd" }, "n" }, -- Obsidian quick capture
    claude   = { { "ctrl", "alt", "cmd" }, "c" }, -- Voice Claude Code (new iTerm)
    dogfood  = { { "ctrl", "alt", "cmd" }, "d" }, -- Claude Chrome side panel (Cmd+E)
    search   = { { "ctrl", "alt", "cmd" }, "g" }, -- Chrome new tab / search
    wispr    = nil, -- Wispr Flow hotkey removed; startWispr() still exists for the dogfood flow
  },

  -- Quick-capture markdown file (parent dir + file auto-created). Point this at
  -- your notes inbox — e.g. an Obsidian vault under iCloud:
  --   ~/Library/Mobile Documents/iCloud~md~obsidian/Documents/<Vault>/Inbox/Quick Capture.md
  quickCaptureFile = os.getenv("HOME") .. "/Documents/Quick Capture.md",

  -- Fallback repo for Voice Claude Code when the iTerm cwd can't be resolved.
  claudeRepoFallback = os.getenv("HOME"),

  -- Command run in the new iTerm window. Permission-respecting by default.
  claudeCommand = "claude",
  -- Opt-in: append --dangerously-skip-permissions so Claude Code runs tools
  -- without per-action approval. Convenient, but it removes a safety gate —
  -- leave false unless you understand and accept that tradeoff.
  claudeDangerouslySkipPermissions = false,

  -- Wispr Flow Raycast extension deeplink (carterm/wispr-flow "Start Recording").
  -- See research notes at bottom of file. Set to nil to disable (shows help alert).
  wisprDeeplink = "raycast://extensions/carterm/wispr-flow/start-recording",

  -- Dogfood flow (⌃⌥⌘D): seconds to wait after activating Chrome before sending
  -- ⌘E (panel toggle), and again before auto-starting Wispr.
  dogfoodChromeDelay = 0.25,
  dogfoodPanelDelay  = 0.6,
  -- If true, after opening the Claude side panel, auto-start Wispr dictation so
  -- you can immediately speak your prompt. The panel grabs focus on open, so the
  -- dictation lands in its composer. Set false to just open the panel.
  dogfoodStartWispr  = true,

  alertDuration = 1.5,
}

----------------------------------------------------------------
-- Obsidian quick-capture append (pure Lua, no Hammerspoon deps).
-- Unit-testable: require this file in plain `lua` and call M.appendCapture.
----------------------------------------------------------------

-- Split a path into its directory component (everything before the last "/").
local function dirname(path)
  return (path:match("^(.*)/[^/]*$"))
end

-- Best-effort recursive mkdir using os.execute (works under plain Lua and HS).
local function ensureDir(dir)
  if not dir or dir == "" then return end
  os.execute(string.format("mkdir -p %q", dir))
end

-- Append `text` to `filePath` as a timestamped markdown task bullet under a
-- per-day "## YYYY-MM-DD" heading. The heading is written once per day: it is
-- only added when the most recent day-heading in the file differs from today.
--
-- Returns true on success, or false plus an error message.
-- `now` is an optional os.date-compatible timestamp (for deterministic tests).
function M.appendCapture(filePath, text, now)
  if not filePath or filePath == "" then
    log.warn("capture rejected", { reason = "no file path" })
    return false, "no file path"
  end
  if not text or text:match("^%s*$") then
    log.warn("capture rejected", { reason = "empty text" })
    return false, "empty text"
  end

  now = now or os.time()
  local today = os.date("%Y-%m-%d", now)
  local hhmm = os.date("%H:%M", now)
  local heading = "## " .. today

  ensureDir(dirname(filePath))

  -- Determine whether today's heading already exists by scanning existing day
  -- headings; we only need to know if `heading` is present anywhere.
  local headingExists = false
  local existing = io.open(filePath, "r")
  if existing then
    for line in existing:lines() do
      if line == heading then
        headingExists = true
        break
      end
    end
    existing:close()
  end

  local f, err = io.open(filePath, "a")
  if not f then
    log.error("capture open failed", { path = filePath, error = err })
    return false, err or "could not open file"
  end

  if not headingExists then
    f:write("\n" .. heading .. "\n")
  end
  -- Collapse internal newlines so dictated multi-line input stays one bullet.
  local oneLine = text:gsub("%s*\n%s*", " "):gsub("%s+$", "")
  f:write(string.format("- [ ] %s %s\n", hhmm, oneLine))
  f:close()
  log.info("capture appended", { path = filePath, chars = #oneLine })
  return true
end

----------------------------------------------------------------
-- Flow actions (require Hammerspoon at runtime).
----------------------------------------------------------------

function M.obsidianCapture()
  local btn, text = hs.dialog.textPrompt(
    "Quick Capture",
    "Capture to Obsidian Inbox (Wispr dictation works here):",
    "",
    "Save",
    "Cancel"
  )
  if btn ~= "Save" then return end
  if not text or text:match("^%s*$") then return end
  local ok, err = M.appendCapture(config.quickCaptureFile, text)
  if ok then
    log.info("obsidian capture saved", { path = config.quickCaptureFile })
    hs.alert.show("Captured to Obsidian", config.alertDuration)
  else
    log.error("obsidian capture failed", { error = err })
    hs.alert.show("Capture failed: " .. tostring(err), config.alertDuration)
  end
end

-- Resolve the git toplevel of the frontmost iTerm session's cwd, if possible.
-- Returns the repo path or the configured fallback.
local function resolveClaudeRepo()
  local script = [[
    tell application "iTerm"
      if (count of windows) is 0 then return ""
      tell current session of current window
        try
          return (variable named "session.path")
        on error
          return ""
        end try
      end tell
    end tell
  ]]
  local ok, result = hs.osascript.applescript(script)
  if ok and result and result ~= "" then
    -- result is the session cwd; ask git for its toplevel.
    local cmd = string.format("cd %q && git rev-parse --show-toplevel 2>/dev/null", result)
    local out = hs.execute(cmd, true) -- true = run in a login shell so git is on PATH
    if out then
      out = out:gsub("%s+$", "")
      if out ~= "" then return out end
    end
  end
  log.info("resolved claude repo", { repo = config.claudeRepoFallback })
  return config.claudeRepoFallback
end

function M.voiceClaudeCode()
  local repo = resolveClaudeRepo()
  -- Build the command, appending the skip-permissions flag only if opted in.
  local command = config.claudeCommand
  if config.claudeDangerouslySkipPermissions then
    command = command .. " --dangerously-skip-permissions"
  end
  log.info("launching voice claude code", { repo = repo, command = command })
  -- Escape double quotes for safe embedding inside the AppleScript string.
  local repoEsc = repo:gsub('"', '\\"')
  local cmdEsc = command:gsub('"', '\\"')
  local script = string.format([[
    tell application "iTerm"
      create window with default profile
      tell current session of current window
        write text "cd \"%s\" && %s"
      end tell
      activate
    end tell
  ]], repoEsc, cmdEsc)
  local ok, _, raw = hs.osascript.applescript(script)
  if not ok then
    log.error("iterm launch failed", { error = raw })
    hs.alert.show("iTerm launch failed", config.alertDuration)
  else
    log.info("iterm launched", { repo = repo })
  end
end

function M.claudeChromeDogfood()
  log.info("starting claude chrome dogfood")
  hs.application.launchOrFocus("Google Chrome")
  -- 1) let Chrome come forward, 2) toggle the Claude side panel (⌘E),
  -- 3) optionally auto-start Wispr so dictation lands in the panel composer.
  hs.timer.doAfter(config.dogfoodChromeDelay, function()
    hs.eventtap.keyStroke({ "cmd" }, "e", 0)
    if config.dogfoodStartWispr then
      hs.timer.doAfter(config.dogfoodPanelDelay, function() M.startWispr() end)
    end
  end)
end

function M.chromeSearch()
  log.info("starting chrome search")
  hs.application.launchOrFocus("Google Chrome")
  hs.timer.doAfter(0.25, function()
    hs.eventtap.keyStroke({ "cmd" }, "t", 0)
  end)
end

function M.startWispr()
  if config.wisprDeeplink and config.wisprDeeplink ~= "" then
    log.info("starting wispr", { deeplink = config.wisprDeeplink })
    hs.execute(string.format("open %q", config.wisprDeeplink))
  else
    log.warn("wispr deeplink missing")
    hs.alert.show(
      "Wispr start needs the Wispr Flow Raycast extension.\n" ..
      "Bind config.wisprDeeplink to e.g.\n" ..
      "raycast://extensions/carterm/wispr-flow/start-recording",
      4
    )
  end
end

----------------------------------------------------------------
-- start() — bind everything. Each binding is pcall-wrapped so one
-- failure cannot prevent the others from registering.
----------------------------------------------------------------
function M.start()
  local function bind(spec, fn, label)
    if not spec then return end
    local ok, err = pcall(function()
      hs.hotkey.bind(spec[1], spec[2], require("litelog").wrap("flows", label, fn))
    end)
    if not ok then
      log.error("hotkey bind failed", { label = label, error = err })
      hs.alert.show("flows: failed to bind " .. tostring(label) .. ": " .. tostring(err), 3)
    else
      log.info("hotkey bound", { label = label, key = spec[2] })
    end
  end

  bind(config.hotkeys.obsidian, function() M.obsidianCapture() end,    "obsidian")
  bind(config.hotkeys.claude,   function() M.voiceClaudeCode() end,    "claude")
  bind(config.hotkeys.dogfood,  function() M.claudeChromeDogfood() end, "dogfood")
  bind(config.hotkeys.search,   function() M.chromeSearch() end,       "search")
  bind(config.hotkeys.wispr,    function() M.startWispr() end,         "wispr")

  hs.alert.show("flows ready", config.alertDuration)
  log.info("started")
end

-- Exposed so users can read/mutate config from init.lua before/after start().
M.config = config

return M

----------------------------------------------------------------
-- WISPR DEEPLINK RESEARCH NOTES
----------------------------------------------------------------
-- The Wispr Flow Raycast extension (raycast.com/carterm/wispr-flow) exposes
-- these commands: Search Transcripts, Add Word to Dictionary, Manage Dictionary,
-- Toggle Recording, Start Recording, Stop Recording, Paste Last Transcript,
-- Open Wispr Flow.
--
-- Raycast deeplinks follow the form:
--   raycast://extensions/<author>/<extension>/<command-slug>
-- where <command-slug> is the command's kebab-cased name. So:
--   Start Recording  -> raycast://extensions/carterm/wispr-flow/start-recording
--   Toggle Recording -> raycast://extensions/carterm/wispr-flow/toggle-recording
--   Stop Recording   -> raycast://extensions/carterm/wispr-flow/stop-recording
--
-- "Start Recording" / "Stop Recording" / "Toggle Recording" are no-view
-- commands (designed for automation), so firing the deeplink with `open` runs
-- them with no UI. This module uses start-recording (config.wisprDeeplink);
-- swap to toggle-recording if you prefer one hotkey for start+stop.
--
-- DEPENDENCY: requires Raycast + the carterm/wispr-flow extension installed.
-- If the slug differs in your install, open Raycast, find the command, and use
-- its "Copy Deeplink" action to get the exact URL, then set config.wisprDeeplink.
