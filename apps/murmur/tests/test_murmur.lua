local root = arg[0]:match("^(.*)/tests/") or "hammerspoon"
package.path = root .. "/?.lua;" .. package.path
local core = require("murmur_core")
local cases = dofile(root .. "/tests/replay_cases.lua")
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
  "Tell Daniel the Postgres demo moved. Ask Marcus on Tuesday about the API.",
  { postgres = true })
check(table.concat(nouns, "|") == "Daniel|Marcus",
  "proper noun candidates: " .. table.concat(nouns, "|"))
local camel = core.properNounCandidates(
  "GitHub's new integration with Nimbus works. Nimbus ships Monday.", {})
check(table.concat(camel, "|") == "GitHub|Nimbus",
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

-- Polish acceptance fixtures: the validator must ACCEPT every desired
-- raw -> expected transformation (collapses, merges, numbered lists) and
-- REJECT every `bad` output (answering, invention, changed numbers).
-- tests/eval_polish.lua replays the same fixtures against the live model.
local polishCases = dofile(root .. "/tests/polish_cases.lua")
for _, case in ipairs(polishCases) do
  local ok, reason = core.validateAIOutput(case.raw, case.expected)
  check(ok, "polish fixture rejected (" .. tostring(reason) .. "): " .. case.name)
  if case.bad then
    local badOk, badReason = core.validateAIOutput(case.raw, case.bad.output)
    check(not badOk and badReason == case.bad.reason,
      "polish fixture bad output not caught (" .. tostring(badReason) .. "): "
        .. case.name)
  end
end

-- List-marker stripping is scoped tightly: a single numbered line, or a run
-- that doesn't count up from 1, is real digit content and trips the guard.
check(select(2, core.validateAIOutput("check the logs", "3. Check the logs"))
  == "numerals_changed", "lone list marker still guarded")
check(select(2, core.validateAIOutput("first alpha second beta",
  "2. Alpha\n3. Beta")) == "numerals_changed", "non-ascending markers guarded")
check(core.maxOutputTokens(string.rep("word ", 1200)) == 2000, "token cap")

-- ITN-aware numeral guard: rendering spoken numbers as digits is a polish
-- feature, not corruption ("the number four faith" -> "4 Faith" was being
-- vetoed while the stream's mishears pasted). Real digit changes still fail.
local numCands = core.spokenNumberCandidates
check(numCands("the number four faith")["4"], "single number word")
check(numCands("twenty five dollars")["25"], "tens plus unit")
check(numCands("seven thirty")["730"], "spoken time concatenation")
check(numCands("nineteen ninety five")["1995"], "spoken year concatenation")
check(numCands("two hundred five items")["205"], "hundreds parse")
check(numCands("three point five")["35"], "decimal via point connector")
check(numCands("five five five one two one two")["555"]
  and numCands("five five five one two one two")["1212"], "phone digit runs")
check(select(1, core.validateAIOutput(
  "change for faith to the number four faith so it reads correctly",
  'Change "for faith" to "4 Faith" so it reads correctly.')),
  "ITN word-to-digit accepted")
check(select(1, core.validateAIOutput(
  "the meeting moved to seven thirty tomorrow",
  "The meeting moved to 7:30 tomorrow.")), "ITN spoken time accepted")
check(select(1, core.validateAIOutput(
  "call me back in nineteen ninety five seriously",
  "Call me back in 1995, seriously.")), "ITN spoken year accepted")
check(select(2, core.validateAIOutput(
  "the price is four dollars for everyone here",
  "The price is 5 dollars for everyone here.")) == "numerals_changed",
  "invented digit still caught")
check(select(2, core.validateAIOutput("Use 42 items today okay",
  "Use 43 items today, okay?")) == "numerals_changed",
  "digit corruption still caught")
check(select(1, core.validateSegmentPolish(
  "and it costs twenty five dollars", "and it costs $25")),
  "segment ITN accepted")
check(select(2, core.validateSegmentPolish(
  "and it costs twenty five dollars", "and it costs $26")) == "numerals_changed",
  "segment digit invention caught")

-- Edit mining: word replacements inside the pasted region become correction
-- candidates; edits elsewhere, rewrites, and common-word swaps do not.
local mined = core.mineEdits(
  "and cc Adam at rental king LLC today",
  "PREFIX and cc Adam at rental king LLC today SUFFIX",
  "PREFIX and cc Adam at Rentalking LLC today SUFFIX")
check(#mined == 1 and mined[1].from == "rental king"
  and mined[1].to == "Rentalking",
  "edit mining learns phrase replacement: " .. (mined[1] and (mined[1].from .. ">" .. mined[1].to) or "none"))
mined = core.mineEdits("talk to daniel about the rollout",
  "talk to daniel about the rollout",
  "talk to Daniel about the rollout")
check(#mined == 1 and mined[1].to == "Daniel", "edit mining learns case fix")
check(#core.mineEdits("hello world", "A hello world B", "A hello world B") == 0,
  "no edits, no mining")
check(#core.mineEdits("send it to the team",
  "send it to the team", "send it to that team") == 0,
  "common-word swap not learned")
check(#core.mineEdits("hello world today",
  "X hello world today Y", "X2 hello world today Y") == 0,
  "edits outside the pasted region ignored")
check(#core.mineEdits("alpha beta gamma delta epsilon zeta",
  "alpha beta gamma delta epsilon zeta", "alpha") == 0,
  "gutted paste treated as rewrite, not corrections")
check(#core.mineEdits("ship it now.", "ship it now.", "ship it now!") == 0,
  "punctuation-only change not learned")

-- Live view: words commit only after agreeing across N consecutive
-- hypotheses; committed text never changes; revisions stay in the tail.
local view = core.newLiveView({ stableCount = 3 })
local snap = view:update("hello", "stream")
check(snap.committed == "" and snap.tail == "hello", "live view starts uncommitted")
view:update("hello there", "stream")
snap = view:update("hello there how", "stream")
check(snap.committed == "hello", "stable prefix commits: " .. snap.committed)
check(snap.tail == "there how", "tail beyond committed: " .. snap.tail)
snap = view:update("hello their how are", "stream")
check(snap.committed == "hello", "revised word does not commit")
snap = view:update("hello their how are you", "stream")
snap = view:update("hello their how are you", "stream")
check(snap.committed == "hello their how are" or snap.committed == "hello their how",
  "revision inside the tail commits once stable: " .. snap.committed)
snap = view:update("goodbye", "stream")
check(snap.committed:find("hello", 1, true) == 1, "committed never shrinks")
snap = view:commitAll()
check(snap.tail == "", "commitAll leaves no tail")
local switched = core.newLiveView({ stableCount = 3 })
switched:update("apple text one", nil)
switched:update("apple text one", nil)
switched:update("apple text one", nil)
snap = switched:update("stream text", "stream")
check(snap.committed == "" and snap.tail == "stream text",
  "engine handoff resets the view")

-- Cached replacements: the live view applies the loaded glossary without
-- re-reading files per partial.
local liveGlossary = os.tmpname()
local lg = assert(io.open(liveGlossary, "w"))
lg:write("Postgres = post gres\n")
lg:close()
local loaded = core.loadReplacements(liveGlossary, nil)
check(core.applyLoadedReplacements("use post gres now", loaded)
  == "use Postgres now", "cached replacement application")
os.remove(liveGlossary)

local queue = core.newDeliveryQueue()
local first = queue:start("first", {pid=1})
local second, superseded = queue:start("second", {pid=1})
check(superseded == first and not first.valid, "pending delivery cancellation")
check(select(2, queue:resolve(first.id)) == "stale", "late callback invalidation")
check(queue:resolve(second.id).localText == "second", "ordered delivery")

local snippetPath = os.tmpname()
local f = assert(io.open(snippetPath, "w")); f:write("signature\tThanks,\\nAlex\n"); f:close()
local snippet, meta = core.cleanupTranscript("insert signature", { snippetsPath=snippetPath })
os.remove(snippetPath)
check(snippet == "Thanks,\nAlex" and meta.snippet, "standalone snippet")
local nonSnippet = core.cleanupTranscript("please insert signature", { snippetsPath=snippetPath })
check(nonSnippet == "please insert signature", "snippet must be standalone")

local glossary, corrections = os.tmpname(), os.tmpname()
local gf = assert(io.open(glossary, "w")); gf:write("Wispr Flow = whisper flow\nGPT-5.6\n"); gf:close()
local cf = assert(io.open(corrections, "w")); cf:write("old\tOlder\nnew\tNewest\n"); cf:close()
local terms = core.contextTerms(glossary, corrections, 100)
check(table.concat(terms, "|") == "Wispr Flow|GPT-5.6|Newest|Older", "context priority")
os.remove(glossary); os.remove(corrections)

local baseline = core.cleanupTranscript("Use hammer spoon with post gres and git hub", {
  glossaryPath = root .. "/data/dictation_glossary.txt",
  correctionsPath = root .. "/data/dictation_corrections.tsv",
  lightCleanup = true,
})
check(baseline == "Use Hammerspoon with Postgres and GitHub",
  "example data corrections: " .. baseline)

local filler = core.cleanupTranscript("Um keep this uh exact", {
  voiceCommands = true, lightCleanup = true,
})
check(filler == "keep this exact", "light filler cleanup: " .. filler)

-- Segment-scale validator: additive introduced-token cap and non-filler
-- survival, so a one-word homophone fix on a short fragment passes while
-- invention and answering still fail.
check(select(1, core.validateSegmentPolish(
  "the lie transcription is working",
  "The live transcription is working.")), "segment one-word fix accepted")
check(select(2, core.validateSegmentPolish(
  "check the deploy status now",
  "verify the rollout condition currently")) == "words_introduced",
  "segment paraphrase rejected")
check(select(1, core.validateSegmentPolish(
  "um yeah okay so basically the deploy failed",
  "The deploy failed.")), "segment filler collapse accepted")
check(not select(1, core.validateSegmentPolish(
  "is the beta flag enabled",
  "Yes, the beta flag is enabled in the current build.")),
  "segment answering rejected")
check(select(2, core.validateSegmentPolish(
  "the invoice is 4250 due in March",
  "The invoice is 4260, due in March.")) == "numerals_changed",
  "segment numeral guard")
check(select(2, core.validateSegmentPolish(
  "the deploy failed because the token expired and the retry never fired",
  "The deploy failed.")) == "over_deleted", "segment over-deletion rejected")
check(select(1, core.validateSegmentPolish(
  "and then we should probably look at the",
  "and then we should probably look at the")),
  "segment mid-sentence passthrough accepted")
check(select(2, core.validateSegmentPolish("anything here", "")) == "empty",
  "segment empty guard")

-- Batch tail splice: anchor the polished prefix's raw stream words inside the
-- batch final; the remainder comes from the batch text.
local spliced = core.spliceBatchTail(
  "so we need to update the docs and tag the release",
  "So we need to update the docs and tag the release. And then announce it to the team.")
check(spliced == "And then announce it to the team.",
  "splice basic: " .. tostring(spliced))
local splicedDiverged = core.spliceBatchTail(
  "and the lie transcription keeps failing on my machine",
  "and the live transcription keeps failing on my machine, so check the logs")
check(splicedDiverged == "so check the logs",
  "splice tolerates stream/batch divergence: " .. tostring(splicedDiverged))
check(core.spliceBatchTail(
  "completely different words spoken here",
  "nothing in common at all with that text") == nil, "splice no-anchor returns nil")
check(core.spliceBatchTail(
  "update the docs and tag the release",
  "Update the docs and tag the release.") == "",
  "splice full consumption returns empty remainder")

-- Mid-sentence continuation detection + segment-start harmonization: a
-- fragment continuing a sentence must not come back restarted ("...and |
-- edits this is" -> "Edits: this is").
check(core.continuesMidSentence("") == false, "empty context starts a take")
check(core.continuesMidSentence("It works fine.") == false,
  "sentence-final context")
check(core.continuesMidSentence('He said "stop."') == false,
  "sentence end inside closing quote")
check(core.continuesMidSentence("faster in the live changes and") == true,
  "dangling conjunction is mid-sentence")
check(core.continuesMidSentence("we need the following:") == false,
  "colon may legitimately capitalize what follows")
local harmonized = core.harmonizeSegmentStart(
  "It needs to be much faster in the live changes and transcriptions and",
  "edits this is just plain not acceptable",
  "Edits: this is just plain not acceptable")
check(harmonized == "edits this is just plain not acceptable",
  "harmonize lowercases restarted first word and drops grafted colon: "
    .. tostring(harmonized))
check(core.harmonizeSegmentStart(
  "it's not doing a great job of",
  "going back and revising sentences",
  "Going back and revising sentences") == "going back and revising sentences",
  "harmonize undoes lone capitalization")
check(core.harmonizeSegmentStart(
  "The take starts here.",
  "and then we continue",
  "And then we continue") == "And then we continue",
  "harmonize leaves new sentences alone")
check(core.harmonizeSegmentStart(
  "so I asked",
  "sarah to review it",
  "Sarah to review it") == "sarah to review it",
  "harmonize prefers lowercase continuation (glossary restores known names)")
check(core.harmonizeSegmentStart(
  "and the",
  "lie transcription keeps failing",
  "Live transcription keeps failing") == "Live transcription keeps failing",
  "harmonize leaves a rewritten first word alone")
check(core.harmonizeSegmentStart(
  "the metrics keep",
  "climbing so we should check",
  "— climbing, so we should check") == "climbing, so we should check",
  "harmonize strips punctuation prepended before the first word")

-- Live polisher state machine (injected clock; all times in seconds).
local lp = core.newLivePolisher({ settleSeconds = 1.5 })
lp:feed("We should update the docs.", 0)
check(#lp.segments == 0, "boundary needs lookahead words")
lp:feed("We should update the docs. And then", 1)
check(#lp.segments == 1 and lp.segments[1].raw == "We should update the docs.",
  "segment closes once speaker moves on")
check(lp:nextDispatch(1.2) == nil, "single fresh segment not yet dispatchable")
local d1 = lp:nextDispatch(3)
check(d1 ~= nil and d1.text == "We should update the docs.",
  "settled segment dispatches")
check(d1.prevContext == nil, "first dispatch has no prev context")
check(lp:nextDispatch(3.1) == nil, "single flight enforced")
local okApply, removed1 = lp:applyResult(d1.callId, "We should update the docs.")
check(okApply and #removed1 == 0, "apply single segment")
check(lp.segments[1].state == "polished", "segment polished")

lp:feed("We should update the docs. And then tag the release. And announce it. Also more words here", 4)
check(#lp.segments == 3, "two more segments closed: " .. #lp.segments)
local d2 = lp:nextDispatch(4.1)
check(d2 ~= nil and #d2.segIds == 2, "run of two dispatches immediately")
check(d2.text == "And then tag the release. And announce it.",
  "dispatch text joins the run: " .. tostring(d2 and d2.text))
check(d2.prevContext == "We should update the docs.", "prev context is polished text")
local okApply2, removed2 = lp:applyResult(d2.callId, "Then tag the release and announce it.")
check(okApply2 and #removed2 == 1, "run collapses to one segment")
check(#lp.segments == 2, "collapsed segment count")
check(core.assembleLive(lp:snapshot()) ==
  "We should update the docs. Then tag the release and announce it. Also more words here",
  "assemble joins polished + open: " .. core.assembleLive(lp:snapshot()))

-- Failure path: retry once, then raw_final; stale results are no-ops.
local lpf = core.newLivePolisher({ settleSeconds = 0.5, maxAttempts = 2 })
lpf:feed("First sentence here now. Second sentence words also here. trailing words extra", 0)
local df1 = lpf:nextDispatch(1)
check(df1 ~= nil, "failure-path dispatch")
check(lpf:applyResult("bogus", "x") == false, "stale callId is a no-op")
lpf:failResult(df1.callId)
check(lpf.segments[1].state == "closed", "first failure reverts to closed")
local df2 = lpf:nextDispatch(2)
check(df2 ~= nil, "retry dispatches")
lpf:failResult(df2.callId)
check(lpf.segments[1].state == "raw_final" and lpf.segments[2].state == "raw_final",
  "second failure freezes raw_final")
check(lpf:applyResult(df2.callId, "late") == false, "post-failure result dropped")

-- Cooldown, quiet-close, finish flush, seal, reset epochs.
local lpc = core.newLivePolisher({ settleSeconds = 1.5 })
lpc:feed("Some words without punctuation arriving now", 0)
check(lpc:onQuiet(1) == true, "quiet closes the open run")
local dc1 = lpc:nextDispatch(1.05)
check(dc1 ~= nil, "quiet-closed segment dispatches immediately (flush)")
lpc:failResult(dc1.callId)
lpc:setCooldown(30)
check(lpc:nextDispatch(2) == nil, "cooldown blocks dispatch")
check(lpc:nextDispatch(31) ~= nil, "cooldown expiry dispatches")
local lps = core.newLivePolisher({})
lps:feed("Only a few words", 0)
lps:finishTake(1)
check(#lps.segments == 1, "finishTake closes short open run")
local ds = lps:nextDispatch(1.01)
check(ds ~= nil, "finish flush dispatches without settle delay")
lps:seal()
check(lps:applyResult(ds.callId, "polished") == false, "post-seal result dropped")
check(lps:nextDispatch(2) == nil, "sealed polisher stops dispatching")
local lpr = core.newLivePolisher({})
lpr:feed("Sentence one is here. More words follow now", 0)
local dr = lpr:nextDispatch(5)
check(dr ~= nil, "pre-reset dispatch")
lpr:reset()
check(lpr:applyResult(dr.callId, "x") == false, "reset invalidates in-flight call")
check(#lpr.segments == 0 and lpr.consumedWords == 0, "reset clears state")
lpr:feed("Fresh epoch text arrives here. And continues on", 10)
check(#lpr.segments == 1, "post-reset feed works")

-- Abbreviations and numerals don't split sentences.
local lpa = core.newLivePolisher({})
lpa:feed("Ask Dr. Smith about the 3.5 release e.g. the beta and more trailing words", 0)
check(#lpa.segments == 0, "abbreviation/decimal words don't close segments")

-- Halt after repeated failures.
local lph = core.newLivePolisher({ settleSeconds = 0, maxAttempts = 10, maxConsecutiveFailures = 3 })
lph:feed("One sentence here now. Two sentence here now. Three sentence here now. tail words", 0)
for i = 1, 3 do
  local dh = lph:nextDispatch(i)
  check(dh ~= nil, "halt-path dispatch " .. i)
  lph:failResult(dh.callId)
end
check(lph.halted and lph:nextDispatch(10) == nil, "polisher halts after consecutive failures")

-- introducedWords: the words a polish invented, per validateAIOutput's rules.
local evidenceIn = "so that it only runs or so that so that you come up with a plan"
local evidenceOut = "so that it only runs the items we've agreed on"
local intro = core.introducedWords(evidenceIn, evidenceOut)
local introSet = {}
for _, w in ipairs(intro) do introSet[w] = true end
check(introSet["agreed"], "introducedWords evidence: agreed")
check(introSet["items"], "introducedWords evidence: items")
check(introSet["we've"], "introducedWords evidence: we've")
check(#core.introducedWords("the number four faith", "4 Faith") == 0,
  "introducedWords ITN excused")
check(#core.introducedWords("hello there", "Hello, there.") == 0,
  "introducedWords punctuation-only polish")
local dup = core.introducedWords("say the thing", "say banana banana banana")
check(#dup == 1 and dup[1] == "banana", "introducedWords dedups repeats")
check(#core.introducedWords("say the thing", "alpha beta gamma delta", 2) == 2,
  "introducedWords respects limit")
check(#core.introducedWords("first alpha second beta", "1. Alpha\n2. Beta") == 0,
  "introducedWords strips list markers")

-- retryFeedback: the reject-retry prompt block.
local fb = core.retryFeedback({ "agreed", "we've" })
check(fb:find("agreed", 1, true) and fb:find("we've", 1, true),
  "retryFeedback names introduced words")
check(fb:find("DELETION", 1, true) ~= nil, "retryFeedback demands deletion-only")
local fbEmpty = core.retryFeedback({})
check(fbEmpty:find("introduced words the speaker never said", 1, true) ~= nil,
  "retryFeedback empty list generic sentence")

-- validateAIOutput regression fixture from live-take evidence: the polish
-- completed an abandoned clause; validator must reject words_introduced.
check(select(2, core.validateAIOutput(evidenceIn, evidenceOut)) == "words_introduced",
  "evidence take rejected words_introduced")

-- newFinalPolishRace: first-wins / retry / cap state machine.
local function newRace(opts, lanes)
  local r = core.newFinalPolishRace(opts)
  for _ = 1, (lanes or 2) do r:launched() end
  return r
end

-- 1. Two lanes; accept pre-cap delivers; the loser is dropped either way.
local r1 = newRace()
check(r1:accepted() == "deliver", "race1 first accept delivers")
check(r1:accepted() == "drop", "race1 second accept drops")
check(r1:rejected("words_introduced") == "drop", "race1 post-settle reject drops")

-- 2. Cap fires first; late winner stores; second late result drops.
local r2 = newRace()
check(r2:onCap() == "fallback", "race2 cap falls back")
check(r2:accepted() == "late", "race2 post-cap accept is late")
check(r2:accepted() == "drop", "race2 second late accept drops")

-- 3. Both lanes fail pre-cap: exactly one fallback, immediately.
local r3 = newRace()
check(r3:failed() == "drop", "race3 first failure drops")
check(r3:failed() == "fallback", "race3 exhaustion falls back")

-- 4. Both lanes fail post-cap: fallback already pasted, stay silent.
local r4 = newRace()
check(r4:onCap() == "fallback", "race4 cap falls back")
check(r4:failed() == "drop", "race4 post-cap failure drops")
check(r4:failed() == "drop", "race4 second post-cap failure drops")

-- 5. words_introduced triggers the retry; retry accept delivers; loser drops.
local r5 = newRace()
check(r5:rejected("words_introduced") == "retry", "race5 reject retries")
r5:launched()
check(r5:accepted() == "deliver", "race5 retry accept delivers")
check(r5:accepted() == "drop", "race5 late loser accept drops")

-- 6. Only one retry ever; a rejected retry exhausts to fallback.
local r6 = newRace()
check(r6:rejected("words_introduced") == "retry", "race6 first reject retries")
r6:launched()
check(r6:rejected("words_introduced") == "drop", "race6 second reject no retry")
check(r6:rejected("words_introduced") == "fallback", "race6 rejected retry falls back")

-- 7. Retry keeps the lane count balanced against the other lane's failure.
local r7 = newRace()
check(r7:rejected("words_introduced") == "retry", "race7 reject retries")
r7:launched()
check(r7:failed() == "drop", "race7 other lane fails while retry in flight")
check(r7:failed() == "fallback", "race7 retry failure falls back")

-- 8. Non-words_introduced rejects never retry.
local r8 = newRace(nil, 1)
check(r8:rejected("over_deleted") == "fallback", "race8 over_deleted no retry")

-- 9. Cap after a settled race drops.
local r9 = newRace()
check(r9:accepted() == "deliver", "race9 accept delivers")
check(r9:onCap() == "drop", "race9 cap after settle drops")

-- 10. Single-lane mode: today's behavior.
local r10a = newRace(nil, 1)
check(r10a:accepted() == "deliver", "race10 single lane accept delivers")
local r10b = newRace(nil, 1)
check(r10b:failed() == "fallback", "race10 single lane failure falls back")

-- 11. retryEnabled=false: words_introduced goes straight to exhaustion.
local r11 = newRace({ retryEnabled = false }, 1)
check(r11:rejected("words_introduced") == "fallback", "race11 retry disabled")

-- 12. Exhaustion already pasted the fallback; the cap must not re-paste.
local r12 = newRace()
check(r12:failed() == "drop", "race12 first failure drops")
check(r12:failed() == "fallback", "race12 exhaustion falls back")
check(r12:onCap() == "drop", "race12 cap after exhaustion drops")

-- 13. Duplicate cap drops; retry launched pre-cap can still land late.
local r13a = newRace()
check(r13a:onCap() == "fallback", "race13 first cap falls back")
check(r13a:onCap() == "drop", "race13 duplicate cap drops")
local r13b = newRace()
check(r13b:rejected("words_introduced") == "retry", "race13b reject retries")
r13b:launched()
check(r13b:onCap() == "fallback", "race13b cap with retry in flight falls back")
check(r13b:accepted() == "late", "race13b post-cap retry accept is late")

if #failures > 0 then
  io.stderr:write(table.concat(failures, "\n") .. "\n")
  os.exit(1)
end
print(string.format("ok - %d replay cases, %d assertions", #cases, assertions))
