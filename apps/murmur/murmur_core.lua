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

-- Apply an already-loaded replacement list (from M.loadReplacements). Split
-- out from the path-based wrapper so the live transcript view can load the
-- glossary once per take instead of re-reading files on every partial.
function M.applyLoadedReplacements(text, replacements)
  for _, r in ipairs(replacements or {}) do
    if r.from ~= "" and r.to ~= "" and r.from ~= r.to then
      text = text:gsub(phrasePattern(r.from), function() return r.to end)
    end
  end
  return text
end

local function applyReplacements(text, opts)
  return M.applyLoadedReplacements(text,
    M.loadReplacements(opts.glossaryPath, opts.correctionsPath))
end

local EXPLICIT_CORRECTION_CUES = {
  "actually no", "let me change that", "scratch that", "never mind",
  "what i mean is", "let me rephrase", "no wait", "wait no", "i meant",
  "sorry i mean",
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

-- A command phrase preceded (whitespace-only) by a determiner or possessive
-- is CONTENT, not a command: "we need a new paragraph about pricing",
-- "that bullet point is wrong" must keep their words.
local COMMAND_BLOCKERS = {
  a = true, an = true, the = true, this = true, that = true, these = true,
  those = true, another = true, each = true, every = true,
  any = true, some = true, no = true, my = true, your = true, our = true,
  their = true, its = true, his = true, her = true,
}

local function substituteCommand(text, phrase, repl)
  local pattern = "%f[%a][" .. phrase:sub(1, 1):upper() .. phrase:sub(1, 1)
    .. "]" .. phrase:sub(2) .. "%f[%A]"
  local searchFrom = 1
  while true do
    local s, e = text:find(pattern, searchFrom)
    if not s then return text end
    local prev = text:sub(1, s - 1):match("([%w']+)%s*$")
    if prev and COMMAND_BLOCKERS[prev:lower()] then
      searchFrom = e + 1
    else
      text = text:sub(1, s - 1) .. repl .. text:sub(e + 1)
      searchFrom = s + #repl
    end
  end
end

-- Layout and pairing commands only. Bare spoken-punctuation words
-- ("question mark", "comma", "period", ...) are deliberately NOT
-- substituted here: a context-blind regex once turned "a question mark
-- wasn't even added" into "a? wasn't even added", and "free trial period"
-- is one regex away from "free trial." — interpreting punctuation intent
-- is the polish LLM's job (see "Toward Interactive Dictation", arXiv
-- 2307.04008: command-vs-content is a segmentation problem, not a
-- trigger-word match).
local COMMAND_SUBSTITUTIONS = {
  { "new paragraph", "\n\n" },
  { "new line", "\n" },
  { "line break", "\n" },
  { "new bullet", "\n- " },
  { "bullet point", "\n- " },
  { "open quote", "\"" },
  { "close quote", "\"" },
  { "end quote", "\"" },
  { "open paren", "(" },
  { "close paren", ")" },
  { "open parenthesis", "(" },
  { "close parenthesis", ")" },
}

local function applyCommands(text)
  text = applyScratchThat(text)
  for _, c in ipairs(COMMAND_SUBSTITUTIONS) do
    text = substituteCommand(text, c[1], c[2])
  end
  return text
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

-- Wispr-style: every ordinary take gets the LLM cleanup pass. Only the
-- Literal profile and tiny acknowledgements ("ok", "yes please") skip it —
-- they gain nothing and latency matters most there.
function M.shouldUseAI(text, profile, opts)
  opts = opts or {}
  if profile == "Literal" then return false, "literal" end
  if wordCount(text) < (opts.minWords or 4)
      or #tostring(text or "") < (opts.minChars or 12) then
    return false, "too_short"
  end
  return true
end

function M.maxOutputTokens(text)
  return math.min(2000, math.max(64, math.ceil(wordCount(text) * 2)))
end

-- Capitalized words the recognizer already nails; learning them would only
-- burn glossary/context slots.
local PROPER_NOUN_STOPLIST = {}
for word in ([[
  i'm i'll i've i'd it's that's what's here's there's let's
  monday tuesday wednesday thursday friday saturday sunday
  january february march april june july august september october
  november december
  mr mrs ms dr jr sr st ave
  usa ceo cto cfo coo faq pdf url api asap fyi lol omg tldr aka diy eta
  google apple microsoft amazon iphone ipad mac macos ios android windows
  english spanish french german american european internet wifi bluetooth
]]):gmatch("%S+") do
  PROPER_NOUN_STOPLIST[word] = true
end

-- Candidate proper nouns worth auto-learning into the glossary: mixed-case
-- tokens anywhere ("PostgreSQL", "GitHub", "McCoy") and capitalized words
-- that are NOT at a sentence start. `known` is a set of lowercased words
-- already covered by the glossary/corrections. Returns first-seen spellings
-- in appearance order.
function M.properNounCandidates(text, known)
  known = known or {}
  local out, seen = {}, {}
  local sentenceStart = true
  for token in tostring(text or ""):gmatch("%S+") do
    local word = token:match("^%p*(.-)%p*$") or ""
    local base = word:gsub("'s$", "")
    if base ~= "" then
      local lower = base:lower()
      local wordish = base:match("^%a[%w'%.%-]*$") ~= nil
      local innerUpper = base:sub(2):match("%u") ~= nil
      local leadUpper = base:match("^%u") ~= nil
      if wordish and #base >= 3
          and not PROPER_NOUN_STOPLIST[lower] and not known[lower]
          and (innerUpper or (leadUpper and not sentenceStart))
          and not seen[lower] then
        seen[lower] = true
        out[#out + 1] = base
      end
      sentenceStart = token:match("[%.!%?][\"')%]]*$") ~= nil
    end
  end
  return out
end

-- Compare numerals by their digits only, so "7:30"/"730" and "4,250"/"4250"
-- count as the same number while a genuinely changed digit still trips.
local function digitSet(text)
  local found = {}
  for n in tostring(text):gmatch("%d[%d,%.%:]*") do
    found[n:gsub("[%,%.%:]", "")] = true
  end
  return found
end

-- Spoken-number vocabulary for the numeral guard's micro-ITN. Ordinals are
-- included because polish may render "july twenty second" as "July 22nd";
-- they only EXPAND the set of explainable digits, never shrink it.
local NUMBER_WORDS = {
  zero = 0, oh = 0, one = 1, two = 2, three = 3, four = 4, five = 5,
  six = 6, seven = 7, eight = 8, nine = 9, ten = 10, eleven = 11,
  twelve = 12, thirteen = 13, fourteen = 14, fifteen = 15, sixteen = 16,
  seventeen = 17, eighteen = 18, nineteen = 19, twenty = 20, thirty = 30,
  forty = 40, fifty = 50, sixty = 60, seventy = 70, eighty = 80, ninety = 90,
  first = 1, second = 2, third = 3, fourth = 4, fifth = 5, sixth = 6,
  seventh = 7, eighth = 8, ninth = 9, tenth = 10, eleventh = 11,
  twelfth = 12, thirteenth = 13, fourteenth = 14, fifteenth = 15,
  sixteenth = 16, seventeenth = 17, eighteenth = 18, nineteenth = 19,
  twentieth = 20, thirtieth = 30, fortieth = 40, fiftieth = 50,
  sixtieth = 60, seventieth = 70, eightieth = 80, ninetieth = 90,
}
local NUMBER_MULTIPLIERS = { hundred = 100, thousand = 1000, million = 1e6 }
local NUMBER_CONNECTORS = { ["and"] = true, point = true }

-- English parse of one contiguous run of number words as a SINGLE value:
-- "twenty five" -> 25, "two hundred five" -> 205. Returns a set of values
-- (parses can be ambiguous). Memoized per run.
local function singleNumberValues(run, i, j, memo)
  local key = i * 64 + j
  if memo[key] then return memo[key] end
  local out = {}
  memo[key] = out
  if i == j then
    local v = NUMBER_WORDS[run[i]] or NUMBER_MULTIPLIERS[run[i]]
    if v then out[v] = true end
    return out
  end
  -- tens + unit ("twenty five" -> 25)
  if j == i + 1 then
    local tens, unit = NUMBER_WORDS[run[i]], NUMBER_WORDS[run[j]]
    if tens and unit and tens >= 20 and tens % 10 == 0
      and unit >= 1 and unit <= 9 then
      out[tens + unit] = true
    end
  end
  -- [left] multiplier [right] ("two hundred five", "hundred twenty")
  for m = i, j do
    local mult = NUMBER_MULTIPLIERS[run[m]]
    if mult then
      local lefts = m == i and { [1] = true }
        or singleNumberValues(run, i, m - 1, memo)
      local rights = m == j and { [0] = true }
        or singleNumberValues(run, m + 1, j, memo)
      for l in pairs(lefts) do
        for r in pairs(rights) do
          if l >= 1 and l < mult and r < mult then
            out[l * mult + r] = true
          end
        end
      end
    end
  end
  return out
end

-- All digit strings a run of spoken number words could legitimately render
-- as: single-number parses of every sub-span, plus concatenations of
-- adjacent groups ("nineteen ninety five" -> "1995", "five five five one
-- two one two" -> "5551212", "seven thirty" -> "730").
local CANDIDATE_CAP = 400
local function runCandidates(run, into)
  local memo = {}
  local full = {} -- full[i][j] = set of digit strings for span i..j
  local n = #run
  for i = 1, n do full[i] = {} end
  local total = 0
  local function add(set, s)
    if not set[s] and total < CANDIDATE_CAP then
      set[s] = true
      total = total + 1
    end
  end
  for span = 0, n - 1 do
    for i = 1, n - span do
      local j = i + span
      local set = full[i][j]
      if not set then set = {}; full[i][j] = set end
      for v in pairs(singleNumberValues(run, i, j, memo)) do
        add(set, tostring(math.floor(v)))
      end
      for k = i, j - 1 do
        for a in pairs(full[i][k]) do
          for b in pairs(full[k + 1][j]) do
            add(set, a .. b)
          end
        end
      end
      for s in pairs(set) do into[s] = true end
    end
  end
end

local MAX_RUN_WORDS = 12
local function spokenNumberCandidates(text)
  local out = {}
  local run = {}
  local function flush()
    -- trailing connectors carry no value
    while #run > 0 and NUMBER_CONNECTORS[run[#run]] do
      table.remove(run)
    end
    if #run > 0 and #run <= MAX_RUN_WORDS then
      -- connectors join runs but are invisible to the parser
      local packed = {}
      for _, w in ipairs(run) do
        if not NUMBER_CONNECTORS[w] then packed[#packed + 1] = w end
      end
      if #packed > 0 then runCandidates(packed, out) end
    end
    run = {}
  end
  for token in tostring(text):lower():gmatch("[%a']+") do
    if NUMBER_WORDS[token] or NUMBER_MULTIPLIERS[token] then
      run[#run + 1] = token
    elseif NUMBER_CONNECTORS[token] and #run > 0 then
      run[#run + 1] = token
    else
      flush()
    end
  end
  flush()
  return out
end

-- Numeral corruption guard, ITN-aware. Literal digits must match — except a
-- digit only one side has is forgiven when the OTHER side could have spoken
-- it in words ("the number four faith" -> "4 Faith" passes; "7:30" ->
-- "8:30" still fails). Both directions are checked so the polish may write
-- spoken numbers as digits (or vice versa) but can never invent or drop one.
function M.numeralsCompatible(input, output)
  local inD, outD = digitSet(input), digitSet(output)
  local equal = true
  for d in pairs(inD) do if not outD[d] then equal = false; break end end
  if equal then
    for d in pairs(outD) do if not inD[d] then equal = false; break end end
  end
  if equal then return true end
  local inWords, outWords = nil, nil
  for d in pairs(outD) do
    if not inD[d] then
      inWords = inWords or spokenNumberCandidates(input)
      if not inWords[d] then return false end
    end
  end
  for d in pairs(inD) do
    if not outD[d] then
      outWords = outWords or spokenNumberCandidates(output)
      if not outWords[d] then return false end
    end
  end
  return true
end

M.spokenNumberCandidates = spokenNumberCandidates

-- True when `token` (a normalized output token like "4", "30" or "22nd")
-- is a digit rendering explainable by spoken numbers on the input side.
local function itnExplained(token, inputCandidates)
  local d = token:match("^(%d+)%a*$")
  return d ~= nil and inputCandidates[d] == true
end

local function isNumberWord(token)
  return NUMBER_WORDS[token] ~= nil or NUMBER_MULTIPLIERS[token] ~= nil
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

-- Longest common subsequence over token arrays (rolling-row DP). Transcripts
-- are at most a few hundred tokens, so this stays in the low milliseconds.
local function lcsLength(a, b)
  local n, m = #a, #b
  if n == 0 or m == 0 then return 0 end
  local dp = {}
  for j = 0, m do dp[j] = 0 end
  for i = 1, n do
    local prevDiag = 0
    for j = 1, m do
      local above = dp[j]
      if a[i] == b[j] then
        dp[j] = prevDiag + 1
      elseif dp[j - 1] > dp[j] then
        dp[j] = dp[j - 1]
      end
      prevDiag = above
    end
  end
  return dp[m]
end

local function correctionTail(tokens)
  local cues = {
    { "actually", "no" }, { "let", "me", "change", "that" },
    { "scratch", "that" }, { "never", "mind" },
    { "what", "i", "mean", "is" }, { "let", "me", "rephrase" },
    { "no", "wait" }, { "wait", "no" }, { "i", "meant" },
    { "sorry", "i", "mean" },
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

local LEAK_MARKERS = {
  "you are the cleanup engine", "system instruction", "developer message",
  "return only the", "raw transcript", "transcript json data",
  "do not answer the speaker", "preserve imperative voice",
}

-- Strip line-leading enumeration markers ("1. ", "2) ") that the polish pass
-- may render from a spoken "first... second... third". Only a run counting up
-- from 1 across two or more lines is treated as list formatting; any other
-- digits are real content and stay subject to the numeral guard.
local function stripListMarkers(text)
  local lines, markers = {}, {}
  for line in (tostring(text) .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
    local n = line:match("^%s*(%d+)[%.%)]%s")
    if n then markers[#markers + 1] = { index = #lines, value = tonumber(n) } end
  end
  if #markers < 2 then return text end
  for i, m in ipairs(markers) do
    if m.value ~= i then return text end
  end
  for _, m in ipairs(markers) do
    lines[m.index] = lines[m.index]:gsub("^(%s*)%d+[%.%)]%s+", "%1")
  end
  return table.concat(lines, "\n")
end

-- Multiset coverage of output tokens by input occurrences, ITN-aware.
-- Returns (coveredCount, introducedList) where introducedList holds the
-- output tokens no input occurrence could pay for (in output order, dups
-- kept — callers dedup).
local function multisetCoverage(input, inputTokens, outputTokens)
  local available = {}
  for _, t in ipairs(inputTokens) do available[t] = (available[t] or 0) + 1 end
  local covered, introduced, inputCandidates = 0, {}, nil
  for _, t in ipairs(outputTokens) do
    if (available[t] or 0) > 0 then
      available[t] = available[t] - 1
      covered = covered + 1
    elseif t:match("^%d") then
      inputCandidates = inputCandidates or spokenNumberCandidates(input)
      if itnExplained(t, inputCandidates) then covered = covered + 1
      else introduced[#introduced + 1] = t end
    else
      introduced[#introduced + 1] = t
    end
  end
  return covered, introduced
end

-- The polish pass collapses rephrasings, resolves self-corrections, and may
-- reflow clauses while merging attempts, so fidelity is checked as word
-- coverage rather than ordered overlap:
--   * nearly every output word must occur in the input (multiset containment)
--     — blocks invented content, answered questions, and paraphrase;
--   * the output must still cover most of the input's DISTINCT words — a
--     collapsed triple-rephrasing keeps its (repeated) vocabulary, while a
--     summary that drops half the content does not.
function M.validateAIOutput(input, output)
  input, output = trim(input), trim(output)
  if output == "" then return false, "empty" end
  if output:match('^%s*{%s*["\']transcript["\']%s*:') then
    return false, "json_wrapper"
  end
  local comparable = stripListMarkers(output)
  if not M.numeralsCompatible(input, comparable) then return false, "numerals_changed" end
  if not containsURL(input) and containsURL(output) then return false, "url_introduced" end
  local inLower, outLower = input:lower(), output:lower()
  for _, marker in ipairs(LEAK_MARKERS) do
    if outLower:find(marker, 1, true) and not inLower:find(marker, 1, true) then
      return false, "prompt_leak"
    end
  end
  local inputTokens, outputTokens = normalizedTokens(input), normalizedTokens(comparable)
  if #outputTokens == 0 then return false, "empty" end
  local ratio = #output / math.max(1, #input)
  if ratio > 1.45 then return false, "length_ratio" end

  -- Multiset containment: every output word must be paid for by an input
  -- occurrence. The small allowance covers glue like "gonna" -> "going to".
  -- Digit tokens the input spoke in words ("four" -> "4") count as covered:
  -- ITN is a rendering, not an invention.
  local covered = multisetCoverage(input, inputTokens, outputTokens)
  if covered < math.ceil(#outputTokens * 0.85) then
    return false, "words_introduced"
  end

  if M.hasExplicitCorrection(input) then
    -- Backtracking takes are allowed large deletions — that is the point —
    -- but the replacement wording (after the last cue) has to survive.
    if covered < math.min(#inputTokens, 2) then return false, "over_deleted" end
    local tail = correctionTail(inputTokens)
    if tail and #tail > 0 then
      local window = {}
      for i = math.max(1, #outputTokens - #tail - 5), #outputTokens do
        window[#window + 1] = outputTokens[i]
      end
      if lcsLength(tail, window) < math.ceil(#tail * 0.6) then
        return false, "correction_tail_changed"
      end
    end
  else
    -- No explicit cue: rephrasings may collapse (their words repeat, so the
    -- distinct vocabulary survives), but dropping distinct content may not.
    -- A number word survives as its digit rendering when the output carries
    -- any digits ("four" lives on inside "4 Faith").
    local seen, distinct, surviving = {}, 0, 0
    local inOutput, outHasDigit = {}, false
    for _, t in ipairs(outputTokens) do
      inOutput[t] = true
      if t:match("^%d") then outHasDigit = true end
    end
    for _, t in ipairs(inputTokens) do
      if not seen[t] then
        seen[t] = true
        distinct = distinct + 1
        if inOutput[t] or (outHasDigit and isNumberWord(t)) then
          surviving = surviving + 1
        end
      end
    end
    if surviving < math.floor(distinct * 0.55 + 0.5) then
      return false, "over_deleted"
    end
  end
  return true
end

-- The words the polish invented, per the same rules validateAIOutput uses
-- (multiset coverage, ITN digits excused, list markers stripped). Deduped,
-- output order, capped (default 8). Feeds the reject-retry prompt.
function M.introducedWords(input, output, limit)
  limit = limit or 8
  input = trim(input)
  local comparable = stripListMarkers(trim(output))
  local _, introduced = multisetCoverage(input,
    normalizedTokens(input), normalizedTokens(comparable))
  local out, seen = {}, {}
  for _, t in ipairs(introduced) do
    if not seen[t] and #out < limit then
      seen[t] = true
      out[#out + 1] = t
    end
  end
  return out
end

-- The feedback block appended to the polish system prompt for the single
-- reject-retry. Pure Lua so the template is unit-testable.
function M.retryFeedback(words)
  local list = table.concat(words or {}, ", ")
  local named = list ~= ""
    and ("It INTRODUCED words the speaker never said: " .. list .. ".")
    or "It introduced words the speaker never said."
  return "RETRY — your previous attempt was rejected by an automatic "
    .. "fidelity check. " .. named .. "\n"
    .. "Redo the polish by DELETION only: remove fillers, false starts, and "
    .. "abandoned fragments, and fix punctuation, capitalization, and "
    .. "sentence boundaries. Delete an unfinished false start entirely — "
    .. "never finish, complete, or paraphrase it. Apart from punctuation, "
    .. "capitalization, and numeral formatting, every word of your output "
    .. "must already occur in the transcript. Output only the polished text."
end

-- Committed-prefix model for the live transcript view. Each ASR hypothesis
-- replaces the whole take's text, so raw partials visibly rewrite words the
-- reader has already read. This view splits the text into a COMMITTED prefix
-- (frozen — a word commits only once it has been identical across
-- `stableCount` consecutive hypotheses) and a revisable tail. Committed text
-- never changes on screen; revisions are permitted only inside the tail.
-- commitAll() is the stall escape hatch: the caller freezes everything heard
-- so far after a quiet period, so the view can never deadlock waiting for
-- consensus that isn't coming.
function M.newLiveView(opts)
  opts = opts or {}
  local stableCount = math.max(1, opts.stableCount or 3)

  local view = {
    committed = {}, -- frozen words; grows append-only, never mutated
    hyps = {},      -- the last `stableCount` hypotheses as word arrays
    latest = {},    -- newest hypothesis words
    source = nil,   -- recognizer tag of the hypotheses being consumed
  }

  local function splitWords(text)
    local out = {}
    for w in tostring(text or ""):gmatch("%S+") do out[#out + 1] = w end
    return out
  end

  function view:reset()
    self.committed = {}
    self.hyps = {}
    self.latest = {}
  end

  -- Feed the newest full-text hypothesis. `source` tags the recognizer; when
  -- it changes mid-take (Apple partials hand off to the streaming engine,
  -- which re-reads the take from the beginning) the view resets rather than
  -- stitching two engines' texts together positionally.
  function view:update(text, source)
    if source ~= self.source then
      self.source = source
      self:reset()
    end
    local words = splitWords(text)
    self.latest = words
    self.hyps[#self.hyps + 1] = words
    if #self.hyps > stableCount then table.remove(self.hyps, 1) end
    if #self.hyps == stableCount then
      -- Longest prefix on which every buffered hypothesis agrees.
      local limit = math.huge
      for _, h in ipairs(self.hyps) do limit = math.min(limit, #h) end
      local stable = 0
      for i = 1, limit do
        local word = self.hyps[1][i]
        local agree = true
        for j = 2, #self.hyps do
          if self.hyps[j][i] ~= word then agree = false; break end
        end
        if not agree then break end
        stable = i
      end
      for i = #self.committed + 1, stable do
        self.committed[i] = words[i]
      end
    end
    return self:snapshot()
  end

  -- Freeze everything heard so far (quiet-period timeout or take end).
  function view:commitAll()
    for i = #self.committed + 1, #self.latest do
      self.committed[i] = self.latest[i]
    end
    return self:snapshot()
  end

  function view:snapshot()
    local tailWords = {}
    for i = #self.committed + 1, #self.latest do
      tailWords[#tailWords + 1] = self.latest[i]
    end
    return {
      committed = table.concat(self.committed, " "),
      tail = table.concat(tailWords, " "),
    }
  end

  return view
end

-- Segment-scale variant of validateAIOutput. The full-take thresholds are
-- quantitatively wrong on a 5-15 word fragment: one legitimate word fix
-- ("lie" -> "live") fails the 85% multiset check, and a filler-heavy short
-- segment collapsing to its content words fails the 55% survival floor. Here
-- invention is bounded by an ADDITIVE cap on introduced tokens, and survival
-- is measured over non-filler vocabulary only.
local SEGMENT_FILLERS = {
  um = true, uh = true, er = true, ah = true, like = true, basically = true,
  actually = true, so = true, well = true, okay = true, ok = true,
  yeah = true, right = true, know = true, mean = true, sort = true,
  kind = true,
}

local SEGMENT_LEAK_MARKERS = {
  "live transcript polisher", "corrected fragment", "inert context",
  "system instruction", "developer message", "raw fragment",
}

function M.validateSegmentPolish(input, output)
  input, output = trim(input), trim(output)
  if output == "" then return false, "empty" end
  if output:match("^%s*{") then return false, "json_wrapper" end
  if not M.numeralsCompatible(input, output) then
    return false, "numerals_changed"
  end
  if not containsURL(input) and containsURL(output) then
    return false, "url_introduced"
  end
  local inLower, outLower = input:lower(), output:lower()
  for _, marker in ipairs(SEGMENT_LEAK_MARKERS) do
    if outLower:find(marker, 1, true) and not inLower:find(marker, 1, true) then
      return false, "prompt_leak"
    end
  end
  local inputTokens, outputTokens = normalizedTokens(input), normalizedTokens(output)
  if #outputTokens == 0 then return false, "empty" end
  -- Punctuation weighs more on short text, so the ratio is looser than the
  -- full-take 1.45.
  if #output / math.max(1, #input) > 1.6 then return false, "length_ratio" end

  local available = {}
  for _, t in ipairs(inputTokens) do available[t] = (available[t] or 0) + 1 end
  local introduced = 0
  local inputCandidates = nil
  for _, t in ipairs(outputTokens) do
    if (available[t] or 0) > 0 then
      available[t] = available[t] - 1
    elseif t:match("^%d") then
      inputCandidates = inputCandidates or spokenNumberCandidates(input)
      if not itnExplained(t, inputCandidates) then
        introduced = introduced + 1
      end
    else
      introduced = introduced + 1
    end
  end
  if introduced > math.max(2, math.floor(#outputTokens * 0.15)) then
    return false, "words_introduced"
  end

  local inOutput = {}
  for _, t in ipairs(outputTokens) do inOutput[t] = true end
  local seen, distinct, surviving = {}, 0, 0
  for _, t in ipairs(inputTokens) do
    if not seen[t] and not SEGMENT_FILLERS[t] then
      seen[t] = true
      distinct = distinct + 1
      if inOutput[t] then surviving = surviving + 1 end
    end
  end
  if distinct >= 4 and surviving < math.ceil(distinct * 0.5) then
    return false, "over_deleted"
  end
  return true
end

-- Splice the batch final's tail onto a live-polished prefix. The live paste
-- is assembled from stream-recognizer words; the not-yet-polished remainder
-- is exactly where neither the LLM nor the batch pass has helped, so when the
-- last words of the (raw, stream-heard) prefix can be anchored inside the
-- batch final, the remainder is taken from the batch text instead — best
-- recognizer plus native punctuation, precisely where polish is missing.
-- Returns the batch remainder string ("" when the prefix consumed the whole
-- take) or nil when no confident anchor exists (caller keeps stream words).
function M.spliceBatchTail(prefixRaw, batchFinal)
  local function bareToken(w)
    local t = w:lower()
      :gsub("\226\128\153", "'")
      :gsub("[^%w']", "")
    return t
  end
  local prefixWords = {}
  for w in tostring(prefixRaw or ""):gmatch("%S+") do
    prefixWords[#prefixWords + 1] = w
  end
  if #prefixWords == 0 then return nil end
  local anchorLen = math.min(6, #prefixWords)
  local anchor = {}
  for i = #prefixWords - anchorLen + 1, #prefixWords do
    anchor[#anchor + 1] = bareToken(prefixWords[i])
  end
  local batchWords, batchNorm = {}, {}
  for w in tostring(batchFinal or ""):gmatch("%S+") do
    batchWords[#batchWords + 1] = w
    batchNorm[#batchNorm + 1] = bareToken(w)
  end
  if #batchWords == 0 then return nil end
  -- Stream and batch word counts track closely, so the anchor should sit
  -- near the prefix's own length; searching a window around it keeps a
  -- repeated phrase elsewhere in the take from stealing the match.
  local expectedEnd = math.min(#batchWords, #prefixWords)
  local from = math.max(anchorLen, expectedEnd - 15)
  local to = math.min(#batchWords, expectedEnd + 15)
  local best, bestScore, bestDist = nil, 0, math.huge
  for j = from, to do
    local window = {}
    for i = j - anchorLen + 1, j do window[#window + 1] = batchNorm[i] end
    local score = lcsLength(anchor, window)
    local dist = math.abs(j - expectedEnd)
    if score > bestScore or (score == bestScore and dist < bestDist) then
      best, bestScore, bestDist = j, score, dist
    end
  end
  local need = math.max(2, math.ceil(anchorLen * 2 / 3))
  if not best or bestScore < need then return nil end
  if best >= #batchWords then return "" end
  return table.concat(batchWords, " ", best + 1, #batchWords)
end

-- Does text ending at `prevContext` leave a sentence open? Used to warn the
-- segment polisher that its fragment continues mid-sentence. Colons and
-- dashes count as sentence-ish stops: what follows them may legitimately be
-- capitalized, so we only claim "mid-sentence" when we are sure.
function M.continuesMidSentence(prevContext)
  local prev = trim(tostring(prevContext or ""))
  if prev == "" then return false end
  local tail = prev:gsub("[\"'%)%]\226\128\157\226\128\153]+$", "")
  return not tail:match("[%.%!%?:%-\226\128\148\226\128\147]$")
    and not tail:match("\226\128\166$")
end

-- The segment LLM sees a fragment without the words before it, so a fragment
-- that continues a sentence tends to come back restarted: first word
-- capitalized, sometimes with an invented colon ("...transcriptions and |
-- edits this is" -> "Edits: this is"). Deterministic repair when the
-- preceding text does not end a sentence: strip punctuation prepended before
-- the first word, and when the first word survived the polish unchanged,
-- restore its original case and drop a colon/semicolon grafted onto it.
function M.harmonizeSegmentStart(prevContext, rawSegment, output)
  output = tostring(output or "")
  if not M.continuesMidSentence(prevContext) then return output end
  local function bare(w)
    return (tostring(w or ""):lower()
      :gsub("\226\128\153", "'")
      :gsub("[^%w']", ""))
  end
  local out = output:gsub("^%s*[:;%-\226\128\148\226\128\147]+%s*", "")
  local rawFirst = tostring(rawSegment or ""):match("%S+")
  local outFirst = out:match("%S+")
  if rawFirst and outFirst and bare(rawFirst) == bare(outFirst)
    and rawFirst:match("^%l") and outFirst:match("^%u") then
    out = out:gsub("^(%s*)(%S)", function(sp, ch) return sp .. ch:lower() end, 1)
    if not rawFirst:match("[:;]$") then
      out = out:gsub("^(%s*[%w']+)[:;]", "%1", 1)
    end
  end
  return out
end

-- Live-polish segment pipeline. Sits on top of newLiveView: consumes only its
-- COMMITTED text (already stable, append-only within a source epoch), divides
-- it into sentence-ish segments, and hands out at most one polish batch at a
-- time — always the OLDEST contiguous unpolished run, so results assemble in
-- order. Pure Lua with an injected clock (`now` in seconds on every method)
-- so the whole state machine is unit-testable.
--
-- Segment states: closed -> pending -> polished | closed(retry) | raw_final.
-- "polished" and "raw_final" are terminal; polished text is never re-polished
-- (calls always carry RAW text; a polished neighbor travels only as inert
-- prompt context).
function M.newLivePolisher(opts)
  opts = opts or {}
  local minSegmentWords = opts.minSegmentWords or 3
  local maxSegmentWords = opts.maxSegmentWords or 40
  local lookaheadWords = opts.lookaheadWords or 2
  local settleSeconds = opts.settleSeconds or 1.5
  local windowMaxWords = opts.windowMaxWords or 100
  local maxAttempts = opts.maxAttempts or 2
  local maxCalls = opts.maxCalls or 40
  local maxConsecutiveFailures = opts.maxConsecutiveFailures or 3

  local ABBREV = {
    ["etc."] = true, ["e.g."] = true, ["i.e."] = true, ["vs."] = true,
    ["dr."] = true, ["mr."] = true, ["mrs."] = true, ["ms."] = true,
    ["st."] = true, ["inc."] = true, ["dept."] = true, ["approx."] = true,
  }

  -- Sentence boundary AFTER this word? Closing quotes/brackets may follow the
  -- terminator; abbreviations, single-letter initials, and bare numerals
  -- ("42.") don't count.
  local function endsSentence(word)
    local w = word:gsub("[\"'%)%]]+$", "")
    if not w:match("[%.%!%?]$") then return false end
    local lower = w:lower()
    if ABBREV[lower] then return false end
    if lower:match("^%a%.$") then return false end
    if lower:match("^[%d%,%.%:]+$") then return false end
    return true
  end

  local p = {
    epoch = 1,
    consumedWords = 0,
    open = {},          -- committed words not yet in a segment
    segments = {},      -- ordered; ids strictly increase
    nextSegId = 1,
    nextCallSeq = 0,
    inflight = nil,     -- { callId, segIds, sentAt }
    cooldownUntil = 0,
    callsMade = 0,
    consecutiveFailures = 0,
    flushRequested = false,
    done = false,
    halted = false,
  }

  local function closeSegment(words, now)
    if #words == 0 then return end
    local seg = {
      id = p.nextSegId,
      raw = table.concat(words, " "),
      state = "closed",
      closedAt = now,
      attempts = 0,
    }
    p.nextSegId = p.nextSegId + 1
    p.segments[#p.segments + 1] = seg
  end

  -- Ingest the latest committed text (full-take, append-only) and close any
  -- segments whose boundary has settled (speaker moved >= lookaheadWords
  -- past it). A head shorter than minSegmentWords rides forward to the next
  -- boundary. Without terminal punctuation (the stream model may emit none),
  -- maxSegmentWords force-splits at the last clause comma when possible.
  function p:feed(committedText, now)
    local words = {}
    for w in tostring(committedText or ""):gmatch("%S+") do
      words[#words + 1] = w
    end
    if #words < self.consumedWords then return false end -- caller missed a reset
    for i = self.consumedWords + 1, #words do
      self.open[#self.open + 1] = words[i]
    end
    self.consumedWords = #words
    local changed = false
    while true do
      local boundary = nil
      for i = 1, #self.open - lookaheadWords do
        if i >= minSegmentWords and endsSentence(self.open[i]) then
          boundary = i
          break
        end
      end
      if not boundary and #self.open >= maxSegmentWords then
        boundary = maxSegmentWords
        for i = maxSegmentWords, math.max(1, maxSegmentWords - 15), -1 do
          if self.open[i]:match("[,;:]$") then boundary = i; break end
        end
      end
      if not boundary then break end
      local segWords, rest = {}, {}
      for i = 1, boundary do segWords[i] = self.open[i] end
      for i = boundary + 1, #self.open do rest[#rest + 1] = self.open[i] end
      self.open = rest
      closeSegment(segWords, now)
      changed = true
    end
    return changed
  end

  -- Pause boundary: a quiet period closes the open run (if it is a real
  -- sentence-ish chunk) and requests an immediate dispatch, so text polishes
  -- DURING silences instead of after them.
  function p:onQuiet(now)
    if #self.open >= minSegmentWords then
      closeSegment(self.open, now)
      self.open = {}
      self.flushRequested = true
      return true
    end
    return false
  end

  -- The next polish batch, or nil. Single call in flight; strictly the oldest
  -- contiguous run of closed segments (in-order polish keeps prev-context
  -- honest and assembly coherent), word-capped so a post-outage backlog
  -- becomes one catch-up call.
  function p:nextDispatch(now)
    if self.done or self.halted or self.inflight then return nil end
    if now < self.cooldownUntil then return nil end
    if self.callsMade >= maxCalls then return nil end
    local run, runWords, prevText = {}, 0, nil
    for _, seg in ipairs(self.segments) do
      if seg.state == "closed" then
        local w = wordCount(seg.raw)
        if #run > 0 and runWords + w > windowMaxWords then break end
        run[#run + 1] = seg
        runWords = runWords + w
      elseif #run == 0 then
        prevText = seg.text or seg.raw
      else
        break
      end
    end
    if #run == 0 then return nil end
    local eligible = #run >= 2 or self.flushRequested
      or (now - run[1].closedAt) >= settleSeconds
    if not eligible then return nil end
    self.flushRequested = false
    self.nextCallSeq = self.nextCallSeq + 1
    local callId = "e" .. self.epoch .. "c" .. self.nextCallSeq
    local texts, ids = {}, {}
    for _, seg in ipairs(run) do
      seg.state = "pending"
      seg.attempts = seg.attempts + 1
      texts[#texts + 1] = seg.raw
      ids[#ids + 1] = seg.id
    end
    self.callsMade = self.callsMade + 1
    self.inflight = { callId = callId, segIds = ids, sentAt = now }
    local prevContext = prevText
    if prevContext and #prevContext > 200 then
      prevContext = prevContext:sub(-200)
    end
    return {
      callId = callId,
      text = table.concat(texts, " "),
      segIds = ids,
      prevContext = prevContext,
    }
  end

  -- Apply a validated polish result. Stale callIds (epoch bump, timeout
  -- already failed it, post-seal) are no-ops. The batch's pending segments
  -- collapse into one polished segment (first id survives); returns
  -- true, removedIds so the renderer can drop their spans.
  function p:applyResult(callId, polishedText)
    if not self.inflight or self.inflight.callId ~= callId then return false end
    local ids = {}
    for _, id in ipairs(self.inflight.segIds) do ids[id] = true end
    self.inflight = nil
    self.consecutiveFailures = 0
    local first, removed, kept = nil, {}, {}
    for _, seg in ipairs(self.segments) do
      if ids[seg.id] then
        if not first then
          first = seg
          kept[#kept + 1] = seg
        else
          first.raw = first.raw .. " " .. seg.raw
          removed[#removed + 1] = seg.id
        end
      else
        kept[#kept + 1] = seg
      end
    end
    if not first then return false end
    first.state = "polished"
    first.text = polishedText
    self.segments = kept
    return true, removed
  end

  -- A call failed (HTTP error, timeout, validation reject). Members retry by
  -- riding the next window until maxAttempts, then freeze as raw_final.
  -- Repeated failures halt dispatch for the take — the display just stays raw.
  function p:failResult(callId)
    if not self.inflight or self.inflight.callId ~= callId then return false end
    local ids = {}
    for _, id in ipairs(self.inflight.segIds) do ids[id] = true end
    self.inflight = nil
    self.consecutiveFailures = self.consecutiveFailures + 1
    if self.consecutiveFailures >= maxConsecutiveFailures then
      self.halted = true
    end
    for _, seg in ipairs(self.segments) do
      if ids[seg.id] then
        seg.state = (seg.attempts >= maxAttempts) and "raw_final" or "closed"
      end
    end
    return true
  end

  function p:setCooldown(untilTime)
    self.cooldownUntil = math.max(self.cooldownUntil, untilTime or 0)
  end

  -- Engine handoff or cancel: discard everything including the in-flight
  -- call (late results die on the callId check). callsMade survives — the
  -- budget is per take, not per epoch.
  function p:reset()
    self.epoch = self.epoch + 1
    self.consumedWords = 0
    self.open = {}
    self.segments = {}
    self.inflight = nil
    self.flushRequested = false
    self.done = false
    self.halted = false
    self.consecutiveFailures = 0
  end

  -- Take ended: close the open run regardless of size and request a flush
  -- dispatch. The caller seals once pasting is done.
  function p:finishTake(now)
    if #self.open > 0 then
      closeSegment(self.open, now)
      self.open = {}
    end
    self.flushRequested = true
  end

  -- No further dispatches or results; anything still in flight is dropped.
  function p:seal()
    self.done = true
    self.inflight = nil
  end

  function p:snapshot()
    local items = {}
    for _, seg in ipairs(self.segments) do
      items[#items + 1] = {
        id = seg.id,
        text = seg.text or seg.raw,
        raw = seg.raw,
        state = seg.state,
      }
    end
    return { items = items, openText = table.concat(self.open, " ") }
  end

  function p:counts()
    local c = { closed = 0, pending = 0, polished = 0, raw_final = 0 }
    for _, seg in ipairs(self.segments) do c[seg.state] = c[seg.state] + 1 end
    c.calls = self.callsMade
    c.halted = self.halted
    return c
  end

  return p
end

-- Join a polisher snapshot back into one display/paste string.
function M.assembleLive(snapshot)
  local parts = {}
  for _, item in ipairs(snapshot.items) do
    if item.text and item.text ~= "" then parts[#parts + 1] = item.text end
  end
  if snapshot.openText and snapshot.openText ~= "" then
    parts[#parts + 1] = snapshot.openText
  end
  return table.concat(parts, " ")
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

-- First-wins controller for the at-stop final-polish race. hs http calls
-- cannot be cancelled, so losing lanes are dropped by this latch instead.
-- The driver reports events; the returned action is what to do:
--   "deliver"  — paste this result now (winner, pre-cap)
--   "late"     — winner arrived post-cap: late-polish path (store/auto-apply)
--   "retry"    — launch the single feedback retry lane (then call launched())
--   "fallback" — paste the assembled screen text now
--   "drop"     — ignore (loser, duplicate, or fallback already pasted)
-- Invariant (unit-tested): across any event sequence, "fallback" is
-- returned at most once, and exactly once when no lane ever validates.
function M.newFinalPolishRace(opts)
  opts = opts or {}
  local race = {
    lanes = 0,        -- lanes still in flight
    settled = false,  -- a validated polish has been accepted (paste OR late)
    capFired = false, -- the cap timer has run
    retryUsed = false,
    retryEnabled = opts.retryEnabled ~= false,
  }
  function race:launched() self.lanes = self.lanes + 1 end
  local function laneExhausted(self)
    self.lanes = self.lanes - 1
    if self.settled or self.lanes > 0 then return "drop" end
    if self.capFired then return "drop" end -- fallback already on screen
    return "fallback"                       -- all lanes dead pre-cap: don't wait
  end
  function race:accepted()   -- a lane's result passed validateAIOutput
    if self.settled then return "drop" end -- first-wins latch
    self.settled = true
    return self.capFired and "late" or "deliver"
  end
  function race:rejected(reason)
    if self.settled then return "drop" end
    if reason == "words_introduced" and self.retryEnabled
        and not self.retryUsed then
      self.retryUsed = true
      self.lanes = self.lanes - 1 -- this lane dies; driver launches the retry
      return "retry"
    end
    return laneExhausted(self)
  end
  function race:failed() -- HTTP failure after hone's own provider chain
    if self.settled then return "drop" end
    return laneExhausted(self)
  end
  function race:onCap()
    if self.capFired then return "drop" end -- duplicate cap event
    self.capFired = true
    if self.settled then return "drop" end
    if self.lanes <= 0 then return "drop" end -- exhaustion already pasted it
    return "fallback"
  end
  return race
end

----------------------------------------------------------------
-- EDIT MINING — the Wispr-style learning loop's diff engine.
--
-- After a paste, murmur re-reads the target text field a little later and
-- hands (pastedText, fieldValueAtPaste, fieldValueLater) to mineEdits. Word
-- replacements the user made INSIDE the pasted region are correction
-- candidates ("rental king" -> "Rentalking"); murmur counts them and
-- promotes repeat offenders into dictation_corrections.tsv, exactly like
-- glossary auto-learn. Pure functions here so the diff is testable offline.
----------------------------------------------------------------

-- Words too common to learn as a correction target on their own.
local COMMON_EDIT_WORDS = {}
for w in ([[the a an and or but if then else of to in on at by for with from
as is are was were be been being am do does did done have has had having
will would can could should may might must shall not never always it its
it's this that these those there here he she they them his her their our
your my me you i we us who whom which what when where why how all any some
none more most much many few little other another such only just also too
very so than because while about into over under again further once out up
down off above below between through during before after yes no ok okay
get got make made go went going come came take took new old good bad well
way thing things something anything nothing everything really actually
basically literally kind sort maybe perhaps please thanks thank]])
  :gmatch("%S+") do COMMON_EDIT_WORDS[w] = true end

local MAX_MINE_TOKENS = 400

local function splitTokens(text)
  local out = {}
  for w in tostring(text or ""):gmatch("%S+") do out[#out + 1] = w end
  return out
end

-- Word-level diff hunks between token arrays via LCS backtrack.
local function wordDiffHunks(a, b)
  local n, m = #a, #b
  local dp = {}
  for i = 0, n do dp[i] = {}; dp[i][0] = 0 end
  for j = 0, m do dp[0][j] = 0 end
  for i = 1, n do
    for j = 1, m do
      if a[i] == b[j] then
        dp[i][j] = dp[i - 1][j - 1] + 1
      else
        dp[i][j] = math.max(dp[i - 1][j], dp[i][j - 1])
      end
    end
  end
  local hunks = {}
  local i, j = n, m
  local del, ins = {}, {}
  local function flushHunk()
    if #del > 0 or #ins > 0 then
      -- backtrack collects in reverse
      local d, s = {}, {}
      for k = #del, 1, -1 do d[#d + 1] = del[k] end
      for k = #ins, 1, -1 do s[#s + 1] = ins[k] end
      table.insert(hunks, 1, { del = d, ins = s })
      del, ins = {}, {}
    end
  end
  while i > 0 or j > 0 do
    if i > 0 and j > 0 and a[i] == b[j] then
      flushHunk()
      i, j = i - 1, j - 1
    elseif j > 0 and (i == 0 or dp[i][j - 1] >= dp[i - 1][j]) then
      ins[#ins + 1] = b[j]
      j = j - 1
    else
      del[#del + 1] = a[i]
      i = i - 1
    end
  end
  flushHunk()
  return hunks
end

local function stripPunct(word)
  return (tostring(word or ""):gsub("^[%p]+", ""):gsub("[%p]+$", ""))
end

-- Returns a list of {from=..., to=...} correction candidates, or {}.
function M.mineEdits(pasted, before, after)
  pasted = tostring(pasted or "")
  before, after = tostring(before or ""), tostring(after or "")
  if pasted == "" or before == after then return {} end
  local p = before:find(pasted, 1, true)
  if not p then return {} end
  -- The pasted region maps into `after` only if the text around it is
  -- untouched; edits outside our paste mean we can't attribute anything.
  local prefix = before:sub(1, p - 1)
  local suffix = before:sub(p + #pasted)
  if after:sub(1, #prefix) ~= prefix then return {} end
  if #suffix > 0 and after:sub(-#suffix) ~= suffix then return {} end
  local afterPasted = after:sub(#prefix + 1, #after - #suffix)
  if afterPasted == pasted then return {} end
  -- A gutted or replaced paste is a rewrite, not a correction pass.
  if #afterPasted < #pasted * 0.5 then return {} end

  local a, b = splitTokens(pasted), splitTokens(afterPasted)
  if #a > MAX_MINE_TOKENS or #b > MAX_MINE_TOKENS then return {} end
  local edits = {}
  for _, hunk in ipairs(wordDiffHunks(a, b)) do
    if #hunk.del >= 1 and #hunk.del <= 3
      and #hunk.ins >= 1 and #hunk.ins <= 3 then
      local from = table.concat(hunk.del, " ")
      local to = table.concat(hunk.ins, " ")
      -- Compare word cores so pure punctuation shuffles don't count, but
      -- keep the punctuated forms out of what we learn.
      local fromCore, toCore = stripPunct(from), stripPunct(to)
      if fromCore ~= "" and toCore ~= "" and fromCore ~= toCore
        and toCore:match("%a")
        and not to:find("\n", 1, true)
        and not (#hunk.ins == 1 and COMMON_EDIT_WORDS[toCore:lower()]) then
        edits[#edits + 1] = { from = fromCore, to = toCore }
      end
    end
  end
  return edits
end

M.trim = trim
M.wordCount = wordCount

return M
