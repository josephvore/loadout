-- dictation.lua — push-to-talk voice dictation, fully on-device.
-- Load from ~/.hammerspoon/init.lua with: pcall(function() require("dictation").start() end)
--
--   Right⌘, held      push-to-talk: speak while holding, release to paste
--   Right⌘, tapped    hands-free: keeps listening until you tap Right⌘ again
--   Esc               cancel while recording, discard the take
--
-- One key, two behaviors: releasing within `tapThreshold` seconds counts as
-- a tap (hands-free); longer is a hold. Pressing any OTHER key while Right⌘
-- is down means you were typing a normal ⌘-shortcut — dictation silently
-- cancels and the shortcut goes through untouched.
--
-- Speech-to-text runs locally via ~/bin/hs-dictate, a small Swift daemon
-- built on Apple's SpeechAnalyzer (macOS 26). The daemon stays warm between
-- takes with the model loaded AND the mic engine hot (see micIdleSeconds),
-- and transcribes WHILE you speak, so text is ready almost instantly when
-- you stop. No cloud, no cost, works offline.
--
-- Build the daemon (source lives next to this file):
--   ~/dotfiles/hammerspoon/hs-dictate/build.sh

local M = {}
local log = require("logging").new("dictation")
local core = require("dictation_core")

----------------------------------------------------------------
-- CONFIG — edit values to taste.
----------------------------------------------------------------
local config = {
  binary = os.getenv("HOME") .. "/bin/hs-dictate",
  locale = "en_US",

  -- Bias the transcriber toward more frequent partial/final updates. Keep
  -- this off by default: stable final text matters more than partial churn.
  fastResults = false,

  -- Keep native punctuation on in every profile. Literal disables AI cleanup,
  -- not punctuation, so it remains readable without rewriting the speaker.
  punctuation = true,

  -- The daemon keeps the mic engine HOT between takes (starting it fresh
  -- costs ~100-300 ms and clips your first word). -1 holds it forever for
  -- instant starts; set 180 if you prefer the orange mic indicator to turn
  -- off after a few idle minutes.
  micIdleSeconds = -1,

  -- Trigger key. Must be a bare MODIFIER key name from hs.keycodes.map
  -- ("rightcmd", "rightalt", "rightctrl", "rightshift", "cmd", …); it is
  -- watched via a flagsChanged event tap, so ordinary keys won't work here.
  trigger = { {}, "rightcmd" },

  -- Bluetooth headset microphones can change CoreAudio format/route under
  -- AVAudioEngine and have been the source of installTap crashes. Prefer
  -- stable dedicated mics in this order; set to {} to use system default.
  preferredInputDevices = {
    "Insta360 Link 2C",
    "MacBook Pro Microphone",
  },
  preferredInputDevice = nil, -- legacy single-name override

  -- Releasing the trigger within this many seconds of pressing = a "tap" →
  -- switch to hands-free instead of stopping. Longer = push-to-talk release.
  tapThreshold = 0.35,

  -- Feedback sounds (system sound names; set to nil to silence). Dictation is
  -- used constantly, so the default is quiet.
  soundStart = nil,
  soundStop  = nil,

  -- After pasting, leave the transcript on the clipboard (false restores
  -- whatever was there before).
  keepOnClipboard = true,

  -- The instant you stop a take, the live transcript is written to the
  -- clipboard as a backup — BEFORE finalize runs — so even if everything
  -- downstream hangs or crashes, Cmd+V has your words.
  clipboardBackup = true,

  -- Light cleanup sends text to OpenAI only for explicit backtracking cues.
  -- Ordinary takes stay local and paste immediately after deterministic
  -- glossary/filler cleanup.
  autoRefine = true,
  autoRefineTimeout = 2.25,
  autoRefineMinChars = 12,   -- skip only tiny acknowledgements
  autoRefineMinWords = 4,

  -- Free, local cleanup that runs before paste. This is intentionally
  -- conservative: polish transcription artifacts without changing meaning.
  localCleanup = true,

  -- Data-driven cleanup. Put canonical words/phrases in the glossary; put
  -- learned "wrong -> right" replacements in correctionMemoryPath.
  glossaryPath = os.getenv("HOME") .. "/dotfiles/hammerspoon/dictation_glossary.txt",
  correctionMemoryPath = os.getenv("HOME") .. "/dotfiles/hammerspoon/dictation_corrections.tsv",
  snippetsPath = os.getenv("HOME") .. "/dotfiles/hammerspoon/dictation_snippets.tsv",

  -- Spoken editing commands: "new paragraph", "scratch that", "comma",
  -- "open quote", "send" (when dictated alone), etc.
  voiceCommands = true,

  -- Extra local cleanup only for longer rambly takes before the LLM pass.
  longDictationPolish = true,
  longDictationMinWords = 35,

  -- Rejoin short SpeechAnalyzer fragments into sentence-like text.
  joinChoppyFragments = true,

  -- Write short transcript samples into logs so agents can debug actual
  -- capture/cleanup failures. Logs are local and gitignored.
  logTranscriptSamples = true,
  logTranscriptSampleChars = 320,

  -- Show live words in the overlay so the app feels like a live dictation
  -- surface instead of a black-box paste macro.
  showLiveTranscript = true,

  -- Show a small live mic level meter in the pill. Disabled until the daemon
  -- has a crash-safe level source; the visual shell stays small and quiet.
  showInputLevel = true,

  -- Insert a leading space when dictating right after existing text, so
  -- back-to-back takes read "…end of sentence. Next sentence" instead of
  -- "…end of sentence.Next sentence". Asks the accessibility API for the
  -- character before the cursor; falls back to remembering the previous
  -- paste in the same app.
  smartSpacing = true,

  -- If "Finishing…" takes longer than this many seconds, assume the daemon
  -- is wedged: kill it, paste the live transcript anyway, and prewarm a
  -- fresh daemon. (The daemon itself already caps finalize at ~1s; this is
  -- the belt-and-braces layer above it.)
  stopTimeout = 2.5,
  cancelTimeout = 0.8,

  -- Starting should feel instant when the daemon is warm. If CoreAudio gets
  -- stuck while opening the mic, reset quickly instead of leaving the hotkey
  -- in a dead "starting" state.
  startTimeout = 1.8,
  startRetryDelay = 0.35,
  inputSwitchCooldownSeconds = 8.0,
  deviceFailureCooldownSeconds = 45.0,

  pasteDelay = 0.01,   -- wait after writing pasteboard before Cmd+V
  restoreDelay = 0.4,  -- wait after paste before restoring old clipboard
  alertDuration = 2.0,
}

----------------------------------------------------------------
-- STATE
----------------------------------------------------------------
local task = nil            -- hs.task handle for the daemon
local spawnDaemon = nil     -- forward declaration for input watcher
local daemonReady = false
local state = "idle"        -- idle | starting | recording | stopping
local handsFree = false
local pressTime = 0         -- when the current take began (for tap detection)
local pendingStart = false  -- deferred start (waiting for daemon ready)
local stopOnStarted = false -- hold released before "started" arrived
local cancelQuiet = false   -- suppress the "canceled" alert (combo cancels)
local savedClipboard = nil
local stdoutBuf = ""
local lastPartial = ""      -- newest live transcript (for backup/recovery)
local stopReason = nil      -- "finish" | "cancel" — why we entered stopping
local stopWatchdog = nil    -- hs.timer guarding against a wedged "Finishing…"
local startWatchdog = nil   -- hs.timer guarding against a wedged mic start
local disarmStartWatchdog = nil -- forward declaration for daemon restarts
local lastPasteApp = nil    -- app of the previous paste (smart spacing)
local typedSinceLastPaste = false
local inputWatcher = nil
local inputDebounce = nil
local inputSwitchCooldownUntil = 0
local beginAtMs = nil
local startedAtMs = nil
local finishAtMs = nil
local lastStartLatencyMs = nil
local lastFinalizeMs = nil
local lastTakeMs = nil
local lastPasteQueueMs = nil
local lastErrorMessage = nil
local deviceFailureUntil = {}
local profileOverride = hs.settings.get("dictation.profileOverride.v1") or "Auto"
local activeProfile = "Prompt"
local activeTarget = nil
local takeSequence = 0
local pendingDelivery = nil
local contextTermCount = 0
local lastTotalLatencyMs = nil
local lastAILatencyMs = nil
local lastAIModel = nil
local lastAIReason = nil
local recognizerEngine = nil

local function transcriptSample(text)
  if not config.logTranscriptSamples then return nil end
  local cleaned = tostring(text or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  local max = config.logTranscriptSampleChars or 320
  if #cleaned > max then
    cleaned = cleaned:sub(1, max) .. "..."
  end
  return cleaned
end

local function nowMs()
  return math.floor(hs.timer.secondsSinceEpoch() * 1000)
end

local function elapsedMs(sinceMs)
  if not sinceMs then return nil end
  return math.max(0, nowMs() - sinceMs)
end

----------------------------------------------------------------
-- PILL UI — a small bottom-center overlay with a live mic level meter.
----------------------------------------------------------------
local pill = nil
local pillVisible = false
local currentLevel = 0

local PILL_W, PILL_H = 460, 48
local METER_START, METER_BARS = 344, 9

local function pillFrame()
  local f = hs.screen.mainScreen():frame()
  return {
    x = f.x + (f.w - PILL_W) / 2,
    y = f.y + f.h - PILL_H - 76,
    w = PILL_W,
    h = PILL_H,
  }
end

local function showPill(text, live)
  if not pill then
    pill = hs.canvas.new(pillFrame())
    pill:level(hs.canvas.windowLevels.overlay)
    pill:behavior({ "canJoinAllSpaces", "stationary" })
    pill[1] = {
      type = "rectangle",
      action = "strokeAndFill",
      roundedRectRadii = { xRadius = 13, yRadius = 13 },
      fillColor = { red = 0.035, green = 0.039, blue = 0.047, alpha = 0.92 },
      strokeColor = { red = 0.42, green = 0.78, blue = 1, alpha = 0.22 },
      strokeWidth = 1,
    }
    pill[2] = { -- recording dot
      type = "rectangle",
      action = "strokeAndFill",
      frame = { x = 14, y = 13, w = 22, h = 22 },
      roundedRectRadii = { xRadius = 11, yRadius = 11 },
      strokeColor = { white = 1, alpha = 0.1 },
      strokeWidth = 1,
      fillColor = { red = 0.95, green = 0.23, blue = 0.19, alpha = 1 },
    }
    pill[3] = { -- inner recording dot
      type = "circle",
      center = { x = 25, y = PILL_H / 2 },
      radius = 5,
      action = "fill",
      fillColor = { red = 0.95, green = 0.23, blue = 0.19, alpha = 1 },
    }
    pill[4] = { -- transcript text
      type = "text",
      frame = { x = 48, y = (PILL_H - 24) / 2 - 1, w = 280, h = 26 },
      text = "",
      textSize = 14,
      textColor = { white = 1, alpha = 0.95 },
      textLineBreak = "truncateHead", -- keep the most recent words visible
    }
    for i = 1, METER_BARS do
      pill[4 + i] = {
        type = "rectangle",
        action = "fill",
        frame = {
          x = METER_START + ((i - 1) * 11),
          y = (PILL_H - 5) / 2,
          w = 6,
          h = 5,
        },
        roundedRectRadii = { xRadius = 3, yRadius = 3 },
        fillColor = { red = 0.35, green = 0.78, blue = 1, alpha = 0.16 },
      }
    end
  end
  -- Partials arrive many times a second; only re-place the pill when it
  -- comes on screen, not on every text update.
  if not pillVisible then
    pill:frame(pillFrame())
  end
  pill[2].fillColor =
    live and { red = 0.95, green = 0.23, blue = 0.19, alpha = 1 }
      or { red = 0.22, green = 0.26, blue = 0.31, alpha = 1 }
  pill[3].fillColor =
    live and { red = 1, green = 1, blue = 1, alpha = 0.92 }
      or { red = 0.35, green = 0.78, blue = 1, alpha = 0.9 }
  pill[4].text = text
  pill[4].textColor = { white = 1, alpha = live and 0.96 or 0.72 }
  for i = 1, METER_BARS do
    local bar = pill[4 + i]
    local threshold = i / METER_BARS
    local lit = live and config.showInputLevel and currentLevel >= threshold
    local height = lit and (8 + (i % 4) * 4) or 5
    bar.frame = {
      x = METER_START + ((i - 1) * 11),
      y = (PILL_H - height) / 2,
      w = 6,
      h = height,
    }
    bar.fillColor = lit
      and { red = 0.35, green = 0.78, blue = 1, alpha = 0.86 }
      or { red = 0.35, green = 0.78, blue = 1, alpha = live and 0.18 or 0.1 }
  end
  if not pillVisible then
    pill:show()
    pillVisible = true
  end
end

local function updatePillLevel(level)
  currentLevel = math.max(0, math.min(1, tonumber(level) or 0))
  if pillVisible and state == "recording" then
    showPill(pill[4].text or "Listening", true)
  end
end

local function hidePill()
  if pill then pill:hide() end
  currentLevel = 0
  pillVisible = false
end

----------------------------------------------------------------
-- LOCAL TRANSCRIPT CLEANUP
----------------------------------------------------------------

local function trim(s)
  local cleaned = (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
  return cleaned
end

local function lowerFirst(s)
  local cleaned = s:gsub("^([\"'(%[]*)(%u)", function(prefix, c)
    return prefix .. c:lower()
  end)
  return cleaned
end

local function sentenceCase(s)
  local cleaned = s:gsub("^([\"'(%[]*)(%l)", function(prefix, c)
    return prefix .. c:upper()
  end)
  return cleaned
end

local function wordCount(s)
  local n = 0
  for _ in s:gmatch("%S+") do n = n + 1 end
  return n
end

local function transcriptLogFields(text)
  local fields = {
    chars = #(text or ""),
    words = wordCount(text or ""),
  }
  local sample = transcriptSample(text)
  if sample and sample ~= "" then fields.sample = sample end
  return fields
end

local function splitList(s)
  local out = {}
  for item in (s or ""):gmatch("[^,|]+") do
    local cleaned = trim(item)
    if cleaned ~= "" then out[#out + 1] = cleaned end
  end
  return out
end

local function charPattern(c)
  if c:match("%a") then
    return "[" .. c:lower() .. c:upper() .. "]"
  end
  if c:match("%s") then return "%s+" end
  return (c:gsub("([^%w])", "%%%1"))
end

local function phrasePattern(phrase)
  local parts = {}
  for i = 1, #phrase do
    parts[#parts + 1] = charPattern(phrase:sub(i, i))
  end
  return "%f[%w]" .. table.concat(parts) .. "%f[%W]"
end

local function readLines(path)
  local f = io.open(path or "", "r")
  if not f then return {} end
  local lines = {}
  for line in f:lines() do lines[#lines + 1] = line end
  f:close()
  return lines
end

local function loadGlossaryReplacements()
  local replacements = {
    { from = "right command", to = "Right Command" },
    { from = "whisper flow", to = "Wispr Flow" },
    { from = "whisperflow", to = "Wispr Flow" },
    { from = "wisper flow", to = "Wispr Flow" },
    { from = "more liable", to = "more reliable" },
  }

  for _, line in ipairs(readLines(config.glossaryPath)) do
    local cleaned = trim((line:gsub("#.*$", "")))
    if cleaned ~= "" then
      local canonical, variants = cleaned:match("^(.-)%s*=%s*(.+)$")
      if not canonical then canonical, variants = cleaned:match("^(.-)%s*=>%s*(.+)$") end
      if canonical then
        canonical = trim(canonical)
        for _, variant in ipairs(splitList(variants)) do
          replacements[#replacements + 1] = { from = variant, to = canonical }
        end
      else
        replacements[#replacements + 1] = { from = cleaned, to = cleaned }
      end
    end
  end

  for _, line in ipairs(readLines(config.correctionMemoryPath)) do
    local cleaned = trim((line:gsub("#.*$", "")))
    if cleaned ~= "" then
      local from, to = cleaned:match("^(.-)\t(.+)$")
      if not from then from, to = cleaned:match("^(.-)%s*=>%s*(.+)$") end
      if from and to then
        replacements[#replacements + 1] = { from = trim(from), to = trim(to) }
      end
    end
  end

  table.sort(replacements, function(a, b)
    return #a.from > #b.from
  end)
  return replacements
end

local function applyPhraseReplacements(text)
  for _, r in ipairs(loadGlossaryReplacements()) do
    if r.from ~= "" and r.to ~= "" and r.from ~= r.to then
      text = text:gsub(phrasePattern(r.from), function() return r.to end)
    end
  end
  return text
end

local function appendCorrection(from, to)
  from, to = trim(from), trim(to)
  if from == "" or to == "" or from:lower() == to:lower() then
    return false
  end
  local f = io.open(config.correctionMemoryPath, "a")
  if not f then return false end
  f:write(from, "\t", to, "\n")
  f:close()
  return true
end

local function applyScratchThat(text)
  if not config.voiceCommands then return text end
  text = text:gsub("^.*%f[%a][Ss]cratch all that%f[%A][,%.%!%?%s]*", "")
  text = text:gsub("^.*%f[%a][Nn]ever mind%f[%A][,%.%!%?%s]*", "")

  while true do
    local s, e = text:find("%f[%a][Ss]cratch that%f[%A]")
    if not s then s, e = text:find("%f[%a][Dd]elete that%f[%A]") end
    if not s then break end

    local before = text:sub(1, s - 1):gsub("[%s,%.%!%?;:]+$", "")
    local after = text:sub(e + 1):gsub("^[%s,%.%!%?;:]+", "")
    local cut = 0
    local pos = 1
    while true do
      local _, boundaryEnd = before:find("[%.%!%?]%s*", pos)
      if not boundaryEnd then break end
      cut = boundaryEnd
      pos = boundaryEnd + 1
    end
    if cut == 0 then
      pos = 1
      while true do
        local _, boundaryEnd = before:find("[,;:]%s*", pos)
        if not boundaryEnd then break end
        cut = boundaryEnd
        pos = boundaryEnd + 1
      end
    end
    before = trim(before:sub(1, cut))
    text = trim((before ~= "" and (before .. " ") or "") .. after)
  end
  return text
end

local function applyVoiceCommands(text)
  if not config.voiceCommands then return text end
  text = applyScratchThat(text)
  text = text
    :gsub("%f[%a][Nn]ew paragraph%f[%A]", "\n\n")
    :gsub("%f[%a][Nn]ew line%f[%A]", "\n")
    :gsub("%f[%a][Ll]ine break%f[%A]", "\n")
    :gsub("%f[%a][Oo]pen quote%f[%A]", "\"")
    :gsub("%f[%a][Cc]lose quote%f[%A]", "\"")
    :gsub("%f[%a][Ee]nd quote%f[%A]", "\"")
    :gsub("%f[%a][Oo]pen paren%f[%A]", "(")
    :gsub("%f[%a][Cc]lose paren%f[%A]", ")")
    :gsub("%f[%a][Oo]pen parenthesis%f[%A]", "(")
    :gsub("%f[%a][Cc]lose parenthesis%f[%A]", ")")
    :gsub("%f[%a][Qq]uestion mark%f[%A]", "?")
    :gsub("%f[%a][Ee]xclamation point%f[%A]", "!")
    :gsub("%f[%a][Ee]xclamation mark%f[%A]", "!")
    :gsub("%f[%a][Ss]emicolon%f[%A]", ";")
    :gsub("%f[%a][Cc]olon%f[%A]", ":")
    :gsub("%f[%a][Cc]omma%f[%A]", ",")
    :gsub("%f[%a][Pp]eriod%f[%A]", ".")
    :gsub("%f[%a][Ff]ull stop%f[%A]", ".")
    :gsub("[ \t]+([,%.%!%?%;:%)])", "%1")
    :gsub("([%(])%s+", "%1")
    :gsub("([\"%(])%s+", "%1")
    :gsub("[ \t]+([\"%)])", "%1")
  return text
end

local function polishLongDictation(text)
  if not config.longDictationPolish then return text end
  if wordCount(text) < (config.longDictationMinWords or 35) then return text end

  text = text
    :gsub("[, ]+%f[%a][Uu]h%f[%A][, ]+", " ")
    :gsub("[, ]+%f[%a][Uu]m%f[%A][, ]+", " ")
    :gsub("[, ]+%f[%a][Ee]r%f[%A][, ]+", " ")
    :gsub("%f[%a][Yy]ou know,%s*", "")
    :gsub("%f[%a][Ii] mean,%s*", "")
    :gsub("%f[%a][Ii]'m gonna%f[%A]", "I'm going to")
    :gsub("%f[%a][Ii]m gonna%f[%A]", "I'm going to")
    :gsub("%f[%a][Gg]onna%f[%A]", "going to")
    :gsub("%f[%a][Ww]anna%f[%A]", "want to")
    :gsub("%f[%a][Uu]se,%s+[Uu]se%s+", "Use ")
    :gsub("%f[%a][Tt]he,%s+([Ii] like)%f[%A]", "%1")
    :gsub("%f[%a]on long,%s+sessions%f[%A]", "on long sessions")
    :gsub(",%s+([Aa]nd)%s+", " %1 ")
    :gsub(",%s+([Bb]ut)%s+", " %1 ")
    :gsub(",%s+([Oo]r)%s+", " %1 ")
    :gsub(",%s+([Ss]o)%s+", " %1 ")
    :gsub(",%s+([Bb]ecause)%s+", " %1 ")
    :gsub(",%s+([Ww]hen)%s+", " %1 ")
    :gsub(",%s+([Ii]f)%s+", " %1 ")
    :gsub(",%s+([Ww]hile)%s+", " %1 ")
    :gsub("[ \t]+", " ")
  return text
end

local function isStandaloneFragment(s)
  local compact = trim(s):lower():gsub("[%.%!%?]+$", "")
  local standalone = {
    ok = true, okay = true, yes = true, no = true, thanks = true,
    ["thank you"] = true, sure = true, great = true,
  }
  return standalone[compact] or false
end

local function shouldJoinFragment(s)
  local compact = trim(s):lower()
  if compact == "" then return false end
  if isStandaloneFragment(compact) then
    return false
  end
  if compact:match("^[\"']") then return false end
  if wordCount(compact) <= 2 then return true end
  local first = compact:match("^(%a+)")
  local joinStarters = {
    ["and"] = true, ["but"] = true, ["or"] = true, so = true,
    because = true, with = true, without = true, to = true, ["for"] = true,
    from = true, of = true, ["in"] = true, on = true, as = true,
    that = true, which = true,
  }
  return joinStarters[first] or false
end

local function joinChoppyFragments(text)
  local out = {}
  local pos = 1
  while true do
    local s, e, seg, punc = text:find("([^%.%!%?]+)([%.%!%?])", pos)
    if not s then break end
    local fragment = trim(seg)
    if fragment ~= "" then
      if #out > 0 and shouldJoinFragment(fragment)
          and not isStandaloneFragment(out[#out]) then
        out[#out] = out[#out]:gsub("[%。%.%!%?]+$", "") ..
          ", " .. lowerFirst(fragment) .. punc
      else
        out[#out + 1] = sentenceCase(fragment) .. punc
      end
    end
    pos = e + 1
  end

  local tail = trim(text:sub(pos))
  if tail ~= "" then
    if #out > 0 and shouldJoinFragment(tail)
        and not isStandaloneFragment(out[#out]) then
      out[#out] = out[#out]:gsub("[%。%.%!%?]+$", "") ..
        ", " .. lowerFirst(tail)
    else
      out[#out + 1] = sentenceCase(tail)
    end
  end

  if #out == 0 then return text end
  return table.concat(out, " ")
end

local function joinChoppyParagraphs(text)
  if not text:find("\n") then return joinChoppyFragments(text) end
  local out = {}
  for para in (text .. "\n\n"):gmatch("(.-)\n\n") do
    out[#out + 1] = joinChoppyFragments(para)
  end
  return table.concat(out, "\n\n")
end

local function cleanupTranscript(text)
  if not config.localCleanup then return text end
  return core.cleanupTranscript(text, {
    glossaryPath = config.glossaryPath,
    correctionsPath = config.correctionMemoryPath,
    snippetsPath = config.snippetsPath,
    voiceCommands = config.voiceCommands,
  })
end

----------------------------------------------------------------
-- SOUNDS
----------------------------------------------------------------
local function play(name)
  if not name then return end
  local s = hs.sound.getByName(name)
  if s then s:play() end
end

local function deviceFields(dev)
  if not dev then return {} end
  return {
    input = dev:name(),
    uid = dev:uid(),
  }
end

local function quarantineInputDevice(dev, reason)
  if not dev then return end
  local uid = dev:uid()
  if not uid then return end
  local untilTs = hs.timer.secondsSinceEpoch()
    + (config.deviceFailureCooldownSeconds or 45)
  deviceFailureUntil[uid] = untilTs
  local fields = deviceFields(dev)
  fields.reason = reason
  fields.cooldownSeconds = config.deviceFailureCooldownSeconds
  log.warn("temporarily avoiding input device", fields)
end

local function deviceAvailable(dev)
  if not dev or dev:inputMuted() == true then return false end
  local uid = dev:uid()
  local blockedUntil = uid and deviceFailureUntil[uid] or nil
  if blockedUntil and blockedUntil > hs.timer.secondsSinceEpoch() then
    return false
  end
  if blockedUntil then deviceFailureUntil[uid] = nil end
  return true
end

local function preferredInputDevice()
  local wantedNames = {}
  if type(config.preferredInputDevices) == "table" then
    for _, name in ipairs(config.preferredInputDevices) do
      if type(name) == "string" and name ~= "" then
        wantedNames[#wantedNames + 1] = name
      end
    end
  end
  if type(config.preferredInputDevice) == "string"
      and config.preferredInputDevice ~= "" then
    table.insert(wantedNames, 1, config.preferredInputDevice)
  end
  if #wantedNames == 0 then return nil end

  local devices = hs.audiodevice.allInputDevices()
  for _, wanted in ipairs(wantedNames) do
    for _, dev in ipairs(devices) do
      if dev:name() == wanted and deviceAvailable(dev) then
        return dev
      end
    end
  end
  return nil
end

local function setDefaultInputDevice(dev, reason)
  local current = hs.audiodevice.defaultInputDevice()
  if not dev then return false end
  if current and current:uid() == dev:uid() then return false end

  local ok, result = pcall(function()
    return dev:setDefaultInputDevice()
  end)
  local after = hs.audiodevice.defaultInputDevice()
  local stuck = after and after:uid() == dev:uid()
  if not ok or not stuck then
    local fields = deviceFields(dev)
    fields.reason = reason
    fields.result = result
    fields.current = after and after:name() or nil
    log.warn("preferred input did not stick", fields)
    return false
  end

  log.info("default input changed", {
    reason = reason,
    from = current and current:name() or nil,
    to = dev:name(),
  })
  return true
end

local function selectPreferredInput(reason)
  local current = hs.audiodevice.defaultInputDevice()
  local preferred = preferredInputDevice()
  if not preferred then return false end
  if current and current:uid() == preferred:uid() then return false end
  return setDefaultInputDevice(preferred, reason or "select preferred")
end

local function stopDaemonForInputSwitch()
  if task then
    log.warn("stopping daemon for input switch")
    local old = task
    task = nil
    daemonReady = false
    stdoutBuf = ""
    if disarmStartWatchdog then disarmStartWatchdog() end
    old:terminate()
  end
end

local function ensurePreferredInput(allowRestart)
  local current = hs.audiodevice.defaultInputDevice()
  local preferred = preferredInputDevice()
  if not preferred then return false end
  if current and current:uid() == preferred:uid() then return false end

  if task and not allowRestart then
    if setDefaultInputDevice(preferred, "daemon hot reassert") then
      inputSwitchCooldownUntil = hs.timer.secondsSinceEpoch()
        + (config.inputSwitchCooldownSeconds or 8.0)
      log.warn("preferred input drifted while daemon hot; reasserted without restart", {
        from = current and current:name() or nil,
        preferred = preferred:name(),
      })
    end
    return false
  end

  stopDaemonForInputSwitch()
  return setDefaultInputDevice(preferred,
    allowRestart and "begin/restart" or "idle")
end

local function maintainPreferredInput()
  if state ~= "idle" then return end
  local now = hs.timer.secondsSinceEpoch()
  if now < inputSwitchCooldownUntil then
    log.debug("input switch cooldown active", {
      remainingMs = math.floor((inputSwitchCooldownUntil - now) * 1000),
    })
    hs.timer.doAfter(inputSwitchCooldownUntil - now + 0.25, maintainPreferredInput)
    return
  end
  local changed = ensurePreferredInput(false)
  if changed then
    inputSwitchCooldownUntil = now + (config.inputSwitchCooldownSeconds or 8.0)
    log.info("input watcher changed device; respawning daemon after debounce")
    hs.timer.doAfter(1.5, function()
      if state == "idle" then spawnDaemon() end
    end)
  end
end

local function startInputWatcher()
  if inputWatcher then return end
  hs.audiodevice.watcher.setCallback(function()
    log.debug("audio device watcher fired")
    if inputDebounce then inputDebounce:stop() end
    inputDebounce = hs.timer.doAfter(1.25, maintainPreferredInput)
  end)
  hs.audiodevice.watcher.start()
  inputWatcher = hs.audiodevice.watcher
end

----------------------------------------------------------------
-- ESC-TO-CANCEL (only active while recording)
----------------------------------------------------------------
local escHotkey = nil

local function bindEsc()
  if not escHotkey then
    escHotkey = hs.hotkey.new({}, "escape", function() M.cancel() end)
  end
  escHotkey:enable()
end

local function unbindEsc()
  if escHotkey then escHotkey:disable() end
end

----------------------------------------------------------------
-- PASTE
----------------------------------------------------------------

-- Should the transcript get a leading space? True when the character just
-- before the cursor is a non-space (we'd butt up against existing text).
local function needsLeadingSpace()
  -- Precise path: ask accessibility what's immediately before the cursor.
  local ok, verdict = pcall(function()
    local focused = hs.axuielement.systemWideElement()
      :attributeValue("AXFocusedUIElement")
    if not focused then return nil end
    local range = focused:attributeValue("AXSelectedTextRange")
    local loc = range and (range.location or range.loc)
    if not loc then return nil end
    if loc == 0 then return false end -- start of the field
    local prev = focused:parameterizedAttributeValue("AXStringForRange",
      { location = loc - 1, length = 1 })
    if type(prev) ~= "string" or prev == "" then return nil end
    return prev:match("%s") == nil
  end)
  if ok and verdict ~= nil then return verdict end
  -- Fallback (app doesn't speak AX): back-to-back dictations into the same
  -- app with no typing in between almost certainly need the space.
  local app = hs.application.frontmostApplication()
  local name = app and app:name() or nil
  return name ~= nil and name == lastPasteApp and not typedSinceLastPaste
end

local function captureTarget()
  local app = hs.application.frontmostApplication()
  local focused = nil
  pcall(function()
    focused = hs.axuielement.systemWideElement():attributeValue("AXFocusedUIElement")
  end)
  return {
    pid = app and app:pid() or nil,
    app = app and app:name() or nil,
    focusedField = focused,
  }
end

local function pasteTranscript(text, target)
  target = target or activeTarget
  local front = hs.application.frontmostApplication()
  local targetStillFront = target and front and target.pid == front:pid()
  -- Smart spacing: only when the transcript starts like prose (not when
  -- the user dictated leading punctuation).
  if targetStillFront and config.smartSpacing
      and text:match("^[%w\"'(]") and needsLeadingSpace() then
    text = " " .. text
  end
  local pasteQueuedAtMs = nowMs()
  local fields = transcriptLogFields(text)
  fields.finalizeMs = lastFinalizeMs
  fields.takeMs = lastTakeMs
  log.info("pasting transcript", fields)
  local restoreTo = nil
  if not config.keepOnClipboard then
    restoreTo = savedClipboard
  end
  hs.pasteboard.setContents(text)
  hs.timer.doAfter(config.pasteDelay, function()
    local current = hs.application.frontmostApplication()
    if not target or not current or current:pid() ~= target.pid then
      lastPasteQueueMs = elapsedMs(pasteQueuedAtMs)
      lastTotalLatencyMs = elapsedMs(finishAtMs)
      lastAIReason = lastAIReason or "target_changed_clipboard"
      log.warn("paste withheld; target application changed", {
        target = target and target.app or nil,
        frontmost = current and current:name() or nil,
        pasteQueueMs = lastPasteQueueMs,
      })
      hs.alert.show("Dictation ready—clipboard", 1.2)
      return
    end
    hs.eventtap.keyStroke({ "cmd" }, "v", 0)
    local app = hs.application.frontmostApplication()
    lastPasteApp = app and app:name() or nil
    lastPasteQueueMs = elapsedMs(pasteQueuedAtMs)
    lastTotalLatencyMs = elapsedMs(finishAtMs)
    log.info("paste keystroke sent", {
      app = lastPasteApp,
      pasteQueueMs = lastPasteQueueMs,
    })
    -- Our own synthetic ⌘V trips the typed-flag; clear it once it lands.
    hs.timer.doAfter(0.3, function() typedSinceLastPaste = false end)
    if restoreTo then
      hs.timer.doAfter(config.restoreDelay, function()
        hs.pasteboard.setContents(restoreTo)
      end)
    end
  end)
end

local function handleDictationCommand(text)
  if not config.voiceCommands then return false end
  local command = trim(text):gsub("[%.%!%?]+$", "")
  local compact = command:lower()

  if compact == "send" or compact == "send it" then
    log.info("voice command handled", { command = compact })
    hidePill()
    play(config.soundStop)
    hs.eventtap.keyStroke({}, "return", 0)
    return true
  end

  if compact == "cancel" or compact == "cancel that"
      or compact == "never mind" or compact == "scratch all that" then
    log.info("voice command handled", { command = compact })
    hidePill()
    play(config.soundStop)
    return true
  end

  local from, to = command:match("^[Rr]emember correction%s+(.+)%s+[Tt]o%s+(.+)$")
  if not from then
    from, to = command:match("^[Cc]orrect%s+(.+)%s+[Tt]o%s+(.+)$")
  end
  if from and to then
    local ok = appendCorrection(from, to)
    if ok and task then task:setInput("reload-context\n") end
    log.info("voice correction command", {
      from = from,
      to = to,
      saved = ok,
    })
    hidePill()
    play(config.soundStop)
    hs.alert.show(ok and "Dictation learned correction"
      or "Dictation could not save correction", 1.2)
    return true
  end

  return false
end

local LIGHT_CLEANUP_INSTRUCTIONS =
  "You are a conservative speech-to-text cleanup pass. Return only the "
  .. "corrected transcript. Add natural punctuation and capitalization. "
  .. "Correct an obvious speech-recognition error only when the surrounding "
  .. "sentence makes the intended wording highly likely. Resolve explicit "
  .. "backtracking: when the speaker says actually no, let me change that, "
  .. "scratch that, never mind, what I mean is, or let me rephrase, delete "
  .. "the abandoned wording and correction cue while keeping only the "
  .. "replacement wording. Example: Input: Let us meet at five actually no "
  .. "let me change that six. Output: Let us meet at six. Otherwise preserve "
  .. "every claim, name, number, negation, modal verb, and content word. Do "
  .. "not paraphrase, summarize, reorganize, or make the writing more concise. "
  .. "If uncertain, leave the wording unchanged."

local function flushPendingDelivery(reason)
  local pending = pendingDelivery
  if not pending then return end
  pendingDelivery = nil
  pending.valid = false
  lastAIReason = reason or "superseded"
  pasteTranscript(pending.localText, pending.target)
end

-- Deliver a finished transcript: run it through the LLM refiner when
-- enabled (pill shows progress), pasting the raw text on any failure or
-- timeout so words are never lost — just less polished.
local function deliverTranscript(text)
  log.info("delivering raw transcript", transcriptLogFields(text))
  if handleDictationCommand(text) then return end
  local rawText = text
  local cleanupMeta
  text, cleanupMeta = core.cleanupTranscript(text, {
    glossaryPath = config.glossaryPath,
    correctionsPath = config.correctionMemoryPath,
    snippetsPath = config.snippetsPath,
    voiceCommands = config.voiceCommands,
    lightCleanup = activeProfile ~= "Literal",
  })
  if text ~= rawText then
    log.info("local cleanup changed transcript", {
      raw = transcriptLogFields(rawText),
      cleaned = transcriptLogFields(text),
    })
  else
    log.info("local cleanup kept transcript", transcriptLogFields(text))
  end
  if handleDictationCommand(text) then return end
  local refine = nil
  local shouldPolish, skipReason = core.shouldUseAI(text, activeProfile)
  if not config.autoRefine then shouldPolish, skipReason = false, "disabled" end
  if cleanupMeta and cleanupMeta.snippet then
    shouldPolish, skipReason = false, "snippet"
  end
  if shouldPolish then
    local ok, mod = pcall(require, "refine")
    if ok and type(mod) == "table" and type(mod.refineText) == "function" then
      refine = mod
    else
      skipReason = ok and "refine_unavailable" or tostring(mod)
    end
  end
  if not refine then
    log.info("pasting without polish", {
      autoRefine = config.autoRefine,
      reason = skipReason,
      chars = #text,
      words = wordCount(text),
      profile = activeProfile,
    })
    hidePill()
    play(config.soundStop)
    lastAIReason = skipReason
    pasteTranscript(text, activeTarget)
    return
  end

  hs.pasteboard.setContents(text) -- local backup while we wait
  local polishStartMs = nowMs()
  takeSequence = takeSequence + 1
  local pending = {
    id = takeSequence,
    localText = text,
    target = activeTarget,
    valid = true,
  }
  pendingDelivery = pending
  log.info("starting dictation polish", {
    takeId = pending.id, profile = activeProfile, chars = #text,
  })

  local done = false
  local timeout = nil
  local polishPill = hs.timer.doAfter(0.35, function()
    if pendingDelivery == pending and pending.valid then
      showPill("Polishing...", false)
    end
  end)
  local function finishWith(result, reason, meta)
    if done or not pending.valid or pendingDelivery ~= pending then return end
    done = true
    pendingDelivery = nil
    if timeout then timeout:stop() end
    if polishPill then polishPill:stop() end
    if state == "idle" then hidePill() end -- don't clobber a new take's pill
    play(config.soundStop)
    lastAILatencyMs = elapsedMs(polishStartMs)
    lastAIModel = meta and meta.model or lastAIModel
    lastAIReason = reason or (meta and meta.fallbackReason) or nil
    if result ~= text then
      log.info("dictation polish finished", {
        input = transcriptLogFields(text),
        output = transcriptLogFields(result),
        polishMs = elapsedMs(polishStartMs),
      })
    else
      local fields = transcriptLogFields(text)
      fields.polishMs = elapsedMs(polishStartMs)
      log.info("dictation polish returned raw", fields)
    end
    pasteTranscript(result, pending.target)
  end

  timeout = hs.timer.doAfter(config.autoRefineTimeout, function()
    log.warn("dictation polish timed out", {
      timeoutSeconds = config.autoRefineTimeout,
      chars = #text,
    })
    finishWith(text, "timeout")
  end)
  refine.refineText(text,
    function(result, meta)
      local accepted, rejectReason = core.validateAIOutput(text, result)
      if not accepted then
        log.warn("dictation polish rejected", { reason = rejectReason, takeId = pending.id })
        finishWith(text, "rejected:" .. rejectReason, meta)
      else
        finishWith(result, nil, meta)
      end
    end,
    function(msg)
      if not done then
        log.error("dictation polish failed", { message = msg, chars = #text })
        hs.alert.show("Refine failed — pasting raw (" .. msg .. ")", 1.5)
      end
      finishWith(text, "api_failure:" .. tostring(msg))
    end, {
      systemPrompt = LIGHT_CLEANUP_INSTRUCTIONS,
      maxOutputTokens = core.maxOutputTokens(text),
    })
end

----------------------------------------------------------------
-- DAEMON MANAGEMENT
----------------------------------------------------------------
local handleEvent -- forward decl

local function onStdout(_, chunk)
  stdoutBuf = stdoutBuf .. (chunk or "")
  while true do
    local nl = stdoutBuf:find("\n", 1, true)
    if not nl then break end
    local line = stdoutBuf:sub(1, nl - 1)
    stdoutBuf = stdoutBuf:sub(nl + 1)
    if line ~= "" then
      local ok, event = pcall(hs.json.decode, line)
      if ok and type(event) == "table" then
        handleEvent(event)
      else
        log.error("daemon emitted invalid json", { line = line })
      end
    end
  end
  return true
end

local function onStderr(chunk)
  if chunk and chunk ~= "" then
    log.error("daemon stderr", { message = chunk:gsub("%s+$", "") })
  end
end

local function onExit(_, code)
  log.warn("daemon exited", { code = code, state = state, stopReason = stopReason })
  local exitStopReason = stopReason
  task = nil
  daemonReady = false
  handsFree = false
  pendingStart = false
  stopOnStarted = false
  stopReason = nil
  if stopWatchdog then stopWatchdog:stop(); stopWatchdog = nil end
  if disarmStartWatchdog then disarmStartWatchdog() end
  if state ~= "idle" then
    local wasStopping = (state == "stopping")
    state = "idle"
    hidePill()
    unbindEsc()
    -- Salvage the take: the live transcript was streamed to us, so a dead
    -- daemon never loses words.
    if lastPartial ~= "" then
      log.warn("salvaging transcript after daemon exit", transcriptLogFields(lastPartial))
      if wasStopping and exitStopReason == "finish" then
        play(config.soundStop)
        pasteTranscript(lastPartial)
      else
        hs.pasteboard.setContents(lastPartial)
      end
    end
    hs.alert.show("Dictation daemon exited (code " .. tostring(code) ..
      (lastPartial ~= "" and ") — transcript saved to clipboard" or ")"),
      config.alertDuration)
  end
end

spawnDaemon = function()
  if task then return true end
  if not hs.fs.attributes(config.binary) then
    log.error("daemon binary missing", { binary = config.binary })
    hs.alert.show(
      "Dictation: " .. config.binary .. " not found.\n" ..
      "Build it: ~/dotfiles/hammerspoon/hs-dictate/build.sh",
      4)
    return false
  end
  daemonReady = false
  stdoutBuf = ""
  local args = { config.locale,
    "--idle", tostring(config.micIdleSeconds or 180),
    "--glossary", config.glossaryPath,
    "--corrections", config.correctionMemoryPath }
  if config.fastResults then table.insert(args, "--fast") end
  if config.punctuation then
    table.insert(args, "--punctuation")
  end
  local input = hs.audiodevice.defaultInputDevice()
  table.insert(args, "--content-hint")
  table.insert(args, input and input:name() == "Insta360 Link 2C"
    and "far-field" or "default")
  log.info("spawning daemon", {
    binary = config.binary,
    locale = config.locale,
    idle = config.micIdleSeconds,
    fast = config.fastResults,
    punctuation = config.punctuation,
  })
  -- Callbacks are gated on identity: after a watchdog kill-and-respawn, a
  -- late callback from the old daemon must not touch the new one's state.
  local t
  t = hs.task.new(config.binary,
    function(code)
      if task == t then onExit(nil, code) end
    end,
    function(_, so, se)
      if task == t then
        onStderr(se)
        return onStdout(nil, so)
      end
      return false
    end,
    args)
  if not t or not t:start() then
    log.error("daemon launch failed", { binary = config.binary })
    hs.alert.show("Dictation: failed to launch daemon", config.alertDuration)
    return false
  end
  task = t
  log.info("daemon task started", { pid = t:pid() })
  return true
end

local function send(cmd)
  if task then task:setInput(cmd .. "\n") end
end

----------------------------------------------------------------
-- STOP WATCHDOG — "Finishing…" must never hang.
--
-- The daemon already caps finalize at ~1s internally; this layer covers a
-- fully wedged daemon: kill it, paste the live transcript we streamed
-- during the take, and prewarm a replacement.
----------------------------------------------------------------
local function disarmWatchdog()
  if stopWatchdog then
    stopWatchdog:stop()
    stopWatchdog = nil
  end
end

local function restartDaemonSoon(reason, delay)
  log.warn("restarting daemon", { reason = reason, delay = delay or 0.5 })
  local old = task
  task = nil
  daemonReady = false
  stdoutBuf = ""
  pendingStart = false
  stopOnStarted = false
  stopReason = nil
  handsFree = false
  state = "idle"
  hidePill()
  unbindEsc()
  disarmWatchdog()
  if disarmStartWatchdog then disarmStartWatchdog() end
  if old then
    local pid = old:pid()
    old:terminate()
    hs.timer.doAfter(1.0, function()
      if pid and pid > 0 then
        hs.execute("kill -9 " .. pid .. " 2>/dev/null")
      end
    end)
  end
  hs.timer.doAfter(delay or 0.5, function()
    if state == "idle" then spawnDaemon() end
  end)
end

disarmStartWatchdog = function()
  if startWatchdog then
    startWatchdog:stop()
    startWatchdog = nil
  end
end

local function armStartWatchdog()
  disarmStartWatchdog()
  startWatchdog = hs.timer.doAfter(config.startTimeout, function()
    startWatchdog = nil
    if state ~= "starting" then return end
    local currentInput = hs.audiodevice.defaultInputDevice()
    lastErrorMessage = "start timeout"
    log.error("start watchdog fired", {
      timeoutSeconds = config.startTimeout,
      beginMs = elapsedMs(beginAtMs),
      input = currentInput and currentInput:name() or nil,
    })
    restartDaemonSoon("start timeout", config.startRetryDelay)
    hs.alert.show("Dictation mic reset — try again", 1.0)
  end)
end

local function armWatchdog(timeoutSeconds)
  disarmWatchdog()
  local deadline = timeoutSeconds or config.stopTimeout
  stopWatchdog = hs.timer.doAfter(deadline, function()
    stopWatchdog = nil
    if state ~= "stopping" then return end
    log.error("stop watchdog fired", {
      stopReason = stopReason,
      timeoutSeconds = deadline,
      lastPartial = transcriptLogFields(lastPartial),
    })
    local reason = stopReason
    local wasCancel = (reason == "cancel")
    local wasQuiet = cancelQuiet
    state = "idle"
    stopReason = nil
    cancelQuiet = false
    hidePill()
    unbindEsc()
    -- Detach the wedged daemon first so its exit callback is a no-op and
    -- spawnDaemon() can't be blocked by it, then kill it (hard, if needed).
    local dead = task
    task = nil
    daemonReady = false
    if dead then
      local pid = dead:pid()
      dead:terminate()
      hs.timer.doAfter(1.0, function()
        if pid and pid > 0 then
          hs.execute("kill -9 " .. pid .. " 2>/dev/null")
        end
      end)
    end
    if reason == "finish" and lastPartial ~= "" then
      play(config.soundStop)
      pasteTranscript(lastPartial)
    end
    if not wasCancel or not wasQuiet then
      hs.alert.show("Dictation recovered (daemon restarted)", 1.2)
    end
    hs.timer.doAfter(0.5, function() spawnDaemon() end)
  end)
end

----------------------------------------------------------------
-- EVENTS FROM THE DAEMON
----------------------------------------------------------------
handleEvent = function(event)
  local e = event.event

  if e == "ready" then
    contextTermCount = tonumber(event.contextCount) or contextTermCount
    recognizerEngine = event.engine or recognizerEngine
    log.info("daemon ready", {
      contextTerms = contextTermCount, engine = recognizerEngine,
    })
    daemonReady = true
    if pendingStart then
      pendingStart = false
      M.begin()
      -- Caps was released while the daemon warmed up, so a hold can't be in
      -- progress — treat the deferred take as hands-free.
      handsFree = true
    end

  elseif e == "downloading" then
    log.info("daemon downloading speech model", { message = event.message })
    hs.alert.show("Dictation: downloading speech model…", 3)

  elseif e == "started" then
    startedAtMs = nowMs()
    lastStartLatencyMs = elapsedMs(beginAtMs)
    lastErrorMessage = nil
    disarmStartWatchdog()
    log.info("recording started", {
      handsFree = handsFree,
      startLatencyMs = lastStartLatencyMs,
    })
    state = "recording"
    play(config.soundStart)
    showPill("Listening", true)
    if stopOnStarted then -- caps was released before the mic came up
      stopOnStarted = false
      M.finish()
    end

  elseif e == "level" then
    updatePillLevel(event.value)

  elseif e == "context" then
    contextTermCount = tonumber(event.count) or contextTermCount
    log.info("recognition context reloaded", { contextTerms = contextTermCount })

  elseif e == "diagnostic" then
    log.warn("daemon diagnostic", { message = event.message })

  elseif e == "partial" then
    if event.text and event.text ~= "" then
      lastPartial = event.text
      if state == "recording" then
        if config.showLiveTranscript then
          showPill(event.text, true)
        else
          showPill("Listening", true)
        end
      end
    end

  elseif e == "final" then
    disarmWatchdog()
    disarmStartWatchdog()
    state = "idle"
    stopReason = nil
    handsFree = false
    unbindEsc()
    local text = (event.text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local fields = transcriptLogFields(text)
    fields.finalizeMs = elapsedMs(finishAtMs)
    fields.takeMs = elapsedMs(beginAtMs)
    lastFinalizeMs = fields.finalizeMs
    lastTakeMs = fields.takeMs
    log.info("daemon final", fields)
    if text ~= "" then
      deliverTranscript(text) -- owns the pill + stop sound from here
    else
      hidePill()
      hs.alert.show("Dictation: didn't catch anything", 1.2)
    end

  elseif e == "canceled" then
    log.info("daemon canceled")
    disarmWatchdog()
    disarmStartWatchdog()
    state = "idle"
    stopReason = nil
    handsFree = false
    hidePill()
    unbindEsc()
    if not cancelQuiet then
      hs.alert.show("Dictation canceled", 1.0)
    end
    cancelQuiet = false

  elseif e == "error" then
    local message = tostring(event.message or "")
    lastErrorMessage = message
    log.error("daemon error", { message = message, state = state })
    if message:match("^mic start:")
        or message:match("^analyzer start:")
        or message:match("^prepare:")
        or message:match("^rebuild:") then
      local currentInput = hs.audiodevice.defaultInputDevice()
      quarantineInputDevice(currentInput, message)
      restartDaemonSoon(message, config.startRetryDelay)
      hs.alert.show("Dictation mic reset — try again", 1.2)
      return
    end
    hs.alert.show("Dictation error: " .. message,
      config.alertDuration + 1)
  end
end

----------------------------------------------------------------
-- ACTIONS
----------------------------------------------------------------

-- Begin a take (always starts in hold mode; a quick Caps release upgrades
-- it to hands-free — see capsReleased).
function M.begin()
  if state == "recording" or state == "starting" then return end
  flushPendingDelivery("superseded_by_new_take")
  activeTarget = captureTarget()
  activeProfile = core.profileForApp(activeTarget.app, profileOverride)
  beginAtMs = nowMs()
  startedAtMs = nil
  finishAtMs = nil
  lastFinalizeMs = nil
  lastTakeMs = nil
  lastPasteQueueMs = nil
  lastErrorMessage = nil
  log.info("begin requested", {
    state = state, daemonReady = daemonReady, profile = activeProfile,
    targetApp = activeTarget.app, targetPID = activeTarget.pid,
  })
  if ensurePreferredInput(true) then
    pendingStart = true
    hs.timer.doAfter(config.startRetryDelay or 0.35, function()
      if pendingStart and state == "idle" then M.begin() end
    end)
    return
  end
  if not spawnDaemon() then return end
  if not daemonReady then
    pendingStart = true
    log.info("begin deferred until daemon ready")
    return
  end
  handsFree = false
  stopOnStarted = false
  lastPartial = ""
  stopReason = nil
  pressTime = hs.timer.secondsSinceEpoch()
  savedClipboard = hs.pasteboard.getContents()
  state = "starting"
  bindEsc()
  log.info("sending start")
  armStartWatchdog()
  send("start")
end

-- Stop the take; transcript arrives via the "final" event and is pasted.
function M.finish()
  if state == "starting" then
    -- Mic not up yet; flag it and stop as soon as "started" lands. The
    -- daemon serializes commands, so a stop sent now is also safe, but
    -- waiting yields a clean empty-take alert instead of a race.
    stopOnStarted = true
    log.info("finish deferred until started")
    return
  end
  if state ~= "recording" then return end
  finishAtMs = nowMs()
  local fields = transcriptLogFields(lastPartial)
  fields.recordingMs = elapsedMs(startedAtMs)
  log.info("finish requested", fields)
  state = "stopping"
  stopReason = "finish"
  -- Backup FIRST: whatever happens downstream, Cmd+V has the words.
  if config.clipboardBackup and lastPartial ~= "" then
    hs.pasteboard.setContents(lastPartial)
  end
  armWatchdog()
  showPill(lastPartial ~= "" and lastPartial or "Listening", false)
  local thisFinish = finishAtMs
  hs.timer.doAfter(0.4, function()
    if state == "stopping" and stopReason == "finish"
        and finishAtMs == thisFinish then
      showPill("Finishing...", false)
    end
  end)
  send("stop")
end

function M.cancel(quiet)
  if state ~= "recording" and state ~= "starting" then return end
  log.info("cancel requested", { quiet = quiet, state = state })
  cancelQuiet = quiet or false
  state = "stopping"
  stopReason = "cancel"
  disarmStartWatchdog()
  armWatchdog(config.cancelTimeout)
  send("cancel")
end

-- Trigger released cleanly (no other key was pressed during the hold).
-- Quick release = a tap → go hands-free (or stop, if already hands-free);
-- longer = the end of a push-to-talk hold → stop and paste.
local function triggerReleased()
  if state ~= "recording" and state ~= "starting" then return end
  if handsFree then
    M.finish()
    return
  end
  if hs.timer.secondsSinceEpoch() - pressTime < config.tapThreshold then
    handsFree = true
    log.info("tap promoted to hands-free")
    if state == "recording" then
      showPill("Listening", true)
    end
  else
    M.finish()
  end
end

----------------------------------------------------------------
-- TRIGGER TAP — watches the bare modifier key (default: Right⌘).
--
-- Modifier presses arrive as flagsChanged events. The key's press/release
-- is never consumed (a lone modifier is harmless to apps); instead, a
-- keyDown of any other key during the hold marks the press as a normal
-- keyboard shortcut: recording cancels silently and the combo passes
-- through untouched.
----------------------------------------------------------------
local trigTap = nil
local trigDown = false
local comboUsed = false

-- Modifier keycode -> the flag bit it sets.
local MODIFIER_FLAG = {
  cmd = "cmd", rightcmd = "cmd",
  shift = "shift", rightshift = "shift",
  alt = "alt", rightalt = "alt",
  ctrl = "ctrl", rightctrl = "ctrl",
}

local function startTriggerTap()
  local keyName = tostring(config.trigger[2] or "rightcmd"):lower()
  local trigCode = hs.keycodes.map[keyName]
  local flagName = MODIFIER_FLAG[keyName]
  if not trigCode or not flagName then
    log.error("invalid trigger", { key = keyName })
    hs.alert.show("dictation: trigger '" .. keyName ..
      "' must be a modifier key (e.g. rightcmd)", 4)
    return
  end

  local typeFlags   = hs.eventtap.event.types.flagsChanged
  local typeKeyDown = hs.eventtap.event.types.keyDown

  if trigTap then trigTap:stop(); trigTap = nil end
  trigTap = hs.eventtap.new({ typeFlags, typeKeyDown }, function(e)
    local etype = e:getType()

    if etype == typeFlags and e:getKeyCode() == trigCode then
      local pressed = e:getFlags()[flagName] or false
      if pressed and not trigDown then
        trigDown = true
        comboUsed = false
        log.debug("trigger down", { key = keyName, state = state })
        if state == "idle" then M.begin() end
      elseif not pressed and trigDown then
        trigDown = false
        log.debug("trigger up", { key = keyName, comboUsed = comboUsed, state = state })
        if comboUsed then
          comboUsed = false -- was a ⌘-shortcut; nothing to do
        else
          triggerReleased()
        end
      end
      return false -- never consume the modifier itself

    elseif etype == typeKeyDown then
      typedSinceLastPaste = true -- cursor context changed (smart spacing)
      if trigDown then
        -- Another key while the trigger is held = a real keyboard shortcut.
        comboUsed = true
        log.info("trigger used as combo; canceling dictation", { state = state })
        if not handsFree and (state == "recording" or state == "starting") then
          M.cancel(true) -- silent: the user was never dictating
        end
      end
      return false
    end

    return false
  end)
  trigTap:start()
  log.info("trigger tap started", { key = keyName })
end

----------------------------------------------------------------
-- start()
----------------------------------------------------------------
function M.setProfile(profile)
  local allowed = { Auto = true, Prompt = true, Message = true, Literal = true }
  if not allowed[profile] then return false, "unknown profile" end
  profileOverride = profile
  hs.settings.set("dictation.profileOverride.v1", profile)
  activeProfile = core.profileForApp(
    hs.application.frontmostApplication() and hs.application.frontmostApplication():name(),
    profileOverride)
  hs.alert.show("Dictation profile: " .. profile, 1.0)
  return true
end

function M.promptCorrection()
  local button, wrong = hs.dialog.textPrompt(
    "Learn dictation correction", "Wrong text from the last take:", "", "Next", "Cancel")
  if button ~= "Next" or trim(wrong) == "" then return false end
  local button2, right = hs.dialog.textPrompt(
    "Learn dictation correction", "Replace it with:", "", "Save", "Cancel")
  if button2 ~= "Save" or not appendCorrection(wrong, right) then return false end
  send("reload-context")
  hs.alert.show("Dictation learned correction", 1.0)
  return true
end

function M.start()
  startTriggerTap()
  startInputWatcher()
  -- Prewarm so the very first take starts instantly.
  if ensurePreferredInput() then
    hs.timer.doAfter(1.0, function()
      if state == "idle" then spawnDaemon() end
    end)
  else
    spawnDaemon()
  end
  log.info("started", {
    autoRefine = config.autoRefine,
    autoRefineMinChars = config.autoRefineMinChars,
    autoRefineMinWords = config.autoRefineMinWords,
    autoRefineTimeout = config.autoRefineTimeout,
    cancelTimeout = config.cancelTimeout,
    punctuation = config.punctuation,
    voiceCommands = config.voiceCommands,
    longDictationPolish = config.longDictationPolish,
    joinChoppyFragments = config.joinChoppyFragments,
    micIdleSeconds = config.micIdleSeconds,
  })
end

-- Toggle from code/menus: start a take, or stop the current one.
function M.toggle()
  log.info("toggle requested", { state = state })
  if state == "recording" or state == "starting" then
    M.finish()
  else
    M.begin()
  end
end

-- Debug/introspection: current state of the module and daemon.
function M.status()
  local input = hs.audiodevice.defaultInputDevice()
  local preferred = preferredInputDevice()
  return {
    state = state,
    daemonRunning = task ~= nil,
    daemonReady = daemonReady,
    handsFree = handsFree,
    inputDevice = input and input:name() or nil,
    preferredInputDevice = preferred and preferred:name() or nil,
    autoRefine = config.autoRefine,
    autoRefineTimeout = config.autoRefineTimeout,
    autoRefineMinChars = config.autoRefineMinChars,
    autoRefineMinWords = config.autoRefineMinWords,
    cancelTimeout = config.cancelTimeout,
    punctuation = config.punctuation,
    voiceCommands = config.voiceCommands,
    lastError = lastErrorMessage,
    lastStartLatencyMs = lastStartLatencyMs,
    lastFinalizeMs = lastFinalizeMs,
    lastTakeMs = lastTakeMs,
    lastPasteQueueMs = lastPasteQueueMs,
    activeProfile = activeProfile,
    profileOverride = profileOverride,
    pendingTakeId = pendingDelivery and pendingDelivery.id or nil,
    contextTermCount = contextTermCount,
    recognizerEngine = recognizerEngine,
    lastTotalLatencyMs = lastTotalLatencyMs,
    lastAILatencyMs = lastAILatencyMs,
    aiModel = lastAIModel or "gpt-5.4-mini",
    lastAIReason = lastAIReason,
  }
end

-- Debug/introspection: run the local cleanup pass without recording.
M.cleanupTranscript = cleanupTranscript
M.rememberCorrection = appendCorrection

-- Exposed so users can read/mutate config from init.lua before/after start().
M.config = config

return M
