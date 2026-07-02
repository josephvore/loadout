-- shortcuts.lua — Caps+K: a popup window listing every Hammerspoon shortcut.
-- Mouse-driven hs.webview panel: each row shows the key, what it does, and the
-- file it lives in, with Run / Rebind / Reset buttons. Rebinding is done by
-- clicking Rebind and pressing the new combo directly in the window.
--
-- Rebinds are persisted in hs.settings and applied to each module's config
-- table on startup (before the modules bind), so the .lua files in git remain
-- the defaults and custom keys layer on top. Rows show "custom" when a
-- persisted override is active.
--
-- init.lua wiring (ORDER MATTERS):
--   pcall(function() require("shortcuts").applyOverrides() end)  -- before any module starts
--   ...quickshots / flows / refine start...
--   pcall(function() require("shortcuts").start() end)           -- last

local M = {}

local HOME = os.getenv("HOME") or ""
local OVERRIDES_KEY = "shortcuts.overrides.v1"
local REOPEN_KEY = "shortcuts.reopenAfterReload"

----------------------------------------------------------------
-- CONFIG
----------------------------------------------------------------
local config = {
  capsMenu = { {}, "k" }, -- Caps+K opens the window (via QuickShots' F18 tap)
  fallbackMenu = { { "ctrl", "alt", "cmd" }, "k" }, -- used if the caps tap is unavailable
  windowWidth = 780,
  windowHeight = 720,
}

----------------------------------------------------------------
-- REGISTRY — one entry per shortcut across all modules.
-- `path` walks that module's exposed `config` table to the { mods, key }
-- binding, so the window always displays the live binding (incl. overrides).
----------------------------------------------------------------
local MODULE_FILES = {
  quickshots = "/Volumes/Code/quickshots/quickshots.lua",
  flows      = HOME .. "/dotfiles/hammerspoon/flows.lua",
  refine     = HOME .. "/dotfiles/hammerspoon/refine.lua",
  shortcuts  = HOME .. "/dotfiles/hammerspoon/shortcuts.lua",
}

local MODULE_ORDER = { "quickshots", "refine", "flows", "shortcuts" }

local MODULE_TITLES = {
  quickshots = "QuickShots — Screenshots",
  refine     = "Refine — AI Text",
  flows      = "Flows — Quick Launch",
  shortcuts  = "This Menu",
}

local REGISTRY = {
  -- QuickShots — Caps-held combos consumed by the shared F18 tap.
  { id = "quickshots.capture", module = "quickshots", path = { "capsBindings", "capture" }, kind = "caps",
    label = "Drag-area screenshot",
    desc  = "Interactive drag-region capture to ~/Pictures/QuickShots (Space = window mode, Esc = cancel)",
    run   = function(m) m.capture() end },
  { id = "quickshots.pasteGroup", module = "quickshots", path = { "capsBindings", "pasteGroup" }, kind = "caps",
    label = "Paste latest screenshot group",
    desc  = "Copy the newest auto-grouped shots (taken within 20s of each other) and Cmd+V them",
    run   = function(m) m.pasteGroup() end },
  { id = "quickshots.pasteLastN", module = "quickshots", path = { "capsBindings", "pasteLastN" }, kind = "caps",
    label = "Paste last 4 screenshots",
    desc  = "Copy the most recent N shots (default 4) and Cmd+V them",
    run   = function(m) m.pasteLastN() end },
  { id = "quickshots.promptLastN", module = "quickshots", path = { "capsBindings", "promptLastN" }, kind = "caps",
    label = "Paste last N screenshots (prompt)",
    desc  = "Ask how many recent shots to paste, then paste them",
    run   = function(m) m.promptLastN() end },
  { id = "quickshots.openFolder", module = "quickshots", path = { "capsBindings", "openFolder" }, kind = "caps",
    label = "Open screenshots folder",
    desc  = "Open ~/Pictures/QuickShots in Finder",
    run   = function(m) m.openFolder() end },
  { id = "quickshots.toggleBurst", module = "quickshots", path = { "capsBindings", "toggleBurst" }, kind = "caps",
    label = "Toggle burst capture",
    desc  = "Chain drag-captures until toggled off (or Esc); the whole burst pastes as one group",
    run   = function(m) m.toggleBurst() end },
  { id = "quickshots.pasteFiles", module = "quickshots", path = { "capsBindings", "pasteFiles" }, kind = "caps",
    label = "Paste latest group as files",
    desc  = "Paste the newest group as Finder-style file objects (for Slack/Mail/Messages)",
    run   = function(m)
      local saved = m.config.pasteMode
      m.config.pasteMode = "files"
      m.pasteGroup()
      m.config.pasteMode = saved
    end },
  { id = "quickshots.devCapture", module = "quickshots", path = { "capsBindings", "devCapture" }, kind = "caps",
    label = "Dev capture → Codex",
    desc  = "Capture shots into a session dir, then open Codex in iTerm with them staged",
    run   = function(m) m.toggleDevCapture() end },

  -- Refine — OpenAI text refinement.
  { id = "refine.clipboard", module = "refine", path = { "capsClipboard" }, kind = "caps",
    label = "Refine clipboard text (AI)",
    desc  = "Send clipboard text to OpenAI for clarity/conciseness, then paste the result",
    run   = function(m) m.refineClipboard() end },
  { id = "refine.selection", module = "refine", path = { "capsSelection" }, kind = "caps",
    label = "Refine selected text (AI)",
    desc  = "Copy the current selection, refine it via OpenAI, and paste over it in place",
    run   = function(m) m.refineSelection() end },

  -- Flows — ordinary global hotkeys (⌃⌥⌘ combos).
  { id = "flows.obsidian", module = "flows", path = { "hotkeys", "obsidian" }, kind = "hotkey",
    label = "Obsidian quick capture",
    desc  = "Prompt for text (Wispr-friendly) and append it to the Obsidian Inbox note",
    run   = function(m) m.obsidianCapture() end },
  { id = "flows.claude", module = "flows", path = { "hotkeys", "claude" }, kind = "hotkey",
    label = "Voice Claude Code",
    desc  = "Open a new iTerm window in the current repo running claude",
    run   = function(m) m.voiceClaudeCode() end },
  { id = "flows.dogfood", module = "flows", path = { "hotkeys", "dogfood" }, kind = "hotkey",
    label = "Claude Chrome side panel",
    desc  = "Focus Chrome, toggle the Claude panel (Cmd+E), then auto-start Wispr dictation",
    run   = function(m) m.claudeChromeDogfood() end },
  { id = "flows.search", module = "flows", path = { "hotkeys", "search" }, kind = "hotkey",
    label = "Chrome new tab / search",
    desc  = "Focus Chrome and open a new tab ready to type a search",
    run   = function(m) m.chromeSearch() end },

  -- This window.
  { id = "shortcuts.menu", module = "shortcuts", path = { "capsMenu" }, kind = "caps",
    label = "Shortcuts window (this window)",
    desc  = "Popup listing every Hammerspoon shortcut; run, rebind, or reset them",
    run   = function(m) m.show() end },
}

----------------------------------------------------------------
-- HELPERS
----------------------------------------------------------------
local function loadOverrides()
  local o = hs.settings.get(OVERRIDES_KEY)
  if type(o) ~= "table" then o = {} end
  return o
end

local function saveOverrides(o)
  hs.settings.set(OVERRIDES_KEY, o)
end

-- Walk `module.config` along entry.path; returns the {mods, key} binding
-- table, or nil if the module failed to load (e.g. volume unmounted).
local function currentBinding(entry)
  local ok, m = pcall(require, entry.module)
  if not ok or type(m) ~= "table" or type(m.config) ~= "table" then return nil end
  local node = m.config
  for _, k in ipairs(entry.path) do
    if type(node) ~= "table" then return nil end
    node = node[k]
  end
  if type(node) == "table" and node[2] then return node end
  return nil
end

-- Overwrite the binding at entry.path with `binding` ({mods, key}).
local function setBinding(entry, binding)
  local ok, m = pcall(require, entry.module)
  if not ok or type(m) ~= "table" or type(m.config) ~= "table" then return false end
  local node = m.config
  for i = 1, #entry.path - 1 do
    node = node[entry.path[i]]
    if type(node) ~= "table" then return false end
  end
  node[entry.path[#entry.path]] = binding
  return true
end

local MOD_SYMBOLS = { shift = "⇧", ctrl = "⌃", alt = "⌥", cmd = "⌘" }

local function comboLabel(kind, binding)
  local s = (kind == "caps") and "⇪" or ""
  for _, mod in ipairs(binding[1] or {}) do
    s = s .. (MOD_SYMBOLS[mod] or mod)
  end
  local key = tostring(binding[2] or "?")
  return s .. (#key == 1 and key:upper() or key)
end

-- Canonical signature for conflict detection: kind + sorted mods + key.
local function comboSig(kind, mods, key)
  local sorted = {}
  for _, mod in ipairs(mods or {}) do sorted[#sorted + 1] = mod end
  table.sort(sorted)
  return kind .. ":" .. table.concat(sorted, "+") .. ":" .. tostring(key):lower()
end

local function prettyPath(path)
  return (tostring(path):gsub("^" .. HOME, "~"))
end

local function entryById(id)
  for _, e in ipairs(REGISTRY) do
    if e.id == id then return e end
  end
  return nil
end

----------------------------------------------------------------
-- WINDOW DATA + HTML
----------------------------------------------------------------
-- Sections/rows for the window, reflecting live bindings and override state.
function M.buildData()
  local overrides = loadOverrides()
  local sections = {}
  for _, mod in ipairs(MODULE_ORDER) do
    local rows = {}
    for _, e in ipairs(REGISTRY) do
      if e.module == mod then
        local b = currentBinding(e)
        if b then
          rows[#rows + 1] = {
            id = e.id,
            kind = e.kind,
            combo = comboLabel(e.kind, b),
            label = e.label,
            desc = e.desc,
            custom = overrides[e.id] ~= nil,
          }
        end
      end
    end
    if #rows > 0 then
      sections[#sections + 1] = {
        title = MODULE_TITLES[mod] or mod,
        file = prettyPath(MODULE_FILES[mod] or "?"),
        rows = rows,
      }
    end
  end
  return { sections = sections }
end

local PAGE_HEAD = [[<!DOCTYPE html>
<html><head><meta charset="utf-8"><style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  html, body { background: #1b1c20; color: #e8e8ec;
    font: 13px/1.45 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
    -webkit-user-select: none; user-select: none; }
  .wrap { padding: 18px 22px 14px; }
  .top { display: flex; align-items: center; gap: 14px; margin-bottom: 14px; }
  .top h1 { font-size: 17px; font-weight: 700; letter-spacing: .2px; flex: 0 0 auto; }
  .top input { flex: 1; background: #26272d; border: 1px solid #3a3b42; color: #e8e8ec;
    border-radius: 8px; padding: 7px 12px; font-size: 13px; outline: none; }
  .top input:focus { border-color: #5b8cff; }
  .section { margin-bottom: 16px; }
  .sechead { display: flex; align-items: baseline; gap: 10px; padding: 4px 2px 6px;
    border-bottom: 1px solid #2e2f36; margin-bottom: 4px; }
  .sechead .t { font-size: 12px; font-weight: 700; text-transform: uppercase;
    letter-spacing: .8px; color: #9a9ba6; }
  .sechead .f { font-size: 11px; color: #5f6069; font-family: ui-monospace, Menlo, monospace; }
  .row { display: flex; align-items: center; gap: 12px; padding: 8px 8px;
    border-radius: 8px; }
  .row:hover { background: #24252b; }
  .row.listening { background: #1f2a45; outline: 1px solid #5b8cff; }
  kbd { flex: 0 0 96px; text-align: center; background: #2b2c33; border: 1px solid #45464f;
    border-bottom-width: 2px; border-radius: 7px; padding: 5px 4px;
    font: 600 13px ui-monospace, Menlo, monospace; color: #fff; cursor: pointer;
    white-space: nowrap; }
  kbd:hover { border-color: #5b8cff; }
  .row.listening kbd { color: #8fb0ff; border-color: #5b8cff; animation: pulse 1s infinite; }
  @keyframes pulse { 50% { opacity: .55; } }
  .txt { flex: 1; min-width: 0; }
  .txt .l { font-weight: 600; font-size: 13px; }
  .txt .l .tag { font-size: 10px; font-weight: 700; color: #ffb054; background: #3a2d19;
    border-radius: 4px; padding: 1px 6px; margin-left: 8px; vertical-align: 1px; }
  .txt .d { color: #8f909a; font-size: 12px; margin-top: 1px;
    overflow: hidden; text-overflow: ellipsis; }
  .btns { flex: 0 0 auto; display: flex; gap: 6px; opacity: 0; transition: opacity .12s; }
  .row:hover .btns, .row.listening .btns { opacity: 1; }
  button { background: #32333b; color: #d8d8de; border: 1px solid #45464f; border-radius: 6px;
    padding: 4px 10px; font-size: 12px; font-weight: 600; cursor: pointer; }
  button:hover { background: #3d3e48; border-color: #5b8cff; }
  button.run { color: #9fe6a8; }
  button.reset { color: #ffb054; }
  .foot { margin-top: 4px; padding-top: 10px; border-top: 1px solid #2e2f36;
    color: #5f6069; font-size: 11px; text-align: center; }
  #toast { position: fixed; left: 50%; bottom: 22px; transform: translateX(-50%);
    background: #101116; border: 1px solid #45464f; color: #fff; border-radius: 8px;
    padding: 8px 16px; font-size: 12px; opacity: 0; transition: opacity .15s;
    pointer-events: none; max-width: 80%; }
  #toast.show { opacity: 1; }
</style></head><body>
<div class="wrap">
  <div class="top">
    <h1>⌨️ Shortcuts</h1>
    <input id="q" type="text" placeholder="Filter…" autofocus>
  </div>
  <div id="list"></div>
  <div class="foot">⇪ = while Caps is held &nbsp;·&nbsp; click a key or “Rebind” to change it &nbsp;·&nbsp; Esc closes</div>
</div>
<div id="toast"></div>
<script>
]]

local PAGE_TAIL = [[
let listening = null;
let toastTimer = null;

function post(m) { window.webkit.messageHandlers.shortcuts.postMessage(m); }

function toast(msg, ms) {
  const t = document.getElementById('toast');
  t.textContent = msg;
  t.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => t.classList.remove('show'), ms || 2200);
}

function esc(s) {
  return String(s).replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
}

function rowById(id) {
  for (const s of DATA.sections) for (const r of s.rows) if (r.id === id) return r;
  return null;
}

function render() {
  const list = document.getElementById('list');
  let html = '';
  for (const s of DATA.sections) {
    html += '<div class="section">';
    html += '<div class="sechead"><span class="t">' + esc(s.title) + '</span>' +
            '<span class="f">' + esc(s.file) + '</span></div>';
    for (const r of s.rows) {
      html += '<div class="row" id="row-' + esc(r.id) + '" data-id="' + esc(r.id) + '"' +
              ' data-search="' + esc((r.label + ' ' + r.desc + ' ' + r.combo).toLowerCase()) + '">';
      html += '<kbd onclick="startListen(\'' + esc(r.id) + '\')">' + esc(r.combo) + '</kbd>';
      html += '<div class="txt"><div class="l">' + esc(r.label) +
              (r.custom ? '<span class="tag">custom</span>' : '') + '</div>' +
              '<div class="d">' + esc(r.desc) + '</div></div>';
      html += '<div class="btns">';
      html += '<button class="run" onclick="post({action:\'run\', id:\'' + esc(r.id) + '\'})">Run</button>';
      html += '<button onclick="startListen(\'' + esc(r.id) + '\')">Rebind</button>';
      if (r.custom) {
        html += '<button class="reset" onclick="post({action:\'reset\', id:\'' + esc(r.id) + '\'})">Reset</button>';
      }
      html += '</div></div>';
    }
    html += '</div>';
  }
  list.innerHTML = html;
}

function startListen(id) {
  stopListen();
  listening = id;
  const row = document.getElementById('row-' + id);
  row.classList.add('listening');
  row.dataset.oldCombo = row.querySelector('kbd').textContent;
  const r = rowById(id);
  row.querySelector('kbd').textContent = '…';
  toast(r.kind === 'caps'
    ? 'Press the new key (it will be used while Caps is held) — Esc cancels'
    : 'Press the new hotkey combo (needs a modifier) — Esc cancels', 6000);
}

function stopListen() {
  if (!listening) return;
  const row = document.getElementById('row-' + listening);
  if (row) {
    row.classList.remove('listening');
    if (row.dataset.oldCombo) row.querySelector('kbd').textContent = row.dataset.oldCombo;
  }
  listening = null;
}

function normKey(e) {
  const c = e.code || '';
  if (c.startsWith('Key')) return c.slice(3).toLowerCase();
  if (c.startsWith('Digit')) return c.slice(5);
  if (/^F\d+$/.test(e.key)) return e.key.toLowerCase();
  const map = { Space:'space', Slash:'/', Period:'.', Comma:',', Semicolon:';',
    Quote:"'", BracketLeft:'[', BracketRight:']', Backslash:'\\', Backquote:'`',
    Minus:'-', Equal:'=', Enter:'return', Tab:'tab', Backspace:'delete',
    Delete:'forwarddelete', ArrowUp:'up', ArrowDown:'down', ArrowLeft:'left',
    ArrowRight:'right', Home:'home', End:'end', PageUp:'pageup', PageDown:'pagedown' };
  if (map[c]) return map[c];
  if (e.key.length === 1) return e.key.toLowerCase();
  return null;
}

document.addEventListener('keydown', function(e) {
  if (!listening) {
    if (e.key === 'Escape') post({ action: 'close' });
    return;
  }
  e.preventDefault();
  e.stopPropagation();
  if (e.key === 'Escape') { stopListen(); toast('Cancelled', 1200); return; }
  if (['Shift','Control','Alt','Meta','CapsLock'].includes(e.key)) return;
  const key = normKey(e);
  if (!key) { toast('Unrecognized key — try another (Esc cancels)'); return; }
  const mods = [];
  if (e.shiftKey) mods.push('shift');
  if (e.ctrlKey) mods.push('ctrl');
  if (e.altKey) mods.push('alt');
  if (e.metaKey) mods.push('cmd');
  const r = rowById(listening);
  if (r.kind === 'hotkey' && mods.length === 0) {
    toast('Global hotkeys need at least one modifier — try again (Esc cancels)');
    return;
  }
  post({ action: 'rebind', id: listening, mods: mods, key: key });
}, true);

// Called from Lua with { ok, error } after a rebind attempt.
function onRebindResult(res) {
  if (res.ok) {
    toast('Saved — reloading Hammerspoon…', 4000);
  } else {
    toast(res.error || 'Rebind failed');
    stopListen();
  }
}

document.getElementById('q').addEventListener('input', function() {
  const q = this.value.trim().toLowerCase();
  document.querySelectorAll('.row').forEach(function(row) {
    row.style.display = (!q || row.dataset.search.includes(q)) ? '' : 'none';
  });
  document.querySelectorAll('.section').forEach(function(sec) {
    const any = Array.from(sec.querySelectorAll('.row')).some(r => r.style.display !== 'none');
    sec.style.display = any ? '' : 'none';
  });
});

render();
</script></body></html>
]]

local function buildHTML()
  return PAGE_HEAD .. "const DATA = " .. hs.json.encode(M.buildData()) .. ";\n" .. PAGE_TAIL
end

----------------------------------------------------------------
-- WINDOW
----------------------------------------------------------------
local webview = nil

function M.hide()
  if webview then
    pcall(function() webview:delete() end)
    webview = nil
  end
end

local function respondJS(result)
  if webview then
    webview:evaluateJavaScript("onRebindResult(" .. hs.json.encode(result) .. ")")
  end
end

local function handleMessage(msg)
  local b = msg and msg.body
  if type(b) ~= "table" then return end

  if b.action == "close" then
    M.hide()

  elseif b.action == "run" then
    local entry = entryById(b.id)
    if not entry then return end
    M.hide()
    -- Let focus return to the previous app before actions that type/paste.
    hs.timer.doAfter(0.25, function()
      local ok, m = pcall(require, entry.module)
      if ok then entry.run(m) end
    end)

  elseif b.action == "reset" then
    local entry = entryById(b.id)
    if not entry then return end
    local o = loadOverrides()
    o[entry.id] = nil
    saveOverrides(o)
    hs.settings.set(REOPEN_KEY, true)
    hs.alert.show(entry.label .. " reset to default — reloading…", 1.2)
    hs.timer.doAfter(0.3, hs.reload)

  elseif b.action == "rebind" then
    local entry = entryById(b.id)
    if not entry then return end
    local key, mods = b.key, b.mods or {}
    if type(key) ~= "string" or not hs.keycodes.map[key] then
      respondJS({ ok = false, error = "Unrecognized key: " .. tostring(key) })
      return
    end
    local newSig = comboSig(entry.kind, mods, key)
    for _, other in ipairs(REGISTRY) do
      if other.id ~= entry.id then
        local bnd = currentBinding(other)
        if bnd and comboSig(other.kind, bnd[1], bnd[2]) == newSig then
          respondJS({ ok = false, error = "That key is already bound to: " .. other.label })
          return
        end
      end
    end
    local o = loadOverrides()
    o[entry.id] = { mods = mods, key = key }
    saveOverrides(o)
    respondJS({ ok = true })
    hs.settings.set(REOPEN_KEY, true)
    hs.alert.show(
      entry.label .. " → " .. comboLabel(entry.kind, { mods, key }) .. " — reloading…", 1.2)
    hs.timer.doAfter(0.5, hs.reload)
  end
end

function M.show()
  M.hide()

  local uc = hs.webview.usercontent.new("shortcuts"):setCallback(handleMessage)

  local screen = hs.screen.mainScreen():frame()
  local w, h = config.windowWidth, config.windowHeight
  local rect = {
    x = screen.x + (screen.w - w) / 2,
    y = screen.y + (screen.h - h) / 2,
    w = w, h = h,
  }

  webview = hs.webview.new(rect, { developerExtrasEnabled = false }, uc)
    :windowStyle({ "titled", "closable" })
    :windowTitle("Hammerspoon Shortcuts")
    :allowTextEntry(true)     -- window may become key so typing/rebinding works
    :deleteOnClose(true)
    :closeOnEscape(false)     -- Esc is handled in JS (cancels rebind vs closes)
    :shadow(true)
    :level(hs.drawing.windowLevels.floating)
    :html(buildHTML())

  webview:show()
  -- Focus so the filter box and key capture receive keystrokes immediately.
  hs.timer.doAfter(0.1, function()
    if webview then
      local win = webview:hswindow()
      if win then win:focus() end
    end
  end)
end

----------------------------------------------------------------
-- OVERRIDES — call BEFORE any module's start() so bindings pick them up.
----------------------------------------------------------------
function M.applyOverrides()
  local o = loadOverrides()
  for _, e in ipairs(REGISTRY) do
    local ov = o[e.id]
    if type(ov) == "table" and ov.key then
      setBinding(e, { ov.mods or {}, ov.key })
    end
  end
end

----------------------------------------------------------------
-- start() — bind the window hotkey; reopen after a rebind-triggered reload.
----------------------------------------------------------------
function M.start()
  local ok, qs = pcall(require, "quickshots")
  if ok and type(qs) == "table" and type(qs.registerCapsAction) == "function" then
    qs.registerCapsAction(config.capsMenu[1], config.capsMenu[2], function() M.show() end)
  else
    hs.hotkey.bind(config.fallbackMenu[1], config.fallbackMenu[2], function() M.show() end)
    hs.alert.show("shortcuts: caps tap unavailable — window on ⌃⌥⌘K", 3)
  end

  -- If the last reload was caused by a rebind/reset from the window, reopen it
  -- so the user can continue editing.
  if hs.settings.get(REOPEN_KEY) then
    hs.settings.set(REOPEN_KEY, false)
    hs.timer.doAfter(0.5, function() M.show() end)
  end
end

-- Exposed so users can read/mutate config from init.lua before/after start().
M.config = config

return M
