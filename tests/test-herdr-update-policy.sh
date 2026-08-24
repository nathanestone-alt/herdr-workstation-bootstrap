#!/usr/bin/env bash
set -euo pipefail
umask 022

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d /tmp/herdr-update-policy-test.XXXXXX)"
trap 'rm -rf -- "$test_root"' EXIT

# Extract the production decision and attestation functions into a disposable
# harness. The publication fence is replaced only by an atomic fixture move;
# the version ordering, staged download, integrity check, and manifest
# attestation remain the committed production functions.
extract_function() {
  local function_name="$1"
  awk -v name="$function_name" '
    $0 ~ "^" name "\\(\\) \\{$" { capture=1; depth=0 }
    capture {
      print
      opens=gsub(/\{/, "{")
      closes=gsub(/\}/, "}")
      depth += opens - closes
      if (depth == 0) exit
    }
  ' "$repo_root/scripts/ubuntu/bootstrap.sh"
}

harness="$test_root/herdr-harness.sh"
{
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
  printf '%s\n' "readonly bootstrap_sort_bin='/usr/bin/sort'"
  printf '%s\n' "readonly bootstrap_head_bin='/usr/bin/head'"
  printf '%s\n' "readonly bootstrap_sha256_bin='/usr/bin/sha256sum'"
  printf '%s\n' "readonly bootstrap_awk_bin='/usr/bin/gawk'"
  printf '%s\n' 'declare -a bootstrap_cleanup_paths=()'
  printf '%s\n' 'bootstrap_register_cleanup() { [[ -n "${1:-}" ]] && bootstrap_cleanup_paths+=("$1"); }'
  printf '%s\n' 'bootstrap_exec_system() { "$@"; }'
  extract_function bootstrap_version_at_least
  extract_function bootstrap_version_greater
  extract_function bootstrap_herdr_version
  extract_function bootstrap_integrity_check
  extract_function download_verified
  extract_function bootstrap_herdr_attestation
  extract_function converge_herdr
  cat <<'EOF'
fence_replace_file() {
  local source="$1"
  local target="$2"
  local mode="$3"
  chmod "$mode" "$source"
  mv -T -- "$source" "$target"
}

bootstrap_download_transport() {
  local _url="$1"
  local destination="$2"
  download_calls=$((download_calls + 1))
  cp -- "$FIXTURE_ARTIFACT" "$destination"
}

write_herdr() {
  local path="$1"
  local version="$2"
  cat > "$path" <<HERDR
#!/usr/bin/env bash
printf 'herdr %s\n' '$version'
HERDR
  chmod 0755 "$path"
}

assert_version() {
  local path="$1"
  local expected="$2"
  [[ "$("$path" --version)" == "herdr $expected" ]] || {
    echo "Expected $path to report $expected." >&2
    exit 1
  }
}

run_converge() {
  local home="$1"
  bin_dir="$home/bin"
  mkdir -p "$bin_dir"
  converge_herdr
}

HERDR_VERSION='0.8.2'
HERDR_URL='fixture://herdr'
mkdir -p "$HOME"
FIXTURE_ARTIFACT="$HOME/fixture-herdr"
write_herdr "$FIXTURE_ARTIFACT" "$HERDR_VERSION"
HERDR_SHA256="$(sha256sum -- "$FIXTURE_ARTIFACT" | gawk '{print $1}')"

newer_home="$HOME/newer"
mkdir -p "$newer_home/bin"
write_herdr "$newer_home/bin/herdr" '0.8.10'
newer_before="$(sha256sum -- "$newer_home/bin/herdr" | gawk '{print $1}')"
download_calls=0
run_converge "$newer_home"
[[ "$download_calls" == 0 ]] || { echo 'Newer Herdr triggered a download.' >&2; exit 1; }
[[ "$(sha256sum -- "$newer_home/bin/herdr" | gawk '{print $1}')" == "$newer_before" ]] ||
  { echo 'Newer Herdr was replaced.' >&2; exit 1; }
assert_version "$newer_home/bin/herdr" '0.8.10'

older_home="$HOME/older"
mkdir -p "$older_home/bin"
write_herdr "$older_home/bin/herdr" '0.8.1'
download_calls=0
run_converge "$older_home"
[[ "$download_calls" == 1 ]] || { echo 'Older Herdr did not trigger one download.' >&2; exit 1; }
assert_version "$older_home/bin/herdr" "$HERDR_VERSION"

missing_home="$HOME/missing"
mkdir -p "$missing_home/bin"
download_calls=0
run_converge "$missing_home"
[[ "$download_calls" == 1 ]] || { echo 'Missing Herdr did not trigger one download.' >&2; exit 1; }
assert_version "$missing_home/bin/herdr" "$HERDR_VERSION"

marker_output="$(bootstrap_herdr_attestation "$newer_home/bin/herdr")"
IFS=$'\t' read -r marker_output_version marker_version marker_sha256 marker_newer <<< "$marker_output"
[[ "$marker_output_version" == 'herdr 0.8.10' &&
  "$marker_version" == '0.8.10' &&
  "$marker_sha256" == "$newer_before" &&
  "$marker_newer" == true ]] || {
  echo 'Newer Herdr attestation did not preserve actual version, hash, and marker.' >&2
  exit 1
}

hash_fail_home="$HOME/hash-fail"
mkdir -p "$hash_fail_home/bin"
write_herdr "$hash_fail_home/bin/herdr" '0.8.1'
HERDR_SHA256="$(printf '0%.0s' {1..64})"
download_calls=0
set +e
( run_converge "$hash_fail_home" ) > "$HOME/hash-fail.out" 2>&1
hash_fail_status=$?
set -e
[[ "$hash_fail_status" == 23 ]] || {
  cat "$HOME/hash-fail.out" >&2
  echo "Hash mismatch returned $hash_fail_status instead of 23." >&2
  exit 1
}
assert_version "$hash_fail_home/bin/herdr" '0.8.1'

echo 'Herdr update-policy convergence, floor ordering, attestation, and hash-fail-closed tests passed.'
EOF
} > "$harness"
chmod 0755 "$harness"

HOME="$test_root/home" PATH=/usr/sbin:/usr/bin:/sbin:/bin \
  /usr/bin/bash "$harness"
