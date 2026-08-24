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
  'payload/agents-skills/herdr-coordination/scripts/test_herdr_workflow_empty_ledger.ps1'
  'payload/agents-skills/herdr-coordination/scripts/test_herdr_workflow_profile_reporting.ps1'
  'payload/agents-skills/herdr-coordination/scripts/test_ubuntu_portability.ps1'
  'payload/agents-skills/st-herdr-dispatch/scripts/test_st_herdr_dispatch.ps1'
)

source_commit=''
source_commit_before_transaction=''
stage_root=''
backup_root=''
transaction_root=''
transaction_root_anchor=''
transaction_state_file=''
transaction_display_root=''
transaction_display_state_file=''
transaction_display_backup_root=''
transaction_id=''
transaction_phase=''
transaction_owner_uid=''
transaction_state_untrusted=0
transaction_recovery_required=0
transaction_recovery_mode=0
agents_had_original=0
claude_had_original=0
agents_new=0
claude_new=0
receipt_had_original=0
receipt_touched=0
agents_backup_present=0
claude_backup_present=0
receipt_backup_present=0
agents_backup_pending=0
claude_backup_pending=0
receipt_backup_pending=0
agents_publish_pending=0
claude_publish_pending=0
receipt_publish_pending=0
transaction_guard_enabled=0
transaction_backups_ready=0
transaction_committed=0
transaction_rolled_back=0
rollback_in_progress=0
lock_fd=''
receipt_tmp=''
state_dir_fd=''
state_dir_anchor=''
agents_parent_fd=''
agents_parent_path=''
agents_destination_anchor=''
claude_parent_fd=''
claude_parent_path=''
claude_destination_anchor=''

fail_closed() {
  echo "BLOCKED: $*" >&2
  exit 31
}

path_is_under() {
  local child="$1"
  local parent="$2"
  [[ "$child" == "$parent" || "$child" == "$parent/"* ]]
}

payload_version_at_least() {
  local actual="$1"
  local floor="$2"
  local sorted
  local lowest
  [[ "$actual" =~ ^[0-9]+([.][0-9]+)*$ && "$floor" =~ ^[0-9]+([.][0-9]+)*$ ]] || return 1
  sorted="$(printf '%s\n%s\n' "$floor" "$actual" | LC_ALL=C sort -V)"
  lowest="${sorted%%$'\n'*}"
  [[ "$lowest" == "$floor" ]]
}

payload_version_greater() {
  payload_version_at_least "$1" "$2" && [[ "$1" != "$2" ]]
}

path_present() {
  [[ -e "$1" || -L "$1" ]]
}

transaction_state_keys=(
  state_version transaction_id owner_uid home_real state_dir repo_root source_commit
  manifest_sha256 transaction_root stage_root backup_root state_file
  agents_destination claude_destination payload_receipt phase
  agents_had_original claude_had_original receipt_had_original
  agents_backup_present claude_backup_present receipt_backup_present
  agents_backup_pending claude_backup_pending receipt_backup_pending
  agents_publish_pending claude_publish_pending receipt_publish_pending
  agents_new claude_new receipt_touched
)

write_transaction_state() {
  local phase="$1"
  local state_tmp
  transaction_phase="$phase"
  [[ -n "$transaction_root_anchor" && -n "$transaction_state_file" ]] || return 1
  if ! state_tmp="$(mktemp "$transaction_root_anchor/.state.tmp.XXXXXX" 2>/dev/null)"; then
    transaction_state_untrusted=1
    return 1
  fi
  if ! {
    printf 'state_version=issue-961-payload-transaction-v1\n'
    printf 'transaction_id=%s\n' "$transaction_id"
    printf 'owner_uid=%s\n' "$(id -u)"
    printf 'home_real=%s\n' "$home_real"
    printf 'state_dir=%s\n' "$state_dir"
    printf 'repo_root=%s\n' "$repo_root"
    printf 'source_commit=%s\n' "$source_commit"
    printf 'manifest_sha256=%s\n' "$manifest_sha256"
    printf 'transaction_root=%s\n' "$transaction_display_root"
    printf 'stage_root=%s\n' "$transaction_display_root/stage"
    printf 'backup_root=%s\n' "$transaction_display_backup_root"
    printf 'state_file=%s\n' "$transaction_display_state_file"
    printf 'agents_destination=%s\n' "$agents_destination"
    printf 'claude_destination=%s\n' "$claude_destination"
    printf 'payload_receipt=%s\n' "$payload_receipt"
    printf 'phase=%s\n' "$phase"
    printf 'agents_had_original=%s\n' "$agents_had_original"
    printf 'claude_had_original=%s\n' "$claude_had_original"
    printf 'receipt_had_original=%s\n' "$receipt_had_original"
    printf 'agents_backup_present=%s\n' "$agents_backup_present"
    printf 'claude_backup_present=%s\n' "$claude_backup_present"
    printf 'receipt_backup_present=%s\n' "$receipt_backup_present"
    printf 'agents_backup_pending=%s\n' "$agents_backup_pending"
    printf 'claude_backup_pending=%s\n' "$claude_backup_pending"
    printf 'receipt_backup_pending=%s\n' "$receipt_backup_pending"
    printf 'agents_publish_pending=%s\n' "$agents_publish_pending"
    printf 'claude_publish_pending=%s\n' "$claude_publish_pending"
    printf 'receipt_publish_pending=%s\n' "$receipt_publish_pending"
    printf 'agents_new=%s\n' "$agents_new"
    printf 'claude_new=%s\n' "$claude_new"
    printf 'receipt_touched=%s\n' "$receipt_touched"
  } > "$state_tmp"; then
    rm -f -- "$state_tmp"
    transaction_state_untrusted=1
    return 1
  fi
  if ! chmod 0600 -- "$state_tmp" || ! mv -T -- "$state_tmp" "$transaction_state_file"; then
    rm -f -- "$state_tmp"
    transaction_state_untrusted=1
    return 1
  fi
  sync -f "$transaction_state_file" 2>/dev/null || true
  transaction_state_untrusted=0
}

create_transaction() {
  local transaction_root_created
  fence_require_directory "$state_dir" "$state_dir_fd" 'payload transaction state directory'
  if ! transaction_root_anchor="$(mktemp -d "$state_dir_anchor/.payload-transaction.XXXXXX")"; then
    fail_closed 'could not create the payload transaction journal.'
  fi
  transaction_id="${transaction_root_anchor##*/}"
  transaction_display_root="$state_dir/$transaction_id"
  transaction_root="$transaction_display_root"
  transaction_display_state_file="$transaction_display_root/state"
  transaction_display_backup_root="$transaction_display_root/backup"
  transaction_state_file="$transaction_root_anchor/state"
  stage_root="$transaction_root_anchor/stage"
  backup_root="$transaction_root_anchor/backup"
  transaction_root_created=1
  if ! chmod 0700 -- "$transaction_root_anchor" ||
    ! mkdir -- "$stage_root" "$backup_root" ||
    ! chmod 0700 -- "$stage_root" "$backup_root"; then
    (( transaction_root_created == 1 )) && rm -rf -- "$transaction_root_anchor"
    fail_closed "could not initialize the payload transaction journal: $transaction_display_root"
  fi
  transaction_owner_uid="$(id -u)"
  transaction_phase='staging'
  transaction_state_untrusted=0
  manifest_sha256="$(sha256sum "$manifest_file" | awk '{print $1}')"
  if ! write_transaction_state staging; then
    rm -rf -- "$transaction_root_anchor"
    fail_closed "could not persist the payload transaction journal: $transaction_display_root"
  fi
}

load_transaction_state() {
  local candidate_root="$1"
  local line
  local key
  local value
  local state_mode
  local root_mode
  local backup_mode
  local stage_mode
  local -A values=()

  [[ -d "$candidate_root" && ! -L "$candidate_root" ]] || {
    fail_closed "incomplete payload transaction is not a real directory: $candidate_root"
  }
  root_mode="$(stat -c '%a' -- "$candidate_root" 2>/dev/null || true)"
  [[ "$(stat -c '%u' -- "$candidate_root" 2>/dev/null || true)" == "$(id -u)" && "$root_mode" == 700 ]] || {
    fail_closed "incomplete payload transaction has unsafe ownership or permissions: $candidate_root"
  }

  transaction_root_anchor="$candidate_root"
  transaction_id="${candidate_root##*/}"
  [[ "$transaction_id" =~ ^\.payload-transaction\.[A-Za-z0-9]+$ ]] || {
    fail_closed "incomplete payload transaction has an invalid identity: $candidate_root"
  }
  transaction_display_root="$state_dir/$transaction_id"
  transaction_root="$transaction_display_root"
  transaction_state_file="$transaction_root_anchor/state"
  transaction_display_state_file="$transaction_display_root/state"
  transaction_display_backup_root="$transaction_display_root/backup"
  stage_root="$transaction_root_anchor/stage"
  backup_root="$transaction_root_anchor/backup"
  [[ -f "$transaction_state_file" && ! -L "$transaction_state_file" ]] || {
    fail_closed "incomplete payload transaction has no trusted journal: $transaction_display_root"
  }
  state_mode="$(stat -c '%a' -- "$transaction_state_file" 2>/dev/null || true)"
  [[ "$(stat -c '%u' -- "$transaction_state_file" 2>/dev/null || true)" == "$(id -u)" && "$state_mode" == 600 ]] || {
    fail_closed "incomplete payload transaction journal has unsafe ownership or permissions: $transaction_display_state_file"
  }

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^([a-z0-9_]+)=(.*)$ ]] || {
      fail_closed "malformed payload transaction journal: $transaction_display_state_file"
    }
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    case "$key" in
      state_version|transaction_id|owner_uid|home_real|state_dir|repo_root|source_commit|manifest_sha256|\
      transaction_root|stage_root|backup_root|state_file|agents_destination|claude_destination|payload_receipt|phase|\
      agents_had_original|claude_had_original|receipt_had_original|agents_backup_present|claude_backup_present|\
      receipt_backup_present|agents_backup_pending|claude_backup_pending|receipt_backup_pending|agents_publish_pending|\
      claude_publish_pending|receipt_publish_pending|agents_new|claude_new|receipt_touched) ;;
      *) fail_closed "unknown payload transaction journal key: $key" ;;
    esac
    [[ -z "${values[$key]+present}" ]] || fail_closed "duplicate payload transaction journal key: $key"
    values["$key"]="$value"
  done < "$transaction_state_file"

  local required_key
  for required_key in "${transaction_state_keys[@]}"; do
    [[ -n "${values[$required_key]+present}" ]] || {
      fail_closed "missing payload transaction journal key: $required_key"
    }
  done

  [[ "${values[state_version]}" == 'issue-961-payload-transaction-v1' ]] || fail_closed 'unsupported payload transaction journal version.'
  [[ "${values[transaction_id]}" == "$transaction_id" ]] || fail_closed 'payload transaction journal identity mismatch.'
  [[ "${values[owner_uid]}" == "$(id -u)" ]] || fail_closed "payload transaction is owned by another uid: $transaction_display_root"
  [[ "${values[home_real]}" == "$home_real" ]] || fail_closed "payload transaction belongs to another HOME: $transaction_display_root"
  [[ "${values[state_dir]}" == "$state_dir" && "${values[repo_root]}" == "$repo_root" ]] || fail_closed "payload transaction ownership path mismatch: $transaction_display_root"
  [[ "${values[transaction_root]}" == "$transaction_display_root" &&
    "${values[stage_root]}" == "$transaction_display_root/stage" &&
    "${values[backup_root]}" == "$transaction_display_root/backup" &&
    "${values[state_file]}" == "$transaction_display_root/state" ]] || {
    fail_closed "payload transaction journal path mismatch: $transaction_display_root"
  }
  [[ "${values[agents_destination]}" == "$agents_destination" &&
    "${values[claude_destination]}" == "$claude_destination" &&
    "${values[payload_receipt]}" == "$payload_receipt" ]] || {
    fail_closed "payload transaction destination ownership mismatch: $transaction_display_root"
  }
  [[ "${values[source_commit]}" =~ ^[0-9a-f]{40}$ && "${values[manifest_sha256]}" =~ ^[0-9a-f]{64}$ ]] || {
    fail_closed "payload transaction source identity is malformed: $transaction_display_root"
  }
  case "${values[phase]}" in
    staging|backing-up|publishing|writing-receipt|rollback-started|rollback-incomplete|committing|committed|rolled-back) ;;
    *) fail_closed "payload transaction journal phase is invalid: ${values[phase]}" ;;
  esac
  for required_key in agents_had_original claude_had_original receipt_had_original \
    agents_backup_present claude_backup_present receipt_backup_present \
    agents_backup_pending claude_backup_pending receipt_backup_pending \
    agents_publish_pending claude_publish_pending receipt_publish_pending \
    agents_new claude_new receipt_touched; do
    [[ "${values[$required_key]}" =~ ^[01]$ ]] || fail_closed "payload transaction journal flag is malformed: $required_key"
  done

  transaction_owner_uid="${values[owner_uid]}"
  source_commit="${values[source_commit]}"
  manifest_sha256="${values[manifest_sha256]}"
  transaction_phase="${values[phase]}"
  agents_had_original="${values[agents_had_original]}"
  claude_had_original="${values[claude_had_original]}"
  receipt_had_original="${values[receipt_had_original]}"
  agents_backup_present="${values[agents_backup_present]}"
  claude_backup_present="${values[claude_backup_present]}"
  receipt_backup_present="${values[receipt_backup_present]}"
  agents_backup_pending="${values[agents_backup_pending]}"
  claude_backup_pending="${values[claude_backup_pending]}"
  receipt_backup_pending="${values[receipt_backup_pending]}"
  agents_publish_pending="${values[agents_publish_pending]}"
  claude_publish_pending="${values[claude_publish_pending]}"
  receipt_publish_pending="${values[receipt_publish_pending]}"
  agents_new="${values[agents_new]}"
  claude_new="${values[claude_new]}"
  receipt_touched="${values[receipt_touched]}"
  transaction_state_untrusted=0
  transaction_backups_ready=1
  [[ -d "$backup_root" && ! -L "$backup_root" ]] || {
    [[ "$transaction_phase" == committed || "$transaction_phase" == rolled-back ]] || {
      fail_closed "incomplete payload transaction backup root is missing: $transaction_display_backup_root"
    }
  }
  if [[ -d "$backup_root" && ! -L "$backup_root" ]]; then
    backup_mode="$(stat -c '%a' -- "$backup_root" 2>/dev/null || true)"
    [[ "$(stat -c '%u' -- "$backup_root" 2>/dev/null || true)" == "$(id -u)" && "$backup_mode" == 700 ]] || {
      fail_closed "incomplete payload transaction backup root has unsafe ownership or permissions: $transaction_display_backup_root"
    }
  fi
  if [[ -e "$stage_root" || -L "$stage_root" ]]; then
    [[ -d "$stage_root" && ! -L "$stage_root" ]] || fail_closed "incomplete payload transaction stage root is unsafe: $transaction_display_root/stage"
    stage_mode="$(stat -c '%a' -- "$stage_root" 2>/dev/null || true)"
    [[ "$(stat -c '%u' -- "$stage_root" 2>/dev/null || true)" == "$(id -u)" && "$stage_mode" == 700 ]] || {
      fail_closed "incomplete payload transaction stage root has unsafe ownership or permissions: $transaction_display_root/stage"
    }
  fi
}

reconcile_pending_transaction_state() {
  local changed=0
  local backup_path
  local receipt_tmp_candidate

  if (( agents_backup_pending == 1 )); then
    backup_path="$backup_root/agents-skills"
    if path_present "$backup_path" && ! path_present "$agents_destination_anchor"; then
      agents_backup_pending=0
      agents_backup_present=1
    elif ! path_present "$backup_path" && path_present "$agents_destination_anchor"; then
      agents_backup_pending=0
      agents_backup_present=0
    else
      return 1
    fi
    changed=1
  fi
  if (( claude_backup_pending == 1 )); then
    backup_path="$backup_root/claude-skills"
    if path_present "$backup_path" && ! path_present "$claude_destination_anchor"; then
      claude_backup_pending=0
      claude_backup_present=1
    elif ! path_present "$backup_path" && path_present "$claude_destination_anchor"; then
      claude_backup_pending=0
      claude_backup_present=0
    else
      return 1
    fi
    changed=1
  fi
  if (( receipt_backup_pending == 1 )); then
    backup_path="$backup_root/payload-runtime-receipt.txt"
    if path_present "$backup_path" && ! path_present "$state_dir_anchor/payload-runtime-receipt.txt"; then
      receipt_backup_pending=0
      receipt_backup_present=1
    elif ! path_present "$backup_path" && path_present "$state_dir_anchor/payload-runtime-receipt.txt"; then
      receipt_backup_pending=0
      receipt_backup_present=0
    else
      return 1
    fi
    changed=1
  fi
  if (( agents_publish_pending == 1 )); then
    if path_present "$agents_destination_anchor" && ! path_present "$stage_root/agents-skills"; then
      agents_publish_pending=0
      agents_new=1
    elif ! path_present "$agents_destination_anchor" && path_present "$stage_root/agents-skills"; then
      agents_publish_pending=0
      agents_new=0
    elif (( transaction_recovery_mode == 1 )) && ! path_present "$agents_destination_anchor" && ! path_present "$stage_root/agents-skills"; then
      agents_publish_pending=0
      agents_new=0
    else
      return 1
    fi
    changed=1
  fi
  if (( claude_publish_pending == 1 )); then
    if path_present "$claude_destination_anchor" && ! path_present "$stage_root/claude-skills"; then
      claude_publish_pending=0
      claude_new=1
    elif ! path_present "$claude_destination_anchor" && path_present "$stage_root/claude-skills"; then
      claude_publish_pending=0
      claude_new=0
    elif (( transaction_recovery_mode == 1 )) && ! path_present "$claude_destination_anchor" && ! path_present "$stage_root/claude-skills"; then
      claude_publish_pending=0
      claude_new=0
    else
      return 1
    fi
    changed=1
  fi
  if (( receipt_publish_pending == 1 )); then
    receipt_tmp_candidate="$(find -L "$transaction_root_anchor" -maxdepth 1 -type f -name '.payload-runtime-receipt.*' -print -quit 2>/dev/null || true)"
    if path_present "$state_dir_anchor/payload-runtime-receipt.txt" && [[ -z "$receipt_tmp_candidate" ]]; then
      receipt_publish_pending=0
      receipt_touched=1
    elif ! path_present "$state_dir_anchor/payload-runtime-receipt.txt" && [[ -n "$receipt_tmp_candidate" ]]; then
      receipt_publish_pending=0
      receipt_touched=0
    elif (( transaction_recovery_mode == 1 )) && ! path_present "$state_dir_anchor/payload-runtime-receipt.txt" && [[ -z "$receipt_tmp_candidate" ]]; then
      receipt_publish_pending=0
      receipt_touched=0
    else
      return 1
    fi
    changed=1
  fi
  if (( changed == 1 )); then
    write_transaction_state "$transaction_phase" || return 1
  fi
}

recover_prior_transaction() {
  local candidate
  local candidate_list=''
  local -a candidates=()
  while IFS= read -r -d '' candidate; do
    candidates+=("$candidate")
    candidate_list+="${candidate_list:+,}$candidate"
  done < <(find -P "$state_dir_anchor/." -mindepth 1 -maxdepth 1 -name '.payload-transaction.*' -print0 2>/dev/null)
  (( ${#candidates[@]} == 0 )) && return 0
  (( ${#candidates[@]} == 1 )) || fail_closed "manual operator recovery required for multiple payload transactions; no transaction was selected or mutated; no-follow candidates=$candidate_list state_dir=$state_dir"

  load_transaction_state "${candidates[0]}"
  case "$transaction_phase" in
    committed|rolled-back)
      transaction_committed=1
      transaction_recovery_mode=1
      cleanup_transaction_residue || fail_closed "could not remove committed payload transaction residue; recover $transaction_display_root"
      transaction_recovery_mode=0
      ;;
    staging|backing-up|publishing|writing-receipt|committing|rollback-started|rollback-incomplete)
      fail_closed "manual operator recovery required for incomplete payload transaction; automatic restore and cleanup are disabled and no destination, backup, receipt, stage, cleanup, or new-transaction mutation was attempted: transaction=$transaction_display_root state=$transaction_display_state_file backup=$transaction_display_backup_root stage=$transaction_display_root/stage phase=$transaction_phase agents_destination=$agents_destination claude_destination=$claude_destination payload_receipt=$payload_receipt agents_new=$agents_new claude_new=$claude_new receipt_touched=$receipt_touched agents_backup_present=$agents_backup_present claude_backup_present=$claude_backup_present receipt_backup_present=$receipt_backup_present agents_backup_pending=$agents_backup_pending claude_backup_pending=$claude_backup_pending receipt_backup_pending=$receipt_backup_pending"
      ;;
    *)
      fail_closed "payload transaction has an unsupported recovery phase at $transaction_display_root"
      ;;
  esac
  transaction_root=''
  transaction_root_anchor=''
  transaction_state_file=''
  transaction_display_root=''
  transaction_display_state_file=''
  transaction_display_backup_root=''
  transaction_id=''
  stage_root=''
  backup_root=''
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

fence_components_safe() {
  local path="$1"
  local normalized
  local relative
  local component
  local component_path
  local -a components

  [[ "$path" == "$HOME" || "$path" == "$HOME/"* ]] || return 1
  normalized="$(realpath -m -- "$path" 2>/dev/null || true)"
  path_is_under "$normalized" "$home_real" || return 1
  [[ "$path" == "$HOME" ]] && return 0
  relative="${path#"$HOME"/}"
  component_path="$HOME"
  IFS='/' read -r -a components <<< "$relative"
  for component in "${components[@]}"; do
    [[ -z "$component" || "$component" == '.' ]] && continue
    [[ "$component" != '..' && "$component" != *'/'* ]] || return 1
    component_path="$component_path/$component"
    [[ ! -L "$component_path" ]] || return 1
  done
}

close_fence_fd() {
  local fd="$1"
  [[ "$fd" =~ ^[0-9]+$ ]] || return 0
  eval "exec ${fd}<&-" 2>/dev/null || true
}

fence_open_directory() {
  local path="$1"
  local output_name="$2"
  local relative
  local component
  local current
  local child
  local -a components
  local opened_fd
  local next_fd

  validate_user_home
  fence_components_safe "$path" || fail_closed "unsafe fenced directory: $path"
  exec {opened_fd}<"$HOME" || fail_closed "could not open fenced HOME directory."
  current="/proc/self/fd/$opened_fd"
  relative="${path#"$HOME"}"
  relative="${relative#/}"
  if [[ -n "$relative" ]]; then
    IFS='/' read -r -a components <<< "$relative"
    for component in "${components[@]}"; do
      [[ -n "$component" && "$component" != '.' && "$component" != '..' && "$component" != *'/'* ]] || {
        close_fence_fd "$opened_fd"
        fail_closed "unsafe fenced path component: $component"
      }
      child="$current/$component"
      [[ ! -L "$child" ]] || {
        close_fence_fd "$opened_fd"
        fail_closed "fenced directory contains a symlink: $path"
      }
      if [[ ! -e "$child" ]]; then
        mkdir -- "$child" || {
          close_fence_fd "$opened_fd"
          fail_closed "could not create fenced directory: $path"
        }
      fi
      [[ -d "$child" && ! -L "$child" ]] || {
        close_fence_fd "$opened_fd"
        fail_closed "fenced directory is not a real directory: $path"
      }
      exec {next_fd}<"$child" || {
        close_fence_fd "$opened_fd"
        fail_closed "could not open fenced directory: $path"
      }
      close_fence_fd "$opened_fd"
      opened_fd="$next_fd"
      current="/proc/self/fd/$opened_fd"
    done
  fi
  [[ -d "$current" ]] || {
    close_fence_fd "$opened_fd"
    fail_closed "fenced path is not a directory: $path"
  }
  printf -v "$output_name" '%s' "$opened_fd"
}

fence_directory_matches() {
  local path="$1"
  local fd="$2"
  local fd_id
  local live_id
  [[ "$fd" =~ ^[0-9]+$ ]] || return 1
  [[ -d "/proc/self/fd/$fd" ]] || return 1
  [[ ! -L "$path" ]] || return 1
  fence_components_safe "$path" || return 1
  fd_id="$(stat -Lc '%d:%i' -- "/proc/self/fd/$fd" 2>/dev/null || true)"
  live_id="$(stat -Lc '%d:%i' -- "$path" 2>/dev/null || true)"
  [[ -n "$fd_id" && "$fd_id" == "$live_id" ]]
}

fence_require_directory() {
  local path="$1"
  local fd="$2"
  local label="${3:-managed directory}"
  fence_directory_matches "$path" "$fd" || fail_closed "namespace drift detected for $label: $path"
}

fence_open_parent() {
  local path="$1"
  local fd_name="$2"
  local anchor_name="$3"
  local parent_name="$4"
  local parent="${path%/*}"
  local base="${path##*/}"
  local fd
  fence_open_directory "$parent" fd
  printf -v "$fd_name" '%s' "$fd"
  printf -v "$anchor_name" '/proc/self/fd/%s/%s' "$fd" "$base"
  printf -v "$parent_name" '%s' "$parent"
}

fence_require_parent() {
  fence_require_directory "$1" "$2" "${3:-managed parent}"
}

fence_test_pause() {
  local phase="$1"
  [[ "${HERDR_PAYLOAD_TEST_PAUSE_PHASE:-}" == "$phase" ]] || return 0
  [[ -n "${HERDR_PAYLOAD_TEST_READY_FILE:-}" && -n "${HERDR_PAYLOAD_TEST_CONTINUE_FILE:-}" ]] || {
    fail_closed "test pause is missing synchronization files: $phase"
  }
  : > "$HERDR_PAYLOAD_TEST_READY_FILE"
  while [[ ! -e "$HERDR_PAYLOAD_TEST_CONTINUE_FILE" ]]; do sleep 0.01; done
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
  for required_key in UV_VERSION UV_PLATFORM UV_URL UV_SHA256 PYTHON_VERSION PYTHON_RELEASE PYTHON_PLATFORM PYTHON_ARCHIVE PYTHON_URL PYTHON_SHA256 TAILSCALE_VERSION RUSTUP_VERSION RUST_TOOLCHAIN NODE_VERSION CODEX_VERSION CLAUDE_VERSION BUN_VERSION HERDR_VERSION POWERSHELL_VERSION; do
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
  [[ "$HERDR_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail_closed 'Toolchain lock Herdr version is not exact.'
  [[ "$HERDR_URL" == "https://github.com/herdrdev/herdr/releases/download/v$HERDR_VERSION/herdr-linux-x86_64" ]] || fail_closed 'Toolchain lock Herdr URL is inconsistent.'
  [[ "$HERDR_SHA256" =~ ^[0-9a-f]{64}$ ]] || fail_closed 'Toolchain lock Herdr checksum is not exact.'
  [[ "$TAILSCALE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail_closed 'Toolchain lock Tailscale version is not exact.'
  for version_key in RUSTUP_VERSION RUST_TOOLCHAIN NODE_VERSION CODEX_VERSION CLAUDE_VERSION BUN_VERSION HERDR_VERSION POWERSHELL_VERSION; do
    [[ "${!version_key}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail_closed "Toolchain lock version is not exact: $version_key"
  done
}

capture_receipt_command() {
  local key="$1"
  shift
  local output
  output="$("$@" 2>&1)" || fail_closed "toolchain receipt runtime probe failed: $key"
  [[ -n "$output" && "$output" != *$'\n'* ]] || fail_closed "toolchain receipt runtime probe was malformed: $key"
  expected_by_key["$key"]="$output"
}

capture_receipt_first_line() {
  local key="$1"
  shift
  local output
  output="$("$@" 2>&1)" || fail_closed "toolchain receipt runtime probe failed: $key"
  output="${output%%$'\n'*}"
  [[ -n "$output" && "$output" != *$'\n'* ]] || fail_closed "toolchain receipt runtime probe was malformed: $key"
  expected_by_key["$key"]="$output"
}

validate_locked_receipt_value() {
  local key="$1"
  local value="${expected_by_key[$key]}"
  local escaped_version
  case "$key" in
    rustup)
      escaped_version="${RUSTUP_VERSION//./\\.}"
      [[ "$value" =~ ^rustup[[:space:]]${escaped_version}([[:space:]]\([^[:space:]]+[[:space:]][0-9]{4}-[0-9]{2}-[0-9]{2}\))?$ ]] || fail_closed "rustup receipt value does not match the locked version contract."
      ;;
    rustc)
      escaped_version="${RUST_TOOLCHAIN//./\\.}"
      [[ "$value" =~ ^rustc[[:space:]]${escaped_version}([[:space:]]\([^[:space:]]+[[:space:]][0-9]{4}-[0-9]{2}-[0-9]{2}\))?$ ]] || fail_closed "rustc receipt value does not match the locked version contract."
      ;;
    node)
      [[ "$value" == "v$NODE_VERSION" ]] || fail_closed 'Node receipt value does not match the locked version contract.'
      ;;
    npm)
      [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]] || fail_closed 'npm receipt value is not a bounded semantic version.'
      ;;
    codex)
      escaped_version="${CODEX_VERSION//./\\.}"
      [[ "$value" =~ ^[^[:space:]]+[[:space:]]${escaped_version}$ ]] || fail_closed 'Codex receipt value does not match the locked version contract.'
      ;;
    claude)
      escaped_version="${CLAUDE_VERSION//./\\.}"
      [[ "$value" =~ ^${escaped_version}([[:space:]]+\([^()]+\))?$ ]] || fail_closed 'Claude receipt value does not match the locked version contract.'
      ;;
    bun)
      [[ "$value" == "$BUN_VERSION" ]] || fail_closed 'Bun receipt value does not match the locked version contract.'
      ;;
    herdr)
      [[ "$value" =~ ^[^[:space:]]+[[:space:]][0-9]+([.][0-9]+)*$ ]] || fail_closed 'Herdr receipt value is malformed.'
      payload_version_at_least "$(printf '%s\n' "$value" | awk '{print $NF}')" "$HERDR_VERSION" ||
        fail_closed 'Herdr receipt value is below the lock floor.'
      ;;
    powershell)
      [[ "$value" == "$POWERSHELL_VERSION" ]] || fail_closed 'PowerShell receipt value does not match the locked version contract.'
      ;;
  esac
}

append_apt_receipt_expectations() {
  local package
  local apt_line
  local apt_key
  local apt_value
  local apt_arch
  local -a apt_packages=(
    cifs-utils curl gawk git git-lfs gh jq mosh openssh-client openssh-server ripgrep rsync
  )
  for package in "${apt_packages[@]}"; do
    apt_line="$(dpkg-query -W -f='apt:${binary:Package}=${Version}\n' "$package" 2>/dev/null)" || fail_closed "unable to resolve locked APT receipt key: $package"
    [[ "$apt_line" != *$'\n'* && "$apt_line" == apt:* && "$apt_line" == *"="* ]] || fail_closed "malformed APT receipt value: $package"
    apt_key="${apt_line%%=*}"
    apt_value="${apt_line#*=}"
    if [[ "$apt_key" != "apt:$package" ]]; then
      apt_arch="${apt_key#apt:$package}"
      [[ "$apt_arch" =~ ^:[A-Za-z0-9_.+-]+$ ]] || fail_closed "unexpected locked APT receipt key: $apt_key"
    fi
    [[ -n "$apt_value" && "$apt_value" != *[[:space:]=]* ]] || fail_closed "malformed APT receipt version: $apt_key"
    required_keys+=("$apt_key")
    expected_by_key["$apt_key"]="$apt_value"
  done
}

validate_toolchain_receipt() {
  local receipt_path="$1"
  local line_number=0
  local line
  local key
  local value
  local expected
  local herdr_path
  local herdr_version
  local herdr_sha256
  local herdr_newer_than_lock=false
  local -a required_keys=(
    receipt_format lock_sha256 host_platform host_architecture
    uv_path python3.13_path py_path uv_version python3.13_version
    py_3.13_version py_3.13_probe uv_platform uv_url uv_sha256
    python_version python_platform python_release python_archive python_url python_sha256 tailscale
    rustup rustc node npm codex claude bun herdr herdr_version herdr_sha256 herdr_newer_than_lock powershell
  )
  local -A expected_by_key=()
  local -A seen_keys=()

  expected_by_key[receipt_format]='issue-961-toolchain-v2'
  expected_by_key[lock_sha256]="$(sha256sum "$toolchain_lock_file" | awk '{print $1}')"
  expected_by_key[host_platform]='linux'
  expected_by_key[host_architecture]='x86_64'
  expected_by_key[uv_path]="$HOME/.local/bin/uv"
  expected_by_key[python3.13_path]="$HOME/.local/bin/python3.13"
  expected_by_key[py_path]="$HOME/.local/bin/py"
  expected_by_key[uv_version]="uv $UV_VERSION ($UV_PLATFORM)"
  expected_by_key[python3.13_version]="Python $PYTHON_VERSION"
  expected_by_key[py_3.13_version]="Python $PYTHON_VERSION"
  expected_by_key[py_3.13_probe]="$PYTHON_VERSION|x86_64|linux"
  expected_by_key[uv_platform]="$UV_PLATFORM"
  expected_by_key[uv_url]="$UV_URL"
  expected_by_key[uv_sha256]="$UV_SHA256"
  expected_by_key[python_version]="$PYTHON_VERSION"
  expected_by_key[python_platform]="$PYTHON_PLATFORM"
  expected_by_key[python_release]="$PYTHON_RELEASE"
  expected_by_key[python_archive]="$PYTHON_ARCHIVE"
  expected_by_key[python_url]="$PYTHON_URL"
  expected_by_key[python_sha256]="$PYTHON_SHA256"
  expected_by_key[tailscale]="$TAILSCALE_VERSION"

  [[ -f "$receipt_path" && ! -L "$receipt_path" ]] || fail_closed "Missing bootstrap toolchain receipt: $receipt_path"
  for managed_tool in rustup rustc herdr; do
    validate_managed_tool "$managed_tool" "$HOME/.local/bin/$managed_tool"
  done
  for managed_tool in node npm codex claude bun; do
    validate_managed_node_tool "$managed_tool"
  done
  command -v pwsh >/dev/null 2>&1 || fail_closed 'PowerShell is not discoverable.'
  capture_receipt_first_line rustup rustup --version
  capture_receipt_command rustc rustc --version
  capture_receipt_command node node --version
  capture_receipt_command npm npm --version
  capture_receipt_command codex codex --version
  capture_receipt_command claude claude --version
  capture_receipt_command bun bun --version
  capture_receipt_command herdr herdr --version
  capture_receipt_command powershell pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
  herdr_path="$HOME/.local/bin/herdr"
  herdr_version="$(printf '%s\n' "${expected_by_key[herdr]}" | awk '{print $NF}')"
  [[ "$herdr_version" =~ ^[0-9]+([.][0-9]+)*$ ]] || fail_closed 'Herdr receipt version is malformed.'
  payload_version_at_least "$herdr_version" "$HERDR_VERSION" || fail_closed 'Herdr receipt value is below the lock floor.'
  herdr_sha256="$(sha256sum -- "$herdr_path" | awk '{print $1}')" || fail_closed 'Herdr digest probe failed.'
  [[ "$herdr_sha256" =~ ^[0-9a-f]{64}$ ]] || fail_closed 'Herdr digest probe was malformed.'
  if payload_version_greater "$herdr_version" "$HERDR_VERSION"; then
    herdr_newer_than_lock=true
  fi
  expected_by_key[herdr_version]="$herdr_version"
  expected_by_key[herdr_sha256]="$herdr_sha256"
  expected_by_key[herdr_newer_than_lock]="$herdr_newer_than_lock"
  for runtime_key in rustup rustc node npm codex claude bun herdr powershell; do
    validate_locked_receipt_value "$runtime_key"
  done
  append_apt_receipt_expectations
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_number=$((line_number + 1))
    [[ "$line" =~ ^([A-Za-z][A-Za-z0-9_.:-]*)=(.*)$ ]] || {
      fail_closed "malformed toolchain receipt line $line_number"
    }
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    [[ -n "${expected_by_key[$key]+present}" ]] || fail_closed "unknown toolchain receipt key: $key"
    [[ -z "${seen_keys[$key]+present}" ]] || fail_closed "duplicate toolchain receipt key: $key"
    expected="${expected_by_key[$key]}"
    [[ "$value" == "$expected" ]] || fail_closed "toolchain receipt mismatch: $key"
    seen_keys["$key"]=1
  done < "$receipt_path"
  for key in "${required_keys[@]}"; do
    [[ -n "${seen_keys[$key]+present}" ]] || fail_closed "missing toolchain receipt key: $key"
  done
  [[ "${#seen_keys[@]}" -eq "${#required_keys[@]}" ]] || fail_closed 'ambiguous toolchain receipt key set.'
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

validate_managed_node_tool() {
  local name="$1"
  local node_root="$HOME/.local/lib/node-v${NODE_VERSION}-linux-x64"
  validate_managed_tool "$name" "$HOME/.local/bin/$name"
  path_is_under "$resolved_path" "$node_root" || fail_closed "$name resolves outside the locked Node prefix: $resolved_path"
}

validate_managed_toolchain() {
  load_toolchain_lock
  [[ "$(uname -s)" == 'Linux' && "$(uname -m)" == 'x86_64' && "$(getconf LONG_BIT)" == '64' ]] || {
    fail_closed 'Managed toolchain host platform or architecture is unsupported.'
  }
  receipt_path="$toolchain_receipt"
  if [[ -n "$state_dir_fd" ]]; then
    fence_require_directory "$state_dir" "$state_dir_fd" 'toolchain receipt state directory'
    receipt_path="$state_dir_anchor/toolchain-manifest.txt"
  fi

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
  validate_toolchain_receipt "$receipt_path"

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
  if [[ -n "$agents_destination_anchor" && -n "$claude_destination_anchor" ]]; then
    verify_payload_roots "$agents_destination_anchor" "$claude_destination_anchor" installed
  else
    verify_payload_roots "$agents_destination" "$claude_destination" installed
  fi
}

write_runtime_receipt() {
  [[ "${HERDR_PAYLOAD_TEST_FAIL_RECEIPT_WRITE:-0}" != 1 ]] || return 1
  fence_require_directory "$state_dir" "$state_dir_fd" 'payload receipt state directory'
  receipt_publish_pending=1
  write_transaction_state writing-receipt || return 1
  receipt_tmp="$(mktemp "$transaction_root_anchor/.payload-runtime-receipt.XXXXXX")"
  manifest_sha256="$(sha256sum "$manifest_file" | awk '{print $1}')"
  if ! {
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
        agents-skills/*) installed_file="$agents_destination_anchor/${relative_path#agents-skills/}" ;;
        claude-skills/*) installed_file="$claude_destination_anchor/${relative_path#claude-skills/}" ;;
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
  } > "$receipt_tmp"; then
    return 1
  fi
  chmod 0644 "$receipt_tmp" || return 1
  fence_test_pause before-receipt-publish
  fence_require_directory "$state_dir" "$state_dir_fd" 'payload receipt state directory'
  if ! mv -T -- "$receipt_tmp" "$state_dir_anchor/payload-runtime-receipt.txt"; then
    return 1
  fi
  receipt_touched=1
  receipt_publish_pending=0
  rm -f "$receipt_tmp"
  receipt_tmp=''
  write_transaction_state writing-receipt || return 1
}

validate_written_receipt() {
  local receipt_path="$state_dir_anchor/payload-runtime-receipt.txt"
  [[ -s "$receipt_path" ]] || return 1
  grep -Fqx -- 'receipt_format=issue-961-payload-v1' "$receipt_path" || return 1
  grep -Fqx -- "source_commit=$source_commit" "$receipt_path" || return 1
  manifest_sha256="$(sha256sum "$manifest_file" | awk '{print $1}')"
  grep -Fqx -- "tracked_manifest_sha256=$manifest_sha256" "$receipt_path" || return 1
  grep -Fqx -- "installed_payload_file_count=${#manifest_paths[@]}" "$receipt_path" || return 1
}

rollback_transaction() {
  local rollback_status=0
  local old_recovery_mode
  (( rollback_in_progress == 1 )) && return 0
  (( transaction_backups_ready == 1 )) || return 0
  (( transaction_committed == 0 )) || return 0
  (( transaction_rolled_back == 1 )) && return 0
  rollback_in_progress=1
  old_recovery_mode="$transaction_recovery_mode"
  transaction_recovery_mode=1
  if ! write_transaction_state rollback-started || ! reconcile_pending_transaction_state; then
    transaction_recovery_required=1
    write_transaction_state rollback-incomplete || true
    rollback_in_progress=0
    transaction_recovery_mode="$old_recovery_mode"
    return 1
  fi

  rollback_remove_directory() {
    local destination="$1"
    local flag_name="$2"
    local current_value="${!flag_name}"
    (( current_value == 1 )) || return 0
    (( transaction_state_untrusted == 0 )) || return 1
    if path_present "$destination" && ! rm -rf -- "$destination"; then
      return 1
    fi
    printf -v "$flag_name" '%s' 0
    write_transaction_state rollback-started
  }

  rollback_remove_file() {
    local destination="$1"
    local flag_name="$2"
    local current_value="${!flag_name}"
    (( current_value == 1 )) || return 0
    (( transaction_state_untrusted == 0 )) || return 1
    if path_present "$destination" && ! rm -f -- "$destination"; then
      return 1
    fi
    printf -v "$flag_name" '%s' 0
    write_transaction_state rollback-started
  }

  rollback_restore() {
    local backup_path="$1"
    local destination="$2"
    local had_name="$3"
    local backup_name="$4"
    local had_value="${!had_name}"
    local backup_value="${!backup_name}"
    if (( had_value == 1 )); then
      if (( backup_value == 1 )); then
        path_present "$backup_path" || return 1
        path_present "$destination" && return 1
        (( transaction_state_untrusted == 0 )) || return 1
        mv -T -- "$backup_path" "$destination" || return 1
        printf -v "$backup_name" '%s' 0
        write_transaction_state rollback-started
      else
        path_present "$destination" || return 1
      fi
    else
      return 0
    fi
  }

  if ! rollback_remove_directory "$agents_destination_anchor" agents_new; then rollback_status=1; fi
  if ! rollback_remove_directory "$claude_destination_anchor" claude_new; then rollback_status=1; fi
  if ! rollback_restore "$backup_root/agents-skills" "$agents_destination_anchor" agents_had_original agents_backup_present; then rollback_status=1; fi
  if ! rollback_restore "$backup_root/claude-skills" "$claude_destination_anchor" claude_had_original claude_backup_present; then rollback_status=1; fi
  if ! rollback_remove_file "$state_dir_anchor/payload-runtime-receipt.txt" receipt_touched; then rollback_status=1; fi
  if ! rollback_restore "$backup_root/payload-runtime-receipt.txt" "$state_dir_anchor/payload-runtime-receipt.txt" receipt_had_original receipt_backup_present; then rollback_status=1; fi

  if (( rollback_status == 0 && transaction_state_untrusted == 0 )) &&
    (( agents_new == 0 && claude_new == 0 && receipt_touched == 0 &&
       agents_backup_present == 0 && claude_backup_present == 0 && receipt_backup_present == 0 &&
       agents_backup_pending == 0 && claude_backup_pending == 0 && receipt_backup_pending == 0 &&
       agents_publish_pending == 0 && claude_publish_pending == 0 && receipt_publish_pending == 0 )); then
    transaction_rolled_back=1
    transaction_recovery_required=0
    if ! write_transaction_state rolled-back; then
      transaction_recovery_required=1
      rollback_status=1
    fi
  else
    transaction_recovery_required=1
    write_transaction_state rollback-incomplete || true
    rollback_status=1
  fi
  rollback_in_progress=0
  transaction_recovery_mode="$old_recovery_mode"
  return "$rollback_status"
}

cleanup_transaction_residue() {
  local cleanup_status=0
  if (( transaction_recovery_required == 1 )); then
    echo "BLOCKED: incomplete rollback retained at $transaction_display_root; backup evidence: $transaction_display_backup_root" >&2
    return 1
  fi
  if (( transaction_backups_ready == 1 && transaction_committed == 0 && transaction_rolled_back == 0 )); then
    echo "BLOCKED: transaction backups retained at $transaction_display_backup_root until rollback completes." >&2
    return 1
  fi
  if (( transaction_committed == 1 )); then
    fence_test_pause during-backup-cleanup
  fi
  if [[ -n "$transaction_root_anchor" && -e "$transaction_root_anchor" ]]; then
    rm -rf -- "$transaction_root_anchor" || cleanup_status=1
  fi
  if (( transaction_committed == 1 )); then
    fence_test_pause after-backup-cleanup
  fi
  if (( cleanup_status == 0 )); then
    transaction_backups_ready=0
    receipt_tmp=''
  fi
  return "$cleanup_status"
}

transaction_exit_handler() {
  local status="$1"
  local rollback_status=0
  trap - EXIT HUP INT TERM
  if (( transaction_guard_enabled == 1 )); then
    transaction_guard_enabled=0
    if (( status != 0 && transaction_committed == 0 )); then
      rollback_transaction || rollback_status=1
    fi
    if (( rollback_status == 0 )); then
      cleanup_transaction_residue || echo "BLOCKED: transaction residue cleanup was incomplete; recover $transaction_display_root" >&2
    else
      echo "BLOCKED: incomplete rollback retained at $transaction_display_root; backup evidence: $transaction_display_backup_root" >&2
    fi
  fi
  return "$status"
}

install_transaction_guard() {
  transaction_guard_enabled=1
  transaction_committed=0
  transaction_rolled_back=0
  transaction_state_untrusted=0
  transaction_recovery_required=0
  transaction_recovery_mode=0
  trap 'transaction_exit_handler "$?"' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

commit_transaction() {
  write_transaction_state committing || return 1
  transaction_committed=1
  if ! write_transaction_state committed; then
    transaction_committed=0
    return 1
  fi
  transaction_guard_enabled=0
  fence_test_pause between-rollback-disarm-and-trap-removal
  test_failure between-rollback-disarm-and-trap-removal
  trap - EXIT HUP INT TERM
  fence_test_pause after-trap-removal
  test_failure after-trap-removal
}

test_pause() {
  fence_test_pause "$1"
}

test_failure() {
  local phase="$1"
  [[ "${HERDR_PAYLOAD_TEST_FAIL_PHASE:-}" == "$phase" ]] || return 0
  fail_closed "injected transaction failure: $phase"
}

acquire_install_lock() {
  fence_require_directory "$state_dir" "$state_dir_fd" 'payload lock state directory'
  [[ ! -L "$state_dir_anchor/payload-install.lock" ]] || fail_closed "payload lock is a symlink: $lock_file"
  exec {lock_fd}>"$state_dir_anchor/payload-install.lock" || fail_closed "could not open per-user payload lock: $lock_file"
  if ! flock -n "$lock_fd"; then
    fail_closed 'another payload installation is already in progress.'
  fi
  test_pause lock-acquired
}

prepare_receipt_backup() {
  fence_require_directory "$state_dir" "$state_dir_fd" 'payload receipt state directory'
  if [[ -e "$state_dir_anchor/payload-runtime-receipt.txt" || -L "$state_dir_anchor/payload-runtime-receipt.txt" ]]; then
    receipt_had_original=1
    receipt_backup_pending=1
    write_transaction_state backing-up || fail_closed 'could not journal the existing payload receipt reservation.'
    if ! mv -T -- "$state_dir_anchor/payload-runtime-receipt.txt" "$backup_root/payload-runtime-receipt.txt"; then
      fail_closed 'could not reserve the existing payload receipt.'
    fi
    receipt_backup_pending=0
    receipt_backup_present=1
    write_transaction_state backing-up || fail_closed 'could not journal the existing payload receipt backup.'
  else
    receipt_had_original=0
    receipt_backup_pending=0
    receipt_backup_present=0
    write_transaction_state backing-up || fail_closed 'could not journal the absent payload receipt.'
  fi
}

revalidate_source_and_stage() {
  source_commit_before_transaction="$source_commit"
  ensure_source_clean
  [[ "$source_commit" == "$source_commit_before_transaction" ]] || fail_closed 'payload source commit drifted after staging.'
  validate_payload_manifest
  verify_payload_roots "$stage_root/agents-skills" "$stage_root/claude-skills" staged
}

run_herdr_portability_validator() {
  local validator_path="$payload_root/agents-skills/herdr-coordination/scripts/test_ubuntu_portability.ps1"
  local validator_output=''
  local validator_status=0

  [[ -f "$validator_path" && ! -L "$validator_path" ]] || {
    fail_closed "herdr-coordination Ubuntu portability validator is missing: $validator_path"
  }
  validator_output="$(pwsh -NoProfile -File "$validator_path" 2>&1)" || validator_status=$?
  if (( validator_status != 0 )); then
    echo "BLOCKED: herdr-coordination Ubuntu portability validator failed (exit $validator_status)." >&2
    echo "Run: pwsh -NoProfile -File $validator_path" >&2
    if [[ -n "$validator_output" ]]; then
      printf '%s\n' "$validator_output" | tail -n 8 >&2
    else
      echo 'Static validator produced no diagnostic output.' >&2
    fi
    exit 30
  fi
}

main() {
  validate_destination_safety
  fence_open_directory "$state_dir" state_dir_fd
  state_dir_anchor="/proc/self/fd/$state_dir_fd"
  fence_require_directory "$state_dir" "$state_dir_fd" 'payload state directory'
  validate_destination_safety
  acquire_install_lock
  recover_prior_transaction

  ensure_source_clean
  validate_payload_manifest
  validate_managed_toolchain

  if [[ -d "$payload_root/agents-skills/herdr-coordination" ]]; then
    run_herdr_portability_validator
  fi

  fence_require_directory "$state_dir" "$state_dir_fd" 'payload state directory'
  create_transaction
  install_transaction_guard
  mkdir -- "$stage_root/agents-skills" "$stage_root/claude-skills"
  cp -a "$agents_source"/. "$stage_root/agents-skills"/
  cp -a "$claude_source"/. "$stage_root/claude-skills"/
  verify_payload_roots "$stage_root/agents-skills" "$stage_root/claude-skills" staged
  test_pause before-commit
  revalidate_source_and_stage
  validate_managed_toolchain

  fence_require_directory "$state_dir" "$state_dir_fd" 'payload state directory'
  transaction_backups_ready=1
  agents_had_original=0
  claude_had_original=0
  agents_new=0
  claude_new=0
  receipt_had_original=0
  receipt_touched=0
  agents_backup_present=0
  claude_backup_present=0
  receipt_backup_present=0
  agents_backup_pending=0
  claude_backup_pending=0
  receipt_backup_pending=0
  agents_publish_pending=0
  claude_publish_pending=0
  receipt_publish_pending=0
  write_transaction_state backing-up || fail_closed 'could not persist the payload transaction backup state.'
  prepare_receipt_backup

  fence_open_parent "$agents_destination" agents_parent_fd agents_destination_anchor agents_parent_path
  fence_open_parent "$claude_destination" claude_parent_fd claude_destination_anchor claude_parent_path
  fence_test_pause before-destination-mutations
  fence_require_parent "$agents_parent_path" "$agents_parent_fd" 'agents destination parent'
  fence_require_parent "$claude_parent_path" "$claude_parent_fd" 'claude destination parent'

  if [[ -e "$agents_destination_anchor" || -L "$agents_destination_anchor" ]]; then
    agents_had_original=1
    agents_backup_pending=1
    write_transaction_state backing-up || fail_closed 'could not journal the agents-skills backup reservation.'
    fence_test_pause before-agents-backup
    fence_require_parent "$agents_parent_path" "$agents_parent_fd" 'agents destination parent'
    if ! mv -T -- "$agents_destination_anchor" "$backup_root/agents-skills"; then
      fail_closed 'could not reserve agents-skills without leaving a partial installation.'
    fi
    agents_backup_pending=0
    agents_backup_present=1
    write_transaction_state backing-up || fail_closed 'could not journal the agents-skills backup.'
    fence_require_parent "$agents_parent_path" "$agents_parent_fd" 'agents destination parent'
  else
    agents_had_original=0
    write_transaction_state backing-up || fail_closed 'could not journal the absent agents-skills destination.'
  fi
  test_pause after-agents-backup
  test_failure after-agents-backup
  if [[ -e "$claude_destination_anchor" || -L "$claude_destination_anchor" ]]; then
    claude_had_original=1
    claude_backup_pending=1
    write_transaction_state backing-up || fail_closed 'could not journal the claude-skills backup reservation.'
    fence_test_pause before-claude-backup
    fence_require_parent "$claude_parent_path" "$claude_parent_fd" 'claude destination parent'
    if ! mv -T -- "$claude_destination_anchor" "$backup_root/claude-skills"; then
      fail_closed 'could not reserve claude-skills without leaving a partial installation.'
    fi
    claude_backup_pending=0
    claude_backup_present=1
    write_transaction_state backing-up || fail_closed 'could not journal the claude-skills backup.'
    fence_require_parent "$claude_parent_path" "$claude_parent_fd" 'claude destination parent'
  else
    claude_had_original=0
    write_transaction_state backing-up || fail_closed 'could not journal the absent claude-skills destination.'
  fi
  agents_publish_pending=1
  write_transaction_state publishing || fail_closed 'could not journal the agents-skills publication.'
  fence_test_pause before-agents-publish
  fence_require_parent "$agents_parent_path" "$agents_parent_fd" 'agents destination parent'
  if ! mv -T -- "$stage_root/agents-skills" "$agents_destination_anchor"; then
    fail_closed 'could not stage agents-skills without leaving a partial installation.'
  fi
  agents_publish_pending=0
  agents_new=1
  write_transaction_state publishing || fail_closed 'could not journal the agents-skills publication.'
  fence_require_parent "$agents_parent_path" "$agents_parent_fd" 'agents destination parent'
  test_pause after-agents-commit
  test_failure after-agents-commit
  claude_publish_pending=1
  write_transaction_state publishing || fail_closed 'could not journal the claude-skills publication.'
  fence_test_pause before-claude-publish
  fence_require_parent "$claude_parent_path" "$claude_parent_fd" 'claude destination parent'
  if ! mv -T -- "$stage_root/claude-skills" "$claude_destination_anchor"; then
    fail_closed 'could not stage claude-skills without leaving a partial installation.'
  fi
  claude_publish_pending=0
  claude_new=1
  write_transaction_state publishing || fail_closed 'could not journal the claude-skills publication.'
  fence_require_parent "$claude_parent_path" "$claude_parent_fd" 'claude destination parent'
  test_pause after-claude-commit
  test_failure after-claude-commit

  if ! (verify_installed_payload); then
    fail_closed 'installed payload hash verification failed; previous destinations were restored.'
  fi
  if ! validate_managed_toolchain; then
    fail_closed 'managed toolchain changed during payload installation; previous destinations were restored.'
  fi
  if ! write_runtime_receipt || ! validate_written_receipt; then
    fail_closed 'runtime receipt could not be produced; previous destinations were restored.'
  fi
  test_pause after-receipt-completion
  sync -f "$agents_destination_anchor" 2>/dev/null || true
  sync -f "$claude_destination_anchor" 2>/dev/null || true
  sync -f "$state_dir_anchor/payload-runtime-receipt.txt" 2>/dev/null || true
  fence_require_parent "$agents_parent_path" "$agents_parent_fd" 'agents destination parent'
  fence_require_parent "$claude_parent_path" "$claude_parent_fd" 'claude destination parent'
  fence_require_directory "$state_dir" "$state_dir_fd" 'payload state directory'
  commit_transaction || fail_closed 'payload commit was not durably journaled; previous state was retained.'
  fence_test_pause before-cleanup
  test_failure before-cleanup
  cleanup_transaction_residue || fail_closed "transaction residue could not be removed; recover $transaction_display_root"
  close_fence_fd "$agents_parent_fd"
  close_fence_fd "$claude_parent_fd"
  close_fence_fd "$state_dir_fd"
  echo "Payload installed from clean commit $source_commit. Runtime receipt: $payload_receipt"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
