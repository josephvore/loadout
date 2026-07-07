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
local log = require("logging").new("refine")

----------------------------------------------------------------
-- CONFIG — edit values to taste.
----------------------------------------------------------------
local config = {
  keychainService = "openai-refine",

  -- This project has access to the GPT-5 family only.
  --   model           — manual Caps+C / Caps+S. gpt-5.4 edits best (cuts
  --                     filler, not just grammar) at ~1.4-2.4s.
  --   autoRefineModel — optional dictation cleanup. Dictation no longer runs
  --                     this by default because release→paste needs to be
  --                     immediate; keep it available for explicit cleanup.
  model = "gpt-5.4",
  autoRefineModel = "gpt-5.4-mini",
  reasoningEffort = "none", -- fastest; gpt-5.4 supports none/low/medium/high/xhigh
  temperature = nil, -- GPT-5 models reject non-default temperature; e.g. 0.3 for gpt-4.1-mini

  -- Words the speech engine tends to mishear — names, brand/product words,
  -- jargon. The dictation auto-refine is told to fix clear misrecognitions of
  -- these (e.g. "amplified" → "Amplifyd"). Add your own; the recognizer itself
  -- can't be biased (SpeechTranscriber exposes no vocabulary API), so this
  -- LLM-side glossary is how proper nouns get corrected. Empty = no glossary.
  dictationGlossaryPath = os.getenv("HOME") .. "/dotfiles/hammerspoon/dictation_glossary.txt",
  vocabulary = {
    "Amplify", "Amplifyd",
  },

  -- Generic refine (Caps+C / Caps+S): rewrite for clarity without changing
  -- meaning. The output-format sentence stops the model wrapping results in
  -- quotes or "Here's your text:" preambles.
  prompt = "Refine the following text for clarity, conciseness, readability, "
    .. "and understanding without changing its meaning or intent. "
    .. "Return only the refined text — no preamble, no quotes, no commentary.",

  -- Dictation cleanup: keep this much more conservative than the generic
  -- refine path. The raw transcript should still sound like the speaker.
  dictationPrompt =
    "You are lightly cleaning raw speech-to-text dictation. Preserve the exact "
    .. "wording, repetitions, rambling structure, meaning, and tone. Do not "
    .. "rewrite, summarize, tighten, remove filler, or add new ideas. Fix only "
    .. "clear speech-recognition mistakes and glossary terms when the intended "
    .. "word is obvious. Use minimal punctuation: avoid commas unless required "
    .. "for basic grammar, and do not insert punctuation merely because the "
    .. "speaker paused or changed pace. Return only the cleaned text: no "
    .. "preamble, no quotes, no commentary.",

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
-- opts (optional table):
--   quiet        suppress alerts (programmatic callers own their own UI)
--   model        override config.model (e.g. the faster auto-refine model)
--   systemPrompt override config.prompt (e.g. the dictation cleanup prompt)
-- onFail(message) is optional; when given, failures are reported through it.
local function callOpenAI(text, onDone, onFail, opts)
  opts = opts or {}
  local quiet = opts.quiet
  local key = apiKey()
  if not key then
    local msg = "no API key found in Keychain (service '"
      .. config.keychainService .. "')"
    log.error("api key missing", { service = config.keychainService })
    if onFail then onFail(msg) end
    if not quiet then
      hs.alert.show("Refine: " .. msg, config.alertDuration)
    end
    return
  end

  local body = hs.json.encode({
    model = opts.model or config.model,
    temperature = config.temperature,
    reasoning_effort = config.reasoningEffort,
    messages = {
      { role = "system", content = opts.systemPrompt or config.prompt },
      { role = "user",   content = text },
    },
  })

  local model = opts.model or config.model
  local mode = opts.mode or (quiet and "programmatic" or "manual")
  log.info("openai request", { mode = mode, model = model, chars = #text })

  if not quiet then hs.alert.show("✍️ Refining…", 1.0) end

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
      log.error("openai request failed", {
        mode = mode,
        model = model,
        status = status,
        message = msg,
      })
      if onFail then onFail(msg) end
      if not quiet then
        hs.alert.show("Refine failed — " .. msg, config.alertDuration + 1.5)
      end
      return
    end

    local ok, parsed = pcall(hs.json.decode, responseBody)
    local result = ok and type(parsed) == "table"
      and parsed.choices and parsed.choices[1]
      and parsed.choices[1].message and parsed.choices[1].message.content
    if type(result) ~= "string" or result:match("^%s*$") then
      log.error("openai empty response", { mode = mode, model = model })
      if onFail then onFail("empty response") end
      if not quiet then
        hs.alert.show("Refine failed — empty response", config.alertDuration)
      end
      return
    end

    result = result:gsub("^%s+", ""):gsub("%s+$", "")
    log.info("openai response", {
      mode = mode,
      model = model,
      inputChars = #text,
      outputChars = #result,
    })
    onDone(result)
  end)
end

-- Put `result` on the clipboard and paste it. If `restoreTo` is non-nil,
-- restore it to the clipboard shortly after the paste lands.
local function pasteResult(result, restoreTo)
  log.info("pasting result", { chars = #result, restoreClipboard = restoreTo ~= nil })
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

local function trim(s)
  return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function glossaryTerms()
  local terms = {}
  for _, term in ipairs(config.vocabulary or {}) do
    if trim(term) ~= "" then terms[#terms + 1] = trim(term) end
  end

  local f = io.open(config.dictationGlossaryPath or "", "r")
  if f then
    for line in f:lines() do
      local cleaned = trim((line:gsub("#.*$", "")))
      if cleaned ~= "" then
        local canonical = cleaned:match("^(.-)%s*=")
          or cleaned:match("^(.-)%s*=>")
          or cleaned
        canonical = trim(canonical)
        if canonical ~= "" then terms[#terms + 1] = canonical end
      end
    end
    f:close()
  end

  table.sort(terms)
  local deduped, last = {}, nil
  for _, term in ipairs(terms) do
    if term ~= last then
      deduped[#deduped + 1] = term
      last = term
    end
  end
  return deduped
end

-- Build the dictation system prompt, appending the glossary if non-empty.
local function dictationSystemPrompt()
  local p = config.dictationPrompt
  local terms = glossaryTerms()
  if #terms > 0 then
    p = p .. " Correct clear misrecognitions of these terms to the exact "
      .. "spelling shown: " .. table.concat(terms, ", ") .. "."
  end
  return p
end

-- Programmatic API: refine `text` and call onDone(result). No alerts, no
-- pasting — the caller owns the UI. onFail(message) fires on any failure.
-- Used by dictation.lua's autoRefine — runs the faster autoRefineModel with
-- the dictation-cleanup prompt (+ glossary), not the generic Caps+C prompt.
function M.refineText(text, onDone, onFail)
  callOpenAI(text, onDone, onFail, {
    quiet = true,
    model = config.autoRefineModel,
    systemPrompt = dictationSystemPrompt(),
    mode = "dictation",
  })
end

-- Caps+C: refine whatever is on the clipboard, paste the result.
function M.refineClipboard()
  local text = hs.pasteboard.getContents()
  if not text or text:match("^%s*$") then
    log.warn("clipboard refine rejected", { reason = "empty clipboard" })
    hs.alert.show("Refine: clipboard is empty", config.alertDuration)
    return
  end
  log.info("clipboard refine requested", { chars = #text })
  callOpenAI(text, function(result)
    pasteResult(result, nil)
  end, nil, { mode = "clipboard" })
end

-- Caps+S: copy the current selection (Cmd+C), refine it, paste over it.
-- The pasteboard changeCount is polled so we proceed the moment the copy
-- lands instead of guessing with one fixed delay.
function M.refineSelection()
  log.info("selection refine requested")
  local original = hs.pasteboard.getContents()
  local before = hs.pasteboard.changeCount()
  hs.eventtap.keyStroke({ "cmd" }, "c", 0)

  local attempts = 0
  local function poll()
    if hs.pasteboard.changeCount() ~= before then
      local text = hs.pasteboard.getContents()
      if not text or text:match("^%s*$") then
        log.warn("selection refine rejected", { reason = "empty selection" })
        hs.alert.show("Refine: no text selected", config.alertDuration)
        return
      end
      log.info("selection copied", { chars = #text })
      callOpenAI(text, function(result)
        pasteResult(result, config.restoreClipboard and original or nil)
      end, nil, { mode = "selection" })
      return
    end
    attempts = attempts + 1
    if attempts < 12 then
      hs.timer.doAfter(0.05, poll)
    else
      log.error("selection copy timed out")
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
      require("logging").wrap("refine", "refine clipboard", function() M.refineClipboard() end))
    qs.registerCapsAction(config.capsSelection[1], config.capsSelection[2],
      require("logging").wrap("refine", "refine selection", function() M.refineSelection() end))
    log.info("caps bindings registered")
  else
    hs.hotkey.bind(config.fallbackClipboard[1], config.fallbackClipboard[2],
      require("logging").wrap("refine", "refine clipboard fallback", function() M.refineClipboard() end))
    hs.hotkey.bind(config.fallbackSelection[1], config.fallbackSelection[2],
      require("logging").wrap("refine", "refine selection fallback", function() M.refineSelection() end))
    log.warn("caps tap unavailable; fallback bindings registered")
    hs.alert.show("refine: caps tap unavailable — using ⌃⌥⌘R / ⌃⌥⌘S", 3)
  end
  log.info("started")
end

-- Exposed so users can read/mutate config from init.lua before/after start().
M.config = config

return M
