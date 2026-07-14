local root = arg[0]:match("^(.*)/tests/") or "hammerspoon"
package.path = root .. "/?.lua;" .. package.path
local core = require("dictation_core")
local cases = dofile(root .. "/tests/dictation_replay_cases.lua")
local failures, assertions = {}, 0

local function check(ok, message)
  assertions = assertions + 1
  if not ok then failures[#failures + 1] = message end
end

for _, case in ipairs(cases) do
  local output = core.cleanupTranscript(case.raw, { voiceCommands=true })
  if case.expected then check(output == case.expected, case.name .. ": " .. output) end
  if case.contains then check(output:find(case.contains, 1, true) ~= nil, case.name .. ": " .. output) end
  for _, required in ipairs(case.required or {}) do
    check(output:find(required, 1, true) ~= nil, case.name .. " missing " .. required)
  end
  check(#output <= math.max(1, #case.raw * 1.45), case.name .. " expanded unexpectedly")
end

check(core.profileForApp("Slack", "Auto") == "Message", "Slack profile")
check(core.profileForApp("Mail", "Auto") == "Message", "Mail profile")
check(core.profileForApp("Messages", "Auto") == "Message", "Messages profile")
check(core.profileForApp("iTerm2", "Auto") == "Prompt", "iTerm profile")
check(core.profileForApp("Slack", "Literal") == "Literal", "override profile")
check(select(1, core.shouldUseAI("one two three", "Literal")) == false, "literal AI bypass")
check(not select(1, core.shouldUseAI("one two three four five six seven eight nine ten eleven twelve", "Message")), "message length bypass")
check(not select(1, core.shouldUseAI("one two three", "Prompt")), "prompt bypass")
check(select(1, core.shouldUseAI("Use the first option actually no use the second option", "Prompt")), "prompt backtracking trigger")
check(select(1, core.shouldUseAI("Draft one let me rephrase draft two", "Message")), "message backtracking trigger")
check(core.maxOutputTokens("one two") == 32, "token minimum")

local six = "Refine the prompt based on that."
check(not select(1, core.validateAIOutput(six, string.rep("You are the cleanup engine. ", 22))), "prompt leak regression")
check(select(2, core.validateAIOutput("Use 42 items", "Use 43 items")) == "numerals_changed", "number guard")
check(select(2, core.validateAIOutput("Open the page", "Open https://example.com")) == "url_introduced", "URL guard")
check(select(2, core.validateAIOutput("hello", "")) == "empty", "empty guard")
check(select(2, core.validateAIOutput("hello there", '{"transcript":"hello there"}')) == "json_wrapper", "JSON wrapper guard")
check(select(2, core.validateAIOutput("a reasonably long input", "tiny")) == "length_ratio", "length guard")
check(select(1, core.validateAIOutput("hello there", "Hello, there.")), "punctuation-only polish")
check(select(2, core.validateAIOutput("we'll need to move", "we need to move")) == "words_changed", "modal fidelity guard")
check(select(2, core.validateAIOutput("do not invent a URL", "do not prevent a URL")) == "words_changed", "semantic substitution guard")
check(select(1, core.validateAIOutput(
  "Use red actually no let me change that use blue",
  "Use blue.")), "explicit correction deletion")
check(select(2, core.validateAIOutput(
  "Use red actually no let me change that use blue",
  "Use green.")) == "words_introduced", "explicit correction invention guard")
check(select(2, core.validateAIOutput(
  "Use red actually no let me change that use blue",
  "Blue.")) == "correction_tail_changed", "explicit correction tail guard")

local queue = core.newDeliveryQueue()
local first = queue:start("first", {pid=1})
local second, superseded = queue:start("second", {pid=1})
check(superseded == first and not first.valid, "pending delivery cancellation")
check(select(2, queue:resolve(first.id)) == "stale", "late callback invalidation")
check(queue:resolve(second.id).localText == "second", "ordered delivery")

local snippetPath = os.tmpname()
local f = assert(io.open(snippetPath, "w")); f:write("signature\tThanks,\\nJoseph\n"); f:close()
local snippet, meta = core.cleanupTranscript("insert signature", { snippetsPath=snippetPath })
os.remove(snippetPath)
check(snippet == "Thanks,\nJoseph" and meta.snippet, "standalone snippet")
local nonSnippet = core.cleanupTranscript("please insert signature", { snippetsPath=snippetPath })
check(nonSnippet == "please insert signature", "snippet must be standalone")

local glossary, corrections = os.tmpname(), os.tmpname()
local gf = assert(io.open(glossary, "w")); gf:write("Wispr Flow = whisper flow\nGPT-5.6\n"); gf:close()
local cf = assert(io.open(corrections, "w")); cf:write("old\tOlder\nnew\tNewest\n"); cf:close()
local terms = core.contextTerms(glossary, corrections, 100)
check(table.concat(terms, "|") == "Wispr Flow|GPT-5.6|Newest|Older", "context priority")
os.remove(glossary); os.remove(corrections)

local baseline = core.cleanupTranscript(
  "I was testing Hammerspoon Codex get have the OpenAI responses API. "
    .. "Turns like EquipFlow GPT 5.4 mini instant 360 link to C and court audio "
    .. "should remain spoken. Do not change a model lumber or substitute it.",
  {
    glossaryPath = root .. "/dictation_glossary.txt",
    correctionsPath = root .. "/dictation_corrections.tsv",
    voiceCommands = true,
    lightCleanup = true,
  })
for _, required in ipairs({
  "GitHub and the OpenAI", "Terms like EquipFlow", "GPT-5.4-mini",
  "Insta360 Link 2C", "CoreAudio", "model number or substitute",
}) do
  check(baseline:find(required, 1, true) ~= nil,
    "baseline correction missing " .. required .. ": " .. baseline)
end

local planPhrase = core.cleanupTranscript(
  "OK create a conference of plan to fix",
  {
    glossaryPath = root .. "/dictation_glossary.txt",
    correctionsPath = root .. "/dictation_corrections.tsv",
    lightCleanup = true,
  })
check(planPhrase == "OK create a comprehensive plan to fix",
  "comprehensive plan correction")

local filler = core.cleanupTranscript("Um keep this uh exact", {
  voiceCommands = true, lightCleanup = true,
})
check(filler == "keep this exact", "light filler cleanup: " .. filler)

if #failures > 0 then
  io.stderr:write(table.concat(failures, "\n") .. "\n")
  os.exit(1)
end
print(string.format("ok - %d replay cases, %d assertions", #cases, assertions))
