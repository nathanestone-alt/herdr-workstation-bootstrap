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
  rg -F -l --hidden --glob '!.git' -- "$secret" "$target" > "$matches" 2> "$errors"
  local result=$?
  set -e
  if [[ "$result" -eq 0 ]]; then
    fail "password matched $label evidence"
  fi
  [[ "$result" -eq 1 ]] || fail "could not scan $label evidence"
}

while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  scan_file_or_directory 'selected' "$path"
done < "$scan_path_list"
scan_file_or_directory 'repository working tree' "$repo_path"

working_diff="$tmp_root/git-working.diff"
index_diff="$tmp_root/git-index.diff"
if ! git -C "$repo_path" diff --no-ext-diff --binary HEAD > "$working_diff" 2> "$tmp_root/git-working.err"; then
  fail 'could not capture the working-tree Git evidence'
fi
if ! git -C "$repo_path" diff --cached --no-ext-diff --binary > "$index_diff" 2> "$tmp_root/git-index.err"; then
  fail 'could not capture the index Git evidence'
fi
scan_file_or_directory 'working-tree Git diff' "$working_diff"
scan_file_or_directory 'index Git diff' "$index_diff"

printf 'PASS password_hygiene=PASS scanned_paths=%s repository_worktree=PASS git_evidence=PASS secret_value=not-disclosed\n' "$scan_count"
