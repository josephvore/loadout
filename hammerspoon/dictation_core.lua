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

local EXPLICIT_CORRECTION_CUES = {
  "actually no", "let me change that", "scratch that", "never mind",
  "what I mean is", "let me rephrase",
}

function M.hasExplicitCorrection(text)
  local lower = tostring(text or ""):lower()
  for _, cue in ipairs(EXPLICIT_CORRECTION_CUES) do
    if lower:find(cue, 1, true) then return true, cue end
  end
  return false
end

local function removeStandaloneFillers(text)
  for _, filler in ipairs({ "uh", "um", "er" }) do
    local pattern = "%f[%a][" .. filler:sub(1, 1):lower()
      .. filler:sub(1, 1):upper() .. "]" .. filler:sub(2)
      .. "%f[%A][,]*"
    text = text:gsub(pattern, "")
  end
  return text:gsub("[ ]+", " ")
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
  if opts.lightCleanup then text = removeStandaloneFillers(text) end
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

function M.shouldUseAI(text, profile)
  if profile == "Literal" then return false, "literal" end
  if M.hasExplicitCorrection(text) then return true end
  return false, "no_explicit_correction"
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

local function normalizedTokens(text)
  text = tostring(text or ""):lower()
    :gsub("\226\128\153", "'")
    :gsub("\226\128\147", "-")
    :gsub("\226\128\148", "-")
  local tokens = {}
  for token in text:gmatch("[%w']+") do tokens[#tokens + 1] = token end
  return tokens
end

local function tokensEqual(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do if a[i] ~= b[i] then return false end end
  return true
end

local function orderedSubsequence(needle, haystack)
  local pos = 1
  for _, token in ipairs(needle) do
    while pos <= #haystack and haystack[pos] ~= token do pos = pos + 1 end
    if pos > #haystack then return false end
    pos = pos + 1
  end
  return true
end

local function correctionTail(tokens)
  local cues = {
    { "actually", "no" }, { "let", "me", "change", "that" },
    { "scratch", "that" }, { "never", "mind" },
    { "what", "i", "mean", "is" }, { "let", "me", "rephrase" },
  }
  local tailStart = nil
  for i = 1, #tokens do
    for _, cue in ipairs(cues) do
      local matches = true
      for j = 1, #cue do
        if tokens[i + j - 1] ~= cue[j] then matches = false; break end
      end
      if matches then tailStart = i + #cue end
    end
  end
  if not tailStart or tailStart > #tokens then return nil end
  local tail = {}
  for i = tailStart, #tokens do tail[#tail + 1] = tokens[i] end
  return tail
end

local function endsWithTokens(tokens, suffix)
  if not suffix or #suffix > #tokens then return false end
  local offset = #tokens - #suffix
  for i = 1, #suffix do
    if tokens[offset + i] ~= suffix[i] then return false end
  end
  return true
end

local LEAK_MARKERS = {
  "you are the cleanup engine", "system instruction", "developer message",
  "return only the", "raw transcript", "transcript json data",
  "do not answer the speaker", "preserve imperative voice",
}

function M.validateAIOutput(input, output)
  input, output = trim(input), trim(output)
  if output == "" then return false, "empty" end
  if output:match('^%s*{%s*["\']transcript["\']%s*:') then
    return false, "json_wrapper"
  end
  if numeralSet(input) ~= numeralSet(output) then return false, "numerals_changed" end
  if not containsURL(input) and containsURL(output) then return false, "url_introduced" end
  local inLower, outLower = input:lower(), output:lower()
  for _, marker in ipairs(LEAK_MARKERS) do
    if outLower:find(marker, 1, true) and not inLower:find(marker, 1, true) then
      return false, "prompt_leak"
    end
  end
  local inputTokens, outputTokens = normalizedTokens(input), normalizedTokens(output)
  local hasCorrection = M.hasExplicitCorrection(input)
  local ratio = #output / math.max(1, #input)
  if ratio > 1.45 or (not hasCorrection and ratio < 0.45) then
    return false, "length_ratio"
  end
  if not hasCorrection then
    if not tokensEqual(inputTokens, outputTokens) then
      return false, "words_changed"
    end
  else
    local tail = correctionTail(inputTokens)
    if not orderedSubsequence(outputTokens, inputTokens) then
      return false, "words_introduced"
    end
    if not endsWithTokens(outputTokens, tail) then
      return false, "correction_tail_changed"
    end
  end
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
