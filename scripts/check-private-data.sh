#!/usr/bin/env bash
# Fails if any file that could hold real financial data is about to be
# committed (--staged, used by the pre-commit hook) or is already tracked
# (--all, used by CI). See docs/PRIVACY.md for the rules.
#
# This is a guard rail, not a guarantee: the real rule is "real data lives in
# /private and nowhere else".
set -euo pipefail

mode="${1:---staged}"
case "$mode" in
  --staged) files="$(git diff --cached --name-only --diff-filter=ACMR)" ;;
  --all) files="$(git ls-files)" ;;
  *) echo "usage: $0 [--staged|--all]" >&2; exit 2 ;;
esac

# File types that bank exports and screenshots come in.
data_extensions='csv|ofx|qfx|qif|xls|xlsx|pdf|png|jpg|jpeg|heic|heif|webp'
# Directories where such files are allowed, because everything in them is fake
# or is part of the app's own UI.
allowed_data_dirs='^(fixtures|docs/images|frontend/public|frontend/src/assets)/'

problems=()
while IFS= read -r path; do
  [[ -z "$path" ]] && continue
  if [[ "$path" =~ ^private/ ]]; then
    problems+=("$path: everything under private/ is real data and must never be committed")
  elif [[ "$(basename "$path")" =~ ^\.env ]] && [[ "$(basename "$path")" != ".env.example" ]]; then
    problems+=("$path: .env files hold secrets (e.g. ANTHROPIC_API_KEY)")
  elif [[ "${path,,}" =~ \.(${data_extensions})$ ]] && ! [[ "$path" =~ $allowed_data_dirs ]]; then
    problems+=("$path: data files belong in private/ (real) or fixtures/ (fake)")
  fi
done <<< "$files"

if (( ${#problems[@]} > 0 )); then
  echo "Refusing: these files may contain private financial data:" >&2
  printf '  - %s\n' "${problems[@]}" >&2
  echo "If a file is genuinely fake test data, move it under fixtures/." >&2
  exit 1
fi
