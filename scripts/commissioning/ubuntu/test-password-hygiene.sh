#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: printf '%s\n' "$PASSWORD" | test-password-hygiene.sh [options]

Reads one password-manager line from stdin and checks that exact value is not
present in the selected manifests, logs, OneDrive-output copies, repository
diffs, or other evidence paths. The value is never printed, passed as a
command argument, or written to a file.

Options:
  --scan PATH     File or directory to scan; may be repeated
  --repo PATH     Git repository whose diff evidence is scanned
EOF
  exit 2
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

command -v rg >/dev/null 2>&1 || fail 'rg is required for the password-hygiene scan'
command -v mktemp >/dev/null 2>&1 || fail 'mktemp is required for the password-hygiene scan'
command -v git >/dev/null 2>&1 || fail 'git is required for the password-hygiene scan'

assert_secret_not_in_argv() {
  local script_path="${BASH_SOURCE[0]}"
  if rg -n -- '(^|[[:space:];|&])rg.*"\$secret"' "$script_path" >/dev/null 2>&1; then
    fail 'password scanner source passes the secret to an rg argument'
  fi
}
assert_secret_not_in_argv

scan_path_list="$(mktemp)"
cleanup_scan_list() { rm -f -- "$scan_path_list"; }
trap cleanup_scan_list EXIT
repo_path=""
scan_count=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --scan)
      [[ $# -ge 2 ]] || usage
      printf '%s\n' "$2" >> "$scan_path_list"
      scan_count=$((scan_count + 1))
      shift 2
      ;;
    --repo)
      [[ $# -ge 2 ]] || usage
      repo_path="$2"
      shift 2
      ;;
    --help|-h)
      usage
      ;;
    *)
      usage
      ;;
  esac
done

secret=""
IFS= read -r secret || fail 'password-manager input was not supplied'
[[ -n "$secret" ]] || fail 'password-manager input was empty'
cleanup_secret() { unset secret; }
trap 'cleanup_scan_list; cleanup_secret' EXIT

if [[ -z "$repo_path" ]]; then
  repo_path="$(git rev-parse --show-toplevel 2>/dev/null || true)"
fi
[[ -n "$repo_path" && -d "$repo_path" ]] || fail 'a Git repository is required for the evidence scan'

tmp_root="$(mktemp -d)"
cleanup_tmp() { rm -rf -- "$tmp_root"; }
trap 'cleanup_tmp; cleanup_scan_list; cleanup_secret' EXIT

scan_file_or_directory() {
  local label="$1"
  local target="$2"
  [[ "$target" != -* ]] || fail "$label path may not start with a dash"
  [[ -e "$target" ]] || fail "$label path is absent"
  local matches="$tmp_root/matches"
  local errors="$tmp_root/errors"
  : > "$matches"
  : > "$errors"
  set +e
  printf '%s\n' "$secret" |
    rg -F -l -f - --hidden --glob '!.git' -- "$target" > "$matches" 2> "$errors"
  local result=$?
  set -e
  if [[ "$result" -eq 0 ]]; then
    fail "password matched $label evidence"
  fi
  [[ "$result" -eq 1 ]] || fail "could not scan $label evidence"
}

scan_stream_for_secret() {
  local line
  local matched=1
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == *"$secret"* ]]; then
      matched=0
    fi
  done
  return "$matched"
}

while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  scan_file_or_directory 'selected' "$path"
done < "$scan_path_list"
scan_file_or_directory 'repository working tree' "$repo_path"

# Keep raw diffs on the pipe: a matched password must never be materialized.
scan_git_diff() {
  local label="$1"
  local error_file="$2"
  shift 2
  : > "$error_file"
  set +e
  git -C "$repo_path" diff --no-ext-diff --binary "$@" 2> "$error_file" |
    scan_stream_for_secret >/dev/null
  local -a statuses=("${PIPESTATUS[@]}")
  set -e
  [[ "${statuses[0]}" -eq 0 ]] || fail "could not capture the $label"
  if [[ "${statuses[1]}" -eq 0 ]]; then
    fail "password matched $label"
  fi
  [[ "${statuses[1]}" -eq 1 ]] || fail "could not scan $label"
}

scan_git_diff 'working-tree Git diff' "$tmp_root/git-working.err" HEAD
scan_git_diff 'index Git diff' "$tmp_root/git-index.err" --cached

printf 'PASS password_hygiene=PASS scanned_paths=%s repository_worktree=PASS git_evidence=PASS secret_value=not-disclosed\n' "$scan_count"
