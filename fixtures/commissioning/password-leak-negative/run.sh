#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "$BASH_SOURCE")" && pwd -P)"
repo_root="$(cd -- "$script_dir/../../.." && pwd -P)"
scanner="$repo_root/scripts/commissioning/ubuntu/test-password-hygiene.sh"
fixture_root="$(mktemp -d)"
cleanup() { rm -rf -- "$fixture_root"; }
trap cleanup EXIT

sentinel="commissioning-synthetic-sentinel-$$"
printf '%s\n' 'clean commissioning evidence' > "$fixture_root/clean.log"
printf '%s\n' "$sentinel" > "$fixture_root/leak.log"

printf '%s\n' "$sentinel" |
  "$scanner" --repo "$repo_root" --scan "$fixture_root/clean.log" >/dev/null

if printf '%s\n' "$sentinel" |
    "$scanner" --repo "$repo_root" --scan "$fixture_root/leak.log" \
      > "$fixture_root/stdout" 2> "$fixture_root/stderr"; then
  echo 'negative fixture unexpectedly passed' >&2
  exit 1
fi
if grep -Fq "$sentinel" "$fixture_root/stdout" ||
   grep -Fq "$sentinel" "$fixture_root/stderr"; then
  echo 'negative fixture leaked its sentinel' >&2
  exit 1
fi
printf '%s\n' 'PASS password-leak negative fixture'
