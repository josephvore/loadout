-- Nightly self-eval: replay the day's real takes and grade the pipeline.
--
--   lua apps/murmur/tools/self_eval.lua [YYYY-MM-DD] [provider]
--
-- Reads the take archive (takes.jsonl) murmur writes on every paste, plus
-- murmur.log/hone.log for the same day, and produces:
--   * metrics — final-polish win rate, cap misses, validator rejections
--     (by reason), provider 429s, Caps+R swaps, mined corrections;
--   * an LLM-judge pass over each pasted take (capped) flagging unresolved
--     self-corrections, uncollapsed restatements, missing punctuation,
--     mangled numbers;
--   * a replay of judged-bad takes through the CURRENT polish prompt +
--     validator, to test whether today's pipeline would have done better;
--   * a markdown report in <configdir>/murmur/self_eval/YYYY-MM-DD.md and
--     auto regression fixtures in tests/polish_cases_auto.lua.
--
-- Talks to the network and spends tokens; murmur.lua schedules it nightly
-- (config.selfEval) and M.selfEval() runs it on demand. The last stdout
-- line is the summary murmur shows as a notification.

local root = arg[0]:match("^(.*)/tools/")
if not root then
  io.stderr:write("run with a path, e.g. lua apps/murmur/tools/self_eval.lua\n")
  os.exit(2)
end
package.path = root .. "/?.lua;" .. root .. "/../hone/?.lua;" .. package.path

package.loaded["litelog"] = {
  new = function()
    return setmetatable({}, { __index = function() return function() end end })
  end,
  wrap = function(_, _, fn) return fn end,
}
hs = {
  configdir = (os.getenv("HOME") or "") .. "/.hammerspoon",
  execute = function(cmd)
    local f = io.popen(cmd)
    if not f then return "" end
    local out = f:read("a") or ""
    f:close()
    return out
  end,
}

local core = require("murmur_core")
local hone = require("hone")

local MURMUR_DIR = hs.configdir .. "/murmur"
local ARCHIVE = MURMUR_DIR .. "/takes.jsonl"
local REPORT_DIR = MURMUR_DIR .. "/self_eval"
local LOG_DIR = hs.configdir .. "/logs"
local FIXTURES = root .. "/tests/polish_cases_auto.lua"
local JUDGE_CAP = tonumber(os.getenv("EVAL_TAKES") or "25")
local REPLAY_CAP = 10
local DELAY = tonumber(os.getenv("EVAL_DELAY") or "6")

-- The day being evaluated: the one that ended most recently (a 03:30 run
-- grades yesterday), unless named on the command line.
local day = arg[1]
local providerArg = arg[2]
if not day or not day:match("^%d%d%d%d%-%d%d%-%d%d$") then
  providerArg = providerArg or day
  day = os.date("%Y-%m-%d", os.time() - 6 * 3600)
end

----------------------------------------------------------------
-- Provider plumbing (same shape as tests/eval_polish.lua).
----------------------------------------------------------------
local function keychainKey(service)
  local out = hs.execute("/usr/bin/security find-generic-password -s '"
    .. service .. "' -w 2>/dev/null")
  out = out:gsub("%s+$", "")
  return out ~= "" and out or nil
end

local function resolveProvider(wanted)
  local providers = hone.config.providers
  local order = wanted and { wanted } or hone.config.autoRefineProviderOrder
  for _, name in ipairs(order) do
    local p = providers[name]
    if p then
      local key = keychainKey(p.keychainService)
      if key then
        local url, model = p.url, p.model
        if name == "openai" then
          url = "https://api.openai.com/v1/chat/completions"
          model = model or hone.config.autoRefineModel
        end
        return name, url, model, key
      end
    end
  end
  io.stderr:write("no provider API key found in the Keychain\n")
  os.exit(2)
end

local function jsonString(s)
  local escaped = s:gsub('[%c"\\]', function(c)
    if c == '"' then return '\\"' end
    if c == "\\" then return "\\\\" end
    if c == "\n" then return "\\n" end
    if c == "\r" then return "\\r" end
    if c == "\t" then return "\\t" end
    return string.format("\\u%04x", c:byte())
  end)
  return '"' .. escaped .. '"'
end

local function shellQuote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local providerName, url, model, key = resolveProvider(providerArg)

local function chat(systemPrompt, userText)
  local body = "{"
    .. '"model":' .. jsonString(model)
    .. ',"temperature":0.2'
    .. ',"messages":['
    .. '{"role":"system","content":' .. jsonString(systemPrompt) .. "},"
    .. '{"role":"user","content":' .. jsonString(userText) .. "}"
    .. "]}"
  local bodyPath = os.tmpname()
  local f = assert(io.open(bodyPath, "w"))
  f:write(body)
  f:close()
  local extract = "import json,sys\n"
    .. "raw=sys.stdin.read()\n"
    .. "try: r=json.loads(raw)\n"
    .. "except Exception: sys.stderr.write('unparseable'); sys.exit(0)\n"
    .. "try: print(r['choices'][0]['message']['content'])\n"
    .. "except Exception: sys.stderr.write(json.dumps(r)[:200])\n"
  local cmd = "curl -sS --max-time 45"
    .. " -H " .. shellQuote("Authorization: Bearer " .. key)
    .. " -H 'Content-Type: application/json'"
    .. " -d @" .. shellQuote(bodyPath) .. " " .. shellQuote(url)
    .. " | python3 -c " .. shellQuote(extract) .. " 2>&1"
  local out = ""
  for attempt = 1, 3 do
    local pipe = io.popen(cmd)
    out = pipe and (pipe:read("a") or "") or ""
    if pipe then pipe:close() end
    out = out:gsub("^%s+", ""):gsub("%s+$", "")
    local errored = out == "" or out == "unparseable"
      or out:match("^%s*{") or out:lower():match("quota")
      or out:lower():match("too_many_requests")
    if not errored then break end
    out = ""
    os.execute("sleep " .. (attempt * 15))
  end
  os.remove(bodyPath)
  os.execute("sleep " .. DELAY)
  return out
end

----------------------------------------------------------------
-- Load the archive. python3 flattens JSONL into unit/record-separated
-- fields so no Lua JSON decoder is needed.
----------------------------------------------------------------
local FIELDS = { "ts", "kind", "app", "profile", "engine", "variant",
  "aiReason", "aiProvider", "raw", "cleaned", "polished", "pasted" }

local function loadRecords()
  local py = "import json,sys\n"
    .. "fields=" .. "['" .. table.concat(FIELDS, "','") .. "']\n"
    .. "for line in sys.stdin:\n"
    .. "  line=line.strip()\n"
    .. "  if not line: continue\n"
    .. "  try: r=json.loads(line)\n"
    .. "  except Exception: continue\n"
    .. "  cols=[str(r.get(f) or '') for f in fields]\n"
    .. "  sys.stdout.write('\\x1f'.join(c.replace('\\x1f',' ').replace('\\x1e',' ') for c in cols)+'\\x1e')\n"
  local cmd = "cat " .. shellQuote(ARCHIVE) .. " 2>/dev/null | python3 -c "
    .. shellQuote(py)
  local out = hs.execute(cmd)
  local records = {}
  for chunk in out:gmatch("([^\30]+)") do
    local record, i = {}, 1
    -- gmatch drops empty trailing fields; split manually.
    local rest = chunk
    while i <= #FIELDS do
      local head, tail = rest:match("^([^\31]*)\31(.*)$")
      if head then
        record[FIELDS[i]] = head
        rest = tail
      else
        record[FIELDS[i]] = rest
        rest = ""
      end
      i = i + 1
    end
    records[#records + 1] = record
  end
  return records
end

local takes, swaps, latePolishes = {}, 0, 0
for _, r in ipairs(loadRecords()) do
  if (r.ts or ""):sub(1, 10) == day then
    if r.kind == "take" and (r.pasted or "") ~= "" then
      takes[#takes + 1] = r
    elseif r.kind == "swap" then
      swaps = swaps + 1
    elseif r.kind == "late_polish" then
      latePolishes = latePolishes + 1
      if #takes > 0 then takes[#takes].latePolished = r.polished end
    end
  end
end

----------------------------------------------------------------
-- Log-derived metrics for the same day.
----------------------------------------------------------------
local function countLog(path, pattern)
  local n = 0
  local f = io.open(path, "r")
  if not f then return 0 end
  for line in f:lines() do
    if line:sub(1, 10) == day and line:find(pattern) then n = n + 1 end
  end
  f:close()
  return n
end

local murmurLog = LOG_DIR .. "/murmur.log"
local honeLog = LOG_DIR .. "/hone.log"
local metrics = {
  takes = #takes,
  swaps = swaps,
  latePolishes = latePolishes,
  capMisses = countLog(murmurLog, "final polish missed the cap"),
  finalRejects = countLog(murmurLog, "final polish rejected"),
  classicRejects = countLog(murmurLog, "dictation polish rejected"),
  segmentRejects = countLog(murmurLog, "live polish segment rejected"),
  segmentTimeouts = countLog(murmurLog, "live polish call timed out"),
  http429 = countLog(honeLog, "HTTP 429"),
  finalPolishWon = 0,
}
for _, t in ipairs(takes) do
  if t.aiReason == "final_polish" then
    metrics.finalPolishWon = metrics.finalPolishWon + 1
  end
end

----------------------------------------------------------------
-- LLM judge over each pasted take.
----------------------------------------------------------------
local JUDGE_PROMPT = [[
You audit a dictation app. RAW is what the speech recognizer heard; PASTED
is what the app actually typed for the user. Grade PASTED as a cleaned-up
rendering of the speaker's intent. Check for: unresolved self-corrections
("no I said...", "actually..." should have been applied, not transcribed);
uncollapsed repeats/restatements; missing or wrong sentence punctuation
(questions need question marks); spoken punctuation or number words that
should have been rendered as symbols/digits (or the reverse — words about
punctuation must stay words); dropped or invented content; wrong names.
Respond with ONLY strict JSON: {"verdict":"good"|"minor"|"bad",
"issues":["short issue descriptions"]} — empty issues array when good.
]]

local judged = {}
local judgeCount = math.min(#takes, JUDGE_CAP)
for i = 1, judgeCount do
  local t = takes[i]
  local reply = chat(JUDGE_PROMPT,
    "RAW:\n" .. (t.raw ~= "" and t.raw or t.cleaned)
    .. "\n\nPASTED:\n" .. t.pasted)
  local verdict, issues = nil, {}
  local blob = reply:match("{.*}")
  if blob then
    verdict = blob:match('"verdict"%s*:%s*"(%a+)"')
    for issue in blob:gmatch('"([^"]-)"') do
      if issue ~= "verdict" and issue ~= "good" and issue ~= "minor"
        and issue ~= "bad" and issue ~= "issues" and #issue > 6 then
        issues[#issues + 1] = issue
      end
    end
  end
  judged[#judged + 1] = {
    take = t, verdict = verdict or "unjudged", issues = issues,
  }
  io.write(string.format("judged %d/%d: %s\n", i, judgeCount,
    verdict or "unjudged"))
end

----------------------------------------------------------------
-- Replay judged-bad takes through the CURRENT polish + validator.
----------------------------------------------------------------
local systemPrompt = hone.dictationSystemPrompt({ profile = "Prompt" })
local replays = 0
for _, j in ipairs(judged) do
  if replays >= REPLAY_CAP then break end
  if j.verdict == "bad" or j.verdict == "minor" then
    replays = replays + 1
    local input = j.take.cleaned ~= "" and j.take.cleaned or j.take.raw
    local out = chat(systemPrompt, input)
    if out ~= "" then
      local ok, reason = core.validateAIOutput(input, out)
      j.replay = { output = out, accepted = ok, reason = reason }
    end
  end
end

----------------------------------------------------------------
-- Auto regression fixtures: judged-bad takes become replayable cases.
----------------------------------------------------------------
local existing = {}
local okFix, current = pcall(dofile, FIXTURES)
if okFix and type(current) == "table" then existing = current end
local known = {}
for _, case in ipairs(existing) do known[case.raw or ""] = true end
local added = 0
for _, j in ipairs(judged) do
  local raw = j.take.cleaned ~= "" and j.take.cleaned or j.take.raw
  if j.verdict == "bad" and raw ~= "" and not known[raw] then
    existing[#existing + 1] = {
      name = "auto " .. day .. " #" .. tostring(#existing + 1),
      raw = raw,
      note = table.concat(j.issues, "; "),
    }
    known[raw] = true
    added = added + 1
  end
end
if added > 0 then
  local f = assert(io.open(FIXTURES, "w"))
  f:write("-- AUTO-GENERATED by tools/self_eval.lua — judged-bad real takes\n")
  f:write("-- kept as replayable regression inputs. Safe to prune by hand.\n")
  f:write("return {\n")
  for _, case in ipairs(existing) do
    f:write(string.format("  { name=%q, raw=%q, note=%q },\n",
      case.name or "", case.raw or "", case.note or ""))
  end
  f:write("}\n")
  f:close()
end

----------------------------------------------------------------
-- Mined-correction summary + report.
----------------------------------------------------------------
local minedLines = {}
local mf = io.open(MURMUR_DIR .. "/dictation_edit_mined.tsv", "r")
if mf then
  for line in mf:lines() do minedLines[#minedLines + 1] = line end
  mf:close()
end

hs.execute("mkdir -p " .. shellQuote(REPORT_DIR))
local counts = { good = 0, minor = 0, bad = 0, unjudged = 0 }
for _, j in ipairs(judged) do
  counts[j.verdict] = (counts[j.verdict] or 0) + 1
end

local report = {}
local function line(s) report[#report + 1] = s end
line("# Murmur self-eval — " .. day)
line("")
line("provider: " .. providerName .. " / " .. model)
line("")
line("## Metrics")
line("")
line(string.format("- takes pasted: %d (final polish won %d, swaps %d, late polishes %d)",
  metrics.takes, metrics.finalPolishWon, metrics.swaps, metrics.latePolishes))
line(string.format("- final polish: %d cap misses, %d validator rejections",
  metrics.capMisses, metrics.finalRejects))
line(string.format("- classic polish rejections: %d", metrics.classicRejects))
line(string.format("- live segments: %d rejections, %d timeouts",
  metrics.segmentRejects, metrics.segmentTimeouts))
line(string.format("- provider 429s: %d", metrics.http429))
line(string.format("- judge verdicts (%d takes): %d good / %d minor / %d bad / %d unjudged",
  judgeCount, counts.good, counts.minor, counts.bad, counts.unjudged))
line("")
if #minedLines > 0 then
  line("## Mined corrections (count, -1 = promoted)")
  line("")
  for _, l in ipairs(minedLines) do line("- " .. l:gsub("\t", " → ")) end
  line("")
end
line("## Takes with issues")
line("")
local flagged = 0
for _, j in ipairs(judged) do
  if j.verdict == "bad" or j.verdict == "minor" then
    flagged = flagged + 1
    line("### " .. j.verdict .. " — " .. (j.take.ts or ""))
    line("")
    line("- pasted: " .. j.take.pasted:gsub("\n", " "):sub(1, 300))
    for _, issue in ipairs(j.issues) do line("- issue: " .. issue) end
    if j.replay then
      line(string.format("- replay with current pipeline: %s%s",
        j.replay.accepted and "validator ACCEPTS" or
          ("validator REJECTS (" .. tostring(j.replay.reason) .. ")"),
        ""))
      line("- replay output: " .. j.replay.output:gsub("\n", " "):sub(1, 300))
    end
    line("")
  end
end
if flagged == 0 then line("(none)") end

local reportPath = REPORT_DIR .. "/" .. day .. ".md"
local rf = assert(io.open(reportPath, "w"))
rf:write(table.concat(report, "\n"), "\n")
rf:close()

-- Final stdout line = the notification murmur shows.
print(string.format(
  "%s: %d takes, %d good/%d minor/%d bad; %d cap misses, %d rejects, %d 429s; %d fixtures added",
  day, metrics.takes, counts.good, counts.minor, counts.bad,
  metrics.capMisses, metrics.finalRejects + metrics.classicRejects,
  metrics.http429, added))
