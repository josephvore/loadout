#!/usr/bin/env bash
# Refuse personal data in the public repo: generated or local-only files,
# home-directory paths, real email addresses, API keys, and oversized files.
#
#   lib/check-leaks.sh            check every tracked file (test.sh, CI)
#   lib/check-leaks.sh --staged   check what is about to be committed (hook)
#   lib/check-leaks.sh FILE...    check specific files on disk
#
# A line that must keep a match can carry the marker "leak-check: allow".
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MAX_BYTES=500000

# Files that only ever hold generated output, user data, or local settings.
BLOCKED_NAMES='(^|/)(polish_cases_auto\.lua|takes\.jsonl|dictation_glossary\.local\.txt|correction_memory[^/]*\.(json|txt)|loadout\.local\.lua|[^/]*\.local\.(lua|conf|json|sh)|\.env(\..*)?|id_(rsa|ed25519)[^/]*|[^/]*\.(pem|p12|key|mlmodelc|mlpackage|wav|m4a|caf|sqlite|db))$'
BLOCKED_DIRS='(^|/)(captures|queue|state|__pycache__|\.build)/'
# Per-user settings files (schemas are fine).
BLOCKED_SETTINGS='^settings/[^/]+\.json$'

HOME_PATH='/(Users|home)/[A-Za-z0-9._-]+'
HOME_PATH_OK='/(Users|home)/(you|me|name|username|USER|runner|example)([/"'"'"' ]|$)'
EMAIL='[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}'
EMAIL_OK='@(example\.(com|org|net)|[A-Za-z0-9.-]+\.(example|test|invalid))\b|noreply@anthropic\.com|@users\.noreply\.github\.com'
SECRET='(sk-(proj-)?[A-Za-z0-9_-]{20,}|gsk_[A-Za-z0-9]{20,}|csk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}|-----BEGIN [A-Z ]*PRIVATE KEY-----)'

mode=tracked
files=()
case "${1:-}" in
  --staged) mode=staged ;;
  -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
  "") ;;
  *) mode=paths; files=("$@") ;;
esac

if [ "$mode" = tracked ]; then
  while IFS= read -r f; do files+=("$f"); done < <(git ls-files)
elif [ "$mode" = staged ]; then
  while IFS= read -r f; do files+=("$f"); done \
    < <(git diff --cached --name-only --diff-filter=ACMR)
fi

problems=0
report() {
  echo "leak-check: $1" >&2
  problems=$((problems + 1))
}

content() {
  if [ "$mode" = staged ]; then git show ":$1"; else cat -- "$1"; fi
}

for ((i = 0; i < ${#files[@]}; i++)); do
  f="${files[$i]}"
  [ "$f" = lib/check-leaks.sh ] && continue
  if [[ "$f" =~ $BLOCKED_NAMES || "$f" =~ $BLOCKED_DIRS ]] \
      || { [[ "$f" =~ $BLOCKED_SETTINGS ]] && [[ "$f" != *.schema.json ]]; }; then
    report "$f: generated or local-only file; keep it out of the repo"
    continue
  fi
  if [ "$mode" != staged ] && [ ! -f "$f" ]; then continue; fi
  bytes="$(content "$f" | wc -c | tr -d ' ')"
  if [ "$bytes" -gt "$MAX_BYTES" ]; then
    report "$f: $bytes bytes; large files are usually generated data"
    continue
  fi
  # Skip binary files for the text checks.
  if ! content "$f" | LC_ALL=C grep -Iq . 2>/dev/null; then continue; fi
  while IFS= read -r hit; do
    report "$f:$hit"
  done < <(
    content "$f" | LC_ALL=C grep -nE "$SECRET" | grep -v 'leak-check: allow' \
      | sed 's/^\([0-9]*\):.*/\1: looks like an API key or private key/' || true
    # shellcheck disable=SC2016  # literal $HOME in the advice text
    content "$f" | LC_ALL=C grep -nE "$HOME_PATH" | grep -vE "$HOME_PATH_OK" \
      | grep -v 'leak-check: allow' \
      | sed 's/^\([0-9]*\):.*/\1: home-directory path (use ~, $HOME or hs.configdir)/' || true
    content "$f" | LC_ALL=C grep -nE "$EMAIL" | grep -v 'leak-check: allow' \
      | LC_ALL=C grep -oE "^[0-9]+:|$EMAIL" | awk '/^[0-9]+:$/ { n = $0; next } { print n $0 }' \
      | grep -vE "$EMAIL_OK" \
      | sed 's/^\([0-9]*\):.*/\1: email address (use an example.com address)/' || true
  )
done

if [ "$problems" -gt 0 ]; then
  echo "leak-check: $problems problem(s). Remove them, or mark a deliberate line with 'leak-check: allow'." >&2
  exit 1
fi
echo "leak-check: ${#files[@]} file(s) clean"
