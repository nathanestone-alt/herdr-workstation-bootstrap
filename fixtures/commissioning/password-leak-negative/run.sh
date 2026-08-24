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

assert_guard_rejects() {
  local label="$1"
  local unsafe_line="$2"
  local unsafe_scanner="$fixture_root/unsafe-${label}.sh"
  local stderr_file="$fixture_root/${label}-stderr"
  cp -- "$scanner" "$unsafe_scanner"
  printf '%s\n' "$unsafe_line" >> "$unsafe_scanner"
  if printf '%s\n' 'fixture-unused-value' |
      "$unsafe_scanner" --repo "$repo_root" --scan "$fixture_root/clean.log" \
        > "$fixture_root/${label}-stdout" 2> "$stderr_file"; then
    echo "${label} argv self-check unexpectedly passed" >&2
    exit 1
  fi
  if ! grep -Fq 'review and extend the allowlist consciously' "$stderr_file"; then
    echo "${label} argv self-check lacked the allowlist diagnostic" >&2
    exit 1
  fi
}

# Build synthetic unsafe source lines without placing an actual fixture value
# in this test script's own command arguments.
r1_line="$(printf '%s%s%s%s%s' \
  '  rg -F -l -- "$' 'secret' '" "$' 'target' '"  # r1 unsafe source')"
unquoted_rg_line="$(printf '%s%s%s' \
  '  rg $' 'secret' ' "$target"  # r2 unquoted unsafe source')"
braced_rg_line="$(printf '%s%s%s%s%s' \
  '  rg "' '$' '{secret}' '"  # r2 braced unsafe source' '')"
grep_line="$(printf '%s%s%s%s%s%s' \
  '  grep -F "' '$' 'secret' '" "$' 'target' '"  # r2 alternate consumer')"
echo_line="$(printf '%s%s%s' \
  '  echo "' '$' 'secret"  # new unallowlisted usage')"

assert_guard_rejects 'r1-rg-quoted' "$r1_line"
assert_guard_rejects 'r2-rg-unquoted' "$unquoted_rg_line"
assert_guard_rejects 'r2-rg-braced' "$braced_rg_line"
assert_guard_rejects 'r2-grep-quoted' "$grep_line"
assert_guard_rejects 'new-echo' "$echo_line"

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
