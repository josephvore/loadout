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
check(select(1, core.shouldUseAI("one two three four five six seven eight nine ten eleven twelve", "Message")), "message threshold")
check(not select(1, core.shouldUseAI("one two three", "Prompt")), "prompt short bypass")
check(select(1, core.shouldUseAI("Um actually no use the second option", "Prompt")), "prompt backtracking trigger")
check(core.maxOutputTokens("one two") == 32, "token minimum")

local six = "Refine the prompt based on that."
check(not select(1, core.validateAIOutput(six, string.rep("You are the cleanup engine. ", 22))), "prompt leak regression")
check(select(2, core.validateAIOutput("Use 42 items", "Use 43 items")) == "numerals_changed", "number guard")
check(select(2, core.validateAIOutput("Open the page", "Open https://example.com")) == "url_introduced", "URL guard")
check(select(2, core.validateAIOutput("hello", "")) == "empty", "empty guard")
check(select(2, core.validateAIOutput("a reasonably long input", "tiny")) == "length_ratio", "length guard")

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

if #failures > 0 then
  io.stderr:write(table.concat(failures, "\n") .. "\n")
  os.exit(1)
end
print(string.format("ok - %d replay cases, %d assertions", #cases, assertions))
