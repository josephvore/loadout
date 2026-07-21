#!/usr/bin/env bash
# Store API keys for Hone/Murmur in the macOS Keychain.
#
# Keys are read by security(1)'s own interactive prompt — they never appear in
# this script, your shell history, process arguments, or the repo. Add at least
# one provider; OpenAI works everywhere, Groq/Cerebras make dictation cleanup
# noticeably faster. Re-run any time to update a key.
set -euo pipefail

# provider label -> keychain service name
providers=(
  "OpenAI|openai-refine"
  "Groq (optional, faster)|groq-api"
  "Cerebras (optional, fastest)|cerebras-api"
)

echo "Storing API keys in the macOS login Keychain."
echo "Press Return to skip a provider you don't use."
echo

for entry in "${providers[@]}"; do
  label="${entry%%|*}"
  service="${entry##*|}"
  printf 'Set up %s? [y/N] ' "$label"
  read -r answer
  case "$answer" in
    y|Y|yes|YES)
      # No -w: security(1) prompts for and confirms the secret itself.
      security add-generic-password -a "$USER" -s "$service" -U \
        && echo "  stored: $service"
      ;;
    *)
      echo "  skipped: $service"
      ;;
  esac
done

echo
echo "Done. Reload Hammerspoon to pick up newly added keys."
