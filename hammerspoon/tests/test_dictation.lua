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
check(select(1, core.shouldUseAI("one two three four five", "Literal")) == false, "literal AI bypass")
check(select(1, core.shouldUseAI("one two three four five six seven eight nine ten eleven twelve", "Message")), "ordinary message take polished")
check(select(1, core.shouldUseAI("Use the first option or the second option", "Prompt")), "ordinary prompt take polished")
check(not select(1, core.shouldUseAI("one two three", "Prompt")), "tiny take bypass")
check(select(2, core.shouldUseAI("ok thanks", "Prompt")) == "too_short", "acknowledgement bypass")
check(select(1, core.shouldUseAI("yes please do it now", "Prompt", { minWords = 5, minChars = 12 })), "min gates configurable")
check(core.maxOutputTokens("one two") == 64, "token minimum")

local nouns = core.properNounCandidates(
  "Tell Daniel the EquipFlow demo moved. Ask Marcus on Tuesday about the API.",
  { equipflow = true })
check(table.concat(nouns, "|") == "Daniel|Marcus",
  "proper noun candidates: " .. table.concat(nouns, "|"))
local camel = core.properNounCandidates(
  "GitHub's new integration with Amplifyd works. Amplifyd ships Monday.", {})
check(table.concat(camel, "|") == "GitHub|Amplifyd",
  "camel-case and possessive nouns: " .. table.concat(camel, "|"))
check(#core.properNounCandidates("The meeting is at nine tomorrow. Fine by me.", {}) == 0,
  "no proper nouns in plain text")

local six = "Refine the prompt based on that."
check(not select(1, core.validateAIOutput(six, string.rep("You are the cleanup engine. ", 22))), "prompt leak regression")
check(select(2, core.validateAIOutput("Use 42 items", "Use 43 items")) == "numerals_changed", "number guard")
check(select(2, core.validateAIOutput("Open the page", "Open https://example.com")) == "url_introduced", "URL guard")
check(select(2, core.validateAIOutput("hello", "")) == "empty", "empty guard")
check(select(2, core.validateAIOutput("hello there", '{"transcript":"hello there"}')) == "json_wrapper", "JSON wrapper guard")
check(select(2, core.validateAIOutput("a reasonably long input", "tiny")) == "words_introduced", "rewrite guard")
check(select(1, core.validateAIOutput("hello there", "Hello, there.")), "punctuation-only polish")
check(select(2, core.validateAIOutput("we'll need to move", "we need to move")) == "words_introduced", "modal fidelity guard")
check(select(2, core.validateAIOutput("do not invent a URL", "do not prevent a URL")) == "words_introduced", "semantic substitution guard")
check(select(1, core.validateAIOutput(
  "Use red actually no let me change that use blue",
  "Use blue.")), "explicit correction deletion")
check(select(2, core.validateAIOutput(
  "Use red actually no let me change that use blue",
  "Use green.")) == "words_introduced", "explicit correction invention guard")
check(select(2, core.validateAIOutput(
  "Use red actually no let me change that use blue",
  "Blue.")) == "over_deleted", "explicit correction over-deletion guard")

-- Wispr-style cleanup: deletions and punctuation pass, rewrites don't.
check(select(1, core.validateAIOutput(
  "Okay, um, I want to, uh, basically fix the thing",
  "Okay, I want to fix the thing.")), "filler deletion accepted")
check(select(1, core.validateAIOutput(
  "I'm using it right now so you can see. The output. But it's still not great.",
  "I'm using it right now so you can see the output, but it's still not great.")),
  "pause-fragment join accepted")
check(select(2, core.validateAIOutput(
  "Should we create a new issue for the demo flag",
  "Yes, creating a new issue for the demo flag sounds good")) == "words_introduced",
  "answering guard")
check(select(2, core.validateAIOutput(
  "The deploy failed because the token expired and the retry loop never fired",
  "The deploy failed")) == "over_deleted", "over-deletion guard")
check(select(1, core.validateAIOutput(
  "delivery windows between 730 and nine tomorrow morning so plan the trucks accordingly please",
  "Delivery windows between 7:30 and nine tomorrow morning, so plan the trucks accordingly, please.")),
  "digit-formatting tolerated")
check(select(1, core.validateAIOutput(
  "send it Tuesday no wait Wednesday works better",
  "Send it Wednesday works better.")), "no-wait backtrack accepted")
check(core.hasExplicitCorrection("use the red one what I mean is the blue one"),
  "mixed-case cue detected")

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

local remainingBaseline = core.cleanupTranscript(
  "without adding a necessary punctuation. Terms like GPD 5.4 mini, "
    .. "Insta 360 link to C, and CoreAudio",
  {
    glossaryPath = root .. "/dictation_glossary.txt",
    correctionsPath = root .. "/dictation_corrections.tsv",
    lightCleanup = true,
  })
check(remainingBaseline ==
  "without adding unnecessary punctuation. Terms like GPT-5.4-mini, "
    .. "Insta360 Link 2C, and CoreAudio",
  "remaining recorded variants: " .. remainingBaseline)

local filler = core.cleanupTranscript("Um keep this uh exact", {
  voiceCommands = true, lightCleanup = true,
})
check(filler == "keep this exact", "light filler cleanup: " .. filler)

if #failures > 0 then
  io.stderr:write(table.concat(failures, "\n") .. "\n")
  os.exit(1)
end
print(string.format("ok - %d replay cases, %d assertions", #cases, assertions))
