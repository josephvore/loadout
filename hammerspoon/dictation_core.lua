-- Pure, deterministic helpers for dictation.lua. This file deliberately has
-- no Hammerspoon dependencies so replay/regression tests can run with lua.

local M = {}

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function wordCount(s)
  local n = 0
  for _ in tostring(s or ""):gmatch("%S+") do n = n + 1 end
  return n
end

local function readLines(path)
  local f = io.open(path or "", "r")
  if not f then return {} end
  local lines = {}
  for line in f:lines() do lines[#lines + 1] = line end
  f:close()
  return lines
end

local function splitList(s)
  local out = {}
  for item in tostring(s or ""):gmatch("[^,|]+") do
    local cleaned = trim(item)
    if cleaned ~= "" then out[#out + 1] = cleaned end
  end
  return out
end

local function charPattern(c)
  if c:match("%a") then return "[" .. c:lower() .. c:upper() .. "]" end
  if c:match("%s") then return "%s+" end
  return (c:gsub("([^%w])", "%%%1"))
end

local function phrasePattern(phrase)
  local parts = {}
  for i = 1, #phrase do parts[#parts + 1] = charPattern(phrase:sub(i, i)) end
  return "%f[%w]" .. table.concat(parts) .. "%f[%W]"
end

local BUILTIN_REPLACEMENTS = {
  { from = "right command", to = "Right Command" },
  { from = "whisper flow", to = "Wispr Flow" },
  { from = "whisperflow", to = "Wispr Flow" },
  { from = "wisper flow", to = "Wispr Flow" },
}

function M.loadReplacements(glossaryPath, correctionsPath)
  local replacements = {}
  for _, r in ipairs(BUILTIN_REPLACEMENTS) do
    replacements[#replacements + 1] = { from = r.from, to = r.to }
  end

  for _, line in ipairs(readLines(glossaryPath)) do
    local cleaned = trim((line:gsub("#.*$", "")))
    if cleaned ~= "" then
      local canonical, variants = cleaned:match("^(.-)%s*=%s*(.+)$")
      if not canonical then canonical, variants = cleaned:match("^(.-)%s*=>%s*(.+)$") end
      canonical = trim(canonical or cleaned)
      if variants then
        for _, variant in ipairs(splitList(variants)) do
          replacements[#replacements + 1] = { from = variant, to = canonical }
        end
      end
    end
  end

  for _, line in ipairs(readLines(correctionsPath)) do
    local cleaned = trim((line:gsub("#.*$", "")))
    local from, to = cleaned:match("^(.-)\t(.+)$")
    if not from then from, to = cleaned:match("^(.-)%s*=>%s*(.+)$") end
    if from and to then
      replacements[#replacements + 1] = { from = trim(from), to = trim(to) }
    end
  end

  table.sort(replacements, function(a, b) return #a.from > #b.from end)
  return replacements
end

function M.contextTerms(glossaryPath, correctionsPath, limit)
  local terms, seen = {}, {}
  local function add(term)
    term = trim(term)
    local key = term:lower()
    if term ~= "" and not seen[key] and #terms < (limit or 100) then
      seen[key] = true
      terms[#terms + 1] = term
    end
  end

  -- Canonical glossary spellings retain file order.
  for _, line in ipairs(readLines(glossaryPath)) do
    local cleaned = trim((line:gsub("#.*$", "")))
    if cleaned ~= "" then
      add(cleaned:match("^(.-)%s*=") or cleaned:match("^(.-)%s*=>") or cleaned)
    end
  end

  -- Newest learned correction targets receive the remaining context slots.
  local corrections = readLines(correctionsPath)
  for i = #corrections, 1, -1 do
    local cleaned = trim((corrections[i]:gsub("#.*$", "")))
    local target = select(2, cleaned:match("^(.-)\t(.+)$"))
    if not target then target = select(2, cleaned:match("^(.-)%s*=>%s*(.+)$")) end
    if target then add(target) end
  end
  return terms
end

local function applyReplacements(text, opts)
  for _, r in ipairs(M.loadReplacements(opts.glossaryPath, opts.correctionsPath)) do
    if r.from ~= "" and r.to ~= "" and r.from:lower() ~= r.to:lower() then
      text = text:gsub(phrasePattern(r.from), function() return r.to end)
    elseif r.from ~= "" and r.to ~= "" and r.from ~= r.to then
      text = text:gsub(phrasePattern(r.from), function() return r.to end)
    end
  end
  return text
end

local function applyScratchThat(text)
  text = text:gsub("^.*%f[%a][Ss]cratch all that%f[%A][,%.%!%?%s]*", "")
  text = text:gsub("^.*%f[%a][Nn]ever mind%f[%A][,%.%!%?%s]*", "")
  while true do
    local s, e = text:find("%f[%a][Ss]cratch that%f[%A]")
    if not s then s, e = text:find("%f[%a][Dd]elete that%f[%A]") end
    if not s then break end
    local before = text:sub(1, s - 1):gsub("[%s,%.%!%?;:]+$", "")
    local after = text:sub(e + 1):gsub("^[%s,%.%!%?;:]+", "")
    local cut, pos = 0, 1
    while true do
      local _, boundaryEnd = before:find("[%.%!%?]%s*", pos)
      if not boundaryEnd then break end
      cut, pos = boundaryEnd, boundaryEnd + 1
    end
    if cut == 0 then
      pos = 1
      while true do
        local _, boundaryEnd = before:find("[,;:]%s*", pos)
        if not boundaryEnd then break end
        cut, pos = boundaryEnd, boundaryEnd + 1
      end
    end
    before = trim(before:sub(1, cut))
    text = trim((before ~= "" and before .. " " or "") .. after)
  end
  return text
end

local function applyCommands(text)
  text = applyScratchThat(text)
  return text
    :gsub("%f[%a][Nn]ew paragraph%f[%A]", "\n\n")
    :gsub("%f[%a][Nn]ew line%f[%A]", "\n")
    :gsub("%f[%a][Ll]ine break%f[%A]", "\n")
    :gsub("%f[%a][Nn]ew bullet%f[%A]", "\n- ")
    :gsub("%f[%a][Bb]ullet point%f[%A]", "\n- ")
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
end

local function loadSnippets(path)
  local snippets = {}
  for _, line in ipairs(readLines(path)) do
    if not line:match("^%s*#") then
      local cue, expansion = line:match("^(.-)\t(.+)$")
      cue = trim(cue)
      if cue ~= "" and expansion then
        snippets[cue:lower()] = expansion:gsub("\\n", "\n")
      end
    end
  end
  return snippets
end

local function expandSnippet(text, path)
  local cue = trim(text):gsub("[%.%!%?]+$", ""):match("^[Ii]nsert%s+(.+)$")
  if not cue then return text, false end
  local expansion = loadSnippets(path)[trim(cue):lower()]
  if not expansion then return text, false end
  return expansion, true
end

function M.cleanupTranscript(text, opts)
  opts = opts or {}
  text = trim(text)
  if text == "" then return "", { snippet = false } end
  text = text:gsub("\r\n?", "\n"):gsub("[\t\v\f]+", " ")
  text = text:gsub("[ ]+", " ")
  if opts.voiceCommands ~= false then text = applyCommands(text) end
  text = applyReplacements(text, opts)
  local snippet
  text, snippet = expandSnippet(text, opts.snippetsPath)
  text = text
    :gsub("%f[%a][Ii]%f[%A]", "I")
    :gsub("%f[%a][Ee]t cetera%.?", "etc.")
    :gsub("%f[%a][Ee]tcetera%.?", "etc.")
    :gsub("[ \t]+([,%.%!%?%;:%)])", "%1")
    :gsub("([%(])%s+", "%1")
    :gsub("([\"'])%s+", "%1")
    :gsub("%s+([\"'])", "%1")
    :gsub("[ ]*\n[ ]*", "\n")
    :gsub("\n%s*\n", "\n\n")
    :gsub("([,%;:])%s*([,%;:%.%!%?])", "%2")
    :gsub("%.%.+", ".")
    :gsub("!!+", "!")
    :gsub("%?%?+", "?")
    :gsub("[ \t]+", " ")
  return trim(text), { snippet = snippet }
end

local MESSAGE_APPS = { mail = true, messages = true, slack = true }

function M.profileForApp(appName, override)
  override = tostring(override or "Auto")
  if override ~= "Auto" then return override end
  local name = trim(appName):lower()
  return MESSAGE_APPS[name] and "Message" or "Prompt"
end

local FILLER_PATTERNS = {
  "%f[%a]uh+%f[%A]", "%f[%a]um+%f[%A]", "%f[%a]you know%f[%A]",
  "%f[%a]I mean%f[%A]", "%f[%a]actually no%f[%A]",
  "%f[%a]scratch that%f[%A]", "%f[%a]what I mean is%f[%A]",
  "%f[%a]let me rephrase%f[%A]", "%f[%a]rather%f[%A]",
}

function M.shouldUseAI(text, profile)
  if profile == "Literal" then return false, "literal" end
  local words = wordCount(text)
  if profile == "Message" then
    return words >= 12, words >= 12 and nil or "short_message"
  end
  if words >= 20 then return true end
  local lower = tostring(text):lower()
  for _, pattern in ipairs(FILLER_PATTERNS) do
    if lower:find(pattern) then return true end
  end
  return false, "short_prompt"
end

function M.maxOutputTokens(text)
  return math.min(512, math.max(32, math.ceil(wordCount(text) * 1.8)))
end

local function numeralSet(text)
  local found, values = {}, {}
  for n in tostring(text):gmatch("%d[%d,%.]*") do found[n] = true end
  for n in pairs(found) do values[#values + 1] = n end
  table.sort(values)
  return table.concat(values, "|")
end

local function containsURL(text)
  return text:match("https?://[%w]") or text:match("www%.[%w]")
end

local LEAK_MARKERS = {
  "you are the cleanup engine", "system instruction", "developer message",
  "return only the", "raw transcript", "transcript json data",
  "do not answer the speaker", "preserve imperative voice",
}

function M.validateAIOutput(input, output)
  input, output = trim(input), trim(output)
  if output == "" then return false, "empty" end
  if numeralSet(input) ~= numeralSet(output) then return false, "numerals_changed" end
  if not containsURL(input) and containsURL(output) then return false, "url_introduced" end
  local inLower, outLower = input:lower(), output:lower()
  for _, marker in ipairs(LEAK_MARKERS) do
    if outLower:find(marker, 1, true) and not inLower:find(marker, 1, true) then
      return false, "prompt_leak"
    end
  end
  local ratio = #output / math.max(1, #input)
  if ratio < 0.45 or ratio > 1.45 then return false, "length_ratio" end
  return true
end

function M.newDeliveryQueue()
  local queue = { nextId = 0, pending = nil }
  function queue:start(localText, target)
    local superseded = self.pending
    if superseded then superseded.valid = false end
    self.nextId = self.nextId + 1
    self.pending = {
      id = self.nextId, localText = localText, target = target, valid = true,
    }
    return self.pending, superseded
  end
  function queue:resolve(id)
    if not self.pending or not self.pending.valid or self.pending.id ~= id then
      return nil, "stale"
    end
    local pending = self.pending
    self.pending = nil
    pending.valid = false
    return pending
  end
  return queue
end

M.trim = trim
M.wordCount = wordCount

return M
