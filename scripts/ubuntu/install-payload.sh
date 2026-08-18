#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
payload_root="$repo_root/payload"
manifest_file="$repo_root/config/payload-manifest.sha256"
state_dir="${HOME}/.local/state/herdr-workstation-bootstrap"
agents_source="$payload_root/agents-skills"
claude_source="$payload_root/claude-skills"
agents_destination="${HOME}/.agents/skills"
claude_destination="${HOME}/.claude/skills"

regression_tests=(
  'payload/agents-skills/herdr-coordination/scripts/test_claude_session_refresh.ps1'
  'payload/agents-skills/herdr-coordination/scripts/test_codex_session_refresh.ps1'
  'payload/agents-skills/herdr-coordination/scripts/test_herdr_coordination.ps1'
  'payload/agents-skills/herdr-coordination/scripts/test_herdr_naming_lifecycle.ps1'
  'payload/agents-skills/herdr-coordination/scripts/test_herdr_pane_registry.ps1'
  'payload/agents-skills/herdr-coordination/scripts/test_herdr_pane_registry_cli.ps1'
  'payload/agents-skills/herdr-coordination/scripts/test_herdr_skill_compatibility.ps1'
  'payload/agents-skills/herdr-coordination/scripts/test_herdr_workflow.ps1'
  'payload/agents-skills/herdr-coordination/scripts/test_herdr_workflow_stress.ps1'
  'payload/agents-skills/st-herdr-dispatch/scripts/test_st_herdr_dispatch.ps1'
)

fail_closed() {
  echo "BLOCKED: $*" >&2
  exit 31
}

ensure_source_clean() {
  [[ -d "$repo_root/.git" || -f "$repo_root/.git" ]] || fail_closed 'payload source is not a Git checkout.'
  [[ "$(git -C "$repo_root" rev-parse --is-inside-work-tree 2>/dev/null || true)" == true ]] || fail_closed 'payload source is not an identified Git worktree.'
  source_commit="$(git -C "$repo_root" rev-parse --verify HEAD^{commit} 2>/dev/null || true)"
  [[ "$source_commit" =~ ^[0-9a-f]{40}$ ]] || fail_closed 'payload source HEAD is not an identified commit.'
  git -C "$repo_root" diff --quiet || fail_closed 'payload source has unstaged tracked changes.'
  git -C "$repo_root" diff --cached --quiet || fail_closed 'payload source has staged tracked changes.'

  untracked="$(git -C "$repo_root" ls-files --others --exclude-standard)"
  [[ -z "$untracked" ]] || fail_closed "payload source has untracked files: $untracked"
  ignored_files="$(git -C "$repo_root" ls-files --others --ignored --exclude-standard)"
  while IFS= read -r ignored_path; do
    [[ -z "$ignored_path" ]] && continue
    [[ "$ignored_path" == 'LOCAL-COMMISSIONING-LOG.md' ]] || fail_closed "unexpected ignored source file: $ignored_path"
  done <<< "$ignored_files"
}

load_manifest() {
  [[ -f "$manifest_file" ]] || fail_closed "tracked payload manifest is missing: $manifest_file"
  manifest_paths=()
  manifest_hashes=()
  declare -gA manifest_hash_by_path=()
  line_number=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_number=$((line_number + 1))
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ ! "$line" =~ ^([0-9a-f]{64})[[:space:]][[:space:]]([A-Za-z0-9._/-]+)$ ]]; then
      fail_closed "invalid payload manifest line $line_number"
    fi
    file_hash="${BASH_REMATCH[1]}"
    relative_path="${BASH_REMATCH[2]}"
    case "$relative_path" in
      agents-skills/*|claude-skills/*) ;;
      *) fail_closed "payload manifest path is outside the installable roots: $relative_path" ;;
    esac
    [[ "$relative_path" != *'..'* ]] || fail_closed "payload manifest path contains traversal: $relative_path"
    [[ -z "${manifest_hash_by_path[$relative_path]+present}" ]] || fail_closed "duplicate payload manifest path: $relative_path"
    manifest_paths+=("$relative_path")
    manifest_hashes+=("$file_hash")
    manifest_hash_by_path["$relative_path"]="$file_hash"
  done < "$manifest_file"
  (( ${#manifest_paths[@]} > 0 )) || fail_closed 'payload manifest is empty.'

  sorted_manifest_paths="$(printf '%s\n' "${manifest_paths[@]}" | LC_ALL=C sort)"
  listed_manifest_paths="$(printf '%s\n' "${manifest_paths[@]}")"
  [[ "$sorted_manifest_paths" == "$listed_manifest_paths" ]] || fail_closed 'payload manifest paths are not sorted.'
}

list_source_paths() {
  git -C "$repo_root" ls-files --full-name -- 'payload/agents-skills/**' 'payload/claude-skills/**' | sed 's#^payload/##' | LC_ALL=C sort
}

list_files_under_roots() {
  local prefix="$1"
  local root="$2"
  [[ -d "$root" ]] || return 0
  find "$root" -type f -printf '%P\n' | sed "s#^#$prefix/#"
}

validate_payload_manifest() {
  load_manifest
  [[ -d "$agents_source" && -d "$claude_source" ]] || fail_closed 'one or more installable payload roots are missing.'

  source_paths="$(list_source_paths)"
  filesystem_paths="$( { list_files_under_roots agents-skills "$agents_source"; list_files_under_roots claude-skills "$claude_source"; } | LC_ALL=C sort )"
  [[ "$source_paths" == "$filesystem_paths" ]] || fail_closed 'tracked payload paths do not exactly match the source filesystem.'
  manifest_paths_text="$(printf '%s\n' "${manifest_paths[@]}")"
  [[ "$manifest_paths_text" == "$source_paths" ]] || fail_closed 'tracked payload paths do not exactly match the pinned manifest.'

  source_links="$(find "$agents_source" "$claude_source" -type l -print -quit)"
  [[ -z "$source_links" ]] || fail_closed "symlink is not an installable payload file: $source_links"
  for relative_path in "${manifest_paths[@]}"; do
    source_file="$payload_root/$relative_path"
    [[ -f "$source_file" ]] || fail_closed "manifest payload file is missing: $relative_path"
    actual_hash="$(sha256sum "$source_file" | awk '{print $1}')"
    [[ "$actual_hash" == "${manifest_hash_by_path[$relative_path]}" ]] || fail_closed "payload hash mismatch: $relative_path"
  done
}

path_is_under() {
  local child="$1"
  local parent="$2"
  [[ "$child" == "$parent" || "$child" == "$parent/"* ]]
}

validate_destination_safety() {
  [[ -n "${HOME:-}" && "$HOME" == /* && "$HOME" != '/' ]] || fail_closed 'HOME is not a safe absolute user path.'
  source_real="$(realpath -m "$repo_root")"
  for destination in "$agents_destination" "$claude_destination"; do
    destination_real="$(realpath -m "$destination")"
    path_is_under "$destination_real" "$HOME" || fail_closed "destination is outside HOME: $destination"
    if path_is_under "$destination_real" "$source_real" || path_is_under "$source_real" "$destination_real"; then
      fail_closed "destination overlaps the Git source checkout: $destination"
    fi
    [[ ! -L "$destination" ]] || fail_closed "destination is a symlink: $destination"
    probe="$destination"
    while [[ ! -d "$probe" && "$probe" != '/' ]]; do probe="$(dirname "$probe")"; done
    existing_checkout="$(git -C "$probe" rev-parse --show-toplevel 2>/dev/null || true)"
    [[ -z "$existing_checkout" ]] || fail_closed "refusing to overwrite a Git checkout destination: $destination"
  done
}

verify_payload_roots() {
  local agents_root="$1"
  local claude_root="$2"
  local label="$3"
  [[ -d "$agents_root" && -d "$claude_root" ]] || fail_closed "$label payload roots are incomplete."
  links="$(find "$agents_root" "$claude_root" -type l -print -quit)"
  [[ -z "$links" ]] || fail_closed "$label payload contains a symlink: $links"
  actual_paths="$( { list_files_under_roots agents-skills "$agents_root"; list_files_under_roots claude-skills "$claude_root"; } | LC_ALL=C sort )"
  expected_paths="$(printf '%s\n' "${manifest_paths[@]}")"
  [[ "$actual_paths" == "$expected_paths" ]] || fail_closed "$label payload paths do not match the pinned manifest."
  while IFS= read -r relative_path; do
    [[ -z "$relative_path" ]] && continue
    case "$relative_path" in
      agents-skills/*) root="$agents_root"; relative_file="${relative_path#agents-skills/}" ;;
      claude-skills/*) root="$claude_root"; relative_file="${relative_path#claude-skills/}" ;;
      *) fail_closed "$label payload path is outside an installable root: $relative_path" ;;
    esac
    installed_file="$root/$relative_file"
    [[ -f "$installed_file" ]] || fail_closed "$label payload file is missing: $relative_path"
    actual_hash="$(sha256sum "$installed_file" | awk '{print $1}')"
    [[ "$actual_hash" == "${manifest_hash_by_path[$relative_path]}" ]] || fail_closed "$label payload hash mismatch: $relative_path"
  done <<< "$expected_paths"
}

verify_installed_payload() {
  verify_payload_roots "$agents_destination" "$claude_destination" installed
}

write_runtime_receipt() {
  mkdir -p "$state_dir"
  receipt_tmp="$(mktemp "$state_dir/.payload-runtime-receipt.XXXXXX")"
  if ! command -v uv >/dev/null 2>&1 || ! command -v python3.13 >/dev/null 2>&1 || ! command -v py >/dev/null 2>&1; then
    rm -f "$receipt_tmp"
    return 1
  fi
  uv_version="$(uv --version 2>&1)" || { rm -f "$receipt_tmp"; return 1; }
  python_version="$(python3.13 --version 2>&1)" || { rm -f "$receipt_tmp"; return 1; }
  py_version="$(py -3.13 --version 2>&1)" || { rm -f "$receipt_tmp"; return 1; }
  manifest_sha256="$(sha256sum "$manifest_file" | awk '{print $1}')"
  {
    printf 'receipt_format=issue-961-payload-v1\n'
    printf 'source_commit=%s\n' "$source_commit"
    printf 'tracked_manifest_sha256=%s\n' "$manifest_sha256"
    printf 'source_payload_file_count=%s\n' "${#manifest_paths[@]}"
    for relative_path in "${manifest_paths[@]}"; do
      printf 'source_payload_sha256.%s=%s\n' "$relative_path" "${manifest_hash_by_path[$relative_path]}"
    done
    printf 'installed_payload_file_count=%s\n' "${#manifest_paths[@]}"
    for relative_path in "${manifest_paths[@]}"; do
      case "$relative_path" in
        agents-skills/*) installed_file="$agents_destination/${relative_path#agents-skills/}" ;;
        claude-skills/*) installed_file="$claude_destination/${relative_path#claude-skills/}" ;;
      esac
      printf 'installed_payload_sha256.%s=%s\n' "$relative_path" "$(sha256sum "$installed_file" | awk '{print $1}')"
    done
    printf 'tool.uv=%s\n' "$uv_version"
    printf 'tool.python3.13=%s\n' "$python_version"
    printf 'tool.py-3.13=%s\n' "$py_version"
    printf 'regression_test_count=%s\n' "${#regression_tests[@]}"
    test_number=0
    for regression_test in "${regression_tests[@]}"; do
      test_number=$((test_number + 1))
      printf 'regression_test_command_%02d=%s\n' "$test_number" "pwsh -NoProfile -File $regression_test"
    done
  } > "$receipt_tmp"
  if ! install -m 0644 "$receipt_tmp" "$state_dir/payload-runtime-receipt.txt"; then
    rm -f "$receipt_tmp"
    return 1
  fi
  rm -f "$receipt_tmp"
}

rollback_transaction() {
  if [[ "$agents_new" == 1 ]]; then rm -rf -- "$agents_destination"; fi
  if [[ "$claude_new" == 1 ]]; then rm -rf -- "$claude_destination"; fi
  if [[ "$agents_had_original" == 1 ]]; then mv -- "$backup_root/agents-skills" "$agents_destination"; fi
  if [[ "$claude_had_original" == 1 ]]; then mv -- "$backup_root/claude-skills" "$claude_destination"; fi
}

main() {
  ensure_source_clean
  validate_payload_manifest
  validate_destination_safety

  if [[ -d "$payload_root/agents-skills/herdr-coordination" ]]; then
    if grep -RqsE 'C:\\|USERPROFILE|-WindowStyle|@echo off|\.cmd\b' "$payload_root/agents-skills/herdr-coordination"; then
      echo 'BLOCKED: herdr-coordination still contains Windows-specific behavior.' >&2
      echo 'Port it and run its regression suite under native Ubuntu pwsh before installing the agents skill payload.' >&2
      exit 30
    fi
  fi

  mkdir -p "$state_dir"
  stage_root="$(mktemp -d "$state_dir/.payload-stage.XXXXXX")"
  mkdir -p "$stage_root/agents-skills" "$stage_root/claude-skills"
  cp -a "$agents_source"/. "$stage_root/agents-skills"/
  cp -a "$claude_source"/. "$stage_root/claude-skills"/
  verify_payload_roots "$stage_root/agents-skills" "$stage_root/claude-skills" staged

  backup_root="$(mktemp -d "$state_dir/.payload-backup.XXXXXX")"
  agents_had_original=0
  claude_had_original=0
  agents_new=0
  claude_new=0
  if [[ -e "$agents_destination" || -L "$agents_destination" ]]; then
    if ! mv -- "$agents_destination" "$backup_root/agents-skills"; then
      rollback_transaction
      fail_closed 'could not reserve agents-skills without leaving a partial installation.'
    fi
    agents_had_original=1
  fi
  if [[ -e "$claude_destination" || -L "$claude_destination" ]]; then
    if ! mv -- "$claude_destination" "$backup_root/claude-skills"; then
      rollback_transaction
      fail_closed 'could not reserve claude-skills without leaving a partial installation.'
    fi
    claude_had_original=1
  fi
  if ! mkdir -p "$(dirname "$agents_destination")" || ! mv -- "$stage_root/agents-skills" "$agents_destination"; then
    rollback_transaction
    fail_closed 'could not stage agents-skills without leaving a partial installation.'
  fi
  agents_new=1
  if ! mkdir -p "$(dirname "$claude_destination")" || ! mv -- "$stage_root/claude-skills" "$claude_destination"; then
    rollback_transaction
    fail_closed 'could not stage claude-skills without leaving a partial installation.'
  fi
  claude_new=1

  if ! verify_installed_payload; then
    rollback_transaction
    fail_closed 'installed payload hash verification failed; previous destinations were restored.'
  fi
  if ! write_runtime_receipt; then
    rollback_transaction
    fail_closed 'runtime receipt could not be produced; previous destinations were restored.'
  fi
  rm -rf -- "$backup_root" "$stage_root"
  echo "Payload installed from clean commit $source_commit. Runtime receipt: $state_dir/payload-runtime-receipt.txt"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
