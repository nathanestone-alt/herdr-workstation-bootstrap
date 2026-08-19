#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
payload_root="$repo_root/payload"
manifest_file="$repo_root/config/payload-manifest.sha256"
toolchain_lock_file="$repo_root/config/ubuntu-toolchain.lock"
state_dir="${HOME}/.local/state/herdr-workstation-bootstrap"
lock_file="$state_dir/payload-install.lock"
toolchain_receipt="$state_dir/toolchain-manifest.txt"
payload_receipt="$state_dir/payload-runtime-receipt.txt"
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

source_commit=''
source_commit_before_transaction=''
stage_root=''
backup_root=''
agents_had_original=0
claude_had_original=0
agents_new=0
claude_new=0
receipt_had_original=0
receipt_touched=0
transaction_guard_enabled=0
rollback_in_progress=0
lock_fd=''
receipt_tmp=''

fail_closed() {
  echo "BLOCKED: $*" >&2
  exit 31
}

path_is_under() {
  local child="$1"
  local parent="$2"
  [[ "$child" == "$parent" || "$child" == "$parent/"* ]]
}

validate_user_home() {
  [[ -n "${HOME:-}" && "$HOME" == /* && "$HOME" != '/' && -d "$HOME" ]] || {
    fail_closed 'HOME is not a safe absolute user directory.'
  }
  [[ ! -L "$HOME" ]] || fail_closed 'HOME itself must not be a symlink.'
  home_real="$(realpath -e -- "$HOME" 2>/dev/null || true)"
  [[ -n "$home_real" && -d "$home_real" ]] || fail_closed 'Could not resolve the real user home.'
  [[ "$(stat -c '%u' -- "$home_real" 2>/dev/null || true)" == "$(id -u)" ]] || {
    fail_closed 'The resolved user home is not owned by the current user.'
  }
}

validate_managed_path() {
  local path="$1"
  local normalized
  local relative
  local component
  local component_path
  local -a components

  [[ "$path" == "$HOME" || "$path" == "$HOME/"* ]] || fail_closed "Managed path is outside HOME: $path"
  normalized="$(realpath -m -- "$path" 2>/dev/null || true)"
  path_is_under "$normalized" "$home_real" || fail_closed "Managed path resolves outside the real user home: $path"

  [[ "$path" == "$HOME" ]] && return 0
  relative="${path#"$HOME"/}"
  component_path="$HOME"
  IFS='/' read -r -a components <<< "$relative"
  for component in "${components[@]}"; do
    [[ -z "$component" || "$component" == '.' ]] && continue
    component_path="$component_path/$component"
    [[ ! -L "$component_path" ]] || fail_closed "Managed path contains a symlinked component: $component_path"
  done
}

validate_managed_paths() {
  validate_user_home
  local path
  for path in "$@"; do
    validate_managed_path "$path"
  done
}

validate_destination_safety() {
  validate_managed_paths \
    "$state_dir" "$lock_file" "$toolchain_receipt" "$payload_receipt" \
    "$agents_destination" "$claude_destination"
  source_real="$(realpath -e -- "$repo_root" 2>/dev/null || true)"
  [[ -n "$source_real" ]] || fail_closed 'Could not resolve the payload source checkout.'
  for destination in "$agents_destination" "$claude_destination"; do
    destination_real="$(realpath -m -- "$destination")"
    path_is_under "$destination_real" "$home_real" || fail_closed "destination is outside HOME: $destination"
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

load_toolchain_lock() {
  [[ -f "$toolchain_lock_file" && ! -L "$toolchain_lock_file" ]] || fail_closed "Missing toolchain lock: $toolchain_lock_file"
  # shellcheck disable=SC1090
  source "$toolchain_lock_file"
  local required_key
  for required_key in UV_VERSION UV_PLATFORM UV_URL UV_SHA256 PYTHON_VERSION PYTHON_RELEASE PYTHON_PLATFORM PYTHON_ARCHIVE PYTHON_URL PYTHON_SHA256; do
    [[ -n "${!required_key:-}" ]] || fail_closed "Toolchain lock key is missing: $required_key"
  done
  [[ "$UV_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail_closed 'Toolchain lock uv version is not exact.'
  [[ "$UV_PLATFORM" == 'x86_64-unknown-linux-gnu' ]] || fail_closed 'Toolchain lock uv platform is unsupported.'
  [[ "$PYTHON_VERSION" =~ ^3\.13\.[0-9]+$ ]] || fail_closed 'Toolchain lock Python version is not exact.'
  [[ "$PYTHON_RELEASE" =~ ^[0-9]{8}$ ]] || fail_closed 'Toolchain lock Python release is not exact.'
  [[ "$PYTHON_PLATFORM" == 'x86_64-unknown-linux-gnu' ]] || fail_closed 'Toolchain lock Python platform is unsupported.'
  [[ "$UV_URL" == "https://github.com/astral-sh/uv/releases/download/$UV_VERSION/uv-$UV_PLATFORM.tar.gz" ]] || fail_closed 'Toolchain lock uv URL is inconsistent.'
  expected_python_archive="cpython-$PYTHON_VERSION+$PYTHON_RELEASE-$PYTHON_PLATFORM-install_only_stripped.tar.gz"
  [[ "$PYTHON_ARCHIVE" == "$expected_python_archive" ]] || fail_closed 'Toolchain lock Python archive is inconsistent.'
  expected_python_url="https://github.com/astral-sh/python-build-standalone/releases/download/$PYTHON_RELEASE/${PYTHON_ARCHIVE//+/%2B}"
  [[ "$PYTHON_URL" == "$expected_python_url" ]] || fail_closed 'Toolchain lock Python URL is inconsistent.'
  [[ "$UV_SHA256" =~ ^[0-9a-f]{64}$ && "$PYTHON_SHA256" =~ ^[0-9a-f]{64}$ ]] || fail_closed 'Toolchain lock runtime checksum is not exact.'
}

receipt_field() {
  local key="$1"
  local expected="$2"
  grep -Fqx -- "$key=$expected" "$toolchain_receipt" || fail_closed "toolchain receipt mismatch: $key"
}

validate_managed_tool() {
  local name="$1"
  local expected_path="$2"
  local actual_path
  [[ -x "$expected_path" ]] || fail_closed "managed tool is missing or not executable: $expected_path"
  actual_path="$(command -v "$name" 2>/dev/null || true)"
  [[ "$actual_path" == "$expected_path" ]] || fail_closed "$name is not managed: ${actual_path:-unavailable}"
  resolved_path="$(realpath -e -- "$expected_path" 2>/dev/null || true)"
  path_is_under "$resolved_path" "$home_real" || fail_closed "$name resolves outside HOME: $expected_path"
}

validate_managed_toolchain() {
  load_toolchain_lock
  [[ "$(uname -s)" == 'Linux' && "$(uname -m)" == 'x86_64' && "$(getconf LONG_BIT)" == '64' ]] || {
    fail_closed 'Managed toolchain host platform or architecture is unsupported.'
  }
  [[ -f "$toolchain_receipt" && ! -L "$toolchain_receipt" ]] || fail_closed "Missing bootstrap toolchain receipt: $toolchain_receipt"

  managed_bin="$HOME/.local/bin"
  managed_uv="$managed_bin/uv"
  managed_python="$managed_bin/python3.13"
  managed_py="$managed_bin/py"
  validate_managed_paths "$managed_bin"
  validate_managed_tool uv "$managed_uv"
  validate_managed_tool python3.13 "$managed_python"
  validate_managed_tool py "$managed_py"

  expected_uv_version="uv $UV_VERSION ($UV_PLATFORM)"
  expected_python_version="Python $PYTHON_VERSION"
  expected_probe="$PYTHON_VERSION|x86_64|linux"
  expected_lock_sha256="$(sha256sum "$toolchain_lock_file" | awk '{print $1}')"
  receipt_field receipt_format 'issue-961-toolchain-v2'
  receipt_field lock_sha256 "$expected_lock_sha256"
  receipt_field host_platform linux
  receipt_field host_architecture x86_64
  receipt_field uv_path "$managed_uv"
  receipt_field python3.13_path "$managed_python"
  receipt_field py_path "$managed_py"
  receipt_field uv_version "$expected_uv_version"
  receipt_field python3.13_version "$expected_python_version"
  receipt_field py_3.13_version "$expected_python_version"
  receipt_field py_3.13_probe "$expected_probe"
  receipt_field uv_platform "$UV_PLATFORM"
  receipt_field uv_url "$UV_URL"
  receipt_field uv_sha256 "$UV_SHA256"
  receipt_field python_version "$PYTHON_VERSION"
  receipt_field python_platform "$PYTHON_PLATFORM"
  receipt_field python_release "$PYTHON_RELEASE"
  receipt_field python_archive "$PYTHON_ARCHIVE"
  receipt_field python_url "$PYTHON_URL"
  receipt_field python_sha256 "$PYTHON_SHA256"

  actual_uv_version="$($managed_uv --version 2>&1)" || fail_closed 'managed uv version probe failed.'
  actual_python_version="$($managed_python --version 2>&1)" || fail_closed 'managed Python version probe failed.'
  actual_py_version="$($managed_py -3.13 --version 2>&1)" || fail_closed 'managed py version probe failed.'
  actual_probe="$($managed_py -3.13 -c 'import platform, sys; print(f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}|{platform.machine()}|{sys.platform}")' 2>&1)" || fail_closed 'managed py platform probe failed.'
  [[ "$actual_uv_version" == "$expected_uv_version" ]] || fail_closed "managed uv version is not locked: $actual_uv_version"
  [[ "$actual_python_version" == "$expected_python_version" ]] || fail_closed "managed Python version is not locked: $actual_python_version"
  [[ "$actual_py_version" == "$expected_python_version" ]] || fail_closed "managed py version is not locked: $actual_py_version"
  [[ "$actual_probe" == "$expected_probe" ]] || fail_closed "managed py platform probe is not locked: $actual_probe"
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
  [[ -f "$manifest_file" && ! -L "$manifest_file" ]] || fail_closed "tracked payload manifest is missing: $manifest_file"
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
  [[ "${HERDR_PAYLOAD_TEST_FAIL_RECEIPT_WRITE:-0}" != 1 ]] || return 1
  receipt_tmp="$(mktemp "$state_dir/.payload-runtime-receipt.XXXXXX")"
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
    printf 'tool.uv=%s\n' "$actual_uv_version"
    printf 'tool.python3.13=%s\n' "$actual_python_version"
    printf 'tool.py-3.13=%s\n' "$actual_py_version"
    printf 'regression_test_count=%s\n' "${#regression_tests[@]}"
    test_number=0
    for regression_test in "${regression_tests[@]}"; do
      test_number=$((test_number + 1))
      printf 'regression_test_command_%02d=%s\n' "$test_number" "pwsh -NoProfile -File $regression_test"
    done
  } > "$receipt_tmp"
  if ! install -m 0644 "$receipt_tmp" "$payload_receipt"; then
    rm -f "$receipt_tmp"
    return 1
  fi
  receipt_touched=1
  rm -f "$receipt_tmp"
  receipt_tmp=''
}

validate_written_receipt() {
  [[ -s "$payload_receipt" ]] || return 1
  grep -Fqx -- 'receipt_format=issue-961-payload-v1' "$payload_receipt" || return 1
  grep -Fqx -- "source_commit=$source_commit" "$payload_receipt" || return 1
  manifest_sha256="$(sha256sum "$manifest_file" | awk '{print $1}')"
  grep -Fqx -- "tracked_manifest_sha256=$manifest_sha256" "$payload_receipt" || return 1
  grep -Fqx -- "installed_payload_file_count=${#manifest_paths[@]}" "$payload_receipt" || return 1
}

rollback_transaction() {
  local rollback_status=0
  (( rollback_in_progress == 1 )) && return 0
  rollback_in_progress=1
  if (( agents_new == 1 )) && [[ -e "$agents_destination" || -L "$agents_destination" ]]; then
    rm -rf -- "$agents_destination" || rollback_status=1
  fi
  if (( claude_new == 1 )) && [[ -e "$claude_destination" || -L "$claude_destination" ]]; then
    rm -rf -- "$claude_destination" || rollback_status=1
  fi
  if (( agents_had_original == 1 )) && [[ -e "$backup_root/agents-skills" || -L "$backup_root/agents-skills" ]]; then
    mv -- "$backup_root/agents-skills" "$agents_destination" || rollback_status=1
  fi
  if (( claude_had_original == 1 )) && [[ -e "$backup_root/claude-skills" || -L "$backup_root/claude-skills" ]]; then
    mv -- "$backup_root/claude-skills" "$claude_destination" || rollback_status=1
  fi
  if (( receipt_touched == 1 )) && [[ -e "$payload_receipt" || -L "$payload_receipt" ]]; then
    rm -f -- "$payload_receipt" || rollback_status=1
  fi
  if (( receipt_had_original == 1 )) && [[ -e "$backup_root/payload-runtime-receipt.txt" || -L "$backup_root/payload-runtime-receipt.txt" ]]; then
    mv -- "$backup_root/payload-runtime-receipt.txt" "$payload_receipt" || rollback_status=1
  fi
  rollback_in_progress=0
  return "$rollback_status"
}

cleanup_transaction_residue() {
  local cleanup_status=0
  if [[ -n "$receipt_tmp" && -e "$receipt_tmp" ]]; then
    rm -f -- "$receipt_tmp" || cleanup_status=1
  fi
  [[ -z "$backup_root" || ! -e "$backup_root" ]] || rm -rf -- "$backup_root" || cleanup_status=1
  [[ -z "$stage_root" || ! -e "$stage_root" ]] || rm -rf -- "$stage_root" || cleanup_status=1
  return "$cleanup_status"
}

transaction_exit_handler() {
  local status="$1"
  trap - EXIT HUP INT TERM
  if (( transaction_guard_enabled == 1 )); then
    transaction_guard_enabled=0
    if (( status != 0 )); then
      rollback_transaction || echo 'BLOCKED: transaction rollback was incomplete.' >&2
    fi
    cleanup_transaction_residue || echo 'BLOCKED: transaction residue cleanup was incomplete.' >&2
  fi
}

install_transaction_guard() {
  transaction_guard_enabled=1
  trap 'transaction_exit_handler "$?"' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

test_pause() {
  local phase="$1"
  [[ "${HERDR_PAYLOAD_TEST_PAUSE_PHASE:-}" == "$phase" ]] || return 0
  [[ -n "${HERDR_PAYLOAD_TEST_READY_FILE:-}" && -n "${HERDR_PAYLOAD_TEST_CONTINUE_FILE:-}" ]] || fail_closed "test pause is missing synchronization files: $phase"
  : > "$HERDR_PAYLOAD_TEST_READY_FILE"
  while [[ ! -e "$HERDR_PAYLOAD_TEST_CONTINUE_FILE" ]]; do sleep 0.01; done
}

test_failure() {
  local phase="$1"
  [[ "${HERDR_PAYLOAD_TEST_FAIL_PHASE:-}" == "$phase" ]] || return 0
  fail_closed "injected transaction failure: $phase"
}

acquire_install_lock() {
  exec {lock_fd}>"$lock_file" || fail_closed "could not open per-user payload lock: $lock_file"
  if ! flock -n "$lock_fd"; then
    fail_closed 'another payload installation is already in progress.'
  fi
  test_pause lock-acquired
}

prepare_receipt_backup() {
  if [[ -e "$payload_receipt" || -L "$payload_receipt" ]]; then
    receipt_had_original=1
    mv -- "$payload_receipt" "$backup_root/payload-runtime-receipt.txt" || fail_closed 'could not reserve the existing payload receipt.'
  fi
}

revalidate_source_and_stage() {
  source_commit_before_transaction="$source_commit"
  ensure_source_clean
  [[ "$source_commit" == "$source_commit_before_transaction" ]] || fail_closed 'payload source commit drifted after staging.'
  validate_payload_manifest
  verify_payload_roots "$stage_root/agents-skills" "$stage_root/claude-skills" staged
}

main() {
  validate_destination_safety
  mkdir -p "$state_dir"
  validate_destination_safety
  acquire_install_lock

  ensure_source_clean
  validate_payload_manifest
  validate_managed_toolchain

  if [[ -d "$payload_root/agents-skills/herdr-coordination" ]]; then
    if grep -RqsE 'C:\\|USERPROFILE|-WindowStyle|@echo off|\.cmd\b' "$payload_root/agents-skills/herdr-coordination"; then
      echo 'BLOCKED: herdr-coordination still contains Windows-specific behavior.' >&2
      echo 'Port it and run its regression suite under native Ubuntu pwsh before installing the agents skill payload.' >&2
      exit 30
    fi
  fi

  stage_root="$(mktemp -d "$state_dir/.payload-stage.XXXXXX")"
  install_transaction_guard
  mkdir -p "$stage_root/agents-skills" "$stage_root/claude-skills"
  cp -a "$agents_source"/. "$stage_root/agents-skills"/
  cp -a "$claude_source"/. "$stage_root/claude-skills"/
  verify_payload_roots "$stage_root/agents-skills" "$stage_root/claude-skills" staged
  test_pause before-commit
  revalidate_source_and_stage
  validate_managed_toolchain

  backup_root="$(mktemp -d "$state_dir/.payload-backup.XXXXXX")"
  agents_had_original=0
  claude_had_original=0
  agents_new=0
  claude_new=0
  receipt_had_original=0
  receipt_touched=0
  prepare_receipt_backup

  if [[ -e "$agents_destination" || -L "$agents_destination" ]]; then
    agents_had_original=1
    if ! mv -- "$agents_destination" "$backup_root/agents-skills"; then
      fail_closed 'could not reserve agents-skills without leaving a partial installation.'
    fi
  fi
  test_failure after-agents-backup
  if [[ -e "$claude_destination" || -L "$claude_destination" ]]; then
    claude_had_original=1
    if ! mv -- "$claude_destination" "$backup_root/claude-skills"; then
      fail_closed 'could not reserve claude-skills without leaving a partial installation.'
    fi
  fi
  agents_new=1
  if ! mkdir -p "$(dirname "$agents_destination")" || ! mv -- "$stage_root/agents-skills" "$agents_destination"; then
    fail_closed 'could not stage agents-skills without leaving a partial installation.'
  fi
  test_failure after-agents-commit
  claude_new=1
  if ! mkdir -p "$(dirname "$claude_destination")" || ! mv -- "$stage_root/claude-skills" "$claude_destination"; then
    fail_closed 'could not stage claude-skills without leaving a partial installation.'
  fi

  if ! (verify_installed_payload); then
    fail_closed 'installed payload hash verification failed; previous destinations were restored.'
  fi
  if ! validate_managed_toolchain; then
    fail_closed 'managed toolchain changed during payload installation; previous destinations were restored.'
  fi
  if ! write_runtime_receipt || ! validate_written_receipt; then
    fail_closed 'runtime receipt could not be produced; previous destinations were restored.'
  fi
  sync -f "$agents_destination" 2>/dev/null || true
  sync -f "$claude_destination" 2>/dev/null || true
  sync -f "$payload_receipt" 2>/dev/null || true
  cleanup_transaction_residue || fail_closed 'transaction residue could not be removed.'
  transaction_guard_enabled=0
  trap - EXIT HUP INT TERM
  echo "Payload installed from clean commit $source_commit. Runtime receipt: $payload_receipt"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
