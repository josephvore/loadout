-- Live polish-prompt regression harness. Replays tests/polish_cases.lua
-- through the REAL polish system prompt and provider, then checks each
-- fixture's invariants (and the validator) against the model output.
--
-- This talks to the network and spends tokens, so it is manual — the offline
-- validator checks in test_murmur.lua run on every test invocation instead.
--
--   lua apps/murmur/tests/eval_polish.lua            # first provider with a key
--   lua apps/murmur/tests/eval_polish.lua groq       # force a provider
--
-- Requires: curl, python3 (JSON decode), and a provider API key in the
-- Keychain (see apps/hone/setup-keys.sh). Exit code 1 if any invariant
-- fails; exact-match differences from `expected` are reported but are NOT
-- failures (models word things differently take to take — the invariants
-- are the contract).

local root = arg[0]:match("^(.*)/tests/")
if not root then
  io.stderr:write("run with a path, e.g. lua apps/murmur/tests/eval_polish.lua\n")
  os.exit(2)
end
package.path = root .. "/?.lua;" .. root .. "/../hone/?.lua;" .. package.path

-- hone.lua is a Hammerspoon module; give it just enough scaffolding to load
-- outside Hammerspoon. Only its config + prompt builder are used here.
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
local cases = dofile(root .. "/tests/polish_cases.lua")

local function keychainKey(service)
  local out = hs.execute("/usr/bin/security find-generic-password -s '"
    .. service .. "' -w 2>/dev/null")
  out = out:gsub("%s+$", "")
  return out ~= "" and out or nil
end

-- The eval always speaks Chat Completions (every provider supports it), so
-- OpenAI's Responses-API entry gets its chat-completions URL and the
-- fallback model hone uses for dictation.
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
        return name, url, model, key, p.reasoningEffort
      elseif wanted then
        io.stderr:write("no Keychain key for provider '" .. name .. "'\n")
        os.exit(2)
      end
    end
  end
  io.stderr:write("no provider API key found in the Keychain\n")
  os.exit(2)
end

-- Minimal JSON string encoder — enough for the request body we build.
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

local function callPolish(url, model, key, reasoningEffort, systemPrompt, transcript)
  local body = "{"
    .. '"model":' .. jsonString(model)
    .. ',"temperature":0.2'
    .. (reasoningEffort and (',"reasoning_effort":' .. jsonString(reasoningEffort)) or "")
    .. ',"messages":['
    .. '{"role":"system","content":' .. jsonString(systemPrompt) .. "},"
    .. '{"role":"user","content":' .. jsonString(transcript) .. "}"
    .. "]}"
  local bodyPath = os.tmpname()
  local f = assert(io.open(bodyPath, "w"))
  f:write(body)
  f:close()
  local extract = "import json,sys\n"
    .. "raw=sys.stdin.read()\n"
    .. "try: r=json.loads(raw)\n"
    .. "except Exception: sys.stderr.write('unparseable: '+raw[:300]); sys.exit(0)\n"
    .. "try: print(r['choices'][0]['message']['content'])\n"
    .. "except Exception: sys.stderr.write(json.dumps(r)[:300])\n"
  local cmd = "curl -sS --max-time 45"
    .. " -H " .. shellQuote("Authorization: Bearer " .. key)
    .. " -H 'Content-Type: application/json'"
    .. " -d @" .. shellQuote(bodyPath) .. " " .. shellQuote(url)
    .. " | python3 -c " .. shellQuote(extract) .. " 2>&1"
  -- Free-tier providers enforce per-minute request AND token quotas, and the
  -- polish system prompt alone is ~1.1k tokens — so pace generously and back
  -- off hard on a quota error. A full run takes a few minutes by design.
  local out = ""
  for attempt = 1, 4 do
    local pipe = io.popen(cmd)
    out = pipe and (pipe:read("a") or "") or ""
    if pipe then pipe:close() end
    out = out:gsub("^%s+", ""):gsub("%s+$", "")
    -- The extractor emits the raw JSON when there is no message content, so
    -- anything JSON-shaped here is a provider error, not a transcript.
    local errored = out == "" or out:match("^unparseable:")
      or out:match("^%s*{") or out:lower():match("quota")
    if not errored then break end
    io.write(string.format("      (attempt %d failed: %s)\n",
      attempt, out:sub(1, 160)))
    out = ""
    os.execute("sleep " .. (attempt * 20))
  end
  os.remove(bodyPath)
  os.execute("sleep " .. (os.getenv("EVAL_DELAY") or "10"))
  return out
end

-- Case-insensitive containment: single words match on word boundaries so
-- "no" can't match inside "noon"; phrases match as plain substrings.
local function containsTerm(text, term)
  local lowerText, lowerTerm = text:lower(), term:lower()
  if lowerTerm:match("%s") or lowerTerm:match("%p") then
    return lowerText:find(lowerTerm, 1, true) ~= nil
  end
  return lowerText:find("%f[%w]" .. lowerTerm .. "%f[%W]") ~= nil
end

local function sentenceCount(text)
  local n = 0
  for _ in text:gmatch("[%.%!%?]+") do n = n + 1 end
  return math.max(n, 1)
end

local providerName, url, model, key, reasoningEffort = resolveProvider(arg[1])
local systemPrompt = hone.dictationSystemPrompt({})
print(string.format("provider=%s model=%s fixtures=%d", providerName, model, #cases))

local failures, exactMisses = 0, 0
for _, case in ipairs(cases) do
  local got = callPolish(url, model, key, reasoningEffort, systemPrompt, case.raw)
  local problems = {}
  if got == "" then problems[#problems + 1] = "empty/errored response" end
  for _, term in ipairs(case.mustContain or {}) do
    if not containsTerm(got, term) then
      problems[#problems + 1] = "missing: " .. term
    end
  end
  for _, term in ipairs(case.mustNotContain or {}) do
    if containsTerm(got, term) then
      problems[#problems + 1] = "must not contain: " .. term
    end
  end
  if case.oneSentence and sentenceCount(got) > 1 then
    problems[#problems + 1] = "expected one sentence"
  end
  if case.endsWith and got:sub(-#case.endsWith) ~= case.endsWith then
    problems[#problems + 1] = "should end with: " .. case.endsWith
  end
  local valid, reason = core.validateAIOutput(case.raw, got)
  if not valid then
    problems[#problems + 1] = "validator would reject: " .. tostring(reason)
  end

  if #problems > 0 then
    failures = failures + 1
    print("FAIL  " .. case.name)
    for _, p in ipairs(problems) do print("      - " .. p) end
    print("      raw:      " .. case.raw)
    print("      got:      " .. got)
    print("      expected: " .. case.expected)
  elseif got ~= case.expected then
    exactMisses = exactMisses + 1
    print("pass~ " .. case.name .. " (invariants hold, wording differs)")
    print("      got:      " .. got)
    print("      expected: " .. case.expected)
  else
    print("pass  " .. case.name)
  end
end

print(string.format("done: %d fixtures, %d failed, %d wording-diff",
  #cases, failures, exactMisses))
os.exit(failures > 0 and 1 or 0)
