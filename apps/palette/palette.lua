-- palette.lua — Caps+K: search, run, rebind, and configure every Loadout shortcut.
--
-- Keyboard-first hs.webview window:
--   type to search · ↑↓ select · ↵ run · ⌘R rebind · ⇥ next app
--   ⌘, / ⌘O app config · ⌘S save · ⌘⌫ reset to default · esc close
--   right-click a shortcut or option for the same actions.
--
-- ⌘O/⌘R/⌘, collide with Hammerspoon's own menu (Open Config, Reload Config,
-- Settings), so while this window is focused a hotkey modal claims them and
-- forwards them to the page.
--
-- Three kinds of persisted customisation, all edited in this window:
--   • Key bindings — stored in hs.settings (palette.overrides.v1) and applied
--     to each module's config table before modules bind (applyOverrides()).
--   • App settings — the per-app schemas in ~/loadout/settings/<app>.schema.json,
--     read/written through lib/settings/loadout-settings (json overlays merged
--     by settings_overlay.lua, or snag's shell conf). Saving a json app reloads
--     Hammerspoon and reopens this window on that app.
--   • Every other option in an app's `config` table (numbers, toggles, text,
--     lists) — stored in hs.settings (palette.config.v1) and applied in
--     applyOverrides(), so no .lua file is ever rewritten.
--
-- init.lua wiring (ORDER MATTERS):
--   pcall(function() require("palette").applyOverrides() end)  -- before any module starts
--   ...modules start...
--   pcall(function() require("palette").start() end)           -- last

local M = {}
local log = require("litelog").new("palette")

local HOME = os.getenv("HOME") or ""
local OVERRIDES_KEY = "palette.overrides.v1"
local CONFIG_KEY = "palette.config.v1"
local REOPEN_KEY = "palette.reopenAfterReload"
local SETTINGS_DIR = HOME .. "/loadout/settings"
local SETTINGS_BIN = HOME .. "/loadout/lib/settings/loadout-settings"

----------------------------------------------------------------
-- CONFIG
----------------------------------------------------------------
local config = {
  capsMenu = { {}, "k" }, -- Caps+K opens the window (via QuickShots' F18 tap)
  fallbackMenu = { { "ctrl", "alt", "cmd" }, "k" }, -- used if the caps tap is unavailable
  windowWidth = 880,
  windowHeight = 600,
}

----------------------------------------------------------------
-- APPS — sidebar order. `name` is what it does; `product` is the module.
----------------------------------------------------------------
local APPS = {
  { id = "quickshots", name = "Screenshots",  product = "QuickShots" },
  { id = "murmur",     name = "Dictation",    product = "Murmur" },
  { id = "hone",       name = "AI Text",      product = "Hone" },
  { id = "relay",      name = "Launchers",    product = "Relay" },
  { id = "snag",       name = "Bug Capture",  product = "Snag" },
  { id = "unsub",      name = "Unsubscribe",  product = "Unsub" },
  { id = "palette",    name = "This Window",  product = "Palette" },
}

----------------------------------------------------------------
-- REGISTRY — one entry per shortcut. `path` walks that module's `config`
-- table to its { mods, key } binding so the window shows live bindings.
----------------------------------------------------------------
local REGISTRY = {
  -- QuickShots
  { id = "quickshots.capture", module = "quickshots", path = { "capsBindings", "capture" }, kind = "caps",
    label = "Screenshot an area",
    desc  = "Drag to capture (Space = window mode, Esc = cancel). Saved to ~/Pictures/QuickShots",
    run   = function(m) m.capture() end },
  { id = "quickshots.pasteGroup", module = "quickshots", path = { "capsBindings", "pasteGroup" }, kind = "caps",
    label = "Paste latest screenshots",
    desc  = "Pastes the newest group (shots taken within 20s of each other)",
    run   = function(m) m.pasteGroup() end },
  { id = "quickshots.pasteLastN", module = "quickshots", path = { "capsBindings", "pasteLastN" }, kind = "caps",
    label = "Paste last 4 screenshots",
    desc  = "Count is “Default last-N” in Screenshots settings",
    run   = function(m) m.pasteLastN() end },
  { id = "quickshots.promptLastN", module = "quickshots", path = { "capsBindings", "promptLastN" }, kind = "caps",
    label = "Paste last N screenshots…",
    desc  = "Asks how many, then pastes them",
    run   = function(m) m.promptLastN() end },
  { id = "quickshots.pasteFiles", module = "quickshots", path = { "capsBindings", "pasteFiles" }, kind = "caps",
    label = "Paste screenshots as files",
    desc  = "Finder-style files, for Slack, Mail, Messages",
    run   = function(m)
      local saved = m.config.pasteMode
      m.config.pasteMode = "files"
      m.pasteGroup()
      m.config.pasteMode = saved
    end },
  { id = "quickshots.toggleBurst", module = "quickshots", path = { "capsBindings", "toggleBurst" }, kind = "caps",
    label = "Burst capture on/off",
    desc  = "Chain captures until toggled off or Esc; pastes as one group",
    run   = function(m) m.toggleBurst() end },
  { id = "quickshots.openFolder", module = "quickshots", path = { "capsBindings", "openFolder" }, kind = "caps",
    label = "Open screenshots folder",
    desc  = "Opens the screenshot folder in Finder",
    run   = function(m) m.openFolder() end },
  { id = "quickshots.devCapture", module = "quickshots", path = { "capsBindings", "devCapture" }, kind = "caps",
    label = "Dev capture → Codex",
    desc  = "Capture shots, then open Codex in iTerm with them attached",
    run   = function(m) m.toggleDevCapture() end },

  -- Murmur
  { id = "murmur.talk", module = "murmur", path = { "capsTrigger" }, kind = "caps",
    label = "Dictate",
    desc  = "Hold Caps+M and talk, release to paste. Tap Caps+M for hands-free; again to stop",
    run   = function(m) m.toggle() end },
  { id = "murmur.profile.auto", module = "murmur", kind = "action",
    label = "Dictation profile: Auto", desc = "Messages get Message cleanup, everything else Prompt",
    run = function(m) m.setProfile("Auto") end },
  { id = "murmur.profile.prompt", module = "murmur", kind = "action",
    label = "Dictation profile: Prompt", desc = "Keeps imperative, technical, code-like wording",
    run = function(m) m.setProfile("Prompt") end },
  { id = "murmur.profile.message", module = "murmur", kind = "action",
    label = "Dictation profile: Message", desc = "Light grammar and paragraph cleanup",
    run = function(m) m.setProfile("Message") end },
  { id = "murmur.profile.literal", module = "murmur", kind = "action",
    label = "Dictation profile: Literal", desc = "No AI cleanup; punctuation stays on",
    run = function(m) m.setProfile("Literal") end },
  { id = "murmur.learn", module = "murmur", kind = "action",
    label = "Teach a dictation correction", desc = "Save a wrong → right fix for future takes",
    run = function(m) m.promptCorrection() end },

  -- Hone
  { id = "hone.selection", module = "hone", path = { "capsSelection" }, kind = "caps",
    label = "Refine selected text",
    desc  = "Rewrites the selection for clarity with AI and pastes it in place",
    run   = function(m) m.refineSelection() end },
  { id = "hone.clipboard", module = "hone", path = { "capsClipboard" }, kind = "caps",
    label = "Refine clipboard text",
    desc  = "Rewrites the clipboard with AI, then pastes",
    run   = function(m) m.refineClipboard() end },

  -- Relay
  { id = "relay.obsidian", module = "relay", path = { "hotkeys", "obsidian" }, kind = "hotkey",
    label = "Quick note to Obsidian",
    desc  = "Type or dictate a line; appends to the quick-capture note",
    run   = function(m) m.obsidianCapture() end },
  { id = "relay.claude", module = "relay", path = { "hotkeys", "claude" }, kind = "hotkey",
    label = "Claude Code in this repo",
    desc  = "New iTerm window in the current repo running claude",
    run   = function(m) m.voiceClaudeCode() end },
  { id = "relay.dogfood", module = "relay", path = { "hotkeys", "dogfood" }, kind = "hotkey",
    label = "Claude panel in Chrome",
    desc  = "Opens Chrome’s Claude side panel and starts Wispr dictation",
    run   = function(m) m.claudeChromeDogfood() end },
  { id = "relay.search", module = "relay", path = { "hotkeys", "search" }, kind = "hotkey",
    label = "Chrome search",
    desc  = "Focuses Chrome and opens a new tab ready to search",
    run   = function(m) m.chromeSearch() end },

  -- Snag
  { id = "snag.record", module = "snag", path = { "capsRecord" }, kind = "caps",
    label = "Record a bug",
    desc  = "Record a region while narrating; files a verified EquipFlow GitHub issue. Again to stop",
    run   = function(m) m.record() end },
  { id = "snag.cancel", module = "snag", path = { "capsCancel" }, kind = "caps",
    label = "Discard bug recording",
    desc  = "Stops the current recording and throws it away",
    run   = function(m) m.cancel() end },

  -- Unsub
  { id = "unsub.unsubscribe", module = "unsub", path = { "capsUnsub" }, kind = "caps",
    label = "Unsubscribe from this email",
    desc  = "Apple Mail: one-click, else unsubscribe email, else fills out the page with AI",
    run   = function(m) m.unsubscribe() end },

  -- Palette
  { id = "palette.menu", module = "palette", path = { "capsMenu" }, kind = "caps",
    label = "Show all shortcuts",
    desc  = "This window",
    run   = function(m) m.show() end },
}

----------------------------------------------------------------
-- BINDINGS
----------------------------------------------------------------
local function loadOverrides()
  local o = hs.settings.get(OVERRIDES_KEY)
  if type(o) ~= "table" then o = {} end
  return o
end

local function saveOverrides(o) hs.settings.set(OVERRIDES_KEY, o) end

-- { mods, key } at entry.path in module.config, or nil (module not loaded).
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

local MOD_SYMBOLS = { ctrl = "⌃", alt = "⌥", shift = "⇧", cmd = "⌘" }
local MOD_ORDER = { "ctrl", "alt", "shift", "cmd" }
local KEY_LABELS = {
  space = "Space", escape = "Esc", ["return"] = "↵", tab = "⇥",
  delete = "⌫", forwarddelete = "⌦", up = "↑", down = "↓", left = "←", right = "→",
  cmd = "L⌘", rightcmd = "R⌘", shift = "L⇧", rightshift = "R⇧",
  alt = "L⌥", rightalt = "R⌥", ctrl = "L⌃", rightctrl = "R⌃",
}

-- Keycaps for display: { "⇪", "⇧", "P" } or { "⌃", "⌥", "⌘", "N" }.
local function keycaps(kind, binding)
  local caps = {}
  if kind == "caps" then caps[1] = "⇪" end
  local have = {}
  for _, mod in ipairs(binding[1] or {}) do have[mod] = true end
  for _, mod in ipairs(MOD_ORDER) do
    if have[mod] then caps[#caps + 1] = MOD_SYMBOLS[mod] end
  end
  local key = tostring(binding[2] or "?")
  caps[#caps + 1] = KEY_LABELS[key] or (#key == 1 and key:upper() or key:upper())
  return caps
end

local function comboLabel(kind, binding) return table.concat(keycaps(kind, binding), "") end

local function comboSig(kind, mods, key)
  local sorted = {}
  for _, mod in ipairs(mods or {}) do sorted[#sorted + 1] = mod end
  table.sort(sorted)
  return kind .. ":" .. table.concat(sorted, "+") .. ":" .. tostring(key):lower()
end

local function entryById(id)
  for _, e in ipairs(REGISTRY) do
    if e.id == id then return e end
  end
end

local function appById(id)
  for _, a in ipairs(APPS) do
    if a.id == id then return a end
  end
end

----------------------------------------------------------------
-- APP SETTINGS (schemas + loadout-settings)
----------------------------------------------------------------
local function readFile(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function loadSchema(appId)
  local raw = readFile(SETTINGS_DIR .. "/" .. appId .. ".schema.json")
  if not raw then return nil end
  local ok, schema = pcall(hs.json.decode, raw)
  if ok and type(schema) == "table" and type(schema.fields) == "table" then return schema end
  log.warn("bad schema", { app = appId })
end

local function dumpValues(appId)
  local out, ok = hs.execute(string.format("%q %q --dump 2>/dev/null", SETTINGS_BIN, appId))
  local values = {}
  if ok and out then
    for line in out:gmatch("[^\n]+") do
      local k, v = line:match("^([^=]+)=(.*)$")
      if k then values[k] = v end
    end
  end
  return values
end

local function settingsFor(appId)
  local schema = loadSchema(appId)
  if not schema then return nil end
  local values = dumpValues(appId)
  local fields = {}
  for _, f in ipairs(schema.fields) do
    fields[#fields + 1] = {
      key = f.key, label = f.label or f.key, type = f.type or "string",
      options = f.options, help = f.help,
      value = values[f.key] ~= nil and values[f.key]
        or (tostring(f.default or ""):gsub("^~", os.getenv("HOME") or "~")),
    }
  end
  return { format = schema.format or "json", fields = fields }
end

local function realPath(path)
  return hs.fs.pathToAbsolute(path) or path
end

local function moduleFile(appId)
  return realPath(HOME .. "/.hammerspoon/" .. appId .. ".lua")
end

----------------------------------------------------------------
-- APP OPTIONS — every other value in a module's `config` table
----------------------------------------------------------------
local configDefaults = {} -- appId -> path -> in-file value (captured before edits apply)

local function loadConfigEdits()
  local c = hs.settings.get(CONFIG_KEY)
  if type(c) ~= "table" then c = {} end
  return c
end

local function saveConfigEdits(c) hs.settings.set(CONFIG_KEY, c) end

local function splitPath(p)
  local t = {}
  for part in tostring(p):gmatch("[^%.]+") do t[#t + 1] = part end
  return t
end

local function getPath(root, path)
  local node = root
  for _, k in ipairs(path) do
    if type(node) ~= "table" then return nil end
    node = node[k]
  end
  return node
end

local function setPath(root, path, v)
  local node = root
  for i = 1, #path - 1 do
    node = node[path[i]]
    if type(node) ~= "table" then return false end
  end
  if type(node) ~= "table" or node[path[#path]] == nil then return false end
  node[path[#path]] = v
  return true
end

local function deepcopy(v)
  if type(v) ~= "table" then return v end
  local t = {}
  for k, x in pairs(v) do t[k] = deepcopy(x) end
  return t
end

local function isBinding(v)
  return type(v) == "table" and #v == 2 and type(v[1]) == "table" and type(v[2]) == "string"
end

local function isStringList(v)
  if type(v) ~= "table" or #v == 0 then return false end
  local n = 0
  for _ in pairs(v) do n = n + 1 end
  if n ~= #v then return false end
  for _, x in ipairs(v) do if type(x) ~= "string" then return false end end
  return true
end

-- Editor type for a default value, or nil when it isn't editable here.
local function optType(v)
  local t = type(v)
  if t == "boolean" then return "bool" end
  if t == "number" then return math.type(v) == "integer" and "int" or "num" end
  if t == "string" then return (v:find("\n") or #v > 90) and "text" or "str" end
  if isStringList(v) then return "list" end
end

-- Validate/convert an incoming value against the default's type; nil = reject.
local function coerce(def, v)
  local ty = optType(def)
  if ty == "bool" then
    if type(v) == "boolean" then return v end
    return nil
  end
  if ty == "int" then local n = tonumber(v); return n and math.tointeger(n) or nil end
  if ty == "num" then return tonumber(v) end
  if ty == "str" or ty == "text" then return type(v) == "string" and v or nil end
  if ty == "list" and type(v) == "table" then
    local out = {}
    for _, x in ipairs(v) do
      if type(x) ~= "string" then return nil end
      out[#out + 1] = x
    end
    return out
  end
end

local function sameValue(a, b)
  if type(a) == "table" or type(b) == "table" then
    return type(a) == type(b) and hs.json.encode(a) == hs.json.encode(b)
  end
  return a == b
end

-- "autoRefineMinChars" -> "Auto refine min chars"; keeps acronyms ("Use AI").
local function humanize(k)
  local spaced = k:gsub("(%l)(%u)", "%1 %2"):gsub("(%u)(%u%l)", "%1 %2"):gsub("(%a)(%d)", "%1 %2"):gsub("_", " ")
  local words = {}
  local ACRONYMS = { cli = "CLI", url = "URL", id = "ID", ai = "AI", api = "API", llm = "LLM", ui = "UI",
    ok = "(success)", err = "(error)", dir = "folder", cmd = "command" }
  for w in spaced:gmatch("%S+") do
    words[#words + 1] = ACRONYMS[w:lower()] or ((#w > 1 and w:match("^%u+$")) and w or w:lower())
  end
  local out = table.concat(words, " ")
  return (out:gsub("^%l", string.upper))
end

-- Source line and trailing/preceding "-- comment" for a config path.
local function sourceInfo(lines, start, path)
  local i, found = 1, nil
  for n = start, #lines do
    local k = path[i]
    if lines[n]:match("^%s*" .. k:gsub("%p", "%%%0") .. "%s*=") then
      found = n
      i = i + 1
      if i > #path then break end
    end
  end
  if not found or i <= #path then return nil, nil end
  local code = lines[found]:gsub('"[^"]*"', '""'):gsub("'[^']*'", "''")
  local help = code:match("%-%-%s*(.-)%s*$")
  if not help or help == "" then
    -- the comment block directly above (up to 4 lines)
    local block, n = {}, found - 1
    while n >= 1 and #block < 4 do
      local c = lines[n]:match("^%s*%-%-%s*(.-)%s*$")
      if not c then break end
      table.insert(block, 1, c)
      n = n - 1
    end
    help = table.concat(block, " ")
  end
  return found, help
end

-- Editable options for an app: scalars, text, string lists, and one level of
-- nested scalar maps. Bindings (shortcut rows) and schema keys (Settings) are
-- left out so each value appears once.
local function optionsFor(appId)
  local m = package.loaded[appId]
  if type(m) ~= "table" or type(m.config) ~= "table" then return {} end
  local skip = {}
  local schema = loadSchema(appId)
  if schema then for _, f in ipairs(schema.fields) do skip[f.key] = true end end
  local edits = loadConfigEdits()[appId] or {}
  local defs = configDefaults[appId] or {}
  local lines, start = {}, 1
  local fh = io.open(moduleFile(appId), "r")
  if fh then
    for l in fh:lines() do
      lines[#lines + 1] = l
      if start == 1 and l:match("^local config%s*=") then start = #lines end
    end
    fh:close()
  end
  local opts = {}
  local function add(path, v, parent)
    local pkey = table.concat(path, ".")
    local def = defs[pkey]
    if def == nil then def = v end
    local ty = optType(def)
    if not ty then return end
    local line, help = sourceInfo(lines, start, path)
    local leaf = path[#path]
    local name = humanize(leaf)
    local unit = nil
    if ty == "int" or ty == "num" then
      local lk, lh = leaf:lower(), (help or ""):lower()
      if lk:match("ms$") then unit = "ms"
      elseif lk:match("seconds?$") or lk:match("delay") or lk:match("duration") or lk:match("timeout")
        or lh:match("seconds") then unit = "sec" end
      if unit then
        local trimmed = name:gsub("%s+[Ss]econds?$", ""):gsub("%s+[Mm]s$", "")
        if trimmed ~= "" then name = trimmed end
      end
    end
    opts[#opts + 1] = {
      path = pkey, name = name, group = parent and humanize(parent) or nil, unit = unit,
      label = (parent and humanize(parent) .. " › " or "") .. name,
      type = ty, value = v, def = def, custom = edits[pkey] ~= nil, help = help or "",
      _line = line or math.huge,
    }
  end
  for k, v in pairs(m.config) do
    if type(k) == "string" and not skip[k] and not isBinding(v) then
      if type(v) == "table" and #v == 0 and next(v) ~= nil then
        for k2, v2 in pairs(v) do
          if type(k2) == "string" and not isBinding(v2) then add({ k, k2 }, v2, k) end
        end
      else
        add({ k }, v)
      end
    end
  end
  table.sort(opts, function(a, b)
    if a._line ~= b._line then return a._line < b._line end
    return a.path < b.path
  end)
  for _, o in ipairs(opts) do o._line = nil end
  return opts
end

----------------------------------------------------------------
-- WINDOW DATA
----------------------------------------------------------------
function M.buildData()
  local overrides = loadOverrides()
  local apps = {}
  for _, a in ipairs(APPS) do
    local rows = {}
    for _, e in ipairs(REGISTRY) do
      if e.module == a.id then
        local b = e.kind == "action" and {} or currentBinding(e)
        if b then
          rows[#rows + 1] = {
            id = e.id, app = a.id, kind = e.kind,
            keys = e.kind == "action" and { "run" } or keycaps(e.kind, b),
            label = e.label, desc = e.desc or "",
            custom = overrides[e.id] ~= nil,
          }
        end
      end
    end
    local loaded = package.loaded[a.id] ~= nil
    if #rows > 0 or loaded then
      apps[#apps + 1] = {
        id = a.id, name = a.name, product = a.product,
        file = (moduleFile(a.id):gsub("^" .. HOME, "~")),
        rows = rows,
        settings = settingsFor(a.id),
        options = optionsFor(a.id),
      }
    end
  end
  return { apps = apps }
end

----------------------------------------------------------------
-- PAGE
----------------------------------------------------------------
local PAGE_HEAD = [==[<!DOCTYPE html>
<html><head><meta charset="utf-8"><style>
:root {
  --bg:#1c1c1e; --side:#18181a; --line:#2f2f32; --row:#2c2c2f; --sel:rgba(10,132,255,.22);
  --selLine:#0a84ff; --text:#f2f2f7; --muted:#98989f; --faint:#636368;
  --kbd:#2c2c2e; --kbdLine:#434347; --accent:#0a84ff; --warn:#ff9f0a; --good:#30d158;
  --field:#1c1c1e; --card:#252527; --seg:#3a3a3d;
}
@media (prefers-color-scheme: light) {
  :root { --bg:#f5f5f7; --side:#ececee; --line:#e2e2e6; --row:#f0f0f3; --sel:rgba(0,122,255,.12);
    --selLine:#007aff; --text:#1c1c1e; --muted:#6e6e73; --faint:#aeaeb2;
    --kbd:#f2f2f7; --kbdLine:#d1d1d6; --accent:#007aff; --field:#f5f5f7; --card:#ffffff; --seg:#ffffff; }
}
* { margin:0; padding:0; box-sizing:border-box; }
html,body { height:100%; background:transparent; color:var(--text); overflow:hidden;
  font:13px/1.35 -apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif;
  -webkit-user-select:none; user-select:none; }
.app { display:grid; grid-template-rows:auto 1fr auto auto; height:100%; background:var(--bg);
  border:1px solid var(--kbdLine); border-radius:12px; overflow:hidden; }
.search { display:flex; align-items:center; gap:10px; padding:12px 16px 12px 14px; border-bottom:1px solid var(--line);
  background:var(--side); }
.lights { display:flex; gap:8px; margin-right:8px; }
.tl { width:12px; height:12px; border-radius:50%; position:relative; cursor:default; }
.tl.close { background:#ff5f57; } .tl.zoom { background:#28c840; } .tl.min { background:var(--kbdLine); }
.lights:hover .tl::after { position:absolute; inset:0; display:flex; align-items:center; justify-content:center;
  font:700 9px/1 -apple-system,sans-serif; color:rgba(0,0,0,.6); }
.lights:hover .tl.close::after { content:"✕"; } .lights:hover .tl.zoom::after { content:"+"; font-size:11px; }
#grip { position:fixed; right:2px; bottom:2px; width:14px; height:14px; cursor:nwse-resize; z-index:5; }
.search svg { flex:0 0 auto; opacity:.55; }
.search input { flex:1; background:transparent; border:0; outline:0; color:var(--text);
  font-size:17px; font-weight:400; }
.search input::placeholder { color:var(--faint); }
.scope { font-size:11px; font-weight:600; color:var(--accent); background:var(--sel);
  border-radius:5px; padding:2px 7px; white-space:nowrap; }
.body { display:grid; grid-template-columns:168px 1fr; min-height:0; }
.side { background:var(--side); border-right:1px solid var(--line); padding:8px 6px; overflow:auto; }
.side .it { display:flex; align-items:center; justify-content:space-between; padding:5px 10px;
  border-radius:6px; color:var(--muted); cursor:default; font-weight:500; }
.side .it:hover { background:var(--row); color:var(--text); }
.side .it.on { background:var(--sel); color:var(--text); }
.side .it .n { font-size:11px; color:var(--faint); font-variant-numeric:tabular-nums; }
.side .sep { height:1px; background:var(--line); margin:6px 8px; }
.main { overflow:auto; padding:4px 14px 14px; scroll-padding:40px 0 60px; }
.grp { font-size:11px; font-weight:600; color:var(--faint); text-transform:uppercase;
  letter-spacing:.6px; padding:12px 10px 4px; display:flex; justify-content:space-between; }
.grp a { color:var(--faint); text-decoration:none; text-transform:none; letter-spacing:0; font-weight:500; cursor:pointer; }
.grp a:hover { color:var(--accent); }
.row { display:flex; align-items:center; gap:10px; height:38px; padding:0 14px; cursor:default; }
.row:hover { background:var(--row); }
.row.sel { background:var(--sel); box-shadow:inset 2px 0 0 var(--selLine); }
.row .lb { flex:1; min-width:0; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; font-weight:500; }
mark { background:none; color:var(--accent); font-weight:700; }
.row .tag { font-size:11px; color:var(--faint); white-space:nowrap; }
.row .cus { width:6px; height:6px; border-radius:50%; background:var(--warn); flex:0 0 auto; }
.keys { display:flex; gap:3px; flex:0 0 auto; }
kbd { min-width:22px; height:22px; padding:0 6px; display:inline-flex; align-items:center; justify-content:center;
  background:var(--kbd); border:1px solid var(--kbdLine); border-bottom-width:2px; border-radius:5px;
  font:600 12px -apple-system,BlinkMacSystemFont,sans-serif; color:var(--text); }
kbd.cap { color:var(--muted); }
kbd.run { color:var(--muted); font:500 11px -apple-system,sans-serif; border-style:dashed; border-bottom-width:1px; }
.row.listen kbd { color:var(--accent); border-color:var(--accent); animation:pulse 1s infinite; }
@keyframes pulse { 50% { opacity:.5; } }
.empty { color:var(--muted); padding:40px 10px; text-align:center; }
/* app page */
.hero { display:flex; align-items:center; gap:10px; padding:14px 2px 10px; }
.hero h2 { font-size:20px; font-weight:700; }
.hero .p { color:var(--faint); font-size:12px; margin-top:5px; }
.hero .sp { flex:1; }
.seg { display:inline-flex; background:var(--side); border:1px solid var(--line); border-radius:8px; padding:2px; }
.seg button { border:0; background:transparent; color:var(--muted); font:500 12.5px -apple-system,sans-serif;
  padding:4px 16px; border-radius:6px; cursor:default; }
.seg button.on { background:var(--seg); color:var(--text); box-shadow:0 1px 2px rgba(0,0,0,.25); }
.sec { display:flex; justify-content:space-between; align-items:baseline; font-size:12px; font-weight:600;
  color:var(--muted); padding:16px 4px 7px; }
.sec:first-child { padding-top:10px; }
.sec a { color:var(--faint); font-weight:500; cursor:pointer; text-decoration:none; }
.sec a:hover { color:var(--accent); }
.card { background:var(--card); border:1px solid var(--line); border-radius:10px; overflow:hidden; }
.card > * + * { border-top:1px solid var(--line); }
.row.sel, .set.sel { background:var(--sel); box-shadow:inset 3px 0 0 var(--selLine); }
.btn { background:var(--kbd); color:var(--text); border:1px solid var(--kbdLine); border-radius:6px;
  padding:4px 12px; font:500 12px -apple-system,sans-serif; cursor:default; }
.btn:hover { border-color:var(--accent); }
.btn.pri { background:var(--accent); border-color:var(--accent); color:#fff; }
.set { display:flex; align-items:center; gap:18px; min-height:54px; padding:9px 14px; }
.set .lbx { flex:1; min-width:0; }
.set .lbx .l { font-weight:500; }
.set .lbx .h { color:var(--muted); font-size:11.5px; margin-top:2px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
.set .tag { font-size:11px; color:var(--faint); white-space:nowrap; }
.set.dirty .lbx .l::after { content:" •"; color:var(--warn); }
.set .cus { display:inline-block; width:6px; height:6px; border-radius:50%; background:var(--warn); margin-left:6px; vertical-align:middle; }
.ctl { flex:0 0 auto; display:flex; align-items:center; gap:7px; }
.ctl .unit { color:var(--muted); font-size:12px; width:24px; }
.set.wide { flex-wrap:wrap; }
.set.wide .lbx { flex-basis:100%; }
.set.wide .ctl { flex:1 1 100%; }
.set textarea { width:100%; background:var(--field); color:var(--text); border:1px solid var(--kbdLine); border-radius:7px;
  padding:7px 9px; font:12px/1.5 "SF Mono",ui-monospace,Menlo,monospace; outline:0; resize:vertical;
  -webkit-user-select:text; user-select:text; }
.set input[type=text], .set input[type=number], .set select {
  background:var(--field); color:var(--text); border:1px solid var(--kbdLine); border-radius:7px;
  padding:5px 9px; font:13px -apple-system,sans-serif; outline:0; -webkit-user-select:text; user-select:text; }
.set input[type=text] { width:270px; text-overflow:ellipsis; }
.set input[type=number] { width:74px; text-align:right; font-variant-numeric:tabular-nums; }
.set input[type=number]::-webkit-inner-spin-button, .set input[type=number]::-webkit-outer-spin-button { -webkit-appearance:none; margin:0; }
.set input:focus, .set select:focus, .set textarea:focus { border-color:var(--accent); box-shadow:0 0 0 3px var(--sel); }
.tog { width:38px; height:22px; border-radius:11px; background:var(--kbdLine); position:relative; flex:0 0 auto; transition:background .12s; }
.tog::after { content:""; position:absolute; top:2px; left:2px; width:18px; height:18px; border-radius:50%; background:#fff;
  box-shadow:0 1px 2px rgba(0,0,0,.3); transition:left .12s; }
.tog.on { background:var(--good); }
.tog.on::after { left:18px; }
.savebar { display:none; align-items:center; gap:8px; padding:10px 14px; position:sticky; bottom:-14px; margin:12px -14px -14px;
  background:var(--side); border-top:1px solid var(--line); }
.savebar.show { display:flex; }
.savebar .msg { color:var(--muted); font-size:12px; flex:1; }
/* bottom */
.detail:empty { display:none; }
.detail { min-height:30px; display:flex; align-items:center; gap:8px; padding:6px 16px; border-top:1px solid var(--line);
  color:var(--muted); font-size:12px; white-space:nowrap; overflow:hidden; }
.detail .d { overflow:hidden; text-overflow:ellipsis; flex:1; }
.detail .c { color:var(--warn); }
.foot { display:flex; gap:14px; align-items:center; padding:7px 16px; background:var(--side);
  border-top:1px solid var(--line); color:var(--muted); font-size:11.5px; white-space:nowrap; overflow:hidden; }
.foot .k { display:inline-flex; gap:5px; align-items:center; }
.foot kbd { height:18px; min-width:18px; font-size:10.5px; padding:0 4px; }
.foot .gap { flex:1; }
#toast { position:fixed; left:50%; bottom:110px; transform:translateX(-50%); background:var(--text); color:var(--bg);
  border-radius:8px; padding:7px 14px; font-size:12px; font-weight:500; opacity:0; transition:opacity .15s; pointer-events:none; }
#toast.show { opacity:1; }
#ctx { position:fixed; z-index:10; min-width:220px; padding:5px; border-radius:9px; background:var(--side);
  border:1px solid var(--kbdLine); box-shadow:0 10px 30px rgba(0,0,0,.35); display:none; }
#ctx.show { display:block; }
#ctx .mi { display:flex; align-items:center; gap:10px; padding:5px 10px; border-radius:6px; cursor:default; }
#ctx .mi:hover { background:var(--accent); color:#fff; }
#ctx .mi:hover kbd { color:#fff; border-color:rgba(255,255,255,.5); background:transparent; }
#ctx .mi span { flex:1; }
#ctx .mi kbd { height:18px; min-width:18px; font-size:10.5px; padding:0 4px; }
#ctx .hr { height:1px; background:var(--line); margin:4px 6px; }
</style></head><body>
<div class="app">
  <div class="search" id="top">
    <div class="lights"><span class="tl close" data-win="close" title="Close (esc)"></span><span class="tl min"></span><span class="tl zoom" data-win="zoom" title="Expand / restore"></span></div>
    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/></svg>
    <input id="q" type="text" placeholder="Search shortcuts and settings" autofocus spellcheck="false" autocomplete="off">
    <span id="scope" class="scope" style="display:none"></span>
  </div>
  <div class="body">
    <div class="side" id="side"></div>
    <div class="main" id="main"></div>
  </div>
  <div class="detail" id="detail"></div>
  <div class="foot" id="foot"></div>
</div>
<div id="toast"></div>
<div id="ctx"></div>
<div id="grip"></div>
<script>
]==]

local PAGE_TAIL = [==[
const $ = id => document.getElementById(id);
const qEl = $('q');
let view = START_VIEW || 'all';   // 'all' or an app id
let tab = START_TAB || 'keys';    // app page tab: 'keys' (shortcuts) | 'settings'
let sel = 0;                      // index into `items`
let items = [];                   // selectable things currently rendered
let listening = null;             // row id being rebound
let dirty = {};                   // appId -> {key: value}   (schema settings, strings)
let cdirty = {};                  // appId -> {path: value}  (config options, typed)
let toastTimer = null;

function post(m) { window.webkit.messageHandlers.palette.postMessage(m); }
function esc(s) { return String(s == null ? '' : s).replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c])); }
function toast(msg, ms) {
  const t = $('toast'); t.textContent = msg; t.classList.add('show');
  clearTimeout(toastTimer); toastTimer = setTimeout(() => t.classList.remove('show'), ms || 2200);
}
function appOf(id) { return DATA.apps.find(a => a.id === id); }
function nDirty(id) { return Object.keys(dirty[id] || {}).length + Object.keys(cdirty[id] || {}).length; }
function optOf(appId, path) { return arr(appOf(appId).options).find(o => o.path === path); }
function curOpt(appId, o) { const d = cdirty[appId] || {}; return (o.path in d) ? d[o.path] : o.value; }
function same(a, b) { return JSON.stringify(a) === JSON.stringify(b); }
function setOpt(appId, path, value) {
  const o = optOf(appId, path); cdirty[appId] = cdirty[appId] || {};
  if (same(value, o.value)) delete cdirty[appId][path]; else cdirty[appId][path] = value;
}
function parseOpt(o, raw) {
  if (o.type === 'int' || o.type === 'num') {
    const n = Number(raw);
    return (String(raw).trim() === '' || isNaN(n)) ? String(raw) : (o.type === 'int' ? Math.round(n) : n);
  }
  if (o.type === 'list') return String(raw).split('\n').map(x => x.trim()).filter(Boolean);
  return String(raw);
}
function fmtVal(o, v) {
  if (o.type === 'bool') return v ? 'On' : 'Off';
  if (o.type === 'list') return arr(v).join(', ') || '(empty)';
  const s = String(v); return s === '' ? '(empty)' : (s.length > 60 ? s.slice(0, 60) + '…' : s);
}
function optSearch(o) { return { label: o.label, help: o.help + ' ' + o.path }; }
function arr(x) { return Array.isArray(x) ? x : []; }

// ---------- search ----------
function score(row, app, q) {
  if (!q) return 1;
  const label = row.label.toLowerCase();
  const hay = (row.label + ' ' + app.name + ' ' + app.product + ' ' + (row.desc || row.help || '') + ' ' +
               arr(row.keys).join('')).toLowerCase();
  let total = 0;
  for (const t of q.split(/\s+/).filter(Boolean)) {
    if (label.startsWith(t)) total += 100;
    else if (new RegExp('\\b' + t.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).test(label)) total += 70;
    else if (label.includes(t)) total += 45;
    else if ((app.name + ' ' + app.product).toLowerCase().includes(t)) total += 30;
    else if (hay.includes(t)) total += 10;
    else return 0;
  }
  return total;
}
function hl(text, q) {
  const s = esc(text);
  if (!q) return s;
  const t = q.split(/\s+/).filter(Boolean).sort((a, b) => b.length - a.length)[0];
  if (!t) return s;
  const i = text.toLowerCase().indexOf(t);
  if (i < 0) return s;
  return esc(text.slice(0, i)) + '<mark>' + esc(text.slice(i, i + t.length)) + '</mark>' + esc(text.slice(i + t.length));
}

// ---------- render ----------
function keysHTML(keys) {
  return '<span class="keys">' + arr(keys).map((k, i) =>
    k === 'run' ? '<kbd class="run">run</kbd>' : '<kbd' + (k === '⇪' ? ' class="cap"' : '') + '>' + esc(k) + '</kbd>').join('') + '</span>';
}
function rowHTML(r, idx, q, showApp) {
  const app = appOf(r.app);
  return '<div class="row' + (idx === sel ? ' sel' : '') + (listening === r.id ? ' listen' : '') + '" data-i="' + idx + '">' +
    '<span class="lb">' + hl(r.label, q) + '</span>' +
    (r.custom ? '<span class="cus" title="Custom key"></span>' : '') +
    (showApp ? '<span class="tag">' + esc(app.name) + '</span>' : '') +
    (listening === r.id ? '<span class="keys"><kbd>press keys…</kbd></span>' : keysHTML(r.keys)) + '</div>';
}
function settingRowHTML(app, f, idx, q, showApp) {
  const d = (dirty[app.id] || {});
  const val = (f.key in d) ? d[f.key] : f.value;
  let ctl = '';
  if (f.type === 'bool') ctl = '<div class="tog' + (String(val) === 'true' ? ' on' : '') + '" data-tog="' + esc(f.key) + '"></div>';
  else if (f.type === 'enum') ctl = '<select data-k="' + esc(f.key) + '">' + arr(f.options).map(o =>
      '<option' + (String(o) === String(val) ? ' selected' : '') + '>' + esc(o) + '</option>').join('') + '</select>';
  else if (f.type === 'int') ctl = '<input type="number" data-k="' + esc(f.key) + '" value="' + esc(val) + '">';
  else ctl = '<input type="text" data-k="' + esc(f.key) + '" value="' + esc(val) + '" spellcheck="false">';
  if (showApp) ctl = '<span class="tag">' + esc(app.name) + ' setting</span>';
  return '<div class="set' + (idx === sel ? ' sel' : '') + ((f.key in d) ? ' dirty' : '') + '" data-i="' + idx + '" data-app="' + esc(app.id) + '">' +
    '<div class="lbx"><div class="l">' + hl(f.label, q) + '</div>' + (f.help && !showApp ? '<div class="h" title="' + esc(f.help) + '">' + esc(f.help) + '</div>' : '') +
    '</div><div class="ctl">' + ctl + (showApp ? '' : '<span class="unit"></span>') + '</div></div>';
}

function optRowHTML(app, o, idx, q, showApp) {
  const d = cdirty[app.id] || {}; const val = curOpt(app.id, o);
  const dk = ' data-o="' + esc(o.path) + '"';
  let ctl = '';
  if (o.type === 'bool') ctl = '<div class="tog' + (val ? ' on' : '') + '" data-otog="' + esc(o.path) + '"></div>';
  else if (o.type === 'int' || o.type === 'num') ctl = '<input type="number" step="any"' + dk + ' value="' + esc(val) + '">';
  else if (o.type === 'text') ctl = '<textarea rows="4"' + dk + ' spellcheck="false">' + esc(val) + '</textarea>';
  else if (o.type === 'list') ctl = '<textarea rows="' + Math.min(6, Math.max(2, arr(val).length)) + '"' + dk +
      ' spellcheck="false" placeholder="One per line">' + esc(arr(val).join('\n')) + '</textarea>';
  else ctl = '<input type="text"' + dk + ' value="' + esc(val) + '" spellcheck="false">';
  if (showApp) ctl = '<span class="tag">' + esc(app.name) + ' setting</span>';
  const wide = !showApp && (o.type === 'text' || o.type === 'list');
  return '<div class="set' + (wide ? ' wide' : '') + (idx === sel ? ' sel' : '') + ((o.path in d) ? ' dirty' : '') +
    '" data-i="' + idx + '" data-app="' + esc(app.id) + '">' +
    '<div class="lbx"><div class="l">' + hl(showApp ? o.label : o.name, q) + (o.custom ? '<span class="cus" title="Changed from default"></span>' : '') + '</div>' +
    (o.help && !showApp ? '<div class="h" title="' + esc(o.help) + '">' + esc(o.help) + '</div>' : '') + '</div><div class="ctl">' + ctl +
    (showApp || wide ? '' : '<span class="unit">' + esc(o.unit || '') + '</span>') + '</div></div>';
}

function render(keepScroll) {
  const q = qEl.value.trim().toLowerCase();
  const main = $('main');
  const st = main.scrollTop;
  items = [];
  let html = '';

  // sidebar
  let sh = '<div class="it' + (view === 'all' ? ' on' : '') + '" data-v="all"><span>All shortcuts</span><span class="n">' +
    DATA.apps.reduce((n, a) => n + a.rows.length, 0) + '</span></div><div class="sep"></div>';
  for (const a of DATA.apps) {
    sh += '<div class="it' + (view === a.id ? ' on' : '') + '" data-v="' + esc(a.id) + '"><span>' + esc(a.name) +
      (nDirty(a.id) ? ' <span style="color:var(--warn)">•</span>' : '') +
      '</span><span class="n">' + (a.rows.length || '') + '</span></div>';
  }
  $('side').innerHTML = sh;
  const scope = $('scope');
  if (view === 'all') { scope.style.display = 'none'; }
  else { scope.style.display = ''; scope.textContent = appOf(view).name; }

  if (view === 'all' && q) {
    // flat ranked results: shortcuts + settings
    const hits = [];
    for (const a of DATA.apps) {
      for (const r of a.rows) { const s = score(r, a, q); if (s) hits.push({ s, t: 'row', r, a }); }
      if (a.settings) for (const f of a.settings.fields) {
        const s = score({ label: f.label, help: f.help }, a, q); if (s) hits.push({ s: s - 5, t: 'set', f, a });
      }
      for (const o of arr(a.options)) { const s = score(optSearch(o), a, q); if (s) hits.push({ s: s - 10, t: 'opt', o, a }); }
    }
    hits.sort((x, y) => y.s - x.s);
    for (const h of hits) {
      const idx = items.length;
      if (h.t === 'row') { items.push({ t: 'row', r: h.r }); html += rowHTML(h.r, idx, q, true); }
      else if (h.t === 'set') { items.push({ t: 'set', a: h.a, f: h.f }); html += settingRowHTML(h.a, h.f, idx, q, true); }
      else { items.push({ t: 'opt', a: h.a, o: h.o }); html += optRowHTML(h.a, h.o, idx, q, true); }
    }
    html = hits.length ? '<div class="sec"><span>' + hits.length + ' result' + (hits.length > 1 ? 's' : '') + '</span></div><div class="card">' + html + '</div>'
      : '<div class="empty">No matches for “' + esc(qEl.value) + '”</div>';
  } else if (view === 'all') {
    for (const a of DATA.apps) {
      if (!a.rows.length) continue;
      html += '<div class="sec"><span>' + esc(a.name) + '</span>' +
        (hasCfg(a) ? '<a data-go="' + esc(a.id) + '" data-gotab="settings">Settings ›</a>' : '') + '</div><div class="card">';
      for (const r of a.rows) { const idx = items.length; items.push({ t: 'row', r }); html += rowHTML(r, idx, '', false); }
      html += '</div>';
    }
  } else {
    const a = appOf(view);
    if (!hasCfg(a)) tab = 'keys';
    if (!a.rows.length && hasCfg(a)) tab = 'settings';
    html += '<div class="hero"><h2>' + esc(a.name) + '</h2><span class="p">' + esc(a.product) + '</span><span class="sp"></span>' +
      (hasCfg(a) && a.rows.length ? '<div class="seg"><button data-tab="keys"' + (tab === 'keys' ? ' class="on"' : '') + '>Shortcuts</button>' +
        '<button data-tab="settings"' + (tab === 'settings' ? ' class="on"' : '') + '>Settings' + (nDirty(a.id) ? ' •' : '') + '</button></div>' : '') + '</div>';
    if (tab === 'keys') {
      const rows = a.rows.filter(r => score(r, a, q));
      if (rows.length) {
        html += '<div class="card">';
        for (const r of rows) { const idx = items.length; items.push({ t: 'row', r }); html += rowHTML(r, idx, q, false); }
        html += '</div>';
      }
    } else {
      const sections = [];   // [{title, html}]
      if (a.settings) {
        let h = '';
        for (const f of a.settings.fields.filter(f => score({ label: f.label, help: f.help }, a, q))) {
          const idx = items.length; items.push({ t: 'set', a, f }); h += settingRowHTML(a, f, idx, q, false);
        }
        if (h) sections.push({ title: 'General', html: h });
      }
      const groups = new Map();
      for (const o of arr(a.options).filter(o => score(optSearch(o), a, q))) {
        const g = o.group || (a.settings ? 'Advanced' : 'General');
        if (!groups.has(g)) groups.set(g, []);
        groups.get(g).push(o);
      }
      for (const [g, opts] of groups) {
        let h = '';
        for (const o of opts) { const idx = items.length; items.push({ t: 'opt', a, o }); h += optRowHTML(a, o, idx, q, false); }
        const same = sections.find(x => x.title === g);
        if (same) same.html += h; else sections.push({ title: g, html: h });
      }
      for (const sct of sections) html += '<div class="sec"><span>' + esc(sct.title) + '</span></div><div class="card">' + sct.html + '</div>';
    }
    if (!items.length) html += '<div class="empty">' + (q ? 'No matches for “' + esc(qEl.value) + '”' : 'Nothing here') + '</div>';
    html += savebarHTML(a.id);
  }

  main.innerHTML = html;
  if (sel >= items.length) sel = Math.max(0, items.length - 1);
  if (keepScroll) main.scrollTop = st;
  renderDetail();
  renderFoot();
}

function hasCfg(a) { return !!(a.settings || arr(a.options).length); }
function setTab(t) {
  if (view === 'all' || t === tab) return;
  tab = t; sel = 0; post({ action: 'go', view: view + (tab === 'settings' ? ':settings' : '') });
  render(); $('main').scrollTop = 0; qEl.focus();
}
function savebarHTML(appId) {
  const n = nDirty(appId);
  return '<div class="savebar' + (n ? ' show' : '') + '"><span class="msg">' + n + ' unsaved change' + (n === 1 ? '' : 's') +
    ' · saving reloads Hammerspoon</span><button class="btn" data-discard="1">Discard</button>' +
    '<button class="btn pri" data-save="1">Save  ⌘S</button></div>';
}
function updateSavebar(appId) {
  const sb = document.querySelector('.savebar'); if (!sb) return;
  const n = nDirty(appId);
  sb.classList.toggle('show', n > 0);
  sb.querySelector('.msg').textContent = n + ' unsaved change' + (n === 1 ? '' : 's') + ' · saving reloads Hammerspoon';
  renderFoot();
  const side = document.querySelector('.side .it[data-v="' + appId + '"] span'); if (side) render(true);
}

function renderDetail() {
  const it = items[sel];
  let h = '';
  if (listening) h = '<span class="d" style="color:var(--accent)">' + (rowById(listening).kind === 'caps'
      ? 'Press the new key to use with Caps (add ⇧⌃⌥⌘ if you like)' : 'Press the new shortcut (needs ⌃, ⌥, or ⌘)') + '</span>';
  else if (it && it.t === 'row') h = '<span class="d">' + esc(it.r.desc) + '</span>' +
      (it.r.custom ? '<span class="c">Custom key · ⌘⌫ resets</span>' : '');
  else if (it && it.t === 'opt' && it.o.custom) h = '<span class="d"></span><span class="c">Changed · default is ' +
      esc(fmtVal(it.o, it.o.def)) + ' · ⌘⌫ resets</span>';
  $('detail').innerHTML = h;
}

function K(keys, label) { return '<span class="k">' + keys.map(k => '<kbd>' + k + '</kbd>').join('') + ' ' + label + '</span>'; }
function renderFoot() {
  const it = items[sel];
  let h;
  if (listening) h = K(['esc'], 'Cancel');
  else {
    h = K(['↑', '↓'], 'Select');
    if (it && it.t === 'row') h += K(['↵'], 'Run') + (it.r.kind !== 'action' ? K(['⌘', 'R'], 'Change key') : '');
    if (it && (it.t === 'set' || it.t === 'opt')) h += K(['↵'], 'Edit');
    if (it && it.t === 'opt' && it.o.custom) h += K(['⌘', '⌫'], 'Reset');
    if (view !== 'all' && nDirty(view)) h += K(['⌘', 'S'], 'Save');
    h += '<span class="gap"></span>';
    const a = view !== 'all' && appOf(view);
    if (a && hasCfg(a) && a.rows.length) h += K(['⌘', 'O'], tab === 'keys' ? 'Settings' : 'Shortcuts');
    else if (!a) h += K(['⌘', 'O'], 'Settings');
    h += K(['⇥'], 'Next app') + K(['esc'], 'Close');
  }
  $('foot').innerHTML = h;
}

function scrollSel() {
  const el = document.querySelector('[data-i="' + sel + '"]');
  if (el) el.scrollIntoView({ block: 'nearest' });
}
function setSel(i) {
  if (!items.length) return;
  const old = document.querySelector('[data-i="' + sel + '"]');
  if (old) old.classList.remove('sel');
  sel = Math.max(0, Math.min(items.length - 1, i));
  const el = document.querySelector('[data-i="' + sel + '"]');
  if (el) el.classList.add('sel');
  scrollSel(); renderDetail(); renderFoot();
}
function rowById(id) { for (const a of DATA.apps) for (const r of a.rows) if (r.id === id) return r; return null; }

function go(v, focusKey, t) {
  view = v;
  tab = focusKey ? (rowById(focusKey) ? 'keys' : 'settings') : (t || 'keys');
  post({ action: 'go', view: v === 'all' ? v : v + (tab === 'settings' ? ':settings' : '') });
  sel = 0; qEl.value = ''; render();
  $('main').scrollTop = 0;
  qEl.focus();
  if (focusKey) {
    const i = items.findIndex(it => (it.t === 'set' && it.f.key === focusKey) ||
      (it.t === 'opt' && it.o.path === focusKey) || (it.t === 'row' && it.r.id === focusKey));
    if (i >= 0) { setSel(i); if (items[i].t !== 'row') activate(); }
  }
}
function cycleApp(dir) {
  const ids = ['all'].concat(DATA.apps.map(a => a.id));
  go(ids[(ids.indexOf(view) + dir + ids.length) % ids.length]);
}

// ---------- actions ----------
function activate() {
  const it = items[sel]; if (!it) return;
  if (it.t === 'row') { post({ action: 'run', id: it.r.id }); return; }
  if (view === 'all') { go(it.a.id, it.t === 'set' ? it.f.key : it.o.path); return; }
  const el = document.querySelector('[data-i="' + sel + '"]');
  const tog = el && el.querySelector('.tog');
  if (tog) { if (it.t === 'opt') toggleOpt(it.a.id, it.o.path); else toggle(it.a.id, it.f.key); return; }
  const ctl = el && el.querySelector('input,select,textarea');
  if (ctl) { ctl.focus(); if (ctl.select) try { ctl.select(); } catch (e) {} }
}
function setVal(appId, key, value) {
  const a = appOf(appId); const f = a.settings.fields.find(f => f.key === key);
  dirty[appId] = dirty[appId] || {};
  if (String(value) === String(f.value)) delete dirty[appId][key]; else dirty[appId][key] = String(value);
}
function toggle(appId, key) {
  const a = appOf(appId); const f = a.settings.fields.find(f => f.key === key);
  const cur = (dirty[appId] && key in dirty[appId]) ? dirty[appId][key] : f.value;
  setVal(appId, key, String(cur) === 'true' ? 'false' : 'true'); render(true);
}
function toggleOpt(appId, path) { const o = optOf(appId, path); setOpt(appId, path, !curOpt(appId, o)); render(true); }
function resetOpt(it) {
  if (!it || it.t !== 'opt' || !it.o.custom) return;
  setOpt(it.a.id, it.o.path, it.o.def); render(true); toast('Back to default · ⌘S to save');
}
function save() {
  if (view === 'all' || !nDirty(view)) return;
  for (const [path, v] of Object.entries(cdirty[view] || {})) {
    const o = optOf(view, path);
    if ((o.type === 'int' || o.type === 'num') && typeof v !== 'number') { toast(o.label + ' needs a number', 3000); return; }
  }
  post({ action: 'save', app: view, settings: dirty[view] || {}, config: cdirty[view] || {} });
  toast('Saving, reloading Hammerspoon…', 3000);
}
// ⌘O / ⌘0 edit config · ⌘R change key · ⌘, app settings. Lua forwards these
// (Hammerspoon's menu would otherwise take them) via onCmd().
function command(k) {
  const it = items[sel];
  if (k === 'o' || k === '0' || k === ',') editConfig(it);
  else if (k === 'r') startListen();
}
function onCmd(k) {
  hideCtx();
  if (listening) {   // the user is choosing ⌘<k> as the new key
    post({ action: 'rebind', id: listening, mods: ['cmd'], key: k });
    return;
  }
  command(k);
}
// Edit config, in this window: from the overview jump to the item's app page;
// on an app page, a shortcut row jumps to its options, an option gets focus.
// ⌘O: open an app's Settings tab (or flip between Shortcuts and Settings).
function editConfig(it) {
  if (view === 'all') {
    if (!it) return;
    if (it.t === 'row') go(it.r.app, null, 'settings'); else go(it.a.id, it.t === 'set' ? it.f.key : it.o.path);
    return;
  }
  setTab(tab === 'keys' ? 'settings' : 'keys');
}

// ---------- right-click menu ----------
const ctx = $('ctx');
function ctxOpen() { return ctx.classList.contains('show'); }
function hideCtx() { ctx.classList.remove('show'); }
function showCtx(x, y) {
  const it = items[sel]; if (!it) return;
  const mi = (act, label, keys) => '<div class="mi" data-ctx="' + act + '"><span>' + label + '</span>' +
    (keys || []).map(k => '<kbd>' + k + '</kbd>').join('') + '</div>';
  let h = '';
  if (it.t === 'row') {
    if (hasCfg(appOf(it.r.app))) h += mi('edit', appOf(it.r.app).name + ' settings', ['⌘', 'O']);
    if (it.r.kind !== 'action') h += mi('rebind', 'Change key', ['⌘', 'R']);
    if (it.r.custom) h += mi('reset', 'Reset to default key', ['⌘', '⌫']);
    h += '<div class="hr"></div>' + mi('run', 'Run', ['↵']);
  } else {
    h += mi('edit', view === 'all' ? 'Edit in ' + it.a.name : 'Edit', ['↵']);
    if (it.t === 'opt' && it.o.custom) h += mi('resetOpt', 'Reset to default (' + fmtVal(it.o, it.o.def) + ')', ['⌘', '⌫']);
  }
  ctx.innerHTML = h; ctx.classList.add('show');
  const w = ctx.offsetWidth, hgt = ctx.offsetHeight;
  ctx.style.left = Math.min(x, innerWidth - w - 6) + 'px';
  ctx.style.top = Math.min(y, innerHeight - hgt - 6) + 'px';
}
document.addEventListener('contextmenu', function (e) {
  e.preventDefault();
  const row = e.target.closest('[data-i]');
  if (!row || listening) { hideCtx(); return; }
  setSel(+row.dataset.i); showCtx(e.clientX, e.clientY);
});
ctx.addEventListener('click', function (e) {
  const m = e.target.closest('[data-ctx]'); if (!m) return;
  e.stopPropagation(); hideCtx();
  const it = items[sel], a = m.dataset.ctx;
  if (a === 'edit') { if (it.t === 'row') go(it.r.app, null, 'settings'); else activate(); }
  else if (a === 'rebind') startListen();
  else if (a === 'reset') post({ action: 'reset', id: it.r.id });
  else if (a === 'resetOpt') resetOpt(it);
  else if (a === 'run') activate();
});

// ---------- drag the window by its top bar (borderless window) ----------
let drag = null;   // { x, y, mode: 'move' | 'resize' }
$('top').addEventListener('mousedown', function (e) {
  if (e.button !== 0 || e.target === qEl || e.target.closest('[data-win]')) return;
  drag = { x: e.screenX, y: e.screenY, mode: 'move' }; e.preventDefault();
});
$('grip').addEventListener('mousedown', function (e) {
  if (e.button !== 0) return;
  drag = { x: e.screenX, y: e.screenY, mode: 'resize' }; e.preventDefault();
});
document.addEventListener('mousemove', function (e) {
  if (!drag) return;
  const dx = e.screenX - drag.x, dy = e.screenY - drag.y;
  if (dx || dy) {
    post(drag.mode === 'move' ? { action: 'move', dx, dy } : { action: 'resize', dw: dx, dh: dy });
    drag.x = e.screenX; drag.y = e.screenY;
  }
});
document.addEventListener('mouseup', () => { if (drag && drag.mode === 'resize') post({ action: 'resized' }); drag = null; });

function startListen() {
  const it = items[sel];
  if (!it || it.t !== 'row' || it.r.kind === 'action') return;
  listening = it.r.id; render(true);
}
// Called from Lua
function onRebindResult(res) {
  if (res.ok) toast('Saved, reloading…', 4000);
  else { toast(res.error || 'Rebind failed', 3200); listening = null; render(true); }
}
function onSaved(res) {
  if (!res.ok) { toast(res.error || 'Save failed', 4000); return; }
  if (res.data) { DATA = res.data; normalize(); dirty[view] = {}; render(true); toast('Saved'); }
}

function normKey(e) {
  const c = e.code || '';
  if (c.startsWith('Key')) return c.slice(3).toLowerCase();
  if (c.startsWith('Digit')) return c.slice(5);
  if (/^F\d+$/.test(e.key)) return e.key.toLowerCase();
  const map = { Space:'space', Slash:'/', Period:'.', Comma:',', Semicolon:';', Quote:"'", BracketLeft:'[',
    BracketRight:']', Backslash:'\\', Backquote:'`', Minus:'-', Equal:'=', Enter:'return', Tab:'tab',
    Backspace:'delete', Delete:'forwarddelete', ArrowUp:'up', ArrowDown:'down', ArrowLeft:'left',
    ArrowRight:'right', Home:'home', End:'end', PageUp:'pageup', PageDown:'pagedown' };
  return map[c] || (e.key.length === 1 ? e.key.toLowerCase() : null);
}

document.addEventListener('keydown', function (e) {
  if (listening) {
    e.preventDefault(); e.stopPropagation();
    if (e.key === 'Escape') { listening = null; render(true); return; }
    if (['Shift', 'Control', 'Alt', 'Meta', 'CapsLock'].includes(e.key)) return;
    const key = normKey(e); if (!key) { toast('Unrecognized key'); return; }
    const mods = []; if (e.shiftKey) mods.push('shift'); if (e.ctrlKey) mods.push('ctrl');
    if (e.altKey) mods.push('alt'); if (e.metaKey) mods.push('cmd');
    const r = rowById(listening);
    if (r.kind === 'hotkey' && !mods.some(m => m !== 'shift')) { toast('Global shortcuts need ⌃, ⌥, or ⌘'); return; }
    post({ action: 'rebind', id: listening, mods, key });
    return;
  }
  const inField = document.activeElement && document.activeElement !== qEl &&
    ['INPUT', 'SELECT', 'TEXTAREA'].includes(document.activeElement.tagName);
  const it = items[sel];

  if (ctxOpen()) { e.preventDefault(); hideCtx(); if (e.key === 'Escape') return; }
  if (e.key === 'Escape') { e.preventDefault(); post({ action: 'close' }); return; }
  if (e.metaKey && e.key.toLowerCase() === 's') { e.preventDefault(); if (inField) document.activeElement.blur(); save(); return; }
  if (e.metaKey && ['o', '0', ',', 'r'].includes(e.key.toLowerCase())) { e.preventDefault(); command(e.key.toLowerCase()); return; }
  if (e.metaKey && e.key === 'Backspace' && !inField && it && it.t === 'row' && it.r.custom) { e.preventDefault(); post({ action: 'reset', id: it.r.id }); return; }
  if (e.metaKey && e.key === 'Backspace' && !inField && it && it.t === 'opt' && it.o.custom) { e.preventDefault(); resetOpt(it); return; }

  if (inField) {
    if (e.key === 'Enter' && document.activeElement.tagName !== 'TEXTAREA') { e.preventDefault(); document.activeElement.blur(); qEl.focus(); }
    return;
  }
  if ((e.key === 'ArrowLeft' || e.key === 'ArrowRight') && !qEl.value && view !== 'all') {
    e.preventDefault(); setTab(e.key === 'ArrowLeft' ? 'keys' : 'settings'); return;
  }
  if (e.key === 'ArrowDown') { e.preventDefault(); setSel(sel + 1); return; }
  if (e.key === 'ArrowUp') { e.preventDefault(); setSel(sel - 1); return; }
  if (e.key === 'Enter') { e.preventDefault(); activate(); return; }
  if (e.key === 'Tab') { e.preventDefault(); cycleApp(e.shiftKey ? -1 : 1); return; }
  if (document.activeElement !== qEl && e.key.length === 1 && !e.metaKey && !e.ctrlKey) qEl.focus();
}, true);

qEl.addEventListener('input', () => { sel = 0; render(); $('main').scrollTop = 0; });

document.addEventListener('click', function (e) {
  const t = e.target;
  if (ctxOpen()) { hideCtx(); return; }
  const side = t.closest('.side .it'); if (side) { go(side.dataset.v); return; }
  const win = t.closest('[data-win]'); if (win) { post({ action: win.dataset.win }); return; }
  const tb = t.closest('[data-tab]'); if (tb) { setTab(tb.dataset.tab); return; }
  const goA = t.closest('[data-go]'); if (goA) { go(goA.dataset.go, null, goA.dataset.gotab); return; }
  if (t.closest('[data-save]')) { save(); return; }
  if (t.closest('[data-discard]')) { dirty[view] = {}; cdirty[view] = {}; render(true); return; }
  const tog = t.closest('.tog'); const set = t.closest('.set');
  if (tog && set) {
    setSel(+set.dataset.i);
    if (tog.dataset.otog) toggleOpt(set.dataset.app, tog.dataset.otog); else toggle(set.dataset.app, tog.dataset.tog);
    return;
  }
  const row = t.closest('[data-i]');
  if (row) {
    const i = +row.dataset.i;
    if (t.closest('kbd') && items[i] && items[i].t === 'row') { setSel(i); startListen(); return; }
    if (i === sel && !t.closest('input,select,textarea')) { activate(); return; }
    setSel(i);
  }
});
document.addEventListener('dblclick', e => {
  if (e.target.closest('#top') && e.target !== qEl && !e.target.closest('[data-win]')) { post({ action: 'zoom' }); return; }
  const row = e.target.closest('.row'); if (row) { setSel(+row.dataset.i); activate(); }
});
document.addEventListener('change', function (e) {
  const k = e.target.dataset && e.target.dataset.k; const set = e.target.closest('.set');
  if (k && set && e.target.tagName === 'SELECT') { setVal(set.dataset.app, k, e.target.value); render(true); }
});
// Typing updates state in place (no re-render, so the field keeps focus).
document.addEventListener('input', function (e) {
  const set = e.target.closest('.set'); if (!set || e.target === qEl) return;
  const appId = set.dataset.app, k = e.target.dataset.k, p = e.target.dataset.o;
  if (k) { setVal(appId, k, e.target.value); set.classList.toggle('dirty', k in (dirty[appId] || {})); }
  else if (p) { const o = optOf(appId, p); setOpt(appId, p, parseOpt(o, e.target.value)); set.classList.toggle('dirty', p in (cdirty[appId] || {})); }
  else return;
  const sb = document.querySelector('.savebar');
  if (sb) {
    const n = nDirty(appId); sb.classList.toggle('show', n > 0);
    sb.querySelector('.msg').textContent = n + ' unsaved change' + (n === 1 ? '' : 's') + ' · saving reloads Hammerspoon';
  }
  const dot = document.querySelector('.side .it[data-v="' + appId + '"] > span');
  if (dot) dot.innerHTML = esc(appOf(appId).name) + (nDirty(appId) ? ' <span style="color:var(--warn)">•</span>' : '');
  renderFoot();
});

function normalize() {
  DATA.apps = arr(DATA.apps);
  for (const a of DATA.apps) {
    a.rows = arr(a.rows);
    for (const r of a.rows) r.keys = arr(r.keys);
    if (a.settings) a.settings.fields = arr(a.settings.fields);
    a.options = arr(a.options);
    for (const o of a.options) if (o.type === 'list') { o.value = arr(o.value); o.def = arr(o.def); }
  }
}
normalize();
render();
if (view !== 'all') $('main').scrollTop = 0;
qEl.focus();
</script></body></html>
]==]

-- startView is "all", "<app>", or "<app>:settings".
local function buildHTML(startView)
  local v, t = tostring(startView or "all"):match("^([^:]+):?(.*)$")
  return PAGE_HEAD .. "let DATA = " .. hs.json.encode(M.buildData()) .. ";\n"
    .. "const START_VIEW = " .. string.format("%q", v or "all") .. ";\n"
    .. "const START_TAB = " .. string.format("%q", t == "settings" and "settings" or "keys") .. ";\n"
    .. PAGE_TAIL
end

----------------------------------------------------------------
-- WINDOW
----------------------------------------------------------------
local webview = nil
local currentView = "all"
local SIZE_KEY = "palette.windowSize"
local MIN_W, MIN_H = 640, 420
local zoomed = false

-- ⌘O/⌘0/⌘R/⌘, are Hammerspoon menu shortcuts; claim them only while focused.
local cmdModal = nil
local function cmdKeys(on)
  if not cmdModal then
    cmdModal = hs.hotkey.modal.new()
    for _, k in ipairs({ "o", "0", "r", "," }) do
      cmdModal:bind({ "cmd" }, k, function()
        if webview then webview:evaluateJavaScript("onCmd(" .. string.format("%q", k) .. ")") end
      end)
    end
  end
  if on then cmdModal:enter() else cmdModal:exit() end
end

function M.hide()
  cmdKeys(false)
  if webview then
    log.info("hide window")
    pcall(function() webview:delete() end)
    webview = nil
  end
end

local function js(fn, arg)
  if webview then webview:evaluateJavaScript(fn .. "(" .. hs.json.encode(arg) .. ")") end
end

local function reloadInto(view, alertMsg)
  hs.settings.set(REOPEN_KEY, view or "all")
  if alertMsg then hs.alert.show(alertMsg, 1.2) end
  hs.timer.doAfter(0.4, hs.reload)
end

local function handleMessage(msg)
  local b = msg and msg.body
  if type(b) ~= "table" then return end

  if b.action == "close" then
    M.hide()

  elseif b.action == "run" then
    local entry = entryById(b.id)
    if not entry then return end
    log.info("message run", { id = entry.id })
    M.hide()
    -- Let focus return to the previous app before actions that type/paste.
    hs.timer.doAfter(0.25, function()
      local ok, m = pcall(require, entry.module)
      if ok then
        local ran, err = xpcall(function() entry.run(m) end, debug.traceback)
        if not ran then log.error("run failed", { id = entry.id, error = err }) end
      else
        log.error("run module require failed", { id = entry.id, error = m })
      end
    end)


  elseif b.action == "zoom" then
    if webview then
      local f, sf = webview:frame(), hs.screen.mainScreen():frame()
      local w, h
      if zoomed then
        local saved = hs.settings.get(SIZE_KEY)
        w = type(saved) == "table" and saved.w or config.windowWidth
        h = type(saved) == "table" and saved.h or config.windowHeight
      else
        hs.settings.set(SIZE_KEY, { w = math.floor(f.w), h = math.floor(f.h) })
        w, h = math.floor(sf.w * 0.9), math.floor(sf.h * 0.9)
      end
      zoomed = not zoomed
      webview:frame({ x = sf.x + (sf.w - w) / 2, y = sf.y + (sf.h - h) / 2, w = w, h = h })
    end

  elseif b.action == "resize" then
    if webview and tonumber(b.dw) and tonumber(b.dh) then
      local f = webview:frame()
      webview:size({ w = math.max(MIN_W, f.w + b.dw), h = math.max(MIN_H, f.h + b.dh) })
    end

  elseif b.action == "resized" then
    zoomed = false
    if webview then
      local f = webview:frame()
      hs.settings.set(SIZE_KEY, { w = math.floor(f.w), h = math.floor(f.h) })
    end

  elseif b.action == "move" then
    if webview and tonumber(b.dx) and tonumber(b.dy) then
      local tl = webview:topLeft()
      webview:topLeft({ x = tl.x + b.dx, y = tl.y + b.dy })
    end

  elseif b.action == "reset" then
    local entry = entryById(b.id)
    if not entry then return end
    local o = loadOverrides()
    o[entry.id] = nil
    saveOverrides(o)
    log.info("reset", { id = entry.id })
    reloadInto(entry.module, entry.label .. " reset to default")

  elseif b.action == "rebind" then
    local entry = entryById(b.id)
    if not entry then return end
    local key, mods = b.key, b.mods or {}
    if type(key) ~= "string" or not hs.keycodes.map[key] then
      return js("onRebindResult", { ok = false, error = "Unrecognized key: " .. tostring(key) })
    end
    local newSig = comboSig(entry.kind, mods, key)
    for _, other in ipairs(REGISTRY) do
      if other.id ~= entry.id and other.kind ~= "action" then
        local bnd = currentBinding(other)
        if bnd and comboSig(other.kind, bnd[1], bnd[2]) == newSig then
          return js("onRebindResult", { ok = false, error = comboLabel(entry.kind, { mods, key })
            .. " is already “" .. other.label .. "”" })
        end
      end
    end
    local o = loadOverrides()
    o[entry.id] = { mods = mods, key = key }
    saveOverrides(o)
    js("onRebindResult", { ok = true })
    log.info("rebind saved", { id = entry.id, combo = comboLabel(entry.kind, { mods, key }) })
    reloadInto(currentView, entry.label .. " → " .. comboLabel(entry.kind, { mods, key }))

  elseif b.action == "save" then
    local appId = b.app
    if not appById(appId or "") then return js("onSaved", { ok = false, error = "Unknown app" }) end
    local cfg = type(b.config) == "table" and b.config or {}
    local settings = type(b.settings) == "table" and b.settings or {}

    -- Options: validate every value before writing anything.
    if next(cfg) then
      local byPath = {}
      for _, o in ipairs(optionsFor(appId)) do byPath[o.path] = o end
      local all = loadConfigEdits()
      local mine = type(all[appId]) == "table" and all[appId] or {}
      for pkey, v in pairs(cfg) do
        local o = byPath[pkey]
        local nv = o and coerce(o.def, v)
        if nv == nil then
          return js("onSaved", { ok = false, error = "Invalid value for " .. (o and o.label or tostring(pkey)) })
        end
        if sameValue(nv, o.def) then mine[pkey] = nil else mine[pkey] = nv end
      end
      all[appId] = next(mine) and mine or nil
      saveConfigEdits(all)
      log.info("options saved", { app = appId })
    end

    local schema = next(settings) and loadSchema(appId)
    if not schema then
      if next(settings) then return js("onSaved", { ok = false, error = "No settings for " .. appId }) end
      return reloadInto(appId .. ":settings", "Saved")
    end
    local args = { appId, "--set" }
    for k, v in pairs(settings) do args[#args + 1] = tostring(k) .. "=" .. tostring(v) end
    args[#args + 1] = "--no-post-save"
    log.info("save settings", { app = appId, count = #args - 3 })
    hs.task.new(SETTINGS_BIN, function(code, _, stderr)
      if code ~= 0 then
        log.error("save failed", { app = appId, stderr = stderr })
        return js("onSaved", { ok = false, error = "Save failed: " .. tostring(stderr):sub(1, 120) })
      end
      if (schema.format or "json") == "json" or next(cfg) then
        reloadInto(appId .. ":settings", "Saved")
      else
        js("onSaved", { ok = true, data = M.buildData() })
      end
    end, args):start()
  end
end

function M.show(view)
  local base = type(view) == "string" and view:match("^[^:]+") or nil
  view = (base and (base == "all" or appById(base))) and view or "all"
  currentView = view
  log.info("show window", { view = view })
  M.hide()
  zoomed = false

  local uc = hs.webview.usercontent.new("palette"):setCallback(function(msg)
    if type(msg.body) == "table" and msg.body.action == "go" then currentView = msg.body.view end
    handleMessage(msg)
  end)

  local screen = hs.screen.mainScreen():frame()
  local saved = hs.settings.get(SIZE_KEY)
  local w = math.min(type(saved) == "table" and tonumber(saved.w) or config.windowWidth, screen.w)
  local h = math.min(type(saved) == "table" and tonumber(saved.h) or config.windowHeight, screen.h)
  webview = hs.webview.new({ x = screen.x + (screen.w - w) / 2, y = screen.y + (screen.h - h) / 2.4, w = w, h = h },
      { developerExtrasEnabled = false }, uc)
    :windowStyle({ "borderless", "resizable" })
    :windowTitle("Shortcuts")
    :transparent(true)
    :allowTextEntry(true)
    :deleteOnClose(true)
    :closeOnEscape(false)
    :shadow(true)
    :level(hs.drawing.windowLevels.floating)
    :windowCallback(function(action, _, state)
      if action == "focusChange" then cmdKeys(state and true or false)
      elseif action == "frameChange" and not zoomed and webview then
        local f = webview:frame()   -- remember edge-resizes too
        hs.settings.set(SIZE_KEY, { w = math.floor(f.w), h = math.floor(f.h) })
      elseif action == "closing" then cmdKeys(false) end
    end)
    :html(buildHTML(view))

  webview:show()
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
  local count = 0
  for _, e in ipairs(REGISTRY) do
    local ov = o[e.id]
    if type(ov) == "table" and ov.key then
      if setBinding(e, { ov.mods or {}, ov.key }) then
        count = count + 1
      else
        log.warn("override skipped", { id = e.id })
      end
    end
  end
  log.info("overrides applied", { count = count })

  local applied = 0
  for appId, kv in pairs(loadConfigEdits()) do
    local ok, m = pcall(require, appId)
    if appById(appId) and ok and type(m) == "table" and type(m.config) == "table" and type(kv) == "table" then
      configDefaults[appId] = configDefaults[appId] or {}
      for pkey, v in pairs(kv) do
        local path = splitPath(pkey)
        local cur = getPath(m.config, path)
        local nv = nil
        if cur ~= nil then nv = coerce(cur, v) end
        if nv ~= nil then
          configDefaults[appId][pkey] = deepcopy(cur)
          setPath(m.config, path, nv)
          applied = applied + 1
        else
          log.warn("option skipped", { app = appId, key = pkey })
        end
      end
    end
  end
  log.info("options applied", { count = applied })
end

----------------------------------------------------------------
-- start() — bind the window hotkey; reopen after a save/rebind reload.
----------------------------------------------------------------
function M.start()
  local ok, qs = pcall(require, "quickshots")
  if ok and type(qs) == "table" and type(qs.registerCapsAction) == "function" then
    qs.registerCapsAction(config.capsMenu[1], config.capsMenu[2],
      require("litelog").wrap("palette", "show caps menu", function() M.show() end))
    log.info("caps menu bound")
  else
    hs.hotkey.bind(config.fallbackMenu[1], config.fallbackMenu[2],
      require("litelog").wrap("palette", "show fallback menu", function() M.show() end))
    log.warn("caps tap unavailable; fallback bound")
    hs.alert.show("shortcuts: caps tap unavailable — window on ⌃⌥⌘K", 3)
  end

  local reopen = hs.settings.get(REOPEN_KEY)
  if reopen then
    hs.settings.set(REOPEN_KEY, false)
    hs.timer.doAfter(0.5, function() M.show(type(reopen) == "string" and reopen or "all") end)
  end
  log.info("started")
end

M.config = config
M.buildHTML = buildHTML -- for previewing the window outside Hammerspoon
function M.evalJS(code, cb) if webview then webview:evaluateJavaScript(code, cb) end end -- debugging

return M
