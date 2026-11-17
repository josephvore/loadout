-- dictation.lua — push-to-talk voice dictation. Speech-to-text is fully
-- on-device; a fast LLM cleanup pass (Wispr Flow-style) polishes each take
-- before paste, falling back to the raw transcript on timeout or failure.
-- Load from ~/.hammerspoon/init.lua with: pcall(function() require("murmur").start() end)
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
-- Speech-to-text runs locally via ~/bin/hs-dictate, a small Swift daemon.
-- Apple's SpeechAnalyzer (macOS 26) streams live partials WHILE you speak;
-- on stop, Parakeet TDT (FluidAudio CoreML on the Neural Engine) re-reads
-- the take's audio for a markedly more accurate final transcript, falling
-- back to Apple's text automatically. The daemon stays warm between takes
-- with models loaded AND the mic engine hot (see micIdleSeconds). No cloud
-- STT, no cost, works offline.
--
-- Build the daemon (source is installed alongside this module):
--   ~/.hammerspoon/murmur/hs-dictate/build.sh

local M = {}
local log = require("litelog").new("murmur")
local core = require("murmur_core")

-- Where murmur's installed data + daemon source live (installer copies them
-- here). Falls back to ~/.hammerspoon when hs.configdir is unavailable.
local MURMUR_DIR = ((hs and hs.configdir) or (os.getenv("HOME") .. "/.hammerspoon"))
  .. "/murmur"

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

  -- How long the daemon keeps listening after stop for tail audio before
  -- finalizing. Tap buffers are ~21ms, so 150ms is a wide margin; raise it
  -- if the last word of takes starts getting clipped.
  stopGraceMs = 150,

  -- Second-pass ASR: "v3" | "v2" | "off". Parakeet TDT 0.6b (FluidAudio
  -- CoreML, Apple Neural Engine) re-transcribes each take's audio on stop at
  -- roughly half Apple's word error rate, ~0.2s per take. Apple partials
  -- still drive the live pill; Apple finals remain the automatic fallback
  -- while the model loads or if Parakeet is slow. First run downloads
  -- ~450MB to ~/Library/Application Support/FluidAudio (one-time; warm
  -- loads are ~0.2s thereafter). "v2" is English-only and the right default
  -- for this en_US app — equal-or-better English recall than the
  -- multilingual "v3", with a tighter decode and no language-ID overhead.
  parakeet = "v2",

  -- First-pass STREAMING ASR that drives the live pill: "eou160" | "eou320" |
  -- "off". Parakeet EOU 120M (FluidAudio cache-aware streaming encoder,
  -- Neural Engine) transcribes WHILE you speak and updates the overlay
  -- word-by-word — Parakeet-quality live text in place of Apple's weaker
  -- volatile partials (the ChatGPT/Groq-style live feel). The batch parakeet
  -- pass above still owns the final that gets pasted, so live text is snappy
  -- and the pasted text stays best-in-class. "eou160" = lowest latency (160ms
  -- chunks); "eou320" = noticeably more accurate (~5.7% vs ~8-9% WER) for one
  -- extra chunk of latency — the better default now that the transcript panel
  -- shows the whole take (eou160's homophone slips like "lie" for "live" read
  -- as errors, not noise). First run downloads ~120MB to
  -- ~/Library/Application Support/FluidAudio (one-time). Until it loads (or if
  -- off), Apple partials drive the pill as before.
  stream = "eou320",

  -- Trigger: Caps+M through QuickShots' shared Caps (F18) tap. Hold Caps,
  -- press M to start, keep Caps held while speaking, release Caps to stop
  -- and paste. A quick Caps+M tap (< tapThreshold) goes hands-free; Caps+M
  -- again stops. Rebind from Palette (Caps+K). Set to false to disable.
  capsTrigger = { {}, "m" },

  -- Legacy trigger: a bare MODIFIER key name from hs.keycodes.map
  -- ("rightcmd", "rightalt", "rightctrl", "rightshift", "cmd", …) watched via
  -- a flagsChanged event tap, so ordinary keys won't work here. Off (false)
  -- now that Caps+M is the trigger; Murmur falls back to Right⌘ automatically
  -- if QuickShots' Caps tap is unavailable.
  trigger = false,

  -- Use the system microphone unless device names are configured locally.
  preferredInputDevices = {},
  preferredInputDevice = nil, -- legacy single-name override

  -- Speech framework microphone profile: "default" for built-in/ordinary mics,
  -- or "far-field" when the selected microphone is physically distant.
  contentHint = "default",

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

  -- Mark transcripts on the pasteboard with org.nspasteboard.ConcealedType
  -- (the Wispr Flow trick) so clipboard managers don't archive every take.
  -- Plain Cmd+V is unaffected.
  concealPaste = true,

  -- The instant you stop a take, the live transcript is written to the
  -- clipboard as a backup — BEFORE finalize runs — so even if everything
  -- downstream hangs or crashes, Cmd+V has your words.
  clipboardBackup = true,

  -- Wispr-style cleanup: every ordinary take goes through the LLM polish
  -- (fillers, false starts, backtracking, pause-punctuation) via the fastest
  -- provider with a Keychain key — see providers in hone.lua. On timeout
  -- or failure the locally cleaned transcript pastes instead, so words are
  -- never lost, just less polished.
  autoRefine = true,
  -- The polish system prompt is ~1.1k tokens, so even short takes need a
  -- little over two seconds on the free tiers.
  autoRefineTimeout = 3.0,
  autoRefineMinChars = 12,   -- skip only tiny acknowledgements
  autoRefineMinWords = 4,
  -- Long takes get proportionally more polish budget: the timeout grows by
  -- one second per 1000 chars past the first 600, capped at the max. A
  -- five-minute ramble is exactly where full-transcript polish pays off, so
  -- it shouldn't be the take most likely to hit the timeout.
  autoRefineTimeoutMax = 6.0,
  autoRefineTimeoutPerKChars = 1.0,

  -- Free, local cleanup that runs before paste. This is intentionally
  -- conservative: polish transcription artifacts without changing meaning.
  localCleanup = true,

  -- Data-driven cleanup. Put canonical words/phrases in the glossary; put
  -- learned "wrong -> right" replacements in correctionMemoryPath.
  glossaryPath = MURMUR_DIR .. "/dictation_glossary.txt",
  correctionMemoryPath = MURMUR_DIR .. "/dictation_corrections.tsv",
  snippetsPath = MURMUR_DIR .. "/dictation_snippets.tsv",

  -- Wispr-style context injection: give the cleanup LLM the frontmost app
  -- name and up to contextMaxChars of text before the cursor so it can match
  -- mid-sentence capitalization and in-document terminology. The snippet is
  -- sent to the same cleanup provider as the transcript itself; set to false
  -- if that ever feels too chatty.
  contextInjection = true,
  contextMaxChars = 240,

  -- Auto-learn proper nouns: a new name/product word seen in this many
  -- pasted takes gets appended to the glossary and pushed into the
  -- recognizer's context, so the ASR stops mishearing it. Counts persist in
  -- properNounCountsPath (gitignored, next to the logs).
  glossaryAutoLearn = true,
  glossaryAutoLearnThreshold = 2,
  glossaryAutoLearnMaxTerms = 90, -- stop before crowding the 100-slot context
  properNounCountsPath = MURMUR_DIR .. "/dictation_proper_nouns.tsv",

  -- Spoken editing commands: "new paragraph", "scratch that", "comma",
  -- "open quote", "send" (when dictated alone), etc.
  voiceCommands = true,

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

  -- Live transcript panel: a scrollable window above the pill showing the
  -- WHOLE session so far, not just the last line. It auto-grows to
  -- transcriptPanelMaxHeight, then scrolls pinned to the bottom; scrolling
  -- up releases the pin and a "↓ live" button re-pins. Committed text
  -- (stable across liveCommitStableHypotheses consecutive ASR hypotheses,
  -- or frozen after liveCommitTimeoutSeconds of quiet) renders full-opacity
  -- and never changes on screen; the still-revisable tail renders dimmed.
  -- The glossary/corrections dictionary is applied word-level to the live
  -- text — display only; the raw transcript stays the source of truth and
  -- the end-of-take polish always reads the raw text, never this view.
  transcriptPanel = true,
  transcriptPanelWidth = 520,
  transcriptPanelMaxHeight = 260,
  transcriptRenderSeconds = 0.12, -- coalesce partial-burst re-renders
  liveCommitStableHypotheses = 3,
  liveCommitTimeoutSeconds = 2.0,

  -- LIVE polish: committed text is divided into sentence-ish segments and
  -- polished by small LLM calls WHILE you speak — punctuation, caps,
  -- fillers, restarts, contextual word fixes appear on screen as segments
  -- settle. Releasing the key races a bounded FULL polish of the accurate
  -- batch transcript (whole-take context: cross-sentence rambling collapses,
  -- consistent caps, batch ASR fixes) against the assembled screen text; the
  -- screen text pastes only when the full polish misses the cap, and a full
  -- polish that lands late is kept for a Caps+R swap. The batch-final raw
  -- transcript is always retained for Caps+R. Any live failure just leaves
  -- segments raw; zero polished segments falls back to the classic
  -- end-of-take full polish.
  livePolish = true,
  livePolishCallTimeout = 2.5,       -- per segment call, racing the response
  livePolishSettleSeconds = 0.6,     -- lone-segment age before it dispatches
  livePolishMinSegmentWords = 3,
  livePolishMaxSegmentWords = 28,    -- force-split without punctuation
  livePolishWindowMaxWords = 100,    -- catch-up batch cap after outages
  livePolishMaxCalls = 40,           -- per-take budget
  livePolishStopGraceMs = 400,       -- wait for an in-flight call at stop
  -- Cap on the at-stop full-polish race. 1.5 (was 1.2) because a Cerebras
  -- 429 -> OpenAI fallback lands in 1.1-1.5s and real takes missed the old
  -- cap by 63-300ms — a great paste 300ms later beats a bad paste on time.
  livePolishFinalSeconds = 2.0,
  -- Race the final polish to two providers (fast chain + the anchor — the
  -- last keyed provider in hone's order, normally OpenAI). First result
  -- that validates pastes; the loser is ignored (hs http can't cancel).
  livePolishFinalRace = true,
  -- One retry with introduced-word feedback when the final polish is
  -- rejected "words_introduced". Post-cap retry results go down the
  -- late-polish path.
  polishRejectRetry = true,
  -- Auto-swap a late-arriving validated polish into the target field, but
  -- ONLY when AX positively verifies the pasted text still sits untouched
  -- at the caret. On any doubt: today's alert + Caps+R.
  lateAutoApply = true,
  lateAutoApplyWindowSeconds = 20,

  -- SELF-IMPROVEMENT LOOP -----------------------------------------------
  -- Take archive: every paste appends full raw/cleaned/pasted/polished text
  -- + timings to a JSONL so the nightly self-eval (tools/self_eval.lua) can
  -- replay real takes; log samples truncate at 320 chars and can't.
  takeArchive = true,
  takeArchivePath = MURMUR_DIR .. "/takes.jsonl",

  -- Wispr-style edit mining: re-read the target text field a little after
  -- pasting and diff it against what we pasted. Word replacements the user
  -- typed are correction candidates, counted like glossary auto-learn and
  -- promoted into dictation_corrections.tsv on the second sighting.
  editMining = true,
  editMiningDelaySeconds = 45,
  editMiningThreshold = 2,
  editMinedPath = MURMUR_DIR .. "/dictation_edit_mined.tsv",

  -- Nightly self-eval: replay the day's archived takes through the live
  -- polish + validator, LLM-judge the pasted output, aggregate cap-miss /
  -- 429 / rejection rates, and write a report + private regression fixtures
  -- (in MURMUR_DIR). Off by default: it sends the day's transcripts to your
  -- cleanup provider. Enable with selfEval = true in loadout.local.lua.
  selfEval = false,
  selfEvalTime = "03:30",
  selfEvalLua = (hs and hs.fs.attributes("/opt/homebrew/bin/lua")) and "/opt/homebrew/bin/lua"
    or "/usr/local/bin/lua",
  selfEvalDir = MURMUR_DIR .. "/self_eval",

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
local daemonDeviceUID = nil -- --device the running daemon was given (nil = default)
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
local lastAIProvider = nil
local lastAIReason = nil
local recognizerEngine = nil
local lastFinalEngine = nil

-- The newest take, retained in full. `raw` is the daemon's final transcript
-- (the source of truth — always kept, never edited); `cleaned` is raw after
-- deterministic local cleanup (voice commands, glossary); `polished` is the
-- LLM polish when one was produced. The raw/polished toggle swaps the pasted
-- text between `cleaned` and `polished` in place.
local lastTake = {}

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
local hideTranscriptPanel -- defined with the transcript panel below

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
  if hideTranscriptPanel then hideTranscriptPanel() end
end

----------------------------------------------------------------
-- TRANSCRIPT PANEL — the full live transcript, above the pill.
--
-- The pill stays a one-line status strip; this panel shows everything said
-- so far. It is an hs.webview because the behavior is native web behavior:
-- real text wrapping, real scrolling, pin-to-bottom with user-scroll
-- release, and incremental DOM updates. Rendering is append-only for the
-- committed region — only the tail node is rewritten per update — so long
-- sessions never re-layout the whole transcript on a partial event.
--
-- Committed/tail split comes from core.newLiveView (a word commits once it
-- is stable across N consecutive hypotheses, or when the quiet-period timer
-- freezes the buffer). Committed words never change on screen.
----------------------------------------------------------------
local panel = nil            -- hs.webview
local panelReady = false
local panelVisible = false
local panelQueue = {}        -- JS deferred until the page reports ready
local panelHeight = 0
local panelCommittedSent = 0 -- bytes of committed text already in the DOM (legacy path)
local liveView = nil         -- core.newLiveView for the current take
local livePolisher = nil     -- core.newLivePolisher when live polish is active
local liveSource = nil       -- recognizer tag feeding the panel (handoff detect)
local liveReplacements = nil -- glossary/corrections, loaded once per take
local liveCommitTimer = nil
local panelRenderTimer = nil
local panelRenderDirty = false
local panelSegSent = {}      -- segment id -> {text, cls} already in the DOM
local panelOpenSent = nil    -- last open/tail strings sent (live-polish path)
local panelTailSent = nil
local livePolishTimer = nil  -- per-call timeout for the in-flight segment call
local livePolishTransport = nil -- injected sender (previewPanel stubs this)
local previewTicker = nil
local previewTimers = {}

-- End any panel preview: a real take must never inherit the preview's
-- stubbed polish transport.
local function stopPreview()
  if previewTicker then previewTicker:stop(); previewTicker = nil end
  for _, t in ipairs(previewTimers) do pcall(function() t:stop() end) end
  previewTimers = {}
  livePolishTransport = nil
end

local PANEL_MIN_H = 44

-- The pill background/border colors, restated in CSS so the two read as one
-- surface. The window itself is transparent; the rounded box is HTML.
local PANEL_HTML = [[<!DOCTYPE html>
<html><head><meta charset="utf-8"><style>
  html, body { margin:0; padding:0; background:transparent; height:100%; overflow:hidden; }
  #box { position:absolute; inset:0; box-sizing:border-box;
    background:rgba(9,10,12,0.92); border:1px solid rgba(107,199,255,0.22);
    border-radius:13px; display:flex; flex-direction:column; }
  #scroller { flex:1; overflow-y:auto; padding:10px 14px; overscroll-behavior:contain;
    font:14px/1.45 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
    color:#fff; }
  #scroller::-webkit-scrollbar { width:6px; }
  #scroller::-webkit-scrollbar-thumb { background:rgba(255,255,255,0.18); border-radius:3px; }
  #content { white-space:pre-wrap; word-break:break-word; }
  #segs span { border-radius:3px;
    transition: background-color 0.6s ease, opacity 0.25s ease; }
  #segs span.p { opacity:0.96; }
  #segs span.r { opacity:0.8; }
  #segs span.flash { background:rgba(107,199,255,0.28); transition:none; }
  #open { opacity:0.8; }
  #tail { opacity:0.5; }
  #jump { position:absolute; right:10px; bottom:8px; display:none; cursor:pointer;
    font:12px -apple-system, sans-serif; color:#0b0c0e; user-select:none;
    background:rgba(107,199,255,0.9); border-radius:10px; padding:3px 10px; }
</style></head><body>
<div id="box">
  <div id="scroller"><div id="content"><span id="segs"></span><span id="open"></span><span id="tail"></span></div></div>
  <div id="jump">&#8595; live</div>
</div>
<script>
  var segsEl = document.getElementById('segs');
  var openEl = document.getElementById('open');
  var tailEl = document.getElementById('tail');
  var scroller = document.getElementById('scroller');
  var content = document.getElementById('content');
  var jump = document.getElementById('jump');
  var pinned = true;
  function post(m) { try { webkit.messageHandlers.murmur.postMessage(m); } catch (e) {} }
  function atBottom() {
    return scroller.scrollTop + scroller.clientHeight >= scroller.scrollHeight - 6;
  }
  function toBottom() { scroller.scrollTop = scroller.scrollHeight; }
  function setPinned(p) { pinned = p; jump.style.display = p ? 'none' : 'block'; }
  // Any upward wheel motion releases the pin instantly; scrolling back to
  // the bottom (or the jump button) re-pins.
  scroller.addEventListener('wheel', function (e) {
    if (e.deltaY < 0) setPinned(false);
  }, { passive: true });
  scroller.addEventListener('scroll', function () {
    if (!pinned && atBottom()) setPinned(true);
  }, { passive: true });
  jump.addEventListener('click', function () { setPinned(true); toBottom(); });
  function report() {
    // 20 = scroller vertical padding, 2 = box border.
    post({ h: Math.ceil(content.getBoundingClientRect().height) + 22 });
  }
  new ResizeObserver(report).observe(content);
  // Per-segment spans: ids arrive in increasing order, so DOM order is
  // insertion order. Rewriting a span above the viewport while the user has
  // scrolled up gets scroll compensation so their reading position holds.
  // A raw span upgrading to polished flashes briefly (.flash has no
  // transition in, the base rule fades it out).
  function seg(id, text, cls) {
    var el = document.getElementById('s' + id), fresh = !el;
    if (fresh) {
      el = document.createElement('span');
      el.id = 's' + id;
      segsEl.appendChild(el);
    }
    var wasPolished = el.className.indexOf('p') >= 0;
    var beforeH = scroller.scrollHeight;
    el.textContent = text + ' ';
    el.className = cls;
    if (cls === 'p' && !wasPolished && !fresh) {
      el.classList.add('flash');
      setTimeout(function () { el.classList.remove('flash'); }, 40);
    }
    if (pinned) toBottom();
    else scroller.scrollTop += scroller.scrollHeight - beforeH;
  }
  function rmseg(id) {
    var el = document.getElementById('s' + id);
    if (el) el.remove();
  }
  // open = committed words not yet in a segment; tail = still-revisable words.
  function liveTail(openText, tailText) {
    if (openEl.textContent !== openText) openEl.textContent = openText;
    if (tailEl.textContent !== tailText) tailEl.textContent = tailText;
    if (pinned) toBottom();
  }
  // Legacy append-only path (no live polish): committed grows inside #open.
  function up(commitDelta, tailText) {
    if (commitDelta) openEl.appendChild(document.createTextNode(commitDelta));
    if (tailEl.textContent !== tailText) tailEl.textContent = tailText;
    if (pinned) toBottom();
  }
  function rs() {
    segsEl.textContent = '';
    openEl.textContent = '';
    tailEl.textContent = '';
    setPinned(true);
  }
  post({ ready: true });
</script>
</body></html>]]

-- Escape a Lua string into a JS string literal (hs.json.encode only accepts
-- tables). UTF-8 sequences pass through raw; WKWebView's JS accepts them.
local function jsString(s)
  local escaped = tostring(s):gsub('[%c"\\]', function(c)
    if c == '"' then return '\\"' end
    if c == "\\" then return "\\\\" end
    if c == "\n" then return "\\n" end
    if c == "\r" then return "\\r" end
    if c == "\t" then return "\\t" end
    return string.format("\\u%04x", c:byte())
  end)
  return '"' .. escaped .. '"'
end

local function panelFrame(h)
  local f = hs.screen.mainScreen():frame()
  local w = config.transcriptPanelWidth or 520
  local pf = pillFrame()
  return {
    x = f.x + (f.w - w) / 2,
    y = pf.y - 8 - h,
    w = w,
    h = h,
  }
end

local function panelEval(js)
  if not panel then return end
  if not panelReady then
    panelQueue[#panelQueue + 1] = js
    return
  end
  panel:evaluateJavaScript(js)
end

local function ensurePanel()
  if panel then return true end
  local ok, err = pcall(function()
    local uc = hs.webview.usercontent.new("murmur")
    uc:setCallback(function(msg)
      local body = msg and msg.body
      if type(body) ~= "table" then return end
      if body.ready then
        panelReady = true
        local queued = panelQueue
        panelQueue = {}
        for _, js in ipairs(queued) do panel:evaluateJavaScript(js) end
      elseif tonumber(body.h) then
        local max = config.transcriptPanelMaxHeight or 260
        local h = math.max(PANEL_MIN_H, math.min(max, math.floor(body.h)))
        if h ~= panelHeight then
          panelHeight = h
          if panelVisible then panel:frame(panelFrame(h)) end
        end
      end
    end)
    local view = hs.webview.new(panelFrame(PANEL_MIN_H),
      { developerExtrasEnabled = false }, uc)
    -- nonactivating: scrolling/clicking the panel must never steal focus
    -- from the app the transcript will be pasted into.
    view:windowStyle({ "borderless", "utility", "nonactivating" })
    view:level(hs.drawing.windowLevels.overlay)
    view:behaviorAsLabels({ "canJoinAllSpaces", "stationary" })
    view:transparent(true)
    view:allowTextEntry(false)
    view:html(PANEL_HTML)
    panel = view
    panelHeight = PANEL_MIN_H
  end)
  if not ok then
    -- No panel (webview unavailable/misbehaving): fall back to the legacy
    -- one-line transcript in the pill rather than losing the live view.
    log.error("transcript panel unavailable; falling back to pill text",
      { error = tostring(err) })
    config.transcriptPanel = false
    return false
  end
  return true
end

local function panelEnabled()
  return config.transcriptPanel and config.showLiveTranscript
end

local function showTranscriptPanel()
  if not panelEnabled() then return false end
  if not ensurePanel() then return false end
  if not panelVisible then
    panel:frame(panelFrame(panelHeight))
    panel:show()
    panelVisible = true
  end
  return true
end

hideTranscriptPanel = function()
  if panel and panelVisible then panel:hide() end
  panelVisible = false
  if panelRenderTimer then panelRenderTimer:stop(); panelRenderTimer = nil end
  if liveCommitTimer then liveCommitTimer:stop(); liveCommitTimer = nil end
  panelRenderDirty = false
end

-- Live-polish renderer: diff the polisher's segments against what the DOM
-- already has (panelSegSent) and send only changed spans, then the open/tail
-- text. All JS for one render travels as a single eval.
local function renderPanelLive()
  if not (liveView and livePolisher) then return end
  local vsnap = liveView:snapshot()
  local snap = livePolisher:snapshot()
  local js, liveIds = {}, {}
  for _, item in ipairs(snap.items) do
    liveIds[item.id] = true
    local cls = item.state == "polished" and "p" or "r"
    local sent = panelSegSent[item.id]
    if not sent or sent.text ~= item.text or sent.cls ~= cls then
      js[#js + 1] = string.format("seg(%d,%s,%s)",
        item.id, jsString(item.text), jsString(cls))
      panelSegSent[item.id] = { text = item.text, cls = cls }
    end
  end
  for id in pairs(panelSegSent) do
    if not liveIds[id] then
      js[#js + 1] = string.format("rmseg(%d)", id)
      panelSegSent[id] = nil
    end
  end
  local open = snap.openText or ""
  local tail = vsnap.tail or ""
  -- Segments carry their own trailing space; the open run separates itself
  -- from the tail with one leading space when both are present.
  if tail ~= "" and open ~= "" then tail = " " .. tail end
  if open ~= panelOpenSent or tail ~= panelTailSent then
    js[#js + 1] = string.format("liveTail(%s,%s)", jsString(open), jsString(tail))
    panelOpenSent, panelTailSent = open, tail
  end
  if #js > 0 then panelEval(table.concat(js, ";")) end
end

-- Legacy renderer (no live polish): committed only ever grows, so the delta
-- since the last render is a plain suffix append on the JS side.
local function renderPanelLegacy()
  if not liveView then return end
  local snap = liveView:snapshot()
  if #snap.committed < panelCommittedSent then
    -- The live view reset (engine handoff): rebuild the DOM from scratch.
    panelEval("rs()")
    panelCommittedSent = 0
  end
  local delta = ""
  if #snap.committed > panelCommittedSent then
    delta = snap.committed:sub(panelCommittedSent + 1)
    if panelCommittedSent == 0 then delta = delta:gsub("^%s+", "") end
    panelCommittedSent = #snap.committed
  end
  local tail = snap.tail
  if tail ~= "" and snap.committed ~= "" then tail = " " .. tail end
  panelEval(string.format("up(%s,%s)", jsString(delta), jsString(tail)))
end

local function renderPanel()
  if livePolisher then renderPanelLive() else renderPanelLegacy() end
end

-- Coalesce renders: partials can arrive in bursts, and the spec's ~200ms
-- partial cadence means anything faster than ~8 fps here is wasted work.
local function schedulePanelRender()
  panelRenderDirty = true
  if panelRenderTimer then return end
  panelRenderTimer = hs.timer.doAfter(config.transcriptRenderSeconds or 0.12,
    function()
      panelRenderTimer = nil
      if panelRenderDirty then
        panelRenderDirty = false
        renderPanel()
      end
    end)
end

-- hone, resolved lazily once (the live pump and the end-of-take polish both
-- need it; a missing module disables live polish rather than erroring).
local honeModule = nil
local function honeAvailable()
  if honeModule == nil then
    local ok, mod = pcall(require, "hone")
    honeModule = (ok and type(mod) == "table"
      and type(mod.refineText) == "function") and mod or false
  end
  return honeModule or nil
end

-- Default transport for a segment-polish batch: the compact live prompt
-- through hone's provider-fallback chain. previewPanel injects a stub here.
local function honeTransport(dispatch, onDone, onFail)
  local hone = honeAvailable()
  if not hone or type(hone.segmentSystemPrompt) ~= "function" then
    onFail("segment polish unavailable")
    return
  end
  local words = core.wordCount(dispatch.text)
  hone.refineText(dispatch.text, onDone, onFail, {
    systemPrompt = hone.segmentSystemPrompt({
      prevContext = dispatch.prevContext,
      midSentence = core.continuesMidSentence(dispatch.prevContext),
      appName = activeTarget and activeTarget.app or nil,
    }),
    maxOutputTokens = math.min(300, words * 2 + 16),
  })
end

-- Pump: hand the polisher's next eligible batch to the transport. Single
-- call in flight (enforced by the polisher); a hard per-call timer races the
-- response so a hung request can't stall the pipeline. Failures revert or
-- freeze segments — the display just stays raw, the take is never disturbed.
local function dispatchLivePolish()
  if not livePolisher then return end
  local dispatch = livePolisher:nextDispatch(hs.timer.secondsSinceEpoch())
  if not dispatch then return end
  local polisher = livePolisher
  local callId = dispatch.callId
  local settled = false
  local function settle(fn)
    if settled or livePolisher ~= polisher then return end
    settled = true
    if livePolishTimer then livePolishTimer:stop(); livePolishTimer = nil end
    fn()
    schedulePanelRender()
    dispatchLivePolish()
  end
  livePolishTimer = hs.timer.doAfter(config.livePolishCallTimeout or 2.0,
    function()
      settle(function()
        log.warn("live polish call timed out", { callId = callId })
        polisher:failResult(callId)
      end)
    end)
  local dispatchedMs = nowMs()
  local send = livePolishTransport or honeTransport
  send(dispatch,
    function(result)
      settle(function()
        result = core.trim(tostring(result or ""))
        result = core.harmonizeSegmentStart(
          dispatch.prevContext, dispatch.text, result)
        local ok, reason = core.validateSegmentPolish(dispatch.text, result)
        if ok then
          polisher:applyResult(callId, result)
          -- Per-segment before/after at DEBUG: the feedback loop for tuning
          -- the segment prompt and validator against real takes.
          log.debug("live segment polished", {
            callId = callId,
            ms = nowMs() - dispatchedMs,
            input = dispatch.text:sub(1, 90),
            output = result:sub(1, 90),
          })
        else
          log.warn("live polish segment rejected", {
            reason = reason,
            input = dispatch.text:sub(1, 120),
            output = result:sub(1, 120),
          })
          polisher:failResult(callId)
        end
      end)
    end,
    function(msg)
      settle(function()
        if tostring(msg):find("429") then
          local backoff = polisher.consecutiveFailures >= 1 and 60 or 20
          polisher:setCooldown(hs.timer.secondsSinceEpoch() + backoff)
        end
        log.warn("live polish segment failed", { message = tostring(msg) })
        polisher:failResult(callId)
      end)
    end)
end

-- Quiet-period commit: when no new hypothesis lands for a while, freeze the
-- buffer so the view never deadlocks waiting for N-way consensus. With live
-- polish active the pause also closes the open segment run, so text polishes
-- DURING silences instead of after them.
local function armLiveCommitTimeout()
  if liveCommitTimer then liveCommitTimer:stop() end
  liveCommitTimer = hs.timer.doAfter(config.liveCommitTimeoutSeconds or 2.0,
    function()
      liveCommitTimer = nil
      if state == "recording" and liveView then
        liveView:commitAll()
        if livePolisher then
          local now = hs.timer.secondsSinceEpoch()
          livePolisher:feed(liveView:snapshot().committed, now)
          livePolisher:onQuiet(now)
          dispatchLivePolish()
        end
        schedulePanelRender()
      end
    end)
end

-- New take: fresh live view (+ live polisher when enabled), glossary and
-- corrections loaded once, empty DOM.
local function resetLivePanel()
  liveView = core.newLiveView({
    stableCount = config.liveCommitStableHypotheses or 3,
  })
  liveReplacements = core.loadReplacements(
    config.glossaryPath, config.correctionMemoryPath)
  liveSource = nil
  if livePolishTimer then livePolishTimer:stop(); livePolishTimer = nil end
  livePolisher = nil
  if config.livePolish and config.autoRefine and activeProfile ~= "Literal"
    and (livePolishTransport or honeAvailable()) then
    livePolisher = core.newLivePolisher({
      minSegmentWords = config.livePolishMinSegmentWords,
      maxSegmentWords = config.livePolishMaxSegmentWords,
      settleSeconds = config.livePolishSettleSeconds,
      windowMaxWords = config.livePolishWindowMaxWords,
      maxCalls = config.livePolishMaxCalls,
    })
  end
  panelCommittedSent = 0
  panelSegSent = {}
  panelOpenSent, panelTailSent = nil, nil
  panelEval("rs()")
end

-- A live hypothesis from the daemon. Word-level glossary/correction fixes
-- are applied to the DISPLAY text (deterministic, so they can't destabilize
-- the commit consensus); the polisher consumes the same display text, so its
-- segment raws carry the glossary layer but never any LLM output.
local function feedLivePanel(text, source)
  if not liveView then return end
  if livePolisher and liveSource ~= nil and source ~= liveSource then
    -- Engine handoff: the new recognizer re-reads the take from scratch, so
    -- the polisher's segments no longer describe the committed text.
    livePolisher:reset()
    panelSegSent = {}
    panelOpenSent, panelTailSent = nil, nil
    panelEval("rs()")
  end
  liveSource = source
  local display = text
  if liveReplacements then
    display = core.applyLoadedReplacements(display, liveReplacements)
  end
  liveView:update(display, source)
  if livePolisher then
    livePolisher:feed(liveView:snapshot().committed,
      hs.timer.secondsSinceEpoch())
    dispatchLivePolish()
  end
  if showTranscriptPanel() then
    schedulePanelRender()
    armLiveCommitTimeout()
  end
end

-- Take over the panel with settled text (the pasted result): everything
-- polished-tier, no tail, one full render. Ends the live pipeline for the
-- take; the caller captures the polisher BEFORE calling this if it still
-- needs the segment snapshot.
local function panelShowText(text)
  livePolisher = nil
  if livePolishTimer then livePolishTimer:stop(); livePolishTimer = nil end
  if not (panel and panelVisible) then return end
  if liveCommitTimer then liveCommitTimer:stop(); liveCommitTimer = nil end
  if panelRenderTimer then panelRenderTimer:stop(); panelRenderTimer = nil end
  panelRenderDirty = false
  liveView = nil
  panelCommittedSent = #text
  panelSegSent = {}
  panelOpenSent, panelTailSent = nil, nil
  panelEval(string.format("rs(); seg(0,%s,\"p\")", jsString(text)))
end

----------------------------------------------------------------
-- LOCAL TRANSCRIPT CLEANUP
----------------------------------------------------------------

local function trim(s)
  local cleaned = (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
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

-- Take archive: one JSON line per event in takes.jsonl. `kind = "take"` is
-- a paste (full raw/cleaned/pasted/polished text — log samples truncate);
-- "late_polish" is a polish that landed after its cap (kept for Caps+R);
-- "swap" is a Caps+R toggle. tools/self_eval.lua replays these nightly.
local function archiveTake(record)
  if not config.takeArchive then return end
  local ok, err = pcall(function()
    record.ts = os.date("%Y-%m-%dT%H:%M:%S%z")
    local line = hs.json.encode(record)
    if not line then return end
    local f = io.open(config.takeArchivePath, "a")
    if f then
      f:write(line, "\n")
      f:close()
    end
  end)
  if not ok then
    log.warn("take archive write failed", { error = tostring(err) })
  end
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

-- The daemon records from the preferred device directly (hs-dictate
-- --device), so Murmur never changes the system default input: calls and
-- other apps keep whatever mic macOS picked. A restart is needed only when
-- the device the daemon should use changes (the preferred mic was plugged
-- in or removed). Returns true when the daemon was stopped for that.
local function ensurePreferredInput()
  if not task then return false end
  local preferred = preferredInputDevice()
  local wanted = preferred and preferred:uid() or nil
  if wanted == daemonDeviceUID then return false end
  log.info("input device changed; restarting daemon", {
    from = daemonDeviceUID, to = preferred and preferred:name() or "system default",
  })
  stopDaemonForInputSwitch()
  return true
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
  local changed = ensurePreferredInput()
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

-- Transcripts go on the pasteboard marked concealed so clipboard managers
-- skip them; the user's real clipboard history stays theirs. Restores of
-- the ORIGINAL clipboard use plain setContents.
local function setClipboardTranscript(text)
  hs.pasteboard.setContents(text)
  if config.concealPaste then
    pcall(hs.pasteboard.writeDataForUTI, nil,
      "org.nspasteboard.ConcealedType", "1", true)
  end
end

local learnProperNouns -- defined after the daemon plumbing (needs send())
local scheduleEditMining -- defined next to learnProperNouns (needs send())

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

-- Up to maxChars of text immediately before the cursor in the focused
-- field (accessibility), or nil when the app doesn't expose AX text. Feeds
-- capitalization/terminology context to the cleanup LLM.
local function beforeCursorText(maxChars)
  local ok, text = pcall(function()
    local focused = hs.axuielement.systemWideElement()
      :attributeValue("AXFocusedUIElement")
    if not focused then return nil end
    local range = focused:attributeValue("AXSelectedTextRange")
    local loc = range and (range.location or range.loc)
    if not loc or loc == 0 then return nil end
    local len = math.min(loc, maxChars)
    local s = focused:parameterizedAttributeValue("AXStringForRange",
      { location = loc - len, length = len })
    return (type(s) == "string" and s ~= "") and s or nil
  end)
  if ok then return text end
  return nil
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
    beforeCursor = config.contextInjection
      and beforeCursorText(config.contextMaxChars or 240) or nil,
  }
end

-- `variant` tags what is being pasted ("raw" | "polished") so the
-- raw/polished toggle knows which side is on screen. Defaults to "raw" —
-- every non-polish path (salvage, flush, no-polish) pastes raw text.
local function pasteTranscript(text, target, variant)
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
  archiveTake({
    kind = "take",
    app = target and target.app or nil,
    profile = activeProfile,
    engine = lastFinalEngine,
    raw = lastTake.raw,
    cleaned = lastTake.cleaned,
    polished = lastTake.polished,
    pasted = text,
    variant = variant or "raw",
    aiReason = lastAIReason,
    aiModel = lastAIModel,
    aiProvider = lastAIProvider,
    aiMs = lastAILatencyMs,
    finalizeMs = lastFinalizeMs,
    takeMs = lastTakeMs,
  })
  local restoreTo = nil
  if not config.keepOnClipboard then
    restoreTo = savedClipboard
  end
  setClipboardTranscript(text)
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
    -- Exactly what landed in the document (leading space included), for the
    -- raw/polished toggle's in-place swap.
    lastTake.pastedText = text
    lastTake.pastedVariant = variant or "raw"
    log.info("paste keystroke sent", {
      app = lastPasteApp,
      variant = lastTake.pastedVariant,
      pasteQueueMs = lastPasteQueueMs,
    })
    if learnProperNouns then learnProperNouns(text) end
    if scheduleEditMining then scheduleEditMining(text) end
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

local function flushPendingDelivery(reason)
  local pending = pendingDelivery
  if not pending then return end
  pendingDelivery = nil
  pending.valid = false
  lastAIReason = reason or "superseded"
  pasteTranscript(pending.localText, pending.target)
end

----------------------------------------------------------------
-- LATE-POLISH APPLY + SWAP HELPERS (shared by the delivery paths and the
-- Caps+R toggle).
----------------------------------------------------------------
local function utf16Length(s)
  local n = 0
  local ok = pcall(function()
    for _, cp in utf8.codes(s) do n = n + (cp > 0xFFFF and 2 or 1) end
  end)
  if not ok then return #s end -- AX verification still guards the swap
  return n
end

-- AX verification + selection: true only when the focused element has a
-- collapsed caret sitting immediately after text exactly equal to
-- `expected`, in which case that range is selected, ready for ⌘V.
local function axSelectPastedText(expected)
  local swapped = false
  pcall(function()
    local focused = hs.axuielement.systemWideElement()
      :attributeValue("AXFocusedUIElement")
    if not focused then return end
    local range = focused:attributeValue("AXSelectedTextRange")
    local loc = range and (range.location or range.loc)
    local selLen = (range and (range.length or range.len)) or 0
    if not loc or selLen ~= 0 then return end
    local len = utf16Length(expected)
    if loc < len then return end
    local before = focused:parameterizedAttributeValue("AXStringForRange",
      { location = loc - len, length = len })
    if before ~= expected then return end
    focused:setAttributeValue("AXSelectedTextRange",
      { location = loc - len, length = len })
    swapped = true
  end)
  return swapped
end

local swapTimers = {} -- anchor swap timers against hs.timer GC (footgun)

-- Clipboard + ⌘V over the selection axSelectPastedText just made, then
-- retag `take` so Caps+R keeps toggling correctly. opts.expectLen (utf16)
-- re-verifies the selection is still exactly that wide right before the
-- keystroke — aborts if the user typed in the 10ms gap (auto-apply only).
local function queueSwapPaste(take, text, variant, opts)
  setClipboardTranscript(text)
  local t = {}
  swapTimers[t] = true
  t.paste = hs.timer.doAfter(config.pasteDelay, function()
    if opts and opts.expectLen then
      local stillSelected = false
      pcall(function()
        local focused = hs.axuielement.systemWideElement()
          :attributeValue("AXFocusedUIElement")
        local range = focused and focused:attributeValue("AXSelectedTextRange")
        stillSelected = range ~= nil
          and (range.length or range.len) == opts.expectLen
      end)
      if not stillSelected then
        swapTimers[t] = nil
        log.warn("swap aborted; selection changed before paste")
        return
      end
    end
    hs.eventtap.keyStroke({ "cmd" }, "v", 0)
    take.pastedText = text
    take.pastedVariant = variant
    -- Our own synthetic ⌘V trips the typed-flag; clear it once it lands.
    t.clear = hs.timer.doAfter(0.3, function()
      typedSinceLastPaste = false
      swapTimers[t] = nil
    end)
  end)
end

-- Auto-apply a late validated polish IFF every guard holds. Returns true
-- when the swap keystroke was queued; false means caller falls back to the
-- alert + Caps+R behavior. NEVER clipboard-pastes on AX failure.
local function autoApplyLatePolish(take, replacement, startedMs)
  if not config.lateAutoApply then return false end
  if state ~= "idle" then return false end        -- a new take is under way
  if typedSinceLastPaste then return false end    -- user has moved on
  if type(take.pastedText) ~= "string" then return false end -- paste withheld
  local windowMs = (config.lateAutoApplyWindowSeconds or 20) * 1000
  if startedMs and nowMs() - startedMs > windowMs then return false end
  local text = replacement
  -- Mirror the smart-spacing decision the original paste made.
  if take.pastedText:match("^%s") then text = " " .. text end
  if text == take.pastedText then return false end
  if not axSelectPastedText(take.pastedText) then return false end
  queueSwapPaste(take, text, "polished",
    { expectLen = utf16Length(take.pastedText) })
  return true
end

-- A validated full polish arrived after its take already pasted. Store it
-- for Caps+R and, when AX can prove the pasted text is still untouched at
-- the caret, swap it in place (fix 2). `take` is the lastTake identity
-- captured at stop — the cross-take guard.
local function handleLatePolish(take, takeId, result, startedMs)
  if lastTake ~= take then return end
  if type(result) ~= "string" or result == "" then return end
  if result == take.cleaned then return end
  if take.pastedText and result == trim(take.pastedText) then return end
  take.polished = result
  local applied = autoApplyLatePolish(take, result, startedMs)
  log.info(applied and "late final polish auto-applied"
      or "final polish arrived after cap; kept for swap", {
    polishMs = startedMs and (nowMs() - startedMs) or nil,
    takeId = takeId, applied = applied,
  })
  archiveTake({ kind = "late_polish", takeId = takeId,
    polished = result, applied = applied or nil })
  hs.alert.show(applied and "Murmur: polished ✓ — Caps+R for raw"
    or "Polished — Caps+R to swap", 1.2)
end

-- WYSIWYG delivery: live polishing produced screen text, so the paste is the
-- assembled live view — polished segments, plus the not-yet-polished
-- remainder spliced from the (more accurate) batch final where an anchor
-- exists, plus one bounded touch-up call over that remainder. No full-take
-- polish happens; the batch raw stays in lastTake for Caps+R.
-- Stop path when live polishing did real work. Two legs race:
--   A) a FULL polish of the cleaned BATCH transcript — whole-take context
--      (cross-sentence rambling collapses, consistent capitalization) over
--      the most accurate recognizer text, so stream mishearings the batch
--      pass corrected can never reach the paste;
--   B) the assembled screen text — polished segments plus the remainder
--      spliced from the batch final — pasted only when leg A misses its cap
--      or rejects. A leg-A result arriving after the cap is kept on the
--      Caps+R swap side (same contract as the classic path).
-- The paste therefore never waits longer than livePolishFinalSeconds and is
-- never worse than what the panel already showed.
local function deliverLiveAssembled(polisher, rawText, cleanedBatch)
  takeSequence = takeSequence + 1
  local pending = {
    id = takeSequence,
    localText = cleanedBatch,
    target = activeTarget,
    valid = true,
  }
  pendingDelivery = pending
  local startedMs = nowMs()
  local take = lastTake

  -- Leg B: assemble the screen text (cached after the first call).
  local function assembleFallback()
    if pending.fallbackText then return pending.fallbackText end
    polisher:seal()
    local snap = polisher:snapshot()
    local lastPolished = 0
    for i, item in ipairs(snap.items) do
      if item.state == "polished" then lastPolished = i end
    end
    local prefixText, prefixRaw, remainderParts = {}, {}, {}
    for i, item in ipairs(snap.items) do
      if i <= lastPolished then
        prefixText[#prefixText + 1] = item.text
        prefixRaw[#prefixRaw + 1] = item.raw
      else
        remainderParts[#remainderParts + 1] = item.text
      end
    end
    if snap.openText ~= "" then
      remainderParts[#remainderParts + 1] = snap.openText
    end
    local prefix = table.concat(prefixText, " ")
    local remainder = table.concat(remainderParts, " ")
    -- Where the live view ran out of polish, prefer the batch recognizer's
    -- words: anchor the prefix's raw stream text inside the batch final and
    -- take everything after the anchor.
    local spliced = core.spliceBatchTail(table.concat(prefixRaw, " "), rawText)
    if spliced then remainder = spliced end
    local assembled = core.cleanupTranscript(trim(prefix .. " " .. remainder), {
      glossaryPath = config.glossaryPath,
      correctionsPath = config.correctionMemoryPath,
      snippetsPath = config.snippetsPath,
      voiceCommands = config.voiceCommands,
      lightCleanup = activeProfile ~= "Literal",
    })
    assembled = trim(assembled)
    if assembled == "" then assembled = cleanedBatch end
    pending.fallbackText = assembled
    pending.localText = assembled
    return assembled
  end

  local function finalize(final, how, meta)
    if not pending.valid or pendingDelivery ~= pending then return end
    pendingDelivery = nil
    for _, t in ipairs({ pending.finalCap, pending.polishPill,
      pending.graceWaiter, pending.graceCap }) do
      if t then t:stop() end
    end
    polisher:seal()
    local counts = polisher:counts()
    if state == "idle" then hidePill() end -- don't clobber a new take's pill
    play(config.soundStop)
    lastTake.polished = final ~= lastTake.cleaned and final or nil
    lastAIReason = how
    lastAILatencyMs = nowMs() - startedMs
    lastAIModel = meta and meta.model or lastAIModel
    lastAIProvider = meta and meta.provider or lastAIProvider
    log.info("delivering live-polished transcript", {
      input = transcriptLogFields(rawText),
      output = transcriptLogFields(final),
      segmentsPolished = counts.polished,
      segmentsRaw = counts.closed + counts.pending + counts.raw_final,
      calls = counts.calls,
      finalPolishWon = how == "final_polish",
      stopMs = nowMs() - startedMs,
    })
    panelShowText(final)
    pasteTranscript(final, pending.target,
      lastTake.polished and "polished" or "raw")
  end

  local function finishWithFallback()
    finalize(assembleFallback(), "live_assembled")
  end

  -- Give an in-flight segment call a short grace to land before leg B is
  -- assembled (its result is already paid for). Assembly only — the paste
  -- waits on leg A or its cap, never on the grace. Timers are anchored on
  -- `pending` (held by pendingDelivery) so the GC can't collect them.
  local graceSeconds = (config.livePolishStopGraceMs or 400) / 1000
  local function afterGrace(fn)
    if not polisher.inflight or graceSeconds <= 0 then
      fn()
      return
    end
    local graced = false
    local function once()
      if graced then return end
      graced = true
      if pending.graceWaiter then pending.graceWaiter:stop() end
      if pending.graceCap then pending.graceCap:stop() end
      pending.graceWaiter, pending.graceCap = nil, nil
      if pending.valid and pendingDelivery == pending then fn() end
    end
    pending.graceWaiter = hs.timer.waitUntil(
      function() return not polisher.inflight end, once, 0.05)
    pending.graceCap = hs.timer.doAfter(graceSeconds, once)
  end

  setClipboardTranscript(cleanedBatch) -- local backup while we wait
  pending.polishPill = hs.timer.doAfter(0.35, function()
    if pendingDelivery == pending and pending.valid then
      showPill("Polishing...", false)
    end
  end)

  local hone = honeAvailable()
  local budget = config.livePolishFinalSeconds or 1.2
  local shouldPolish = config.autoRefine
    and select(1, core.shouldUseAI(cleanedBatch, activeProfile, {
      minWords = config.autoRefineMinWords,
      minChars = config.autoRefineMinChars,
    }))
  if not hone or budget <= 0 or not shouldPolish then
    afterGrace(finishWithFallback)
    return
  end

  afterGrace(assembleFallback) -- precompute leg B while leg A runs

  -- FINAL-POLISH RACE (fix 1+3a): two refineText lanes with disjoint
  -- providers (fast chain vs the pinned anchor); the first result that
  -- validates wins. The pure state machine owns the latch/retry/cap logic;
  -- this driver just maps its actions onto timers, HTTP, and the paste.
  local race = core.newFinalPolishRace({
    retryEnabled = config.polishRejectRetry ~= false,
  })
  pending.race = race
  -- Build the polish system prompt once (one glossary read for both lanes;
  -- also the base the retry lane appends feedback to). Same content
  -- refineText would build itself from profile + context.app.
  local sysPrompt = type(hone.dictationSystemPrompt) == "function"
    and hone.dictationSystemPrompt({
      profile = activeProfile,
      appName = pending.target and pending.target.app or nil,
    }) or nil

  local runLane -- forward decl
  local function onLaneResult(result, meta)
    if not pending.valid then return end -- cancelled/superseded take
    result = trim(tostring(result or ""))
    local accepted, rejectReason = core.validateAIOutput(cleanedBatch, result)
    if accepted then
      local action = race:accepted()
      if action == "deliver" then
        finalize(result, "final_polish", meta)
      elseif action == "late" then
        handleLatePolish(take, pending.id, result, startedMs)
      end -- "drop": a winner already landed
    else
      local action = race:rejected(rejectReason)
      -- Always log reason AND rejected text (the "4 Faith" lesson).
      if action == "retry" then
        local introduced = core.introducedWords(cleanedBatch, result)
        log.warn("final polish rejected; retrying with feedback", {
          reason = rejectReason, takeId = pending.id,
          introduced = table.concat(introduced, ","),
          output = result:sub(1, 200),
        })
        -- Only append feedback when we hold the base prompt; a nil base
        -- must degrade to refineText's own default prompt, never to a
        -- feedback-only system prompt.
        runLane({ systemPrompt = sysPrompt
          and (sysPrompt .. "\n\n" .. core.retryFeedback(introduced))
          or nil })
      elseif action == "fallback" then
        log.warn("final polish rejected; pasting screen text", {
          reason = rejectReason, takeId = pending.id,
          output = result:sub(1, 200),
        })
        finishWithFallback()
      else
        log.debug("late/loser final polish rejected", {
          reason = rejectReason, takeId = pending.id,
          output = result:sub(1, 200),
        })
      end
    end
  end
  local function onLaneFail(msg)
    if not pending.valid then return end
    if race:failed() == "fallback" then
      log.warn("final polish failed; pasting screen text", {
        message = tostring(msg),
      })
      finishWithFallback()
    else
      log.debug("final polish lane failed (race continues or settled)", {
        message = tostring(msg), takeId = pending.id,
      })
    end
  end
  runLane = function(extra)
    race:launched()
    hone.refineText(cleanedBatch, onLaneResult, onLaneFail, {
      profile = activeProfile,
      maxOutputTokens = core.maxOutputTokens(cleanedBatch),
      context = pending.target and {
        app = pending.target.app,
        beforeCursor = pending.target.beforeCursor,
      } or nil,
      systemPrompt = extra and extra.systemPrompt or sysPrompt,
      provider = extra and extra.provider or nil,
      excludeProviders = extra and extra.excludeProviders or nil,
    })
  end

  pending.finalCap = hs.timer.doAfter(budget, function()
    if race:onCap() == "fallback" then
      log.warn("final polish missed the cap; pasting screen text", {
        budgetSeconds = budget, takeId = pending.id,
      })
      finishWithFallback()
    end
  end)

  local anchor = config.livePolishFinalRace
    and type(hone.raceAnchorProvider) == "function"
    and hone.raceAnchorProvider() or nil
  if anchor then
    runLane({ excludeProviders = { [anchor] = true } }) -- lane A: fast chain
    runLane({ provider = anchor })                      -- lane B: anchor pinned
  else
    runLane(nil) -- single lane: exactly today's behavior
  end
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
  -- Retain the take in full. The raw transcript is the source of truth; the
  -- polish (live or end-of-take) is a derived view of it, and the
  -- raw/polished toggle needs both sides after the paste.
  lastTake = { raw = rawText, cleaned = text, at = os.time() }
  -- WYSIWYG: when live polishing did real work, the paste is the screen
  -- text; zero polished segments falls through to the classic full-take
  -- polish below (short takes, outages, stream model missing).
  if livePolisher and livePolisher:counts().polished > 0 then
    deliverLiveAssembled(livePolisher, rawText, text)
    return
  end
  panelShowText(text)
  local hone = nil
  local shouldPolish, skipReason = core.shouldUseAI(text, activeProfile, {
    minWords = config.autoRefineMinWords,
    minChars = config.autoRefineMinChars,
  })
  if not config.autoRefine then shouldPolish, skipReason = false, "disabled" end
  if cleanupMeta and cleanupMeta.snippet then
    shouldPolish, skipReason = false, "snippet"
  end
  if shouldPolish then
    local ok, mod = pcall(require, "hone")
    if ok and type(mod) == "table" and type(mod.refineText) == "function" then
      hone = mod
    else
      skipReason = ok and "refine_unavailable" or tostring(mod)
    end
  end
  if not hone then
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
    pasteTranscript(text, activeTarget, "raw")
    return
  end

  setClipboardTranscript(text) -- local backup while we wait
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
  local take = lastTake
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
    lastAIProvider = meta and meta.provider or lastAIProvider
    lastAIReason = reason or (meta and meta.fallbackReason) or nil
    if result ~= text then
      log.info("dictation polish finished", {
        input = transcriptLogFields(text),
        output = transcriptLogFields(result),
        polishMs = elapsedMs(polishStartMs),
      })
      lastTake.polished = result
    else
      local fields = transcriptLogFields(text)
      fields.polishMs = elapsedMs(polishStartMs)
      log.info("dictation polish returned raw", fields)
    end
    pasteTranscript(result, pending.target,
      result ~= text and "polished" or "raw")
  end

  -- Long transcripts get a proportionally longer polish budget (capped);
  -- see autoRefineTimeoutMax in config.
  local timeoutSeconds = math.min(
    config.autoRefineTimeoutMax or 6.0,
    (config.autoRefineTimeout or 2.25)
      + math.max(0, #text - 600) / 1000 * (config.autoRefineTimeoutPerKChars or 1.0))
  timeout = hs.timer.doAfter(timeoutSeconds, function()
    log.warn("dictation polish timed out", {
      timeoutSeconds = timeoutSeconds,
      chars = #text,
    })
    finishWith(text, "timeout")
  end)
  hone.refineText(text,
    function(result, meta)
      local accepted, rejectReason = core.validateAIOutput(text, result)
      if done then
        -- The timeout already pasted raw, but the polish still arrived and
        -- the take wasn't cancelled: store it for Caps+R and maybe
        -- auto-apply (handleLatePolish re-checks lastTake == take and the
        -- pasted-identity guards internally).
        if accepted and result ~= text and pending.valid then
          handleLatePolish(take, pending.id, trim(tostring(result)),
            polishStartMs)
        end
        return
      end
      if not accepted then
        log.warn("dictation polish rejected", {
          reason = rejectReason, takeId = pending.id,
          output = tostring(result):sub(1, 200),
        })
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
      profile = activeProfile,
      maxOutputTokens = core.maxOutputTokens(text),
      context = activeTarget and {
        app = activeTarget.app,
        beforeCursor = activeTarget.beforeCursor,
      } or nil,
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
        -- The CoreML/E5RT runtime prints a benign, newline-less shape-
        -- inference exception during Parakeet warmup, which can glue itself
        -- onto the front of the next JSON line. Recover the JSON tail if one
        -- is present so the event survives; only genuinely unparseable
        -- output is an error.
        local brace = line:find("{", 1, true)
        local ok2, event2
        if brace then ok2, event2 = pcall(hs.json.decode, line:sub(brace)) end
        if ok2 and type(event2) == "table" then
          local prefix = line:sub(1, brace - 1):gsub("%s+$", "")
          if prefix ~= "" then
            log.info("daemon runtime notice (benign, prefixed a JSON line)",
              { message = prefix })
          end
          handleEvent(event2)
        else
          log.error("daemon emitted invalid json", { line = line })
        end
      end
    end
  end
  return true
end

-- The CoreML/Espresso runtime (E5RT) prints a one-time C++ shape-inference
-- exception to stderr the first time the Parakeet model is shaped. The
-- daemon's warmup pass deliberately absorbs it so real takes stay clean; it
-- is benign and lives below Swift's error handling, so it can't be caught in
-- the daemon. Recognize it here instead of raising an error on every launch.
local BENIGN_STDERR = {
  "E5RT encountered an STL exception",
  "PropagateInputTensorShapes",
}

local function onStderr(chunk)
  if not chunk or chunk == "" then return end
  local message = chunk:gsub("%s+$", "")
  for _, marker in ipairs(BENIGN_STDERR) do
    if message:find(marker, 1, true) then
      log.info("daemon warmup notice (benign CoreML shape inference)",
        { message = message })
      return
    end
  end
  log.error("daemon stderr", { message = message })
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
    if livePolisher then livePolisher:seal(); livePolisher = nil end
    if lastPartial ~= "" then
      log.warn("salvaging transcript after daemon exit", transcriptLogFields(lastPartial))
      if wasStopping and exitStopReason == "finish" then
        play(config.soundStop)
        lastTake = { raw = lastPartial, cleaned = lastPartial, at = os.time() }
        pasteTranscript(lastPartial)
      else
        setClipboardTranscript(lastPartial)
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
      "Build it: ~/.hammerspoon/murmur/hs-dictate/build.sh",
      4)
    return false
  end
  daemonReady = false
  stdoutBuf = ""
  local args = { config.locale,
    "--idle", tostring(config.micIdleSeconds or 180),
    "--stop-grace", tostring(config.stopGraceMs or 150),
    "--parakeet", tostring(config.parakeet or "off"),
    "--stream", tostring(config.stream or "off"),
    "--glossary", config.glossaryPath,
    "--corrections", config.correctionMemoryPath }
  if config.fastResults then table.insert(args, "--fast") end
  if config.punctuation then
    table.insert(args, "--punctuation")
  end
  table.insert(args, "--content-hint")
  table.insert(args, config.contentHint == "far-field" and "far-field" or "default")
  local preferred = preferredInputDevice()
  daemonDeviceUID = preferred and preferred:uid() or nil
  if daemonDeviceUID then
    table.insert(args, "--device")
    table.insert(args, daemonDeviceUID)
  end
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
-- GLOSSARY AUTO-LEARN — Wispr-style proper-noun pickup.
--
-- After each paste, unknown names/product words are counted; the second
-- sighting graduates the word into the glossary, which both biases the
-- recognizer (reload-context) and joins the LLM cleanup prompt.
----------------------------------------------------------------
local function glossaryLineCount()
  local n = 0
  local f = io.open(config.glossaryPath, "r")
  if not f then return 0 end
  for line in f:lines() do
    if line:gsub("#.*$", ""):match("%S") then n = n + 1 end
  end
  f:close()
  return n
end

learnProperNouns = function(text)
  if not config.glossaryAutoLearn then return end
  local ok, err = pcall(function()
    local known = {}
    for _, term in ipairs(core.contextTerms(
        config.glossaryPath, config.correctionMemoryPath, 1000) or {}) do
      for word in term:gmatch("[%w'%.%-]+") do known[word:lower()] = true end
    end
    local candidates = core.properNounCandidates(text, known)
    if #candidates == 0 then return end

    local counts = {}
    local f = io.open(config.properNounCountsPath, "r")
    if f then
      for line in f:lines() do
        local word, n = line:match("^(.-)\t(%d+)")
        if word and word ~= "" then counts[word] = tonumber(n) end
      end
      f:close()
    end

    local learned = {}
    for _, word in ipairs(candidates) do
      local n = (counts[word] or 0) + 1
      if n >= (config.glossaryAutoLearnThreshold or 2) then
        counts[word] = nil
        learned[#learned + 1] = word
      else
        counts[word] = n
      end
    end

    if #learned > 0 then
      if glossaryLineCount() + #learned > (config.glossaryAutoLearnMaxTerms or 90) then
        log.warn("glossary auto-learn skipped; glossary near context cap", {
          candidates = table.concat(learned, ", "),
        })
      else
        local g = io.open(config.glossaryPath, "a")
        if g then
          for _, word in ipairs(learned) do g:write(word, "\n") end
          g:close()
          send("reload-context")
          log.info("glossary auto-learned terms", {
            terms = table.concat(learned, ", "),
          })
          hs.alert.show("Dictation learned: "
            .. table.concat(learned, ", "), 1.0)
        end
      end
    end

    local w = io.open(config.properNounCountsPath, "w")
    if w then
      for word, n in pairs(counts) do w:write(word, "\t", n, "\n") end
      w:close()
    end
  end)
  if not ok then
    log.warn("glossary auto-learn failed", { error = tostring(err) })
  end
end

-- Wispr-style edit mining: after a paste, snapshot the focused field's
-- value; editMiningDelaySeconds later, re-read it and let core.mineEdits
-- attribute word replacements inside the pasted region to the user. Counts
-- live in editMinedPath ("from\tto\tcount"; -1 = already promoted); a pair
-- seen editMiningThreshold times is promoted into the corrections file the
-- polish + display layers already consume. Timers anchor on this table —
-- an unanchored doAfter can be GC'd before firing.
local editMiningPending = {}

local function readFocusedFieldValue()
  local ok, elem, value = pcall(function()
    local focused = hs.axuielement.systemWideElement()
      :attributeValue("AXFocusedUIElement")
    if not focused then return nil, nil end
    return focused, focused:attributeValue("AXValue")
  end)
  if not ok then return nil, nil end
  return elem, type(value) == "string" and value or nil
end

local function loadEditMineCounts()
  local counts = {}
  local f = io.open(config.editMinedPath, "r")
  if f then
    for line in f:lines() do
      local from, to, n = line:match("^(.-)\t(.-)\t(%-?%d+)$")
      if from and from ~= "" and to then
        counts[from .. "\t" .. to] = tonumber(n)
      end
    end
    f:close()
  end
  return counts
end

local function saveEditMineCounts(counts)
  local f = io.open(config.editMinedPath, "w")
  if not f then return end
  for key, n in pairs(counts) do
    local from, to = key:match("^(.-)\t(.*)$")
    f:write(from, "\t", to, "\t", n, "\n")
  end
  f:close()
end

local function mineEditsNow(job)
  editMiningPending[job] = nil
  local ok, err = pcall(function()
    local after = job.elem:attributeValue("AXValue")
    if type(after) ~= "string" then return end
    local edits = core.mineEdits(job.pasted, job.before, after)
    if #edits == 0 then return end
    local counts = loadEditMineCounts()
    local promoted = {}
    for _, edit in ipairs(edits) do
      local key = edit.from .. "\t" .. edit.to
      local n = counts[key]
      if n ~= -1 then
        n = (n or 0) + 1
        if n >= (config.editMiningThreshold or 2) then
          if appendCorrection(edit.from, edit.to) then
            counts[key] = -1
            promoted[#promoted + 1] = edit.from .. " → " .. edit.to
          end
        else
          counts[key] = n
        end
      end
      log.info("edit mined from user correction", {
        from = edit.from, to = edit.to, count = counts[key],
      })
    end
    saveEditMineCounts(counts)
    if #promoted > 0 then
      send("reload-context")
      hs.alert.show("Murmur learned: "
        .. table.concat(promoted, ", "), 1.2)
    end
  end)
  if not ok then
    log.debug("edit mining pass skipped", { error = tostring(err) })
  end
end

scheduleEditMining = function(pastedText)
  if not config.editMining then return end
  local job = { pasted = pastedText }
  editMiningPending[job] = true
  -- Snapshot slightly after the ⌘V so the field has processed the paste.
  job.snapshotTimer = hs.timer.doAfter(0.5, function()
    local elem, before = readFocusedFieldValue()
    if not elem or not before or #before > 20000
      or not before:find(job.pasted, 1, true) then
      editMiningPending[job] = nil
      return
    end
    job.elem, job.before = elem, before
    job.timer = hs.timer.doAfter(config.editMiningDelaySeconds or 45,
      function() mineEditsNow(job) end)
  end)
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
    if livePolisher then livePolisher:seal(); livePolisher = nil end
    if reason == "finish" and lastPartial ~= "" then
      play(config.soundStop)
      lastTake = { raw = lastPartial, cleaned = lastPartial, at = os.time() }
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
        if panelEnabled() and liveView then
          -- Full transcript lives in the panel; the pill stays a status
          -- strip (its "Listening" text is already up from "started").
          feedLivePanel(event.text, event.source)
        elseif config.showLiveTranscript then
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
    fields.engine = event.engine
    lastFinalizeMs = fields.finalizeMs
    lastTakeMs = fields.takeMs
    lastFinalEngine = event.engine or recognizerEngine
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
  if ensurePreferredInput() then
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
  stopPreview()
  if panelEnabled() then resetLivePanel() end
  pressTime = hs.timer.secondsSinceEpoch()
  savedClipboard = hs.pasteboard.getContents()
  if config.autoRefine then
    pcall(function() require("hone").prewarmConnection() end)
  end
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
    setClipboardTranscript(lastPartial)
  end
  armWatchdog()
  if panelEnabled() and liveView then
    -- The take is over: settle the whole live view to committed opacity and,
    -- with live polish on, flush the remaining words as a final segment so
    -- its call overlaps the batch finalize.
    liveView:commitAll()
    if livePolisher then
      local now = hs.timer.secondsSinceEpoch()
      livePolisher:feed(liveView:snapshot().committed, now)
      livePolisher:finishTake(now)
      dispatchLivePolish()
    end
    renderPanel()
    showPill("Listening", false)
  else
    showPill(lastPartial ~= "" and lastPartial or "Listening", false)
  end
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
  if livePolisher then livePolisher:reset() end
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
-- CAPS TRIGGER — Caps+M via QuickShots' shared Caps (F18) tap (default).
--
-- Caps+M (non-autorepeat keyDown, consumed) starts a take; QuickShots'
-- release hook fires when Caps is let go and routes through the same
-- tap/hold logic as the legacy modifier trigger: a quick release goes
-- hands-free, a longer hold stops and pastes. While hands-free, Caps+M
-- again stops.
----------------------------------------------------------------
local capsTriggerArmed = false -- Caps+M fired during the current Caps hold

local function startCapsTrigger()
  local b = config.capsTrigger
  if type(b) ~= "table" or not b[2] then return false end
  local okQS, qs = pcall(require, "quickshots")
  if not (okQS and type(qs) == "table"
      and type(qs.registerCapsAction) == "function"
      and type(qs.registerCapsReleaseHook) == "function") then
    return false
  end
  qs.registerCapsAction(b[1] or {}, b[2], function()
    if state == "idle" then
      capsTriggerArmed = true
      log.debug("caps trigger down", { key = b[2] })
      M.begin()
    elseif handsFree and (state == "recording" or state == "starting") then
      capsTriggerArmed = false
      log.debug("caps trigger stop (hands-free)", { key = b[2] })
      M.finish()
    end
  end)
  qs.registerCapsReleaseHook("murmur", function()
    if not capsTriggerArmed then return end
    capsTriggerArmed = false
    log.debug("caps trigger released", { state = state })
    triggerReleased()
  end)
  log.info("caps trigger registered", { binding = "caps+" .. tostring(b[2]) })
  return true
end

----------------------------------------------------------------
-- TRIGGER TAP — legacy bare modifier key trigger (e.g. Right⌘), plus the
-- keyDown watcher that smart spacing relies on.
--
-- Modifier presses arrive as flagsChanged events. The key's press/release
-- is never consumed (a lone modifier is harmless to apps); instead, a
-- keyDown of any other key during the hold marks the press as a normal
-- keyboard shortcut: recording cancels silently and the combo passes
-- through untouched. With no modifier trigger configured, only the keyDown
-- watcher runs.
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

local function startTriggerTap(trigger)
  local keyName, trigCode, flagName = nil, nil, nil
  if type(trigger) == "table" then
    keyName = tostring(trigger[2] or "rightcmd"):lower()
    trigCode = hs.keycodes.map[keyName]
    flagName = MODIFIER_FLAG[keyName]
    if not trigCode or not flagName then
      log.error("invalid trigger", { key = keyName })
      hs.alert.show("dictation: trigger '" .. keyName ..
        "' must be a modifier key (e.g. rightcmd)", 4)
      trigCode, flagName = nil, nil
    end
  end

  local typeFlags   = hs.eventtap.event.types.flagsChanged
  local typeKeyDown = hs.eventtap.event.types.keyDown
  local types = trigCode and { typeFlags, typeKeyDown } or { typeKeyDown }

  if trigTap then trigTap:stop(); trigTap = nil end
  trigTap = hs.eventtap.new(types, function(e)
    local etype = e:getType()

    if trigCode and etype == typeFlags and e:getKeyCode() == trigCode then
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
  log.info("trigger tap started", { key = keyName or "none (keyDown watcher only)" })
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

----------------------------------------------------------------
-- RAW / POLISHED TOGGLE — swap the last paste between versions.
--
-- Polish is a derived, non-destructive view: the raw transcript is always
-- retained, so the other version is always available after a paste. In apps
-- that speak the accessibility text API the pasted text is re-selected
-- (verified character-for-character first, so foreign text is never
-- touched) and replaced in place; elsewhere the other version goes on the
-- clipboard to paste manually.
----------------------------------------------------------------
function M.toggleRawPolished()
  local take = lastTake
  if not take.pastedText then
    hs.alert.show("Murmur: nothing to toggle", 1.0)
    return false
  end
  local other, otherVariant
  if take.pastedVariant == "polished" then
    other, otherVariant = take.cleaned, "raw"
  else
    other, otherVariant = take.polished, "polished"
  end
  if type(other) ~= "string" or other == "" then
    hs.alert.show(take.pastedVariant == "polished"
      and "Murmur: raw version unavailable"
      or "Murmur: no polished version of this take", 1.2)
    return false
  end
  -- Mirror the smart-spacing decision made when the original text landed.
  if take.pastedText:match("^%s") then other = " " .. other end

  if axSelectPastedText(take.pastedText) then
    queueSwapPaste(take, other, otherVariant)
    log.info("toggled pasted variant in place", { to = otherVariant })
    archiveTake({ kind = "swap", to = otherVariant })
    hs.alert.show("Murmur: " .. otherVariant, 0.8)
  else
    setClipboardTranscript(other)
    log.info("variant toggle fell back to clipboard", { to = otherVariant })
    hs.alert.show("Murmur: " .. otherVariant .. " version on clipboard — ⌘V",
      1.6)
  end
  return true
end

-- Debug: evaluate JS inside the transcript panel and log the result.
function M.panelDebug(js)
  if not panel then
    log.info("panel debug", { result = "no panel" })
    return
  end
  panel:evaluateJavaScript(js, function(result, err)
    log.info("panel debug", {
      js = js,
      result = hs.inspect(result),
      err = err and hs.inspect(err) or nil,
      ready = panelReady,
      queued = #panelQueue,
    })
  end)
end

-- Debug/introspection: both versions of the newest take.
function M.lastTranscripts()
  return {
    raw = lastTake.raw,
    cleaned = lastTake.cleaned,
    polished = lastTake.polished,
    pastedVariant = lastTake.pastedVariant,
    at = lastTake.at,
  }
end

-- Debug: drive the transcript panel with synthetic hypotheses — no mic, no
-- daemon, no network — to inspect growth, styling, scrolling, and (with the
-- stubbed live polish) segments visibly rewriting raw -> polished:
--   hs -c "require('murmur').previewPanel()"
--   hs -c "require('murmur').previewPanel({ livePolish = false })"  -- legacy
function M.previewPanel(opts)
  opts = opts or {}
  if state ~= "idle" then return end
  local sample = "Um, so this is, uh, a live preview of the Murmur panel. "
    .. "Words appear as they are recognized, you know, and settle into "
    .. "committed text once stable. Ship it on Tuesday, no, Wednesday. "
    .. "Sentences polish themselves while later words are, um, still being "
    .. "spoken, so the transcript upgrades in place as you watch it. One "
    .. "segment stays raw on purpose, because its polish call gets rejected "
    .. "by the validator. Once the transcript grows past the panel's maximum "
    .. "height it scrolls, pinned to the newest words. Scroll up to release "
    .. "the pin and read earlier text, then click the jump-to-live button to "
    .. "re-pin. This preview hides itself a few seconds after the last word."
  local words = {}
  for w in sample:gmatch("%S+") do words[#words + 1] = w end
  stopPreview()
  -- Stubbed transport: canned edits after a delay. Call 3 outlasts the call
  -- timeout (exercises fail + retry), one call returns a validator-rejected
  -- result (its segments stay raw).
  local previewCall = 0
  livePolishTransport = function(dispatch, onDone, onFail)
    previewCall = previewCall + 1
    local n = previewCall
    local delay = n == 3 and 3.0 or 0.8
    previewTimers[#previewTimers + 1] = hs.timer.doAfter(delay, function()
      if n == 4 then
        onDone("See https://example.com for details")
        return
      end
      local out = dispatch.text
        :gsub("%f[%w][Uu]m%f[%W],?%s*", ""):gsub("%f[%w][Uu]h%f[%W],?%s*", "")
        :gsub("%f[%w][Yy]ou know%f[%W],?%s*", "")
        :gsub("Tuesday, no, Wednesday", "Wednesday")
        :gsub("^%l", string.upper)
        :gsub("^[,%s]+", "")
      onDone(out)
    end)
  end
  resetLivePanel()
  if opts.livePolish == false then livePolisher = nil end
  if not showTranscriptPanel() then
    stopPreview()
    hs.alert.show("Murmur: transcript panel unavailable", 1.5)
    return
  end
  showPill("Listening", true)
  local i = 0
  previewTicker = hs.timer.doEvery(0.14, function()
    i = i + 1
    if i > #words then
      if previewTicker then previewTicker:stop(); previewTicker = nil end
      if liveView then
        liveView:commitAll()
        if livePolisher then
          local now = hs.timer.secondsSinceEpoch()
          livePolisher:feed(liveView:snapshot().committed, now)
          livePolisher:finishTake(now)
          dispatchLivePolish()
        end
        renderPanel()
      end
      previewTimers[#previewTimers + 1] = hs.timer.doAfter(8, function()
        stopPreview()
        if state == "idle" then hidePill() end
      end)
      return
    end
    local hyp = table.concat(words, " ", 1, i)
    -- Every seventh hypothesis mangles its newest word, then the next one
    -- corrects it — the tail revises, committed text never does.
    if i % 7 == 3 then
      hyp = hyp:gsub("%S+$", function(w) return w:sub(1, -2) .. "-uh" end)
    end
    feedLivePanel(hyp, "preview")
  end)
end

-- Resolve the real source directory (murmur.lua in ~/.hammerspoon is a
-- symlink into the checkout; tools/ lives next to the real file).
local function murmurSourceDir()
  local src = debug.getinfo(1, "S").source:match("^@(.+)$")
  if not src then return nil end
  local resolved = hs.fs.pathToAbsolute(src) or src
  return resolved:match("^(.*)/")
end

local selfEvalTimer = nil
local selfEvalTask = nil

-- Run the nightly self-eval now (also called by the scheduled timer).
-- `date` optionally names a YYYY-MM-DD day; default is decided by the
-- script (the day that ended most recently).
function M.selfEval(date)
  if selfEvalTask and selfEvalTask:isRunning() then
    log.warn("self-eval already running")
    return false
  end
  local dir = murmurSourceDir()
  local script = dir and (dir .. "/tools/self_eval.lua")
  if not script or not hs.fs.attributes(script) then
    log.warn("self-eval script not found", { script = tostring(script) })
    return false
  end
  if not hs.fs.attributes(config.selfEvalLua) then
    log.warn("self-eval lua interpreter not found", {
      lua = config.selfEvalLua,
    })
    return false
  end
  local args = { script }
  if date then args[#args + 1] = tostring(date) end
  selfEvalTask = hs.task.new(config.selfEvalLua,
    function(exitCode, stdOut, stdErr)
      selfEvalTask = nil
      local summary = tostring(stdOut or ""):match("([^\n]+)%s*$") or ""
      log.info("self-eval finished", {
        exitCode = exitCode, summary = summary,
        stderr = tostring(stdErr or ""):sub(1, 200),
      })
      pcall(function()
        hs.notify.new({
          title = "Murmur self-eval",
          informativeText = summary ~= "" and summary
            or ("exit " .. tostring(exitCode)),
        }):send()
      end)
    end, args)
  selfEvalTask:start()
  log.info("self-eval started", { script = script, date = date })
  return true
end

function M.start()
  -- Saved settings (Caps+K → Settings, via settings_overlay) win over file defaults.
  pcall(function() require("settings_overlay").apply("murmur", config) end)
  -- Caps+M through QuickShots' shared Caps tap is the trigger. If that tap
  -- isn't available and no modifier trigger is configured, fall back to
  -- Right⌘ so dictation is never left without a hotkey.
  local modifierTrigger = config.trigger
  if not startCapsTrigger() and type(modifierTrigger) ~= "table" then
    if type(config.capsTrigger) == "table" then
      modifierTrigger = { {}, "rightcmd" }
      log.warn("caps tap unavailable; falling back to rightcmd trigger")
      pcall(function()
        hs.alert.show("murmur: Caps tap unavailable — using Right⌘", 3)
      end)
    end
  end
  startTriggerTap(modifierTrigger)
  startInputWatcher()
  if config.selfEval then
    selfEvalTimer = hs.timer.doAt(config.selfEvalTime or "03:30", "1d",
      function() M.selfEval() end)
  end
  -- Raw/polished toggle for the last paste: Caps+R through QuickShots'
  -- shared Caps tap when available, otherwise ⌃⌥⌘D.
  local okQS, qs = pcall(require, "quickshots")
  if okQS and type(qs) == "table"
      and type(qs.registerCapsAction) == "function" then
    qs.registerCapsAction({}, "r", function() M.toggleRawPolished() end)
    log.info("caps binding registered", { binding = "caps+r raw/polished" })
  else
    pcall(function()
      hs.hotkey.bind({ "ctrl", "alt", "cmd" }, "d",
        function() M.toggleRawPolished() end)
      log.info("fallback binding registered", { binding = "⌃⌥⌘D raw/polished" })
    end)
  end
  -- Prewarm so the very first take starts instantly.
  if ensurePreferredInput() then
    hs.timer.doAfter(1.0, function()
      if state == "idle" then spawnDaemon() end
    end)
  else
    spawnDaemon()
  end
  log.info("started", {
    capsTrigger = type(config.capsTrigger) == "table"
      and ("caps+" .. tostring(config.capsTrigger[2])) or "off",
    trigger = type(modifierTrigger) == "table"
      and tostring(modifierTrigger[2]) or "off",
    autoRefine = config.autoRefine,
    autoRefineMinChars = config.autoRefineMinChars,
    autoRefineMinWords = config.autoRefineMinWords,
    autoRefineTimeout = config.autoRefineTimeout,
    cancelTimeout = config.cancelTimeout,
    punctuation = config.punctuation,
    voiceCommands = config.voiceCommands,
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
    finalEngine = lastFinalEngine,
    lastTotalLatencyMs = lastTotalLatencyMs,
    lastAILatencyMs = lastAILatencyMs,
    aiModel = lastAIModel,
    aiProvider = lastAIProvider,
    lastAIReason = lastAIReason,
    transcriptPanel = config.transcriptPanel,
    transcriptPanelVisible = panelVisible,
    lastPastedVariant = lastTake.pastedVariant,
    lastPolishAvailable = lastTake.polished ~= nil,
    livePolish = config.livePolish,
    livePolishActive = livePolisher ~= nil,
    livePolishSegments = livePolisher and livePolisher:counts() or nil,
  }
end

-- Debug/introspection: run the local cleanup pass without recording.
M.cleanupTranscript = cleanupTranscript
M.rememberCorrection = appendCorrection

-- Exposed so users can read/mutate config from init.lua before/after start().
M.config = config

return M
