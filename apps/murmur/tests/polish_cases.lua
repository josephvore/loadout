-- Acceptance fixtures for the polish pass. Each case targets one specific
-- failure mode; a change that breaks any of them is a regression.
--
-- Two consumers:
--   * tests/test_murmur.lua (offline, every run) asserts the validator
--     ACCEPTS every raw -> expected transformation — the pipeline must never
--     reject the desired polish — and REJECTS every `bad` output, so the
--     hallucination/answering/numeral guards still hold.
--   * tests/eval_polish.lua (network, manual) replays `raw` through the real
--     polish prompt and provider, then checks `expected` plus the
--     mustContain / mustNotContain / oneSentence / endsWith invariants
--     against the live model output.
--
-- mustContain / mustNotContain entries are matched case-insensitively;
-- single words match on word boundaries, phrases match as substrings.
return {
  {
    name = "triple rephrasing collapses to one sentence",
    raw = "The window needs to expand. I want to see the whole thing. "
      .. "Like right now I only see the last ten words or so and I want the "
      .. "window to expand so I can see everything I've said.",
    expected = "The window needs to expand so I can see everything I've said "
      .. "— right now I only see the last ten words or so.",
    oneSentence = true,
    mustContain = { "expand", "everything" },
  },
  {
    name = "unmarked restart keeps one clause",
    raw = "We should send it we will send it Friday.",
    expected = "We will send it Friday.",
    oneSentence = true,
    mustNotContain = { "should" },
  },
  {
    name = "marked self-correction keeps only the landed value",
    raw = "Wait two, no, three seconds before you retry.",
    expected = "Wait three seconds before you retry.",
    mustContain = { "three seconds" },
    mustNotContain = { "two" },
  },
  {
    name = "spec example: correction plus fillers",
    raw = "So I think we should uh we should probably ship the the billing "
      .. "fix first, or actually no, ship the login bug first because that's "
      .. "blocking people.",
    expected = "I think we should probably ship the login bug first, because "
      .. "that's blocking people.",
    mustContain = { "login bug first", "probably" },
    mustNotContain = { "billing", "uh" },
  },
  {
    name = "dictated question stays a question",
    raw = "Should we use the bigger model for this?",
    expected = "Should we use the bigger model for this?",
    endsWith = "?",
    mustNotContain = { "yes", "sounds good" },
    bad = {
      output = "Yes, using the bigger model for this sounds good.",
      reason = "words_introduced",
      why = "an answered question must be rejected, not pasted",
    },
  },
  {
    name = "dictated imperative appears as text, not obeyed",
    raw = "Remind me to call Dave tomorrow.",
    expected = "Remind me to call Dave tomorrow.",
    mustContain = { "Remind me" },
    bad = {
      output = "I'll remind you to call Dave tomorrow.",
      reason = "words_introduced",
      why = "a response to the instruction must be rejected",
    },
  },
  {
    name = "emphatic repetition preserved",
    raw = "It was very, very expensive.",
    expected = "It was very, very expensive.",
    mustContain = { "very, very" },
  },
  {
    name = "'actually' as an adverb is not a correction cue",
    raw = "I actually enjoyed the movie.",
    expected = "I actually enjoyed the movie.",
    mustContain = { "actually", "enjoyed" },
  },
  {
    name = "hedges survive verbatim",
    raw = "I think we should probably ship it Thursday.",
    expected = "I think we should probably ship it Thursday.",
    mustContain = { "I think", "probably" },
  },
  {
    name = "numbers, dates, amounts, names byte-identical",
    raw = "The invoice is $4,250 due March 3rd, and CC Daniel.",
    expected = "The invoice is $4,250 due March 3rd, and CC Daniel.",
    mustContain = { "$4,250", "March 3rd", "Daniel" },
    bad = {
      output = "The invoice is $4,500 due March 3rd, and CC Daniel.",
      reason = "numerals_changed",
      why = "a changed amount must be rejected",
    },
  },
  {
    name = "genuinely ambiguous restart keeps both",
    raw = "Tell Mark we're ready. Tell the team we're ready.",
    expected = "Tell Mark we're ready. Tell the team we're ready.",
    mustContain = { "Mark", "team" },
  },
  {
    name = "spoken enumeration becomes a numbered list",
    raw = "we need to do three things first update the docs second tag the "
      .. "release third announce it",
    expected = "We need to do three things:\n1. Update the docs\n"
      .. "2. Tag the release\n3. Announce it",
    mustContain = { "1.", "2.", "3." },
  },
}
