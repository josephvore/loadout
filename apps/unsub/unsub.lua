-- unsub.lua — Caps+U: unsubscribe from the email selected in Apple Mail.
--
-- Thin trigger. All the work happens in unsub.py (run as a background task so
-- Hammerspoon never blocks): one-click List-Unsubscribe POST → mailto sent
-- from the receiving account → web unsubscribe page filled and submitted
-- automatically (OpenAI judges unfamiliar pages) → otherwise the page opens
-- in your browser to finish. Nothing in Mail is moved or deleted.
--
-- Dry run (reports the plan, changes nothing):  open -g "hammerspoon://unsub"
-- Load from ~/.hammerspoon/init.lua with: require("unsub").start()

local M = {}

----------------------------------------------------------------
-- USER CONFIGURATION
----------------------------------------------------------------
local config = {
  capsUnsub = { {}, "u" },                              -- Caps+U
  fallbackUnsub = { { "ctrl", "alt", "cmd" }, "u" },    -- if the Caps tap is unavailable

  python = "/usr/bin/python3",
  script = hs.configdir .. "/unsub.py",  -- linked by install.sh

  -- Editable from Caps+K → Unsubscribe (settings/unsub.schema.json).
  mailtoMode = "send",   -- "send" | "compose" (draft opens; you press Send)
  useAI = true,          -- let OpenAI judge unfamiliar unsubscribe pages
  aiModel = "gpt-5.4",

  timeoutSeconds = 120,
  alertSeconds = 3,
}

local log = nil
local running = nil

local function alert(msg, secs) hs.alert.show(msg, secs or config.alertSeconds) end

local function mailFrontmost()
  local app = hs.application.frontmostApplication()
  return app and app:bundleID() == "com.apple.mail"
end

function M.unsubscribe(opts)
  local dry = opts and opts.dry
  if running then
    log.info("skip: already running")
    return alert("Unsub already working on one…", 1.5)
  end
  if not dry and not mailFrontmost() then
    log.info("skip: Mail not frontmost")
    return alert("Caps+U works in Apple Mail. Select an email first", 2)
  end

  local args = { config.script }
  if dry then args[#args + 1] = "--dry" end
  if config.mailtoMode == "compose" then args[#args + 1] = "--compose" end
  if not config.useAI then args[#args + 1] = "--no-ai" end
  if type(config.aiModel) == "string" and config.aiModel ~= "" then
    args[#args + 1] = "--model"; args[#args + 1] = config.aiModel
  end
  alert(dry and "Unsub: dry run…" or "Unsubscribing…", 1)
  log.info("run", { dry = dry and true or false })

  local timer, timedOut = nil, false
  running = hs.task.new(config.python, function(code, stdout, stderr)
    if timer then timer:stop() end
    running = nil
    if timedOut then return end -- the timeout already alerted
    for line in (stderr or ""):gmatch("[^\n]+") do log.info("py", { line = line:sub(1, 300) }) end
    local ok, res = pcall(hs.json.decode, stdout or "")
    if not ok or type(res) ~= "table" then
      log.error("bad output", { code = code, stdout = (stdout or ""):sub(1, 300) })
      return alert("⚠️ Unsub failed. See ~/.hammerspoon/logs/unsub.log", 3)
    end
    log.info("result", { ok = res.ok, method = res.method, sender = res.sender, message = res.message })
    alert((res.ok and "✅ " or "⚠️ ") .. tostring(res.message),
      res.ok and config.alertSeconds or 4)
    if type(res.open_url) == "string" and res.open_url:match("^https?://") then
      hs.urlevent.openURL(res.open_url)
    end
  end, args)
  running:start()

  timer = hs.timer.doAfter(config.timeoutSeconds, function()
    if running and running:isRunning() then
      timedOut = true
      running:terminate()
      log.warn("timed out")
      alert("⚠️ Unsub timed out", 2)
    end
  end)
end

function M.start()
  log = require("litelog").new("unsub")
  pcall(function() require("settings_overlay").apply("unsub", config) end)
  local fn = require("litelog").wrap("unsub", "unsubscribe", function() M.unsubscribe() end)
  local ok, qs = pcall(require, "quickshots")
  if ok and type(qs) == "table" and type(qs.registerCapsAction) == "function" then
    qs.registerCapsAction(config.capsUnsub[1], config.capsUnsub[2], fn)
    log.info("caps binding registered", { key = "caps+" .. config.capsUnsub[2] })
  else
    hs.hotkey.bind(config.fallbackUnsub[1], config.fallbackUnsub[2], fn)
    log.warn("caps tap unavailable; fallback binding registered")
  end
  -- hammerspoon://unsub — ALWAYS a dry run (any app can open this URL).
  hs.urlevent.bind("unsub", function() M.unsubscribe({ dry = true }) end)
  log.info("started")
end

M.config = config

return M
