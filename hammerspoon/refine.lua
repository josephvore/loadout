-- refine.lua — AI text refinement via the OpenAI API.
-- Load from ~/.hammerspoon/init.lua with: pcall(function() require("refine").start() end)
--
--   Caps+C  refine clipboard contents, then paste the result
--   Caps+S  refine the current selection, replacing it in place
--
-- Binds into QuickShots' shared Caps (F18) event tap via registerCapsAction;
-- if that API is unavailable it falls back to ⌃⌥⌘R / ⌃⌥⌘S global hotkeys.
--
-- The API key is read from the macOS Keychain (service "openai-refine") so no
-- secret ever lives in this file / the dotfiles repo. To (re)set it:
--   security add-generic-password -a "$USER" -s openai-refine -w 'sk-...' -U

local M = {}

----------------------------------------------------------------
-- CONFIG — edit values to taste.
----------------------------------------------------------------
local config = {
  keychainService = "openai-refine",

  -- This project has access to the GPT-5 family only. gpt-5.4 edits noticeably
  -- better than -mini (cuts filler, not just grammar) at ~2.4s vs ~1.2s;
  -- drop to gpt-5.4-mini or -nano if latency matters more than polish.
  model = "gpt-5.4",
  reasoningEffort = "none", -- fastest; gpt-5.4 supports none/low/medium/high/xhigh
  temperature = nil, -- GPT-5 models reject non-default temperature; e.g. 0.3 for gpt-4.1-mini

  -- The transformation applied to the text. The output-format sentence keeps
  -- the model from wrapping results in quotes or "Here's your text:" preambles.
  prompt = "Refine the following text for clarity, conciseness, readability, "
    .. "and understanding without changing its meaning or intent. "
    .. "Return only the refined text — no preamble, no quotes, no commentary.",

  -- Caps-held bindings (require QuickShots' registerCapsAction).
  capsClipboard = { {}, "c" },
  capsSelection = { {}, "s" },

  -- Fallback global hotkeys, used only when the Caps tap is unavailable.
  fallbackClipboard = { { "ctrl", "alt", "cmd" }, "r" },
  fallbackSelection = { { "ctrl", "alt", "cmd" }, "s" },

  -- After replacing a selection, restore whatever was on the clipboard before
  -- the refine started. false = leave the refined text on the clipboard.
  restoreClipboard = false,

  copyDelay  = 0.15, -- wait after sending Cmd+C before polling the pasteboard
  pasteDelay = 0.15, -- wait after writing the result before sending Cmd+V
  restoreDelay = 0.6, -- wait after pasting before restoring the old clipboard

  alertDuration = 2.5,
}

----------------------------------------------------------------
-- API KEY (Keychain, cached after first read)
----------------------------------------------------------------
local cachedKey = nil

local function apiKey()
  if cachedKey then return cachedKey end
  local out = hs.execute(
    "/usr/bin/security find-generic-password -s '" ..
    config.keychainService .. "' -w 2>/dev/null")
  if out then
    out = out:gsub("%s+$", "")
    if out ~= "" then cachedKey = out end
  end
  return cachedKey
end

----------------------------------------------------------------
-- OPENAI CALL (async — never blocks the UI)
----------------------------------------------------------------
local function callOpenAI(text, onDone)
  local key = apiKey()
  if not key then
    hs.alert.show(
      "Refine: no API key found in Keychain (service '"
      .. config.keychainService .. "')", config.alertDuration)
    return
  end

  local body = hs.json.encode({
    model = config.model,
    temperature = config.temperature,
    reasoning_effort = config.reasoningEffort,
    messages = {
      { role = "system", content = config.prompt },
      { role = "user",   content = text },
    },
  })

  hs.alert.show("✍️ Refining…", 1.0)

  hs.http.asyncPost("https://api.openai.com/v1/chat/completions", body, {
    ["Authorization"] = "Bearer " .. key,
    ["Content-Type"]  = "application/json",
  }, function(status, responseBody)
    if status ~= 200 then
      local msg = "HTTP " .. tostring(status)
      local ok, parsed = pcall(hs.json.decode, responseBody or "")
      if ok and type(parsed) == "table"
        and parsed.error and parsed.error.message then
        msg = msg .. ": " .. parsed.error.message
      end
      hs.alert.show("Refine failed — " .. msg, config.alertDuration + 1.5)
      return
    end

    local ok, parsed = pcall(hs.json.decode, responseBody)
    local result = ok and type(parsed) == "table"
      and parsed.choices and parsed.choices[1]
      and parsed.choices[1].message and parsed.choices[1].message.content
    if type(result) ~= "string" or result:match("^%s*$") then
      hs.alert.show("Refine failed — empty response", config.alertDuration)
      return
    end

    onDone((result:gsub("^%s+", ""):gsub("%s+$", "")))
  end)
end

-- Put `result` on the clipboard and paste it. If `restoreTo` is non-nil,
-- restore it to the clipboard shortly after the paste lands.
local function pasteResult(result, restoreTo)
  hs.pasteboard.setContents(result)
  hs.timer.doAfter(config.pasteDelay, function()
    hs.eventtap.keyStroke({ "cmd" }, "v", 0)
    if restoreTo then
      hs.timer.doAfter(config.restoreDelay, function()
        hs.pasteboard.setContents(restoreTo)
      end)
    end
  end)
end

----------------------------------------------------------------
-- ACTIONS
----------------------------------------------------------------

-- Caps+C: refine whatever is on the clipboard, paste the result.
function M.refineClipboard()
  local text = hs.pasteboard.getContents()
  if not text or text:match("^%s*$") then
    hs.alert.show("Refine: clipboard is empty", config.alertDuration)
    return
  end
  callOpenAI(text, function(result)
    pasteResult(result, nil)
  end)
end

-- Caps+S: copy the current selection (Cmd+C), refine it, paste over it.
-- The pasteboard changeCount is polled so we proceed the moment the copy
-- lands instead of guessing with one fixed delay.
function M.refineSelection()
  local original = hs.pasteboard.getContents()
  local before = hs.pasteboard.changeCount()
  hs.eventtap.keyStroke({ "cmd" }, "c", 0)

  local attempts = 0
  local function poll()
    if hs.pasteboard.changeCount() ~= before then
      local text = hs.pasteboard.getContents()
      if not text or text:match("^%s*$") then
        hs.alert.show("Refine: no text selected", config.alertDuration)
        return
      end
      callOpenAI(text, function(result)
        pasteResult(result, config.restoreClipboard and original or nil)
      end)
      return
    end
    attempts = attempts + 1
    if attempts < 12 then
      hs.timer.doAfter(0.05, poll)
    else
      hs.alert.show("Refine: couldn't copy selection", config.alertDuration)
    end
  end
  hs.timer.doAfter(config.copyDelay, poll)
end

----------------------------------------------------------------
-- start() — bind into the QuickShots caps tap, or fall back.
----------------------------------------------------------------
function M.start()
  local ok, qs = pcall(require, "quickshots")
  if ok and type(qs) == "table" and type(qs.registerCapsAction) == "function" then
    qs.registerCapsAction(config.capsClipboard[1], config.capsClipboard[2],
      function() M.refineClipboard() end)
    qs.registerCapsAction(config.capsSelection[1], config.capsSelection[2],
      function() M.refineSelection() end)
  else
    hs.hotkey.bind(config.fallbackClipboard[1], config.fallbackClipboard[2],
      function() M.refineClipboard() end)
    hs.hotkey.bind(config.fallbackSelection[1], config.fallbackSelection[2],
      function() M.refineSelection() end)
    hs.alert.show("refine: caps tap unavailable — using ⌃⌥⌘R / ⌃⌥⌘S", 3)
  end
end

-- Exposed so users can read/mutate config from init.lua before/after start().
M.config = config

return M
