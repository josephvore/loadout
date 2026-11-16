-- snag.lua — the THIN Hammerspoon trigger for Snag: Caps+P hotkey + the
-- region-selection overlay, nothing else. Recording, pipeline, and
-- notifications are owned by the `snag` CLI + a launchd folder-watch
-- (pipeline-runner.sh), so Hammerspoon is optional: `snag record` works
-- from any trigger, and a reload mid-capture severs nothing.
-- Load from ~/.hammerspoon/init.lua with: require("snag").start()
--
-- Region selection is drawn here (dim overlay + rubber band) because this
-- macOS build rejects `screencapture -v -i` and there is no CLI region
-- picker for video rects. Selection is stateless UI; everything after the
-- rect is chosen goes through the CLI.

local M = {}

----------------------------------------------------------------
-- USER CONFIGURATION (edit values to taste)
----------------------------------------------------------------
local HOME = os.getenv("HOME") or ""
local SNAG_DIR = HOME .. "/loadout/apps/snag"

local config = {
  -- The CLI that owns the recording lifecycle.
  cli = SNAG_DIR .. "/snag",

  -- Recording state file the CLI maintains (existence = recording).
  stateFile = SNAG_DIR .. "/state/recording.json",

  -- A drag smaller than this (points) counts as a click = whole screen.
  minDragSize = 10,

  -- Caps-held bindings (require QuickShots' shared Caps/F18 tap).
  capsRecord = { {}, "p" },          -- Caps+P        start / stop recording
  capsCancel = { { "shift" }, "p" }, -- Caps+Shift+P  stop and discard

  -- Fallback global hotkeys, used only when the Caps tap is unavailable.
  fallbackRecord = { { "ctrl", "alt", "cmd" }, "b" },
  fallbackCancel = { { "ctrl", "alt", "cmd", "shift" }, "b" },

  -- Alert durations (seconds).
  alertDurationOk  = 0.8,
  alertDurationErr = 2.0,
}

----------------------------------------------------------------
-- INTERNAL STATE (selection UI only — recording state lives in the CLI)
----------------------------------------------------------------
local log = nil
local menubar = nil        -- "● snag" indicator while recording
local selTap = nil         -- eventtap active during region selection
local selOverlays = {}     -- one dim canvas per screen during selection
local selAnchor = nil      -- absolute point where the drag started

local function alertOk(msg)  hs.alert.show(msg, config.alertDurationOk) end
local function alertErr(msg) hs.alert.show(msg, config.alertDurationErr) end

local function isRecording()
  return hs.fs.attributes(config.stateFile) ~= nil
end

local function cli(args, onOk, onFail)
  local task = hs.task.new(config.cli, function(exitCode, stdOut, stdErr)
    if exitCode == 0 then
      if onOk then onOk(stdOut) end
    else
      log.error("cli failed", { args = table.concat(args, " "), stderr = stdErr })
      if onFail then onFail(stdErr) else alertErr("Snag: " .. (stdErr or "command failed")) end
    end
  end, args)
  task:start()
end

local function showRecordingIndicator()
  if menubar then menubar:delete() end
  menubar = hs.menubar.new()
  if menubar then
    menubar:setTitle("● snag")
    menubar:setTooltip("Snag is recording — click to stop")
    menubar:setClickCallback(function() M.stop() end)
  end
end

local function hideRecordingIndicator()
  if menubar then menubar:delete() end
  menubar = nil
end

----------------------------------------------------------------
-- REGION SELECTION (dim overlay + rubber band, Esc cancels)
----------------------------------------------------------------
local function teardownSelection()
  if selTap then selTap:stop(); selTap = nil end
  for _, c in ipairs(selOverlays) do c:delete() end
  selOverlays = {}
  selAnchor = nil
end

local function rectFromPoints(a, b)
  return {
    x = math.min(a.x, b.x), y = math.min(a.y, b.y),
    w = math.abs(a.x - b.x), h = math.abs(a.y - b.y),
  }
end

local function updateRubberBand(rect)
  for _, c in ipairs(selOverlays) do
    local sf = c:frame()
    local rel = { x = rect.x - sf.x, y = rect.y - sf.y, w = rect.w, h = rect.h }
    c[2] = { type = "rectangle", action = "fill", compositeRule = "clear",
             frame = rel }
    c[3] = { type = "rectangle", action = "stroke", frame = rel,
             strokeColor = { white = 1, alpha = 0.9 }, strokeWidth = 2 }
  end
end

local startRecording -- forward declaration

local function finishSelection(endPoint)
  local rect = rectFromPoints(selAnchor, endPoint)
  teardownSelection()
  if rect.w < config.minDragSize or rect.h < config.minDragSize then
    local screen = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
    rect = screen:fullFrame()
  end
  startRecording(rect)
end

local function beginSelection()
  local types = hs.eventtap.event.types
  for _, screen in ipairs(hs.screen.allScreens()) do
    local c = hs.canvas.new(screen:fullFrame())
    c[1] = { type = "rectangle", action = "fill",
             fillColor = { black = 1, alpha = 0.25 } }
    c:level(hs.canvas.windowLevels.screenSaver)
    c:show()
    table.insert(selOverlays, c)
  end
  selTap = hs.eventtap.new(
    { types.leftMouseDown, types.leftMouseDragged, types.leftMouseUp,
      types.keyDown },
    function(e)
      local etype = e:getType()
      if etype == types.keyDown then
        if e:getKeyCode() == 53 then -- Esc
          teardownSelection()
          alertOk("Snag: selection cancelled")
          return true
        end
        return false
      end
      if etype == types.leftMouseDown then
        selAnchor = e:location()
        return true
      end
      if not selAnchor then return true end
      if etype == types.leftMouseDragged then
        updateRubberBand(rectFromPoints(selAnchor, e:location()))
        return true
      end
      finishSelection(e:location()) -- leftMouseUp
      return true
    end)
  selTap:start()
  alertOk("Snag: drag a region (click = whole screen) — talk through the bug. Esc cancels")
end

----------------------------------------------------------------
-- RECORDING (delegated to the CLI)
----------------------------------------------------------------

-- avfoundation captures one display at a time; find the screen holding the
-- rect's center, express the crop in that screen's pixels (points * scale).
local function screenAndCrop(rect)
  local center = { x = rect.x + rect.w / 2, y = rect.y + rect.h / 2 }
  local screens = hs.screen.allScreens()
  local idx, screen = 0, screens[1]
  for i, s in ipairs(screens) do
    local f = s:fullFrame()
    if center.x >= f.x and center.x < f.x + f.w
        and center.y >= f.y and center.y < f.y + f.h then
      idx, screen = i - 1, s
      break
    end
  end
  local f = screen:fullFrame()
  local mode = screen:currentMode()
  local scale = (mode and mode.scale) or 2
  local function even(n) return math.max(2, math.floor(n / 2) * 2) end
  local x = math.max(0, math.floor((rect.x - f.x) * scale))
  local y = math.max(0, math.floor((rect.y - f.y) * scale))
  local w = even(math.min(rect.w * scale, f.w * scale - x))
  local h = even(math.min(rect.h * scale, f.h * scale - y))
  return idx, string.format("%d:%d:%d:%d", w, h, x, y)
end

startRecording = function(rect)
  local screenNum, crop = screenAndCrop(rect)
  cli({ "record", "--screen", tostring(screenNum), "--crop", crop },
    function()
      showRecordingIndicator()
      log.info("recording started", { screen = screenNum, crop = crop })
    end)
end

-- Record a rect directly, skipping the selection UI (scripting/testing).
function M.recordRect(rect)
  if isRecording() then return end
  startRecording(rect)
end

function M.record()
  if isRecording() then return M.stop() end
  if selTap then
    teardownSelection()
    alertOk("Snag: selection cancelled")
    return
  end
  beginSelection()
end

function M.stop()
  if not isRecording() then return end
  cli({ "stop" }, function()
    hideRecordingIndicator()
    alertOk("Snag: processing — notification will follow")
  end)
end

function M.cancel()
  if selTap then
    teardownSelection()
    alertOk("Snag: selection cancelled")
    return
  end
  if not isRecording() then return end
  cli({ "cancel" }, function()
    hideRecordingIndicator()
    alertOk("Snag: discarded")
  end)
end

-- Live state for scripts/observers.
function M.status()
  return { recording = isRecording(), selecting = selTap ~= nil }
end

function M.start()
  log = require("litelog").new("snag")
  -- A reload during a recording severs nothing: state lives in the CLI, so
  -- just restore the indicator.
  if isRecording() then showRecordingIndicator() end
  local ok, qs = pcall(require, "quickshots")
  if ok and type(qs) == "table" and type(qs.registerCapsAction) == "function" then
    qs.registerCapsAction(config.capsRecord[1], config.capsRecord[2],
      require("litelog").wrap("snag", "record toggle", function() M.record() end))
    qs.registerCapsAction(config.capsCancel[1], config.capsCancel[2],
      require("litelog").wrap("snag", "cancel recording", function() M.cancel() end))
    log.info("caps bindings registered", { record = "caps+p", cancel = "caps+shift+p" })
  else
    hs.hotkey.bind(config.fallbackRecord[1], config.fallbackRecord[2], M.record)
    hs.hotkey.bind(config.fallbackCancel[1], config.fallbackCancel[2], M.cancel)
    log.warn("caps tap unavailable; fallback bindings registered")
    hs.alert.show("snag: caps tap unavailable — using ⌃⌥⌘B / ⌃⌥⌘⇧B", 3)
  end
  log.info("started")
end

M.config = config

return M
