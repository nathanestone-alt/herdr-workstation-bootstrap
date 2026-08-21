#!/usr/bin/bash
set -euo pipefail

# Receipt authority is also an entrypoint.  Its live sibling helper is never
# sourced: first bind the helper to either the local committed Git blob or an
# already verified root payload, then source only a private materialization.
readonly receipt_trusted_path='/usr/sbin:/usr/bin:/sbin:/bin'
readonly receipt_env_bin='/usr/bin/env'
readonly receipt_git_bin='/usr/bin/git'
readonly receipt_realpath_bin='/usr/bin/realpath'
readonly receipt_dirname_bin='/usr/bin/dirname'
readonly receipt_find_bin='/usr/bin/find'
readonly receipt_mktemp_bin='/usr/bin/mktemp'
readonly receipt_chmod_bin='/usr/bin/chmod'
readonly receipt_stat_bin='/usr/bin/stat'
readonly receipt_sha256_bin='/usr/bin/sha256sum'
readonly receipt_awk_bin='/usr/bin/gawk'
readonly receipt_head_bin='/usr/bin/head'
readonly receipt_cp_bin='/usr/bin/cp'
readonly receipt_rm_bin='/usr/bin/rm'

export PATH="$receipt_trusted_path"
export LC_ALL=C
export TZ=UTC
while IFS= read -r receipt_env_name; do
  case "$receipt_env_name" in
    GIT_DIR|GIT_WORK_TREE|GIT_INDEX_FILE|GIT_OBJECT_DIRECTORY|GIT_ALTERNATE_OBJECT_DIRECTORIES|GIT_COMMON_DIR|GIT_CONFIG_*)
      echo "receipt authority trust prelude: caller Git environment override is not permitted: $receipt_env_name" >&2
      exit 24
      ;;
  esac
done < <(compgen -e)
unset BASH_ENV ENV CDPATH GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_CONFIG_PARAMETERS
while IFS= read -r receipt_env_name; do
  case "$receipt_env_name" in
    GIT_*) unset "$receipt_env_name" ;;
  esac
done < <(compgen -e)

receipt_trust_fail() {
  echo "receipt authority trust prelude: $*" >&2
  exit 24
}

receipt_trust_reject_symlink_components() {
  local path="$1"
  local current='/'
  local component
  local -a components
  [[ "$path" == /* ]] || return 1
  IFS='/' read -r -a components <<< "${path#/}"
  for component in "${components[@]}"; do
    [[ -z "$component" || "$component" == '.' ]] && continue
    [[ "$component" != '..' && "$component" != *'/'* ]] || return 1
    current="$current/$component"
    [[ ! -L "$current" ]] || return 1
  done
}

receipt_trust_assert_binary() {
  local path="$1"
  local resolved mode
  [[ -f "$path" && ! -L "$path" && -x "$path" ]] || {
    receipt_trust_fail "trusted binary is missing or not a regular executable: $path"
  }
  resolved="$($receipt_realpath_bin -e -- "$path" 2>/dev/null || true)"
  [[ "$resolved" == "$path" ]] || receipt_trust_fail "trusted binary is not canonical: $path -> $resolved"
  mode="$($receipt_stat_bin -c '%a' -- "$path" 2>/dev/null || true)"
  [[ "$mode" =~ ^[0-7]+$ && $((8#$mode & 022)) == 0 ]] || {
    receipt_trust_fail "trusted binary is writable by group or other users: $path"
  }
}

for receipt_trusted_binary in \
  "$receipt_env_bin" "$receipt_realpath_bin" "$receipt_dirname_bin" \
  "$receipt_find_bin" "$receipt_mktemp_bin" "$receipt_chmod_bin" \
  "$receipt_stat_bin" "$receipt_sha256_bin" "$receipt_awk_bin" \
  "$receipt_head_bin" "$receipt_cp_bin" "$receipt_rm_bin"; do
  receipt_trust_assert_binary "$receipt_trusted_binary"
done

receipt_trust_git() {
  "$receipt_env_bin" -i \
    HOME=/nonexistent \
    PATH="$receipt_trusted_path" \
    LC_ALL=C \
    TZ=UTC \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_SYSTEM=/dev/null \
    GIT_CONFIG_COUNT=0 \
    "$receipt_git_bin" --no-replace-objects \
    -C "$receipt_repo_root" --git-dir="${receipt_git_dir:-.git}" --work-tree=. \
    -c core.attributesfile=/dev/null \
    -c core.excludesfile=/dev/null \
    -c core.hooksPath=/dev/null \
    -c core.filemode=true \
    -c core.ignoreCase=false \
    "$@"
}

receipt_canonical_git_storage_path() {
  local path="$1"
  [[ "$path" == /* ]] || path="$receipt_repo_root/$path"
  receipt_trust_reject_symlink_components "$path" || return 1
  [[ -e "$path" && ! -L "$path" ]] || return 1
  printf '%s\n' "$path"
}

receipt_materialize_helper_from_git() {
  receipt_trust_assert_binary "$receipt_git_bin"
  [[ -e "$receipt_repo_root/.git" && ! -L "$receipt_repo_root/.git" && \
    ( -d "$receipt_repo_root/.git" || -f "$receipt_repo_root/.git" ) ]] || {
    receipt_trust_fail 'receipt repository metadata is missing or unsafe'
  }
  if [[ -d "$receipt_repo_root/.git" ]]; then
    receipt_git_dir="$receipt_repo_root/.git"
    receipt_common_git_dir="$receipt_git_dir"
  else
    receipt_git_pointer="$(< "$receipt_repo_root/.git")"
    [[ "$receipt_git_pointer" != *$'\n'* && "$receipt_git_pointer" != *$'\r'* && \
      "$receipt_git_pointer" == gitdir:\ /* ]] || receipt_trust_fail 'receipt Git pointer cannot be read safely'
    receipt_git_pointer_path="${receipt_git_pointer#gitdir: }"
    receipt_git_dir="$($receipt_realpath_bin -e -- "$receipt_git_pointer_path" 2>/dev/null || true)"
    [[ -n "$receipt_git_dir" && "$receipt_git_pointer" == "gitdir: $receipt_git_dir" ]] || receipt_trust_fail 'receipt Git pointer is not canonical'
    [[ -d "$receipt_git_dir" && ! -L "$receipt_git_dir" && \
      -f "$receipt_git_dir/commondir" && ! -L "$receipt_git_dir/commondir" ]] || receipt_trust_fail 'receipt Git worktree metadata is unsafe'
    receipt_commondir_spec="$(< "$receipt_git_dir/commondir")"
    [[ "$receipt_commondir_spec" == '../..' ]] || receipt_trust_fail 'receipt Git common directory is not local'
    receipt_common_git_dir="$($receipt_realpath_bin -e -- "$receipt_git_dir/$receipt_commondir_spec" 2>/dev/null || true)"
  fi
  [[ -n "$receipt_git_dir" && -d "$receipt_git_dir" && ! -L "$receipt_git_dir" && \
    -n "$receipt_common_git_dir" && -d "$receipt_common_git_dir" && ! -L "$receipt_common_git_dir" ]] || receipt_trust_fail 'receipt Git directory is not canonical'
  receipt_trust_reject_symlink_components "$receipt_git_dir" || receipt_trust_fail 'receipt Git directory contains a symlinked component'
  receipt_trust_reject_symlink_components "$receipt_common_git_dir" || receipt_trust_fail 'receipt Git common directory contains a symlinked component'
  receipt_objects_dir="$receipt_common_git_dir/objects"
  receipt_refs_dir="$receipt_common_git_dir/refs"
  receipt_config_path="$receipt_common_git_dir/config"
  receipt_index_path="$receipt_git_dir/index"
  [[ -d "$receipt_objects_dir" && ! -L "$receipt_objects_dir" && -d "$receipt_refs_dir" && ! -L "$receipt_refs_dir" && \
    -f "$receipt_config_path" && ! -L "$receipt_config_path" && -f "$receipt_index_path" && ! -L "$receipt_index_path" ]] || {
    receipt_trust_fail 'receipt Git object, ref, config, or index storage is unsafe'
  }
  for receipt_git_metadata_root in "$receipt_git_dir" "$receipt_common_git_dir"; do
    receipt_git_metadata_entry="$($receipt_find_bin -P "$receipt_git_metadata_root" -mindepth 1 \
      \( -type l -o \( ! -type f ! -type d \) \) -print -quit 2>/dev/null || true)"
    [[ -z "$receipt_git_metadata_entry" ]] || receipt_trust_fail 'receipt Git metadata contains an unsafe entry'
  done
  [[ ! -e "$receipt_common_git_dir/shallow" && ! -e "$receipt_git_dir/shallow" && \
    ! -e "$receipt_common_git_dir/objects/info/alternates" && \
    ! -e "$receipt_common_git_dir/objects/info/http-alternates" ]] || {
    receipt_trust_fail 'receipt repository uses external or shallow Git storage'
  }
  receipt_dangerous_config="$(receipt_trust_git config --local --no-includes --name-only --get-regexp \
    '^(include|filter\.|diff\..*\.textconv$|merge\..*\.driver$|credential\.|url\..*\.insteadOf$|core\.(attributesfile|excludesfile|fsmonitor|hooksPath|worktree|alternateRefsCommand|askPass|gitProxy|sshCommand)$|extensions\.|remote\..*\.(promisor|partialclonefilter|uploadpack|receivepack)$)' \
    2>/dev/null || true)"
  [[ -z "$receipt_dangerous_config" ]] || receipt_trust_fail 'receipt repository-local Git configuration is unsafe'
  [[ "$(receipt_trust_git config --local --no-includes --bool --get core.sparseCheckout 2>/dev/null || true)" != true && \
    "$(receipt_trust_git config --local --no-includes --bool --get index.sparse 2>/dev/null || true)" != true && \
    ! -e "$receipt_common_git_dir/info/sparse-checkout" && \
    ! -e "$receipt_git_dir/info/sparse-checkout" ]] || receipt_trust_fail 'receipt repository sparse checkout metadata is unsafe'
  [[ "$(receipt_trust_git rev-parse --show-toplevel 2>/dev/null || true)" == "$receipt_repo_root" && \
    "$(receipt_trust_git rev-parse --absolute-git-dir 2>/dev/null || true)" == "$receipt_git_dir" && \
    "$(receipt_trust_git rev-parse --is-inside-work-tree 2>/dev/null || true)" == true && \
    "$(receipt_trust_git rev-parse --is-bare-repository 2>/dev/null || true)" == false && \
    "$(receipt_trust_git rev-parse --is-shallow-repository 2>/dev/null || true)" == false ]] || {
    receipt_trust_fail 'receipt repository topology is not a local full worktree'
  }
  receipt_commit="$(receipt_trust_git rev-parse --verify HEAD^{commit} 2>/dev/null || true)"
  [[ "$receipt_commit" =~ ^[0-9a-f]{40}$ ]] || receipt_trust_fail 'receipt HEAD is not a full committed object'
  receipt_trust_git cat-file -e "$receipt_commit^{commit}" || receipt_trust_fail 'receipt HEAD object is unavailable'
  receipt_helper_tree="$(receipt_trust_git ls-tree "$receipt_commit" -- scripts/ubuntu/source-attestation.sh 2>/dev/null || true)"
  [[ "$receipt_helper_tree" != *$'\n'* ]] || receipt_trust_fail 'receipt helper tree lookup was ambiguous'
  IFS=$'\t' read -r receipt_helper_meta receipt_helper_path <<< "$receipt_helper_tree"
  read -r receipt_helper_mode receipt_helper_type receipt_helper_oid <<< "$receipt_helper_meta"
  [[ "$receipt_helper_path" == scripts/ubuntu/source-attestation.sh && "$receipt_helper_type" == blob && \
    "$receipt_helper_oid" =~ ^[0-9a-f]{40}$ && ( "$receipt_helper_mode" == 100644 || "$receipt_helper_mode" == 100755 ) ]] || {
    receipt_trust_fail 'committed receipt helper is not a regular blob'
  }
  receipt_trust_git cat-file -e "$receipt_helper_oid^{blob}" || receipt_trust_fail 'committed receipt helper blob is unavailable'
  receipt_private_helper_dir="$($receipt_mktemp_bin -d /tmp/herdr-receipt-helper.XXXXXX)"
  receipt_register_cleanup "$receipt_private_helper_dir"
  "$receipt_chmod_bin" 0700 -- "$receipt_private_helper_dir"
  receipt_private_helper="$receipt_private_helper_dir/source-attestation.sh"
  receipt_trust_git cat-file blob "$receipt_helper_oid" > "$receipt_private_helper" || receipt_trust_fail 'committed receipt helper could not be materialized'
  receipt_helper_mode_value=0644
  [[ "$receipt_helper_mode" == 100755 ]] && receipt_helper_mode_value=0755
  "$receipt_chmod_bin" "$receipt_helper_mode_value" -- "$receipt_private_helper"
  [[ -f "$receipt_private_helper" && ! -L "$receipt_private_helper" ]] || receipt_trust_fail 'materialized receipt helper is not regular'
  receipt_materialized_oid="$($receipt_env_bin -i HOME=/nonexistent PATH="$receipt_trusted_path" LC_ALL=C TZ=UTC \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_COUNT=0 \
    "$receipt_git_bin" --no-replace-objects --git-dir="$receipt_git_dir" \
    hash-object --no-filters --stdin < "$receipt_private_helper")"
  [[ "$receipt_materialized_oid" == "$receipt_helper_oid" ]] || receipt_trust_fail 'receipt helper bytes do not match committed blob'
  receipt_live_entrypoint_helper="$receipt_repo_root/scripts/ubuntu/source-attestation.sh"
  [[ -f "$receipt_live_entrypoint_helper" && ! -L "$receipt_live_entrypoint_helper" && \
    "$($receipt_sha256_bin -- "$receipt_live_entrypoint_helper" | "$receipt_awk_bin" '{print $1}')" == \
    "$($receipt_sha256_bin -- "$receipt_private_helper" | "$receipt_awk_bin" '{print $1}')" ]] || {
    receipt_trust_fail 'live receipt helper differs from its committed blob'
  }
}

receipt_materialize_helper_from_payload() {
  [[ "$receipt_prelude_source_root" == /* && "$receipt_prelude_source_manifest" == /* && \
    "$receipt_prelude_payload_root" == /* && "$receipt_prelude_payload_manifest" == /* ]] || {
    receipt_trust_fail 'payload receipt invocation lacks absolute trust inputs'
  }
  receipt_prelude_source_root="$($receipt_realpath_bin -e -- "$receipt_prelude_source_root" 2>/dev/null || true)"
  receipt_prelude_source_manifest="$($receipt_realpath_bin -e -- "$receipt_prelude_source_manifest" 2>/dev/null || true)"
  receipt_prelude_payload_root="$($receipt_realpath_bin -e -- "$receipt_prelude_payload_root" 2>/dev/null || true)"
  receipt_prelude_payload_manifest="$($receipt_realpath_bin -e -- "$receipt_prelude_payload_manifest" 2>/dev/null || true)"
  [[ "$receipt_prelude_source_root" == "$receipt_prelude_payload_root/source" && \
    "$receipt_prelude_source_manifest" == "$receipt_prelude_source_root/.source-attestation" && \
    "$receipt_prelude_payload_manifest" == "$receipt_prelude_payload_root/.payload-manifest" && \
    "$receipt_script_path" == "$receipt_prelude_source_root/scripts/ubuntu/receipt-authority.sh" ]] || {
    receipt_trust_fail 'payload receipt paths are not topology-bound'
  }
  receipt_trust_reject_symlink_components "$receipt_prelude_payload_root" || receipt_trust_fail 'payload root contains symlinked components'
  [[ -f "$receipt_prelude_payload_manifest" && ! -L "$receipt_prelude_payload_manifest" && \
    "$($receipt_head_bin -n 1 -- "$receipt_prelude_payload_manifest")" == herdr-payload-manifest-v1 ]] || {
    receipt_trust_fail 'payload manifest is missing or malformed'
  }
  [[ -z "$receipt_prelude_payload_hash" || "$receipt_prelude_payload_hash" =~ ^[0-9a-f]{64}$ ]] || {
    receipt_trust_fail 'payload manifest hash is malformed'
  }
  if [[ -n "$receipt_prelude_payload_hash" ]]; then
    [[ "$($receipt_sha256_bin -- "$receipt_prelude_payload_manifest" | "$receipt_awk_bin" '{print $1}')" == "$receipt_prelude_payload_hash" ]] || {
      receipt_trust_fail 'payload manifest hash does not match the trusted stage'
    }
  fi
  [[ -f "$receipt_prelude_source_manifest" && ! -L "$receipt_prelude_source_manifest" && \
    "$($receipt_head_bin -n 1 -- "$receipt_prelude_source_manifest")" == herdr-source-snapshot-v2 ]] || {
    receipt_trust_fail 'source snapshot manifest is missing or malformed'
  }
  receipt_payload_helper_record="$($receipt_awk -F '\t' '$1 == "F" && $4 == "source/scripts/ubuntu/source-attestation.sh" { print; found++ } END { exit(found == 1 ? 0 : 1) }' "$receipt_prelude_payload_manifest" 2>/dev/null || true)"
  IFS=$'\t' read -r _ receipt_payload_helper_mode receipt_payload_helper_sha receipt_payload_helper_path <<< "$receipt_payload_helper_record"
  receipt_source_helper_record="$($receipt_awk -F '\t' '$1 == "F" && $5 == "scripts/ubuntu/source-attestation.sh" { print; found++ } END { exit(found == 1 ? 0 : 1) }' "$receipt_prelude_source_manifest" 2>/dev/null || true)"
  IFS=$'\t' read -r _ receipt_source_helper_mode receipt_source_helper_oid receipt_source_helper_sha receipt_source_helper_path <<< "$receipt_source_helper_record"
  [[ "$receipt_payload_helper_path" == source/scripts/ubuntu/source-attestation.sh && \
    "$receipt_payload_helper_mode" =~ ^(444|555|644|755)$ && "$receipt_payload_helper_sha" =~ ^[0-9a-f]{64}$ && \
    "$receipt_source_helper_path" == scripts/ubuntu/source-attestation.sh && \
    "$receipt_source_helper_mode" =~ ^(444|555|644|755|0444|0555|0644|0755)$ && \
    "$receipt_source_helper_oid" =~ ^[0-9a-f]{40}$ && "$receipt_source_helper_sha" == "$receipt_payload_helper_sha" ]] || {
    receipt_trust_fail 'payload helper is not bound to the committed source manifest'
  }
  receipt_live_helper="$receipt_prelude_source_root/scripts/ubuntu/source-attestation.sh"
  [[ -f "$receipt_live_helper" && ! -L "$receipt_live_helper" ]] || receipt_trust_fail 'payload helper is missing'
  receipt_private_helper_dir="$($receipt_mktemp_bin -d /tmp/herdr-receipt-helper.XXXXXX)"
  receipt_register_cleanup "$receipt_private_helper_dir"
  "$receipt_chmod_bin" 0700 -- "$receipt_private_helper_dir"
  receipt_private_helper="$receipt_private_helper_dir/source-attestation.sh"
  "$receipt_cp_bin" -- "$receipt_live_helper" "$receipt_private_helper" || receipt_trust_fail 'payload helper could not be privately copied'
  [[ "$($receipt_sha256_bin -- "$receipt_private_helper" | "$receipt_awk_bin" '{print $1}')" == "$receipt_source_helper_sha" ]] || {
    receipt_trust_fail 'payload helper changed during private materialization'
  }
  receipt_payload_helper_mode_value="${receipt_source_helper_mode#0}"
  "$receipt_chmod_bin" "$receipt_payload_helper_mode_value" -- "$receipt_private_helper"
}

declare -a receipt_cleanup_paths=()
receipt_register_cleanup() {
  [[ -n "${1:-}" ]] && receipt_cleanup_paths+=("$1")
}

receipt_private_helper_dir=''
receipt_cleanup() {
  local status="$1"
  set +e
  local cleanup_path
  for cleanup_path in "${receipt_cleanup_paths[@]:-}"; do
    [[ -n "$cleanup_path" ]] && "$receipt_rm_bin" -rf -- "$cleanup_path"
  done
  if declare -F attestation_cleanup_temporary_paths >/dev/null 2>&1; then
    attestation_cleanup_temporary_paths
  fi
  return "$status"
}
trap 'receipt_cleanup "$?"' EXIT

receipt_script_path="$($receipt_realpath_bin -e -- "${BASH_SOURCE[0]}" 2>/dev/null || true)"
receipt_script_dir="$($receipt_dirname_bin -- "$receipt_script_path")"
receipt_repo_root="$($receipt_realpath_bin -e -- "$receipt_script_dir/../.." 2>/dev/null || true)"
[[ -n "$receipt_script_path" && "$receipt_script_path" == "$receipt_repo_root/scripts/ubuntu/receipt-authority.sh" ]] || {
  receipt_trust_fail 'receipt authority entrypoint is not at the canonical repository path'
}

receipt_prelude_source_root=''
receipt_prelude_source_manifest=''
receipt_prelude_payload_root=''
receipt_prelude_payload_manifest=''
receipt_prelude_payload_hash=''
receipt_prelude_args=("$@")
for ((receipt_arg_index=0; receipt_arg_index < ${#receipt_prelude_args[@]}; receipt_arg_index++)); do
  case "${receipt_prelude_args[$receipt_arg_index]}" in
    --source-root)
      ((receipt_arg_index + 1 < ${#receipt_prelude_args[@]})) || receipt_trust_fail '--source-root requires a value'
      receipt_prelude_source_root="${receipt_prelude_args[$((receipt_arg_index + 1))]}"
      ((receipt_arg_index++))
      ;;
    --source-manifest)
      ((receipt_arg_index + 1 < ${#receipt_prelude_args[@]})) || receipt_trust_fail '--source-manifest requires a value'
      receipt_prelude_source_manifest="${receipt_prelude_args[$((receipt_arg_index + 1))]}"
      ((receipt_arg_index++))
      ;;
    --payload-root)
      ((receipt_arg_index + 1 < ${#receipt_prelude_args[@]})) || receipt_trust_fail '--payload-root requires a value'
      receipt_prelude_payload_root="${receipt_prelude_args[$((receipt_arg_index + 1))]}"
      ((receipt_arg_index++))
      ;;
    --payload-manifest)
      ((receipt_arg_index + 1 < ${#receipt_prelude_args[@]})) || receipt_trust_fail '--payload-manifest requires a value'
      receipt_prelude_payload_manifest="${receipt_prelude_args[$((receipt_arg_index + 1))]}"
      ((receipt_arg_index++))
      ;;
    --payload-manifest-sha256)
      ((receipt_arg_index + 1 < ${#receipt_prelude_args[@]})) || receipt_trust_fail '--payload-manifest-sha256 requires a value'
      receipt_prelude_payload_hash="${receipt_prelude_args[$((receipt_arg_index + 1))]}"
      ((receipt_arg_index++))
      ;;
  esac
done

receipt_repo_mode=0
if [[ -e "$receipt_repo_root/.git" && ! -L "$receipt_repo_root/.git" ]]; then
  receipt_repo_mode=1
  receipt_trust_reject_symlink_components "$receipt_repo_root" || receipt_trust_fail 'receipt repository root contains a symlinked component'
  receipt_materialize_helper_from_git
else
  receipt_materialize_helper_from_payload
fi

# shellcheck disable=SC1090
source "$receipt_private_helper"
if (( receipt_repo_mode == 1 )); then
  attestation_create_git_snapshot "$receipt_repo_root" '' '' || receipt_trust_fail 'receipt entrypoint checkout failed exact committed-blob attestation'
  receipt_source_snapshot="$attestation_snapshot_dir"
else
  receipt_source_snapshot=''
fi

mode='install'
script_path="$receipt_script_path"
script_dir="$receipt_script_dir"
repo_root="${receipt_source_snapshot:-$receipt_prelude_source_root}"
source_root="$repo_root"
user_home="${HOME:-}"
authority_path='/etc/stmodel/issue-961/receipt-authority.json'
receipt_path='/etc/stmodel/issue-961/receipt.json'
rtk_source_root=''
source_manifest=''
rtk_source_manifest=''
payload_root=''
payload_manifest_arg=''
fixture_root=''
default_authority_path='/etc/stmodel/issue-961/receipt-authority.json'
default_receipt_path='/etc/stmodel/issue-961/receipt.json'
authority_id='#961-installation-authority-v1'
schema_version=1
trusted_path='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH="$trusted_path"

usage() {
  cat >&2 <<'EOF'
Usage: receipt-authority.sh [--install|--check] [options]

Options:
  --source-root PATH       Clean bootstrap source checkout.
  --user-home PATH         Managed user home whose tools are attested.
  --authority-path PATH    Authority envelope path (production default is /etc/stmodel/issue-961/receipt-authority.json).
  --receipt-path PATH      Receipt body path (production default is /etc/stmodel/issue-961/receipt.json).
  --rtk-source-root PATH   Canonical RTK source checkout (default is USER_HOME/src/rtk).
  --source-manifest PATH   Exact committed source snapshot manifest.
  --rtk-source-manifest PATH Exact committed RTK snapshot manifest.
  --payload-root PATH      Root of the root-owned verified payload staging tree.
  --payload-manifest PATH  Verified payload manifest within PAYLOAD_ROOT.
  --payload-manifest-sha256 SHA256  Internal root-stage payload manifest binding.
  --fixture-root PATH      Test-only role root; requires non-production output paths.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install) mode='install'; shift ;;
    --check) mode='check'; shift ;;
    --source-root) [[ $# -ge 2 ]] || { usage; exit 2; }; source_root="$2"; shift 2 ;;
    --user-home) [[ $# -ge 2 ]] || { usage; exit 2; }; user_home="$2"; shift 2 ;;
    --authority-path) [[ $# -ge 2 ]] || { usage; exit 2; }; authority_path="$2"; shift 2 ;;
    --receipt-path) [[ $# -ge 2 ]] || { usage; exit 2; }; receipt_path="$2"; shift 2 ;;
    --rtk-source-root) [[ $# -ge 2 ]] || { usage; exit 2; }; rtk_source_root="$2"; shift 2 ;;
    --source-manifest) [[ $# -ge 2 ]] || { usage; exit 2; }; source_manifest="$2"; shift 2 ;;
    --rtk-source-manifest) [[ $# -ge 2 ]] || { usage; exit 2; }; rtk_source_manifest="$2"; shift 2 ;;
    --payload-root) [[ $# -ge 2 ]] || { usage; exit 2; }; payload_root="$2"; shift 2 ;;
    --payload-manifest) [[ $# -ge 2 ]] || { usage; exit 2; }; payload_manifest_arg="$2"; shift 2 ;;
    --payload-manifest-sha256) [[ $# -ge 2 ]] || { usage; exit 2; }; receipt_prelude_payload_hash="$2"; shift 2 ;;
    --fixture-root) [[ $# -ge 2 ]] || { usage; exit 2; }; fixture_root="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

fail() {
  echo "receipt authority: $*" >&2
  exit 24
}

receipt_test_pause() {
  local phase="$1"
  local ready_file="${HERDR_RECEIPT_TEST_READY_FILE:-}"
  local continue_file="${HERDR_RECEIPT_TEST_CONTINUE_FILE:-}"
  [[ "${HERDR_RECEIPT_TEST_PAUSE_PHASE:-}" == "$phase" ]] || return 0
  [[ -n "$ready_file" && -n "$continue_file" ]] || fail "receipt test pause is missing synchronization files: $phase"
  : > "$ready_file"
  while [[ ! -e "$continue_file" ]]; do sleep 0.01; done
}

[[ "$mode" == install || "$mode" == check ]] || fail "unsupported mode '$mode'"
[[ "$source_root" == /* && "$user_home" == /* && "$authority_path" == /* && "$receipt_path" == /* \
  && ( -z "$rtk_source_root" || "$rtk_source_root" == /* ) \
  && ( -z "$source_manifest" || "$source_manifest" == /* ) \
  && ( -z "$rtk_source_manifest" || "$rtk_source_manifest" == /* ) \
  && ( -z "$payload_root" || "$payload_root" == /* ) \
  && ( -z "$payload_manifest_arg" || "$payload_manifest_arg" == /* ) ]] || {
  fail 'source, home, authority, and receipt paths must be absolute'
}

if [[ -n "$fixture_root" ]]; then
  [[ "$fixture_root" == /* ]] || fail 'fixture root must be absolute'
  [[ "$authority_path" != "$default_authority_path" && "$receipt_path" != "$default_receipt_path" ]] || {
    fail 'fixture mode cannot address production authority paths'
  }
  system_bin="$fixture_root/bin"
else
  [[ "$(/usr/bin/id -u)" == 0 ]] || {
    [[ "$mode" == check && "$authority_path" == "$default_authority_path" ]] || fail 'production authority operations require root'
  }
  system_bin='/usr/bin'
fi

jq_bin='/usr/bin/jq'
[[ -x "$jq_bin" ]] || fail 'jq is required at /usr/bin/jq'
attestation_assert_canonical_git || fail 'canonical /usr/bin/git is unavailable'
[[ -x /usr/bin/sha256sum && -x /usr/bin/realpath && -x /usr/bin/gawk ]] || fail 'required host utilities are missing'

source_root="$(/usr/bin/realpath -e -- "$source_root" 2>/dev/null || true)"
[[ -n "$source_root" && -d "$source_root" ]] || fail 'source root does not exist'
if [[ -n "$source_manifest" ]]; then
  source_manifest="$(/usr/bin/realpath -e -- "$source_manifest" 2>/dev/null || true)"
  [[ "$source_manifest" == "$source_root/.source-attestation" ]] || fail 'source manifest is not bound to the source snapshot'
  attestation_verify_snapshot "$source_root" "$source_manifest" || fail 'source snapshot manifest is invalid'
else
  attestation_create_git_snapshot "$source_root" '' '' || fail 'source Git checkout failed hardened source attestation'
  source_root="$attestation_snapshot_dir"
  source_manifest="$attestation_snapshot_manifest"
fi
source_commit="$attestation_snapshot_commit"
[[ "$source_commit" =~ ^[0-9a-f]{40}$ ]] || fail 'source snapshot commit is not a full commit'
source_script_path="$source_root/scripts/ubuntu/receipt-authority.sh"
source_helper_path="$source_root/scripts/ubuntu/source-attestation.sh"
[[ -f "$source_script_path" && ! -L "$source_script_path" ]] || fail 'source snapshot authority script is missing'
[[ -f "$source_helper_path" && ! -L "$source_helper_path" ]] || fail 'source snapshot attestation helper is missing'
expected_script_sha256="$(attestation_snapshot_file_digest "$source_manifest" scripts/ubuntu/receipt-authority.sh)" || fail 'source snapshot authority script is not manifested'
expected_helper_sha256="$(attestation_snapshot_file_digest "$source_manifest" scripts/ubuntu/source-attestation.sh)" || fail 'source snapshot helper is not manifested'
[[ "$(attestation_hash_file "$script_path")" == "$expected_script_sha256" ]] || fail 'invoked receipt authority bytes differ from the source snapshot'
[[ "$(attestation_hash_file "$script_dir/source-attestation.sh")" == "$expected_helper_sha256" ]] || fail 'invoked source-attestation helper differs from the source snapshot'
[[ "$(attestation_hash_file "$source_script_path")" == "$expected_script_sha256" ]] || fail 'source snapshot authority script hash is inconsistent'
[[ "$(attestation_hash_file "$source_helper_path")" == "$expected_helper_sha256" ]] || fail 'source snapshot helper hash is inconsistent'

if [[ -n "$payload_root" || -n "$payload_manifest_arg" ]]; then
  [[ -n "$payload_root" && -n "$payload_manifest_arg" ]] || fail 'payload root and manifest must be supplied together'
  payload_root="$(/usr/bin/realpath -e -- "$payload_root" 2>/dev/null || true)"
  payload_manifest_arg="$(/usr/bin/realpath -e -- "$payload_manifest_arg" 2>/dev/null || true)"
  [[ "$payload_manifest_arg" == "$payload_root/.payload-manifest" ]] || fail 'payload manifest is not bound to the payload root'
  attestation_verify_payload_manifest "$payload_root" "$payload_manifest_arg" || fail 'payload manifest is invalid'
fi

user_home="$(/usr/bin/realpath -e -- "$user_home" 2>/dev/null || true)"
[[ -n "$user_home" && -d "$user_home" ]] || fail 'managed user home does not exist'
if [[ -z "$rtk_source_root" ]]; then rtk_source_root="$user_home/src/rtk"; fi
rtk_source_root="$(/usr/bin/realpath -e -- "$rtk_source_root" 2>/dev/null || true)"
[[ -n "$rtk_source_root" && -d "$rtk_source_root" ]] || fail 'RTK source checkout does not exist'
[[ "$(/usr/bin/uname -s)" == 'Linux' && "$(/usr/bin/uname -m)" == 'x86_64' ]] || fail 'receipt authority requires Ubuntu x86_64 Linux'
if [[ -z "$fixture_root" ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == 'ubuntu' ]] || fail 'receipt authority requires an Ubuntu host'
fi

reject_symlink_components() {
  local path="$1"
  local current='/'
  local component
  local -a components
  [[ "$path" == /* ]] || return 1
  IFS='/' read -r -a components <<< "${path#/}"
  for component in "${components[@]}"; do
    [[ -z "$component" || "$component" == '.' ]] && continue
    [[ "$component" != '..' && "$component" != *'/'* ]] || return 1
    current="$current/$component"
    [[ ! -L "$current" ]] || return 1
  done
}

validate_rtk_source_checkout() {
  local source_path="${1:-}"
  local expected_url="${2:-}"
  local expected_ref="${3:-}"
  if [[ -n "$rtk_source_manifest" ]]; then
    rtk_source_manifest="$(/usr/bin/realpath -e -- "$rtk_source_manifest" 2>/dev/null || true)"
    [[ "$rtk_source_manifest" == "$source_path/.source-attestation" ]] || fail 'RTK source manifest is not bound to the RTK snapshot'
    attestation_verify_snapshot "$source_path" "$rtk_source_manifest" "$expected_ref" "$expected_url" || fail 'RTK source snapshot manifest is invalid'
  else
    attestation_create_git_snapshot "$source_path" "$expected_url" "$expected_ref" || return 1
    source_path="$attestation_snapshot_dir"
    rtk_source_manifest="$attestation_snapshot_manifest"
  fi
  rtk_snapshot_path="$source_path"
  rtk_snapshot_manifest="$rtk_source_manifest"
  rtk_snapshot_commit="$attestation_snapshot_commit"
  rtk_snapshot_url="$attestation_snapshot_url"
  rtk_snapshot_manifest_sha256="$(attestation_hash_file "$rtk_snapshot_manifest")" || return 1
}

reject_symlink_components "$user_home" || fail "managed user home contains a symlink: $user_home"
[[ "$(/usr/bin/realpath -e -- "$user_home" 2>/dev/null || true)" == "$user_home" ]] || fail "managed user home is not lexically canonical: $user_home"
reject_symlink_components "$rtk_source_root" || fail "RTK source checkout contains a symlink: $rtk_source_root"
[[ "$(/usr/bin/realpath -e -- "$rtk_source_root" 2>/dev/null || true)" == "$rtk_source_root" ]] || fail "RTK source checkout is not lexically canonical: $rtk_source_root"

lock_file="$source_root/config/ubuntu-toolchain.lock"
allowlist_file="$source_root/config/receipt-authority-role-allowlist.txt"
payload_manifest="$source_root/config/payload-manifest.sha256"
[[ -f "$lock_file" && -f "$allowlist_file" && -f "$payload_manifest" ]] || fail 'source authority inputs are incomplete'
# shellcheck disable=SC1090
source "$lock_file"

[[ "${RTK_REPO_URL:-}" =~ ^https://[^[:space:]]+$ ]] || fail 'RTK_REPO_URL is not a valid locked HTTPS URL'
[[ "${RTK_REF:-}" =~ ^[0-9a-f]{40}$ ]] || fail 'RTK_REF is not a full locked commit'

repo_commit="$source_commit"
[[ "$repo_commit" =~ ^[0-9a-f]{40}$ ]] || fail 'source snapshot commit is not a full commit'

payload_manifest_sha256="$(/usr/bin/sha256sum "$payload_manifest" | /usr/bin/gawk '{print $1}')"
allowlist_sha256="$(/usr/bin/sha256sum "$allowlist_file" | /usr/bin/gawk '{print $1}')"
script_sha256="$expected_script_sha256"

validate_rtk_source_checkout "$rtk_source_root" "$RTK_REPO_URL" "$RTK_REF" || fail 'RTK source checkout failed hardened source attestation'
receipt_test_pause after-rtk-snapshot
rtk_source_url="$rtk_snapshot_url"
rtk_source_commit="$rtk_snapshot_commit"
rtk_source_clean=true

declare -A role_registry role_names role_argv role_implementation
roles=()
while IFS='|' read -r role registry names version_argv implementation; do
  [[ -z "$role" || "$role" == \#* ]] && continue
  [[ "$role" =~ ^[a-z][a-z0-9-]+$ && "$registry" =~ ^[a-z0-9-]+$ && "$version_argv" == '--version' && -n "$names" && -n "$implementation" ]] || {
    fail "malformed role allowlist entry for '$role'"
  }
  [[ -z "${role_registry[$role]+x}" ]] || fail "duplicate role '$role' in allowlist"
  roles+=("$role")
  role_registry["$role"]="$registry"
  role_names["$role"]="$names"
  role_argv["$role"]="$version_argv"
  role_implementation["$role"]="$implementation"
done < "$allowlist_file"

expected_roles='bash git gh node pwsh rtk'
[[ "${roles[*]}" == "$expected_roles" ]] || fail "role allowlist must be sorted and exactly '$expected_roles'"

declare -A role_path
role_path[python313]="$user_home/.local/bin/python3.13"
role_path[rtk]="$user_home/.cargo/bin/rtk"
role_path[node]="$user_home/.local/lib/node-v${NODE_VERSION}-linux-x64/bin/node"
role_path[git]="$system_bin/git"
role_path[gh]="$system_bin/gh"
role_path[bash]="$system_bin/bash"
if [[ -n "$fixture_root" ]]; then
  role_path[pwsh]="$system_bin/pwsh"
else
  if [[ -x /opt/microsoft/powershell/7/pwsh ]]; then
    role_path[pwsh]='/opt/microsoft/powershell/7/pwsh'
  else
    role_path[pwsh]='/usr/bin/pwsh'
  fi
fi

canonical_executable() {
  local path="$1"
  local label="$2"
  reject_symlink_components "$path" || fail "$label contains a symlinked path component: $path"
  [[ -f "$path" && -x "$path" && ! -L "$path" ]] || fail "$label is not a regular executable: $path"
  local resolved
  resolved="$(/usr/bin/realpath -e -- "$path" 2>/dev/null || true)"
  [[ "$resolved" == "$path" ]] || fail "$label is not lexically canonical: $path -> $resolved"
  printf '%s' "$path"
}

build_tree_manifest() {
  local root="$1"
  local output="$2"
  local relative full target resolved
  local count=0
  : > "$output"
  printf 'D\t.\n' >> "$output"
  while IFS= read -r -d '' relative; do
    full="$root/$relative"
    if [[ -L "$full" ]]; then
      target="$(readlink -- "$full")"
      resolved="$(/usr/bin/realpath -e -- "$full" 2>/dev/null || true)"
      [[ -n "$resolved" && ( "$resolved" == "$root" || "$resolved" == "$root/"* ) ]] || fail "Python runtime symlink escapes its managed root: $full"
      printf 'L\t%s\t%s\t%s\n' "$relative" "$target" "$resolved" >> "$output"
    elif [[ -d "$full" ]]; then
      printf 'D\t%s\n' "$relative" >> "$output"
    elif [[ -f "$full" ]]; then
      printf 'F\t%s\t%s\n' "$relative" "$(/usr/bin/sha256sum "$full" | /usr/bin/gawk '{print $1}')" >> "$output"
    else
      fail "Python runtime contains an unsupported filesystem entry: $full"
    fi
    ((count += 1))
  done < <(find -P "$root" -mindepth 1 -printf '%P\0' | sort -z)
  printf '%s' "$count"
}

for role in "${roles[@]}"; do
  role_path["$role"]="$(canonical_executable "${role_path[$role]}" "$role")"
done
python_path="$(canonical_executable "${role_path[python313]}" 'python3.13')"
rtk_path="${role_path[rtk]}"
python_venv_path="$user_home/.local/pyvenv.cfg"
python_runtime_root="$user_home/.local/lib/herdr-workstation/python/$PYTHON_VERSION-$PYTHON_RELEASE-$PYTHON_PLATFORM"
python_stdlib_root="$python_runtime_root/lib/python3.13"
reject_symlink_components "$python_venv_path" || fail 'Python pyvenv.cfg contains a symlinked path component'
[[ -f "$python_venv_path" && ! -L "$python_venv_path" ]] || fail 'Python pyvenv.cfg is missing or not a regular file'
reject_symlink_components "$python_runtime_root" || fail 'Python runtime contains a symlinked path component'
[[ -d "$python_runtime_root" && ! -L "$python_runtime_root" ]] || fail 'Python managed runtime is missing or not a directory'
[[ "$(/usr/bin/realpath -e -- "$python_runtime_root" 2>/dev/null || true)" == "$python_runtime_root" ]] || fail 'Python managed runtime is not lexically canonical'
[[ -d "$python_stdlib_root" && ! -L "$python_stdlib_root" ]] || fail 'Python managed standard library is missing or not a directory'

read_pyvenv_value() {
  local key="$1"
  /usr/bin/gawk -F= -v key="$key" '
    $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
      value=$2
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      result=value
      count++
    }
    END { if (count == 1) print result; else exit 1 }
  ' "$python_venv_path"
}

python_venv_home="$(read_pyvenv_value home 2>/dev/null || true)"
python_venv_site="$(read_pyvenv_value include-system-site-packages 2>/dev/null || true)"
python_venv_version="$(read_pyvenv_value version 2>/dev/null || true)"
[[ "$python_venv_home" == "$python_runtime_root" ]] || fail 'Python pyvenv.cfg selects an unexpected runtime home'
[[ "$python_venv_site" == false ]] || fail 'Python pyvenv.cfg enables system site packages'
[[ "$python_venv_version" == "$PYTHON_VERSION" ]] || fail 'Python pyvenv.cfg version differs from the lock'
python_venv_sha256="$(/usr/bin/sha256sum "$python_venv_path" | /usr/bin/gawk '{print $1}')"

runtime_manifest_file="$($receipt_mktemp_bin /tmp/herdr-receipt-runtime.XXXXXX)"
stdlib_manifest_file="$($receipt_mktemp_bin /tmp/herdr-receipt-stdlib.XXXXXX)"
role_fragments="$($receipt_mktemp_bin /tmp/herdr-receipt-roles.XXXXXX)"
receipt_tmp="$($receipt_mktemp_bin /tmp/herdr-receipt-body.XXXXXX)"
authority_tmp="$($receipt_mktemp_bin /tmp/herdr-receipt-authority.XXXXXX)"
receipt_register_cleanup "$runtime_manifest_file"
receipt_register_cleanup "$stdlib_manifest_file"
receipt_register_cleanup "$role_fragments"
receipt_register_cleanup "$receipt_tmp"
receipt_register_cleanup "$authority_tmp"
runtime_file_count="$(build_tree_manifest "$python_runtime_root" "$runtime_manifest_file")"
stdlib_file_count="$(build_tree_manifest "$python_stdlib_root" "$stdlib_manifest_file")"
runtime_manifest_sha256="$(/usr/bin/sha256sum "$runtime_manifest_file" | /usr/bin/gawk '{print $1}')"
stdlib_manifest_sha256="$(/usr/bin/sha256sum "$stdlib_manifest_file" | /usr/bin/gawk '{print $1}')"

if [[ -n "$fixture_root" ]]; then
  rtk_candidates=("$user_home/.local/bin/rtk" "$user_home/.cargo/bin/rtk" "$system_bin/rtk")
else
  rtk_candidates=("$user_home/.local/bin/rtk" "$user_home/.cargo/bin/rtk" /usr/local/bin/rtk /usr/bin/rtk /bin/rtk)
fi
rtk_count=0
for candidate in "${rtk_candidates[@]}"; do
  if [[ -e "$candidate" || -L "$candidate" ]]; then
    reject_symlink_components "$candidate" || fail "RTK candidate is symlinked or unsafe: $candidate"
    [[ "$candidate" == "$rtk_path" ]] || fail "non-canonical RTK candidate is present: $candidate"
    ((rtk_count += 1))
  fi
done
[[ "$rtk_count" == 1 ]] || fail "RTK must have exactly one canonical candidate, found $rtk_count"

version_output_sha256() {
  printf '%s' "$1" | /usr/bin/sha256sum | /usr/bin/gawk '{print $1}'
}

probe_role_version() {
  local role="$1"
  local path="${role_path[$role]}"
  local output first
  output="$(PATH="$trusted_path" "$path" --version 2>&1)" || fail "$role --version failed"
  [[ -n "$output" ]] || fail "$role --version output is empty"
  first="${output%%$'\n'*}"
  case "$role" in
    bash) [[ "$first" == GNU\ bash,* ]] || fail "unexpected bash version output: $first" ;;
    git) [[ "$first" == git\ version\ * ]] || fail "unexpected git version output: $first" ;;
    gh) [[ "$first" == gh\ version\ * ]] || fail "unexpected gh version output: $first" ;;
    node) [[ "$first" =~ ^v[0-9]+\.[0-9]+\.[0-9]+ ]] || fail "unexpected node version output: $first" ;;
    pwsh) [[ "$first" == PowerShell\ * ]] || fail "unexpected PowerShell version output: $first" ;;
    rtk) [[ "$first" =~ ^rtk\ [0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "unexpected RTK version output: $first" ;;
  esac
  printf '%s\t%s\t%s\n' "$first" "$(version_output_sha256 "$output")" "$output"
}

declare -A role_version role_version_hash role_version_output
for role in "${roles[@]}"; do
  IFS=$'\t' read -r role_version["$role"] role_version_hash["$role"] role_version_output["$role"] < <(probe_role_version "$role")
done

python_version_output="$(PATH="$trusted_path" "$python_path" --version 2>&1)" || fail 'python3.13 --version failed'
[[ "$python_version_output" == "Python $PYTHON_VERSION" ]] || fail "Python version does not match lock: $python_version_output"
python_probe="$(PYTHONNOUSERSITE=1 PYTHONPATH= PATH="$trusted_path" "$python_path" -c 'import json, os, platform, sys, sysconfig; print(json.dumps({"version": platform.python_version(), "version_info": list(sys.version_info[:5]), "implementation": platform.python_implementation(), "executable": sys.executable, "prefix": os.path.realpath(sys.prefix), "base_prefix": os.path.realpath(sys.base_prefix), "stdlib": os.path.realpath(sysconfig.get_path("stdlib"))}, separators=(",", ":"))) ' 2>&1)" || fail 'Python identity probe failed'
python_probe_executable="$(printf '%s' "$python_probe" | "$jq_bin" -r '.executable' 2>/dev/null || true)"
python_probe_prefix="$(printf '%s' "$python_probe" | "$jq_bin" -r '.prefix' 2>/dev/null || true)"
python_probe_base_prefix="$(printf '%s' "$python_probe" | "$jq_bin" -r '.base_prefix' 2>/dev/null || true)"
python_probe_stdlib="$(printf '%s' "$python_probe" | "$jq_bin" -r '.stdlib' 2>/dev/null || true)"
[[ "$python_probe_executable" == "$python_path" ]] || fail 'Python probe executable differs from the canonical launcher'
[[ "$python_probe_prefix" == "$user_home/.local" ]] || fail 'Python probe prefix differs from the managed user environment'
[[ "$python_probe_base_prefix" == "$python_runtime_root" ]] || fail 'Python probe base_prefix differs from the locked managed runtime'
[[ "$python_probe_stdlib" == "$python_stdlib_root" ]] || fail 'Python probe stdlib differs from the locked managed runtime'
python_json="$("$jq_bin" -n -cS \
  --arg executable "$python_path" \
  --arg sha256 "$($receipt_sha256_bin "$python_path" | /usr/bin/gawk '{print $1}')" \
  --arg version "$PYTHON_VERSION" \
  --arg implementation "$(printf '%s' "$python_probe" | "$jq_bin" -r '.implementation')" \
  --argjson version_info "$(printf '%s' "$python_probe" | "$jq_bin" -c '.version_info')" \
  --arg venv_path "$python_venv_path" \
  --arg venv_sha256 "$python_venv_sha256" \
  --arg venv_home "$python_venv_home" \
  --arg venv_site "$python_venv_site" \
  --arg venv_version "$python_venv_version" \
  --arg runtime_root "$python_runtime_root" \
  --arg runtime_manifest_sha256 "$runtime_manifest_sha256" \
  --argjson runtime_file_count "$runtime_file_count" \
  --arg stdlib_root "$python_stdlib_root" \
  --arg stdlib_manifest_sha256 "$stdlib_manifest_sha256" \
  --argjson stdlib_file_count "$stdlib_file_count" \
  --arg prefix "$python_probe_prefix" \
  --arg base_prefix "$python_probe_base_prefix" \
  --arg stdlib "$python_probe_stdlib" \
  '{executable:$executable, sha256:$sha256, version:$version, version_info:$version_info, implementation:$implementation, venv:{path:$venv_path, sha256:$venv_sha256, home:$venv_home, include_system_site_packages:($venv_site == "true"), version:$venv_version}, runtime:{root:$runtime_root, manifest_sha256:$runtime_manifest_sha256, file_count:$runtime_file_count, stdlib_root:$stdlib_root, stdlib_manifest_sha256:$stdlib_manifest_sha256, stdlib_file_count:$stdlib_file_count, prefix:$prefix, base_prefix:$base_prefix, stdlib:$stdlib}}')" || fail 'Python identity probe was not valid JSON'
[[ "$(printf '%s' "$python_probe" | "$jq_bin" -r '.version')" == "$PYTHON_VERSION" ]] || fail 'Python probe version mismatch'
[[ "$(printf '%s' "$python_probe" | "$jq_bin" -r '.implementation')" == CPython ]] || fail 'Python implementation is not CPython'

for role in "${roles[@]}"; do
  role_json="$("$jq_bin" -cn \
    --arg role "$role" \
    --arg executable "${role_path[$role]}" \
    --arg sha256 "$($receipt_sha256_bin "${role_path[$role]}" | /usr/bin/gawk '{print $1}')" \
    --arg registry_id "${role_registry[$role]}" \
    --arg source_commit_sha "$repo_commit" \
    --arg kind '#961-role-manifest-v1' \
    --arg version "${role_version[$role]}" \
    --arg version_output_sha256 "${role_version_hash[$role]}" \
    --arg implementation "${role_implementation[$role]}" \
    '{($role): {executable:$executable, sha256:$sha256, registry_id:$registry_id, source_commit_sha:$source_commit_sha, source_attestation:{kind:$kind, canonical_path:$executable, file_sha256:$sha256}, version:$version, version_argv:["--version"], version_output_sha256:$version_output_sha256, implementation:$implementation}}')"
  if [[ "$role" == rtk ]]; then
    role_json="$(printf '%s' "$role_json" | "$jq_bin" -cS \
      --arg source_commit_sha "$rtk_source_commit" \
      --arg repository_url "$rtk_source_url" \
      --arg locked_ref "$RTK_REF" \
      --arg snapshot_manifest_sha256 "$rtk_snapshot_manifest_sha256" \
      --argjson clean "$rtk_source_clean" \
      'with_entries(.value.source_commit_sha = $source_commit_sha | .value.source_attestation += {repository_url:$repository_url, locked_ref:$locked_ref, source_commit_sha:$source_commit_sha, snapshot_manifest_sha256:$snapshot_manifest_sha256, clean:$clean})')"
  fi
  printf '%s\n' "$role_json" >> "$role_fragments"
done
role_manifest_json="$("$jq_bin" -sc 'add' "$role_fragments" | "$jq_bin" -cS .)" || fail 'role manifest is not valid JSON'
role_manifest_sha256="$(printf '%s' "$role_manifest_json" | /usr/bin/sha256sum | /usr/bin/gawk '{print $1}')"
rtk_source_json="$("$jq_bin" -cSn \
  --arg repository_url "$rtk_source_url" \
  --arg locked_ref "$RTK_REF" \
  --arg commit_sha "$rtk_source_commit" \
  --arg checkout_path "snapshot://$rtk_snapshot_commit/$rtk_snapshot_manifest_sha256" \
  --arg snapshot_manifest_sha256 "$rtk_snapshot_manifest_sha256" \
  --argjson clean "$rtk_source_clean" \
  '{repository_url:$repository_url, locked_ref:$locked_ref, commit_sha:$commit_sha, checkout_path:$checkout_path, snapshot_manifest_sha256:$snapshot_manifest_sha256, clean:$clean}')"

issued_at_utc="$(/usr/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
expires_at_utc="$(/usr/bin/date -u -d '+30 days' '+%Y-%m-%dT%H:%M:%SZ')"
receipt_id="issue-961-bootstrap-${repo_commit:0:12}-$(/usr/bin/date -u '+%Y%m%dT%H%M%SZ')"

build_receipt() {
  "$jq_bin" -n -cS \
    --argjson schema_version "$schema_version" \
    --arg receipt_id "$receipt_id" \
    --arg verification_status 'verified' \
    --arg source_commit_sha "$repo_commit" \
    --argjson clean "$rtk_source_clean" \
    --argjson python313_lock_verified true \
    --arg payload_manifest_sha256 "$payload_manifest_sha256" \
    --arg bridge_allowlist_sha256 "$allowlist_sha256" \
    --arg platform 'Ubuntu' \
    --arg architecture 'x86_64' \
    --arg issued_at_utc "$issued_at_utc" \
    --arg expires_at_utc "$expires_at_utc" \
    --argjson python313 "$python_json" \
    --argjson role_identities "$role_manifest_json" \
    --argjson rtk_source "$rtk_source_json" \
    --arg role_manifest_sha256 "$role_manifest_sha256" \
    --arg source_root "$source_root" \
    --arg script_sha256 "$script_sha256" \
    '{schema_version:$schema_version, receipt_id:$receipt_id, verification_status:$verification_status, source_commit_sha:$source_commit_sha, clean:$clean, python313_lock_verified:$python313_lock_verified, payload_manifest_sha256:$payload_manifest_sha256, bridge_allowlist_sha256:$bridge_allowlist_sha256, platform:$platform, architecture:$architecture, issued_at_utc:$issued_at_utc, expires_at_utc:$expires_at_utc, python313:$python313, role_identities:$role_identities, rtk_source:$rtk_source, role_manifest_sha256:$role_manifest_sha256, provenance:{authority_id:"#961-installation-authority-v1", producer:"herdr-workstation-bootstrap", source_root:$source_root, source_commit_sha:$source_commit_sha, receipt_authority_script_sha256:$script_sha256, authority_mode:"authoritative", secrets_excluded:true}}'
}

validate_parent_chain() {
  local path="$1"
  local current="$path"
  local owner mode
  [[ "$current" == /* ]] || fail "output parent is not absolute: $path"
  [[ -d "$current" ]] || fail "output parent does not exist: $path"
  reject_symlink_components "$current" || fail "output parent contains a symlink: $path"
  if [[ -z "$fixture_root" ]]; then
    while :; do
      owner="$(/usr/bin/stat -c '%u' -- "$current" 2>/dev/null || true)"
      mode="$(/usr/bin/stat -c '%a' -- "$current" 2>/dev/null || true)"
      [[ "$owner" == 0 && "$mode" =~ ^[0-7]+$ && $((8#$mode & 022)) == 0 ]] || fail "production output parent is not root-owned and non-writable: $current"
      [[ "$current" == '/' ]] && break
      current="$(/usr/bin/dirname -- "$current")"
    done
  fi
}

prepare_parent() {
  local target="$1"
  local parent="${target%/*}"
  [[ "$parent" == "$target" ]] && parent='/'
  if [[ "$mode" == install ]]; then
    reject_symlink_components "$parent" || fail "refusing to create through a symlinked output parent: $parent"
    /usr/bin/mkdir -p -- "$parent"
  fi
  validate_parent_chain "$parent"
}

atomic_install_json() {
  local source="$1"
  local target="$2"
  local parent="${target%/*}"
  local stage
  [[ "$parent" != "$target" ]] || parent='/'
  prepare_parent "$target"
  [[ ! -L "$target" ]] || fail "refusing to replace symlink output: $target"
  stage="$(/usr/bin/mktemp "$parent/.receipt-authority.XXXXXX")"
  receipt_register_cleanup "$stage"
  /usr/bin/install -m 0644 -- "$source" "$stage"
  if [[ -z "$fixture_root" ]]; then /usr/bin/chown 0:0 -- "$stage"; fi
  /usr/bin/mv -T -- "$stage" "$target"
  [[ -f "$target" && ! -L "$target" ]] || fail "atomic output did not produce a regular file: $target"
}

validate_json_field() {
  local path="$1"
  local expression="$2"
  "$jq_bin" -e "$expression" "$path" >/dev/null 2>&1 || fail "JSON contract failed for $path"
}

validate_output_file_security() {
  local path="$1"
  local owner mode
  [[ -f "$path" && ! -L "$path" ]] || fail "installed authority output is missing or symlinked: $path"
  mode="$(/usr/bin/stat -c '%a' -- "$path" 2>/dev/null || true)"
  [[ "$mode" =~ ^[0-7]+$ && $((8#$mode & 022)) == 0 ]] || fail "installed authority output is group/other writable: $path"
  if [[ -z "$fixture_root" ]]; then
    owner="$(/usr/bin/stat -c '%u' -- "$path" 2>/dev/null || true)"
    [[ "$owner" == 0 ]] || fail "installed authority output is not root-owned: $path"
  fi
}

validate_installed_authority() {
  [[ -f "$receipt_path" && ! -L "$receipt_path" ]] || fail "receipt body is missing or symlinked: $receipt_path"
  [[ -f "$authority_path" && ! -L "$authority_path" ]] || fail "authority envelope is missing or symlinked: $authority_path"
  validate_output_file_security "$receipt_path"
  validate_output_file_security "$authority_path"
  validate_parent_chain "${receipt_path%/*}"
  validate_parent_chain "${authority_path%/*}"
  validate_json_field "$receipt_path" '.schema_version == 1 and .verification_status == "verified" and .clean == true and .python313_lock_verified == true and (.source_commit_sha|test("^[0-9a-f]{40}$")) and .platform == "Ubuntu" and .architecture == "x86_64" and (.role_identities|type == "object") and ((.role_identities|keys) == ["bash","gh","git","node","pwsh","rtk"])'
  validate_json_field "$authority_path" '.schema_version == 1 and .authority_id == "#961-installation-authority-v1" and .verification_status == "verified" and (.source_commit_sha|test("^[0-9a-f]{40}$")) and .platform == "Ubuntu" and .architecture == "x86_64"'
  local stored_receipt_path stored_receipt_sha stored_role_hash stored_source stored_payload stored_allowlist stored_python stored_roles stored_receipt_id
  stored_receipt_path="$("$jq_bin" -r '.receipt_path // empty' "$authority_path")"
  [[ "$stored_receipt_path" == "$receipt_path" ]] || fail 'authority receipt_path does not match the installed receipt'
  stored_receipt_sha="$("$jq_bin" -r '.receipt_sha256 // empty' "$authority_path")"
  [[ "$stored_receipt_sha" == "$(/usr/bin/sha256sum "$receipt_path" | /usr/bin/gawk '{print $1}')" ]] || fail 'authority receipt hash does not match the receipt body'
  stored_receipt_id="$("$jq_bin" -r '.receipt_id // empty' "$authority_path")"
  [[ -n "$stored_receipt_id" && "$stored_receipt_id" == "$("$jq_bin" -r '.receipt_id // empty' "$receipt_path")" ]] || fail 'authority receipt_id does not match the receipt body'
  stored_source="$("$jq_bin" -r '.source_commit_sha' "$receipt_path")"
  [[ "$stored_source" == "$repo_commit" ]] || fail 'receipt source commit differs from the clean source checkout'
  stored_payload="$("$jq_bin" -r '.payload_manifest_sha256' "$receipt_path")"
  [[ "$stored_payload" == "$payload_manifest_sha256" ]] || fail 'receipt payload manifest hash differs from source'
  stored_allowlist="$("$jq_bin" -r '.bridge_allowlist_sha256' "$receipt_path")"
  [[ "$stored_allowlist" == "$allowlist_sha256" ]] || fail 'receipt role allowlist hash differs from source'
  stored_role_hash="$("$jq_bin" -r '.role_manifest_sha256' "$receipt_path")"
  [[ "$stored_role_hash" == "$role_manifest_sha256" ]] || fail 'receipt role manifest hash differs from live roles'
  [[ "$("$jq_bin" -cS '.rtk_source' "$receipt_path")" == "$rtk_source_json" ]] || fail 'receipt RTK source provenance differs from the locked checkout'
  stored_python="$("$jq_bin" -cS '.python313' "$receipt_path")"
  [[ "$stored_python" == "$python_json" ]] || fail 'receipt Python identity differs from the live regular executable'
  stored_roles="$("$jq_bin" -cS '.role_identities' "$receipt_path")"
  [[ "$stored_roles" == "$role_manifest_json" ]] || fail 'receipt role identities differ from live canonical executables'
  [[ "$("$jq_bin" -r '.provenance.receipt_authority_script_sha256 // empty' "$receipt_path")" == "$script_sha256" ]] || fail 'receipt authority script provenance differs from source'
  [[ "$("$jq_bin" -r '.source_commit_sha' "$authority_path")" == "$repo_commit" ]] || fail 'authority source commit differs from source'
  [[ "$("$jq_bin" -r '.payload_manifest_sha256' "$authority_path")" == "$payload_manifest_sha256" ]] || fail 'authority payload hash differs from source'
  [[ "$("$jq_bin" -r '.bridge_allowlist_sha256' "$authority_path")" == "$allowlist_sha256" ]] || fail 'authority allowlist hash differs from source'
  [[ "$("$jq_bin" -r '.role_manifest_sha256' "$authority_path")" == "$role_manifest_sha256" ]] || fail 'authority role manifest hash differs from receipt'
  [[ "$("$jq_bin" -cS '.rtk_source' "$authority_path")" == "$rtk_source_json" ]] || fail 'authority RTK source provenance differs from the locked checkout'
  [[ "$("$jq_bin" -cS '.python313' "$authority_path")" == "$python_json" ]] || fail 'authority Python identity differs from receipt'
  [[ "$("$jq_bin" -r '.provenance.receipt_authority_script_sha256 // empty' "$authority_path")" == "$script_sha256" ]] || fail 'authority script provenance differs from source'
  local expires_epoch
  expires_epoch="$(/usr/bin/date -u -d "$("$jq_bin" -r '.expires_at_utc' "$receipt_path")" '+%s' 2>/dev/null || true)"
  [[ "$expires_epoch" =~ ^[0-9]+$ && "$expires_epoch" -gt "$(/usr/bin/date -u '+%s')" ]] || fail 'receipt is expired or has an invalid expiry'
}

if [[ "$mode" == install ]]; then
  build_receipt > "$receipt_tmp"
  atomic_install_json "$receipt_tmp" "$receipt_path"
  receipt_sha256="$(/usr/bin/sha256sum "$receipt_path" | /usr/bin/gawk '{print $1}')"
  "$jq_bin" -n -cS \
    --argjson schema_version "$schema_version" \
    --arg authority_id "$authority_id" \
    --arg receipt_path "$receipt_path" \
    --arg receipt_sha256 "$receipt_sha256" \
    --arg receipt_id "$receipt_id" \
    --arg verification_status 'verified' \
    --arg source_commit_sha "$repo_commit" \
    --arg payload_manifest_sha256 "$payload_manifest_sha256" \
    --arg bridge_allowlist_sha256 "$allowlist_sha256" \
    --arg platform 'Ubuntu' \
    --arg architecture 'x86_64' \
    --argjson python313 "$python_json" \
    --argjson rtk_source "$rtk_source_json" \
    --arg role_manifest_sha256 "$role_manifest_sha256" \
    --arg source_root "$source_root" \
    --arg script_sha256 "$script_sha256" \
    '{schema_version:$schema_version, authority_id:$authority_id, receipt_path:$receipt_path, receipt_sha256:$receipt_sha256, receipt_id:$receipt_id, verification_status:$verification_status, source_commit_sha:$source_commit_sha, payload_manifest_sha256:$payload_manifest_sha256, bridge_allowlist_sha256:$bridge_allowlist_sha256, platform:$platform, architecture:$architecture, python313:$python313, rtk_source:$rtk_source, role_manifest_sha256:$role_manifest_sha256, provenance:{source_root:$source_root, source_commit_sha:$source_commit_sha, receipt_authority_script_sha256:$script_sha256, secrets_excluded:true}}' > "$authority_tmp"
  atomic_install_json "$authority_tmp" "$authority_path"
fi

validate_installed_authority
printf 'receipt authority %s: authority=%s receipt=%s source=%s rtk=%s python=%s\n' \
  "$mode" "$authority_path" "$receipt_path" "$repo_commit" "$rtk_path" "$python_path"
