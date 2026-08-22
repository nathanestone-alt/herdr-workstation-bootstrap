#!/usr/bin/env -S -i BASH_ENV= ENV= CDPATH= PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C TZ=UTC /usr/bin/bash
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
readonly receipt_chown_bin='/usr/bin/chown'
readonly receipt_setpriv_bin='/usr/bin/setpriv'
readonly receipt_getent_bin='/usr/bin/getent'
readonly receipt_id_bin='/usr/bin/id'
receipt_git_owner_uid=''
receipt_git_owner_gid=''
declare -a receipt_bound_git_paths=()
declare -A receipt_bound_git_identities=()

export PATH="$receipt_trusted_path"
export LC_ALL=C
export TZ=UTC
receipt_reject_dangerous_environment() {
  local receipt_env_name
  while IFS= read -r receipt_env_name; do
    case "$receipt_env_name" in
      BASH_ENV|ENV|CDPATH)
        [[ -z "${!receipt_env_name:-}" ]] && continue
        echo "receipt authority trust prelude: dangerous caller environment is not permitted: $receipt_env_name" >&2
        exit 24
        ;;
      IFS|SHELLOPTS|BASHOPTS|GIT_DIR|GIT_WORK_TREE|GIT_INDEX_FILE|GIT_OBJECT_DIRECTORY|GIT_ALTERNATE_OBJECT_DIRECTORIES|GIT_COMMON_DIR|GIT_CONFIG_*|LD_*|DYLD_*|LIBRARY_PATH|CPATH|C_INCLUDE_PATH|CPLUS_INCLUDE_PATH|CMAKE_PREFIX_PATH|CARGO_*|RUSTC|RUSTDOC|RUSTFLAGS|RUSTC_WRAPPER|RUSTC_WORKSPACE_WRAPPER|RUSTUP_TOOLCHAIN|RUSTUP_HOME|NODE_OPTIONS|NODE_PATH|NODE_EXTRA_CA_CERTS|NPM_CONFIG_*|COREPACK_*|PYTHONHOME|PYTHONPATH|PYTHONSTARTUP|PYTHONINSPECT|PYTHONUSERBASE|PYTHONWARNINGS|PYTHONBREAKPOINT|CURL_HOME|CURL_CA_BUNDLE|SSL_CERT_FILE|SSL_CERT_DIR|REQUESTS_CA_BUNDLE|HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|NO_PROXY|http_proxy|https_proxy|all_proxy|no_proxy|PERL5OPT|PERL5LIB|RUBYOPT|RUBYLIB|GCONV_PATH|TMPDIR)
        echo "receipt authority trust prelude: dangerous caller environment is not permitted: $receipt_env_name" >&2
        exit 24
        ;;
    esac
  done < <(compgen -e)
}
receipt_reject_dangerous_environment
if [[ -z "${HOME:-}" ]]; then
  receipt_launch_home="$($receipt_getent_bin passwd "$($receipt_id_bin -u)" 2>/dev/null | "$receipt_awk_bin" -F: 'NF >= 6 { print $6; found++ } END { exit(found == 1 ? 0 : 1) }' || true)"
  [[ "$receipt_launch_home" == /* && "$receipt_launch_home" != '/' ]] || {
    echo 'receipt authority trust prelude: the current user has no safe passwd home' >&2
    exit 24
  }
  export HOME="$receipt_launch_home"
fi
while IFS= read -r receipt_env_name; do
  case "$receipt_env_name" in
    GIT_DIR|GIT_WORK_TREE|GIT_INDEX_FILE|GIT_OBJECT_DIRECTORY|GIT_ALTERNATE_OBJECT_DIRECTORIES|GIT_COMMON_DIR|GIT_CONFIG_*)
      echo "receipt authority trust prelude: caller Git environment override is not permitted: $receipt_env_name" >&2
      exit 24
      ;;
  esac
done < <(compgen -e)

receipt_capability_payload_mode=0
receipt_capability_payload_root=''
receipt_capability_args=("$@")
for ((receipt_capability_arg_index=0; receipt_capability_arg_index < ${#receipt_capability_args[@]}; receipt_capability_arg_index++)); do
  if [[ "${receipt_capability_args[$receipt_capability_arg_index]}" == --payload-root ]]; then
    ((receipt_capability_arg_index + 1 < ${#receipt_capability_args[@]})) ||
      { echo 'receipt capability: --payload-root requires a value' >&2; exit 24; }
    receipt_capability_payload_mode=1
    receipt_capability_payload_root="${receipt_capability_args[$((receipt_capability_arg_index + 1))]}"
    break
  fi
done
receipt_capability_entry_path="$($receipt_realpath_bin -e -- "${BASH_SOURCE[0]}" 2>/dev/null || true)"
receipt_capability_entry_dir="${receipt_capability_entry_path%/*}"
receipt_capability_repo_root="$($receipt_realpath_bin -e -- "$receipt_capability_entry_dir/../.." 2>/dev/null || true)"
receipt_capability_helper="$receipt_capability_repo_root/scripts/ubuntu/launcher-capability.sh"
[[ "$receipt_capability_entry_path" == "$receipt_capability_repo_root/scripts/ubuntu/receipt-authority.sh" &&
  -f "$receipt_capability_helper" && ! -L "$receipt_capability_helper" ]] ||
  { echo 'receipt capability helper is not in the staged repository' >&2; exit 24; }
# shellcheck disable=SC1090
launcher_capability_entry_source="$receipt_capability_entry_path"
source "$receipt_capability_helper" receipt-authority "$receipt_capability_payload_mode" "$receipt_capability_payload_root"
launcher_capability_lifetime
receipt_git_owner_uid="$launcher_capability_owner_uid"
receipt_git_owner_gid="$launcher_capability_owner_gid"
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
  "$receipt_head_bin" "$receipt_cp_bin" "$receipt_rm_bin" "$receipt_chown_bin" \
  "$receipt_getent_bin" "$receipt_id_bin" "$receipt_setpriv_bin"; do
  receipt_trust_assert_binary "$receipt_trusted_binary"
done

receipt_exec_system() {
  local receipt_exec_arg
  local -a receipt_exec_args=()
  for receipt_exec_arg in "$@"; do
    if [[ "$receipt_exec_arg" == /proc/self/fd/* ]]; then
      receipt_exec_args+=("/proc/${BASHPID}/fd/${receipt_exec_arg##*/}")
    else
      receipt_exec_args+=("$receipt_exec_arg")
    fi
  done
  "$receipt_env_bin" -i \
    PATH="$receipt_trusted_path" \
    LC_ALL=C \
    TZ=UTC \
    "${receipt_exec_args[@]}"
}

receipt_exec_role() {
  local receipt_exec_arg
  local -a receipt_exec_args=()
  for receipt_exec_arg in "$@"; do
    if [[ "$receipt_exec_arg" == /proc/self/fd/* ]]; then
      receipt_exec_args+=("/proc/${BASHPID}/fd/${receipt_exec_arg##*/}")
    else
      receipt_exec_args+=("$receipt_exec_arg")
    fi
  done
  "$receipt_env_bin" -i \
    HOME=/nonexistent \
    PATH="$receipt_trusted_path" \
    LC_ALL=C \
    TZ=UTC \
    BASH_ENV= \
    ENV= \
    "${receipt_exec_args[@]}"
}

receipt_exec_python() {
  local receipt_exec_arg
  local -a receipt_exec_args=()
  for receipt_exec_arg in "$@"; do
    if [[ "$receipt_exec_arg" == /proc/self/fd/* ]]; then
      receipt_exec_args+=("/proc/${BASHPID}/fd/${receipt_exec_arg##*/}")
    else
      receipt_exec_args+=("$receipt_exec_arg")
    fi
  done
  "$receipt_env_bin" -i \
    HOME=/nonexistent \
    PATH="$receipt_trusted_path" \
    LC_ALL=C \
    TZ=UTC \
    PYTHONNOUSERSITE=1 \
    PYTHONPATH= \
    PYTHONHOME= \
    PYTHONSTARTUP= \
    "${receipt_exec_args[@]}"
}

receipt_exec_python_unprivileged() {
  local receipt_exec_arg
  local -a receipt_exec_args=()
  for receipt_exec_arg in "$@"; do
    if [[ "$receipt_exec_arg" == /proc/self/fd/* ]]; then
      receipt_exec_args+=("/proc/${BASHPID}/fd/${receipt_exec_arg##*/}")
    else
      receipt_exec_args+=("$receipt_exec_arg")
    fi
  done
  if [[ -n "$fixture_root" || "$(/usr/bin/id -u)" != 0 ]]; then
    receipt_exec_python "${receipt_exec_args[@]}"
    return
  fi
  "$receipt_env_bin" -i \
    HOME=/nonexistent \
    PATH="$receipt_trusted_path" \
    LC_ALL=C \
    TZ=UTC \
    PYTHONNOUSERSITE=1 \
    PYTHONPATH= \
    PYTHONHOME= \
    PYTHONSTARTUP= \
    PYTHONSAFEPATH=1 \
    "$receipt_setpriv_bin" --reuid="$receipt_user_uid" --regid="$receipt_user_gid" --clear-groups --no-new-privs \
    "${receipt_exec_args[@]}"
}

receipt_bind_git_path() {
  local path="$1" owner group mode identity
  [[ -e "$path" && ! -L "$path" ]] || return 1
  owner="$($receipt_stat_bin -c '%u' -- "$path" 2>/dev/null || true)"
  group="$($receipt_stat_bin -c '%g' -- "$path" 2>/dev/null || true)"
  mode="$($receipt_stat_bin -c '%a' -- "$path" 2>/dev/null || true)"
  [[ "$owner" == "$receipt_git_owner_uid" && "$group" == "$receipt_git_owner_gid" && "$mode" =~ ^[0-7]+$ && $((8#$mode & 022)) == 0 ]] || return 1
  identity="$($receipt_stat_bin -Lc '%d:%i:%u:%g:%a:%F' -- "$path" 2>/dev/null || true)"
  [[ -n "$identity" ]] || return 1
  if [[ -z "${receipt_bound_git_identities[$path]+x}" ]]; then
    receipt_bound_git_paths+=("$path")
  fi
  receipt_bound_git_identities["$path"]="$identity"
}

receipt_bind_git_layout() {
  local path
  receipt_bound_git_paths=()
  receipt_bound_git_identities=()
  for path in "$receipt_repo_root" "$receipt_repo_root/.git" "$receipt_git_dir" "$receipt_common_git_dir" \
    "$receipt_common_git_dir/objects" "$receipt_common_git_dir/refs" \
    "$receipt_common_git_dir/config" "$receipt_git_dir/index"; do
    receipt_bind_git_path "$path" || return 1
  done
  for path in "$receipt_git_dir/commondir" "$receipt_git_dir/gitdir" \
    "$receipt_common_git_dir/worktrees" "$receipt_git_dir/HEAD" "$receipt_common_git_dir/HEAD" \
    "$receipt_common_git_dir/packed-refs"; do
    [[ -e "$path" ]] || continue
    receipt_bind_git_path "$path" || return 1
  done
  if [[ -n "${receipt_worktree_record:-}" ]]; then
    receipt_bind_git_path "$receipt_worktree_record" || return 1
    receipt_bind_git_path "$receipt_worktree_record/gitdir" || return 1
  fi
}

receipt_assert_git_lifetime() {
  local path owner group mode identity
  for path in "${receipt_bound_git_paths[@]}"; do
    [[ -e "$path" && ! -L "$path" ]] || return 1
    owner="$($receipt_stat_bin -c '%u' -- "$path" 2>/dev/null || true)"
    group="$($receipt_stat_bin -c '%g' -- "$path" 2>/dev/null || true)"
    mode="$($receipt_stat_bin -c '%a' -- "$path" 2>/dev/null || true)"
    identity="$($receipt_stat_bin -Lc '%d:%i:%u:%g:%a:%F' -- "$path" 2>/dev/null || true)"
    [[ "$owner" == "$receipt_git_owner_uid" && "$group" == "$receipt_git_owner_gid" && "$mode" =~ ^[0-7]+$ && $((8#$mode & 022)) == 0 && "$identity" == "${receipt_bound_git_identities[$path]:-}" ]] || return 1
  done
}

receipt_trust_git() {
  local receipt_git_status
  receipt_assert_git_lifetime || return 70
  if "$receipt_env_bin" -i \
    HOME=/nonexistent \
    PATH="$receipt_trusted_path" \
    LC_ALL=C \
    TZ=UTC \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_SYSTEM=/dev/null \
    GIT_CONFIG_COUNT=0 \
    GIT_OPTIONAL_LOCKS=0 \
    "$receipt_git_bin" --no-replace-objects \
    -C "$receipt_repo_root" --git-dir="${receipt_git_dir:-.git}" --work-tree=. \
    -c core.attributesfile=/dev/null \
    -c core.excludesfile=/dev/null \
    -c core.hooksPath=/dev/null \
    -c core.filemode=true \
    -c core.ignoreCase=false \
    "$@"; then
    receipt_git_status=0
  else
    receipt_git_status=$?
  fi
  receipt_assert_git_lifetime || return 70
  return "$receipt_git_status"
}

receipt_trust_git_optional() {
  local output status
  output="$(receipt_trust_git "$@" 2>/dev/null)" || {
    status=$?
    ((status == 1)) || return "$status"
  }
  printf '%s\n' "$output"
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
    receipt_worktree_record="$receipt_common_git_dir/worktrees/${receipt_git_dir##*/}"
    [[ -d "$receipt_common_git_dir/worktrees" && ! -L "$receipt_common_git_dir/worktrees" && \
      "$($receipt_realpath_bin -e -- "$receipt_worktree_record" 2>/dev/null || true)" == "$receipt_git_dir" && \
      -f "$receipt_git_dir/gitdir" && ! -L "$receipt_git_dir/gitdir" ]] || {
      receipt_trust_fail 'receipt Git worktree record is not exact and reciprocal'
    }
    receipt_worktree_record_pointer="$(< "$receipt_git_dir/gitdir")"
    receipt_worktree_record_canonical="$($receipt_realpath_bin -e -- "$receipt_worktree_record_pointer" 2>/dev/null || true)"
    [[ "$receipt_worktree_record_pointer" != *$'\n'* && "$receipt_worktree_record_pointer" != *$'\r'* && \
      "$receipt_worktree_record_canonical" == "$receipt_repo_root/.git" ]] || {
      receipt_trust_fail 'receipt Git worktree record does not own this source path'
    }
    while IFS= read -r -d '' receipt_other_worktree_record; do
      [[ "${receipt_other_worktree_record%/gitdir}" == "$receipt_git_dir" ]] && continue
      receipt_other_worktree_pointer="$(< "$receipt_other_worktree_record")"
      [[ "$receipt_other_worktree_pointer" != *$'\n'* && "$receipt_other_worktree_pointer" != *$'\r'* ]] || {
        receipt_trust_fail 'receipt Git worktree record contains unsafe text'
      }
      [[ "$($receipt_realpath_bin -e -- "$receipt_other_worktree_pointer" 2>/dev/null || true)" != "$receipt_repo_root/.git" ]] || {
        receipt_trust_fail 'receipt Git worktree source ownership is ambiguous'
      }
    done < <("$receipt_find_bin" -P "$receipt_common_git_dir/worktrees" -mindepth 2 -maxdepth 2 -type f -name gitdir -print0 2>/dev/null)
  fi
  [[ -n "$receipt_git_dir" && -d "$receipt_git_dir" && ! -L "$receipt_git_dir" && \
    -n "$receipt_common_git_dir" && -d "$receipt_common_git_dir" && ! -L "$receipt_common_git_dir" ]] || receipt_trust_fail 'receipt Git directory is not canonical'
  receipt_trust_reject_symlink_components "$receipt_git_dir" || receipt_trust_fail 'receipt Git directory contains a symlinked component'
  receipt_trust_reject_symlink_components "$receipt_common_git_dir" || receipt_trust_fail 'receipt Git common directory contains a symlinked component'
  receipt_objects_dir="$receipt_common_git_dir/objects"
  receipt_refs_dir="$receipt_common_git_dir/refs"
  receipt_config_path="$receipt_common_git_dir/config"
  receipt_index_path="$receipt_git_dir/index"
  [[ -d "$receipt_objects_dir" && ! -L "$receipt_objects_dir" && \
    "$($receipt_realpath_bin -e -- "$receipt_objects_dir" 2>/dev/null || true)" == "$receipt_objects_dir" && \
    -d "$receipt_refs_dir" && ! -L "$receipt_refs_dir" && \
    "$($receipt_realpath_bin -e -- "$receipt_refs_dir" 2>/dev/null || true)" == "$receipt_refs_dir" && \
    -f "$receipt_config_path" && ! -L "$receipt_config_path" && -f "$receipt_index_path" && ! -L "$receipt_index_path" ]] || {
    receipt_trust_fail 'receipt Git object, ref, config, or index storage is unsafe'
  }
  receipt_bind_git_layout || receipt_trust_fail 'receipt Git metadata owner, mode, or identity is unsafe'
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
  receipt_dangerous_config="$(receipt_trust_git_optional config --local --no-includes --name-only --get-regexp \
    '^(include|filter\.|diff\..*\.textconv$|merge\..*\.driver$|credential\.|url\..*\.insteadOf$|core\.(attributesfile|excludesfile|fsmonitor|hooksPath|worktree|alternateRefsCommand|askPass|gitProxy|sshCommand)$|extensions\.|remote\..*\.(promisor|partialclonefilter|uploadpack|receivepack)$)' \
    )"
  [[ -z "$receipt_dangerous_config" ]] || receipt_trust_fail 'receipt repository-local Git configuration is unsafe'
  receipt_sparse_checkout="$(receipt_trust_git_optional config --local --no-includes --bool --get core.sparseCheckout)" || receipt_trust_fail 'receipt Git lifetime failed while reading sparse-checkout configuration'
  receipt_sparse_index="$(receipt_trust_git_optional config --local --no-includes --bool --get index.sparse)" || receipt_trust_fail 'receipt Git lifetime failed while reading sparse-index configuration'
  [[ "$receipt_sparse_checkout" != true && \
    "$receipt_sparse_index" != true && \
    ! -e "$receipt_common_git_dir/info/sparse-checkout" && \
    ! -e "$receipt_git_dir/info/sparse-checkout" ]] || receipt_trust_fail 'receipt repository sparse checkout metadata is unsafe'
  receipt_git_top_level="$(receipt_trust_git rev-parse --show-toplevel 2>/dev/null)" || receipt_trust_fail 'receipt Git lifetime failed while reading the worktree root'
  receipt_git_absolute_dir="$(receipt_trust_git rev-parse --absolute-git-dir 2>/dev/null)" || receipt_trust_fail 'receipt Git lifetime failed while reading the Git directory'
  receipt_git_inside_worktree="$(receipt_trust_git rev-parse --is-inside-work-tree 2>/dev/null)" || receipt_trust_fail 'receipt Git lifetime failed while reading worktree state'
  receipt_git_bare="$(receipt_trust_git rev-parse --is-bare-repository 2>/dev/null)" || receipt_trust_fail 'receipt Git lifetime failed while reading bare state'
  receipt_git_shallow="$(receipt_trust_git rev-parse --is-shallow-repository 2>/dev/null)" || receipt_trust_fail 'receipt Git lifetime failed while reading shallow state'
  [[ "$receipt_git_top_level" == "$receipt_repo_root" && \
    "$receipt_git_absolute_dir" == "$receipt_git_dir" && \
    "$receipt_git_inside_worktree" == true && \
    "$receipt_git_bare" == false && \
    "$receipt_git_shallow" == false ]] || {
    receipt_trust_fail 'receipt repository topology is not a local full worktree'
  }
  receipt_commit="$(receipt_trust_git rev-parse --verify HEAD^{commit} 2>/dev/null)" || receipt_trust_fail 'receipt Git lifetime failed while reading HEAD'
  [[ "$receipt_commit" =~ ^[0-9a-f]{40}$ ]] || receipt_trust_fail 'receipt HEAD is not a full committed object'
  receipt_trust_git cat-file -e "$receipt_commit^{commit}" || receipt_trust_fail 'receipt HEAD object is unavailable'
  receipt_helper_tree="$(receipt_trust_git ls-tree "$receipt_commit" -- scripts/ubuntu/source-attestation.sh 2>/dev/null)" || receipt_trust_fail 'receipt Git lifetime failed while reading the committed helper tree'
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
  receipt_materialized_oid="$(receipt_trust_git hash-object --no-filters --stdin < "$receipt_private_helper")"
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
  if [[ -z "$fixture_root" ]]; then
    [[ "$(/usr/bin/id -u)" == 0 ]] || receipt_trust_fail 'production payload receipt requires root'
    while IFS= read -r -d '' receipt_stage_entry; do
      [[ "$(receipt_exec_system "$receipt_stat_bin" -c '%u' -- "$receipt_stage_entry" 2>/dev/null || true)" == 0 && \
        "$(receipt_exec_system "$receipt_stat_bin" -c '%a' -- "$receipt_stage_entry" 2>/dev/null || true)" =~ ^[0-7]+$ && \
        $((8#$(receipt_exec_system "$receipt_stat_bin" -c '%a' -- "$receipt_stage_entry" 2>/dev/null || echo 777) & 022)) == 0 ]] || {
        receipt_trust_fail 'payload receipt stage is not root-owned and non-writable'
      }
    done < <("$receipt_find_bin" -P "$receipt_prelude_payload_root" -print0)
  fi
  receipt_trust_reject_symlink_components "$receipt_prelude_payload_root" || receipt_trust_fail 'payload root contains symlinked components'
  [[ -f "$receipt_prelude_payload_manifest" && ! -L "$receipt_prelude_payload_manifest" && \
    "$($receipt_head_bin -n 1 -- "$receipt_prelude_payload_manifest")" == herdr-payload-manifest-v1 ]] || {
    receipt_trust_fail 'payload manifest is missing or malformed'
  }
  [[ "$receipt_prelude_payload_hash" =~ ^[0-9a-f]{64}$ ]] || {
    receipt_trust_fail 'payload manifest requires a mandatory external SHA-256 binding'
  }
  [[ "$receipt_prelude_source_commit" =~ ^[0-9a-f]{40}$ ]] || {
    receipt_trust_fail 'payload source requires a mandatory externally bound commit'
  }
  [[ "$($receipt_sha256_bin -- "$receipt_prelude_payload_manifest" | "$receipt_awk_bin" '{print $1}')" == "$receipt_prelude_payload_hash" ]] || {
    receipt_trust_fail 'payload manifest hash does not match the trusted stage'
  }
  [[ -f "$receipt_prelude_source_manifest" && ! -L "$receipt_prelude_source_manifest" && \
    "$($receipt_head_bin -n 1 -- "$receipt_prelude_source_manifest")" == herdr-source-snapshot-v2 ]] || {
    receipt_trust_fail 'source snapshot manifest is missing or malformed'
  }
  receipt_prelude_manifest_commit="$($receipt_awk_bin -F= '$1 == "commit" { print $2; found++ } END { exit(found == 1 ? 0 : 1) }' "$receipt_prelude_source_manifest" 2>/dev/null || true)"
  [[ "$receipt_prelude_manifest_commit" == "$receipt_prelude_source_commit" ]] || {
    receipt_trust_fail 'source snapshot commit is not externally bound'
  }
  receipt_payload_helper_record="$($receipt_awk_bin -F '\t' '$1 == "F" && $4 == "source/scripts/ubuntu/source-attestation.sh" { print; found++ } END { exit(found == 1 ? 0 : 1) }' "$receipt_prelude_payload_manifest" 2>/dev/null || true)"
  IFS=$'\t' read -r _ receipt_payload_helper_mode receipt_payload_helper_sha receipt_payload_helper_path <<< "$receipt_payload_helper_record"
  receipt_source_helper_record="$($receipt_awk_bin -F '\t' '$1 == "F" && $5 == "scripts/ubuntu/source-attestation.sh" { print; found++ } END { exit(found == 1 ? 0 : 1) }' "$receipt_prelude_source_manifest" 2>/dev/null || true)"
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

receipt_repo_root="$launcher_capability_repo_root"
receipt_script_path="$launcher_capability_entry_path"
receipt_script_dir="$receipt_repo_root/scripts/ubuntu"
[[ -n "$receipt_script_path" && "$receipt_script_path" == "$receipt_repo_root/scripts/ubuntu/receipt-authority.sh" ]] || {
  receipt_trust_fail 'receipt authority entrypoint is not at the canonical repository path'
}

receipt_prelude_source_root=''
receipt_prelude_source_manifest=''
receipt_prelude_payload_root=''
receipt_prelude_payload_manifest=''
receipt_prelude_payload_hash=''
receipt_prelude_source_commit=''
receipt_prelude_args=("$@")
receipt_user_home_hint="${HOME:-}"
for ((receipt_arg_index=0; receipt_arg_index < ${#receipt_prelude_args[@]}; receipt_arg_index++)); do
  case "${receipt_prelude_args[$receipt_arg_index]}" in
    --user-home)
      ((receipt_arg_index + 1 < ${#receipt_prelude_args[@]})) || receipt_trust_fail '--user-home requires a value'
      receipt_user_home_hint="${receipt_prelude_args[$((receipt_arg_index + 1))]}"
      ((receipt_arg_index++))
      ;;
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
    --source-commit)
      ((receipt_arg_index + 1 < ${#receipt_prelude_args[@]})) || receipt_trust_fail '--source-commit requires a value'
      receipt_prelude_source_commit="${receipt_prelude_args[$((receipt_arg_index + 1))]}"
      ((receipt_arg_index++))
      ;;
  esac
done

receipt_repo_mode=0
receipt_user_home_hint="$($receipt_realpath_bin -e -- "$receipt_user_home_hint" 2>/dev/null || true)"
if [[ -d "$receipt_user_home_hint" && ! -L "$receipt_user_home_hint" ]]; then
  attestation_git_owner_uid="$($receipt_stat_bin -c '%u' -- "$receipt_user_home_hint" 2>/dev/null || true)"
  attestation_git_owner_gid="$($receipt_stat_bin -c '%g' -- "$receipt_user_home_hint" 2>/dev/null || true)"
fi
if [[ -e "$receipt_repo_root/.git" && ! -L "$receipt_repo_root/.git" ]]; then
  receipt_repo_mode=1
  receipt_trust_reject_symlink_components "$receipt_repo_root" || receipt_trust_fail 'receipt repository root contains a symlinked component'
  receipt_materialize_helper_from_git
else
  receipt_materialize_helper_from_payload
fi

# shellcheck disable=SC1090
attestation_capability_owner_uid="$launcher_capability_owner_uid"
attestation_capability_owner_gid="$launcher_capability_owner_gid"
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
source_manifest=''
source_manifest_supplied=0
payload_root=''
payload_manifest_arg=''
source_commit_binding=''
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
  --source-manifest PATH   Exact committed source snapshot manifest.
  --payload-root PATH      Root of the root-owned verified payload staging tree.
  --payload-manifest PATH  Verified payload manifest within PAYLOAD_ROOT.
  --payload-manifest-sha256 SHA256  Internal root-stage payload manifest binding.
  --source-commit SHA1     External binding for the committed source snapshot.
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
    --source-manifest) [[ $# -ge 2 ]] || { usage; exit 2; }; source_manifest="$2"; shift 2 ;;
    --payload-root) [[ $# -ge 2 ]] || { usage; exit 2; }; payload_root="$2"; shift 2 ;;
    --payload-manifest) [[ $# -ge 2 ]] || { usage; exit 2; }; payload_manifest_arg="$2"; shift 2 ;;
    --payload-manifest-sha256) [[ $# -ge 2 ]] || { usage; exit 2; }; receipt_prelude_payload_hash="$2"; shift 2 ;;
    --source-commit) [[ $# -ge 2 ]] || { usage; exit 2; }; source_commit_binding="$2"; shift 2 ;;
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
  && ( -z "$source_manifest" || "$source_manifest" == /* ) \
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
  source_manifest_supplied=1
  source_manifest="$(/usr/bin/realpath -e -- "$source_manifest" 2>/dev/null || true)"
  [[ "$source_manifest" == "$source_root/.source-attestation" ]] || fail 'source manifest is not bound to the source snapshot'
  attestation_verify_snapshot "$source_root" "$source_manifest" "$source_commit_binding" || fail 'source snapshot manifest is invalid or externally unbound'
else
  attestation_create_git_snapshot "$source_root" '' '' || fail 'source Git checkout failed hardened source attestation'
  source_root="$attestation_snapshot_dir"
  source_manifest="$attestation_snapshot_manifest"
fi
source_commit="$attestation_snapshot_commit"
[[ "$source_commit" =~ ^[0-9a-f]{40}$ ]] || fail 'source snapshot commit is not a full commit'
[[ "$source_commit" == "$launcher_capability_policy_commit" ]] ||
  fail 'source snapshot commit does not equal the approved policy commit'
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
  [[ "$source_commit_binding" == "$receipt_prelude_source_commit" && "$source_commit_binding" =~ ^[0-9a-f]{40}$ ]] || fail 'payload source commit binding is missing or inconsistent'
  [[ "$source_commit_binding" == "$launcher_capability_policy_commit" ]] || fail 'payload source commit does not equal the approved policy commit'
  payload_root="$(/usr/bin/realpath -e -- "$payload_root" 2>/dev/null || true)"
  payload_manifest_arg="$(/usr/bin/realpath -e -- "$payload_manifest_arg" 2>/dev/null || true)"
  [[ "$payload_manifest_arg" == "$payload_root/.payload-manifest" ]] || fail 'payload manifest is not bound to the payload root'
  attestation_verify_payload_manifest "$payload_root" "$payload_manifest_arg" "$receipt_prelude_payload_hash" || fail 'payload manifest is invalid or externally unbound'
fi
[[ "$source_manifest_supplied" == 0 || -n "$payload_root" ]] || fail 'a supplied source manifest requires an externally bound payload'

user_home="$(/usr/bin/realpath -e -- "$user_home" 2>/dev/null || true)"
[[ -n "$user_home" && -d "$user_home" ]] || fail 'managed user home does not exist'
receipt_user_uid="$(/usr/bin/stat -c '%u' -- "$user_home" 2>/dev/null || true)"
receipt_user_gid="$(/usr/bin/stat -c '%g' -- "$user_home" 2>/dev/null || true)"
[[ "$receipt_user_uid" =~ ^[0-9]+$ && "$receipt_user_gid" =~ ^[0-9]+$ && "$receipt_user_uid" != 0 ]] || fail 'managed user home must belong to a non-root account'
if [[ -z "$fixture_root" ]]; then
  [[ "$(/usr/bin/id -u)" == 0 && "$(/usr/bin/stat -c '%u' -- "$receipt_setpriv_bin")" == 0 ]] || fail 'root Python probes require a root-owned setpriv boundary'
fi
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

reject_symlink_components "$user_home" || fail "managed user home contains a symlink: $user_home"
[[ "$(/usr/bin/realpath -e -- "$user_home" 2>/dev/null || true)" == "$user_home" ]] || fail "managed user home is not lexically canonical: $user_home"

lock_file="$source_root/config/ubuntu-toolchain.lock"
allowlist_file="$source_root/config/receipt-authority-role-allowlist.txt"
payload_manifest="$source_root/config/payload-manifest.sha256"
[[ -f "$lock_file" && -f "$allowlist_file" && -f "$payload_manifest" ]] || fail 'source authority inputs are incomplete'
# shellcheck disable=SC1090
source "$lock_file"

[[ "${RTK_VERSION:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'RTK_VERSION is not a locked semantic version'
[[ "${RTK_URL:-}" == "https://github.com/rtk-ai/rtk/releases/download/v$RTK_VERSION/rtk-x86_64-unknown-linux-musl.tar.gz" ]] ||
  fail 'RTK_URL is not the locked official x86-64 Linux release URL'
[[ "${RTK_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] || fail 'RTK_SHA256 is not a lowercase SHA-256 value'

repo_commit="$source_commit"
[[ "$repo_commit" =~ ^[0-9a-f]{40}$ ]] || fail 'source snapshot commit is not a full commit'

payload_manifest_sha256="$(/usr/bin/sha256sum "$payload_manifest" | /usr/bin/gawk '{print $1}')"
allowlist_sha256="$(/usr/bin/sha256sum "$allowlist_file" | /usr/bin/gawk '{print $1}')"
script_sha256="$expected_script_sha256"

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

if [[ -z "$fixture_root" ]]; then
  [[ "${role_path[bash]}" == /usr/bin/bash && "${role_path[git]}" == /usr/bin/git && \
    "${role_path[gh]}" == /usr/bin/gh && \
    ( "${role_path[pwsh]}" == /usr/bin/pwsh || "${role_path[pwsh]}" == /opt/microsoft/powershell/7/pwsh ) ]] || {
    fail 'system-only receipt roles are not bound to canonical system binaries'
  }
  for role in bash git gh pwsh; do
    [[ "$(/usr/bin/stat -c '%u' -- "${role_path[$role]}" 2>/dev/null || true)" == 0 && \
      "$(/usr/bin/stat -c '%a' -- "${role_path[$role]}" 2>/dev/null || true)" =~ ^[0-7]+$ && \
      $((8#$(/usr/bin/stat -c '%a' -- "${role_path[$role]}" 2>/dev/null || echo 777) & 022)) == 0 ]] || {
      fail "system-only role is not root-owned and non-writable: $role"
    }
  done
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

declare -A role_execution_path role_execution_command_path role_execution_fd role_execution_owner role_source_identity role_source_hash role_execution_hash
receipt_exec_stage_dir=''

receipt_stage_executable() {
  local role="$1"
  local path="${role_path[$role]}"
  local mode source_id live_id source_hash stage stage_fd stage_id stage_hash current_id current_hash owner_pid descriptor_path
  exec {stage_fd}<"$path" || fail "could not open stable $role source"
  owner_pid="$BASHPID"
  descriptor_path="/proc/$owner_pid/fd/$stage_fd"
  mode="$(receipt_exec_system "$receipt_stat_bin" -c '%a' -- "$path" 2>/dev/null || true)"
  source_id="$(receipt_exec_system "$receipt_stat_bin" -Lc '%d:%i' -- "$descriptor_path" 2>/dev/null || true)"
  live_id="$(receipt_exec_system "$receipt_stat_bin" -Lc '%d:%i' -- "$path" 2>/dev/null || true)"
  source_hash="$(receipt_exec_system "$receipt_sha256_bin" -- "$descriptor_path" | "$receipt_awk_bin" '{print $1}')"
  [[ "$source_id" =~ ^[0-9]+:[0-9]+$ && "$source_hash" =~ ^[0-9a-f]{64}$ && "$mode" =~ ^[0-7]+$ ]] || {
    eval "exec ${stage_fd}<&-" 2>/dev/null || true
    fail "$role source identity is invalid"
  }
  [[ "$source_id" == "$live_id" ]] || {
    eval "exec ${stage_fd}<&-" 2>/dev/null || true
    fail "$role source changed while opening"
  }
  receipt_test_pause "before-$role-staging"
  stage="$receipt_exec_stage_dir/$role"
  receipt_exec_system "$receipt_cp_bin" -- "$descriptor_path" "$stage" || {
    eval "exec ${stage_fd}<&-" 2>/dev/null || true
    fail "$role could not be copied from its stable descriptor"
  }
  # Re-open the canonical source after the first open and compare it with the
  # bytes copied from the stable descriptor.  A same-user replacement is
  # rejected; the staged descriptor is the only object later executed.
  current_id="$(receipt_exec_system "$receipt_stat_bin" -Lc '%d:%i' -- "$path" 2>/dev/null || true)"
  current_hash="$(receipt_exec_system "$receipt_sha256_bin" -- "$path" 2>/dev/null | "$receipt_awk_bin" '{print $1}' || true)"
  [[ "$current_id" == "$source_id" && "$current_hash" == "$source_hash" ]] || {
    eval "exec ${stage_fd}<&-" 2>/dev/null || true
    fail "$role source changed during staging"
  }
  receipt_exec_system "$receipt_chmod_bin" "$mode" -- "$stage"
  stage_id="$(receipt_exec_system "$receipt_stat_bin" -Lc '%d:%i' -- "$stage" 2>/dev/null || true)"
  stage_hash="$(receipt_exec_system "$receipt_sha256_bin" -- "$stage" | "$receipt_awk_bin" '{print $1}')"
  [[ "$stage_id" =~ ^[0-9]+:[0-9]+$ && "$stage_hash" == "$source_hash" ]] || fail "$role staged identity does not match its source"
  if [[ -z "$fixture_root" ]]; then
    receipt_exec_system "$receipt_chown_bin" 0:0 -- "$stage" "$receipt_exec_stage_dir"
    receipt_exec_system "$receipt_chmod_bin" 0500 -- "$stage"
  fi
  eval "exec ${stage_fd}<&-" 2>/dev/null || true
  exec {stage_fd}<"$stage" || fail "could not open stable $role executable"
  role_execution_path["$role"]="/proc/self/fd/$stage_fd"
  role_execution_command_path["$role"]="$descriptor_path"
  role_execution_fd["$role"]="$stage_fd"
  role_execution_owner["$role"]="$owner_pid"
  role_source_identity["$role"]="$source_id"
  role_source_hash["$role"]="$source_hash"
  role_execution_hash["$role"]="$stage_hash"
  receipt_test_pause "after-$role-staging"
}

receipt_assert_source_identity() {
  local role="$1"
  local path="${role_path[$role]}"
  local current_id current_hash
  current_id="$(receipt_exec_system "$receipt_stat_bin" -Lc '%d:%i' -- "$path" 2>/dev/null || true)"
  current_hash="$(receipt_exec_system "$receipt_sha256_bin" -- "$path" 2>/dev/null | "$receipt_awk_bin" '{print $1}' || true)"
  [[ "$current_id" == "${role_source_identity[$role]}" && "$current_hash" == "${role_source_hash[$role]}" ]] || {
    fail "$role source identity changed during receipt authority execution"
  }
  [[ "$(receipt_exec_system "$receipt_sha256_bin" -- "${role_execution_command_path[$role]}" | "$receipt_awk_bin" '{print $1}')" == "${role_execution_hash[$role]}" ]] || {
    fail "$role stable execution object changed"
  }
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

receipt_exec_stage_dir="$($receipt_mktemp_bin -d /tmp/herdr-receipt-exec.XXXXXX)"
receipt_register_cleanup "$receipt_exec_stage_dir"
receipt_exec_system "$receipt_chmod_bin" 0700 -- "$receipt_exec_stage_dir"
if [[ -z "$fixture_root" ]]; then
  receipt_exec_system "$receipt_chown_bin" 0:0 -- "$receipt_exec_stage_dir"
fi
for role in "${roles[@]}" python313; do
  receipt_stage_executable "$role"
done

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
receipt_register_cleanup "$runtime_manifest_file"
stdlib_manifest_file="$($receipt_mktemp_bin /tmp/herdr-receipt-stdlib.XXXXXX)"
receipt_register_cleanup "$stdlib_manifest_file"
role_fragments="$($receipt_mktemp_bin /tmp/herdr-receipt-roles.XXXXXX)"
receipt_register_cleanup "$role_fragments"
receipt_tmp="$($receipt_mktemp_bin /tmp/herdr-receipt-body.XXXXXX)"
receipt_register_cleanup "$receipt_tmp"
authority_tmp="$($receipt_mktemp_bin /tmp/herdr-receipt-authority.XXXXXX)"
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
  local path="${role_execution_command_path[$role]}"
  local output first
  output="$(receipt_exec_role "$path" --version 2>&1)" || fail "$role --version failed"
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
[[ "${role_version[rtk]}" == "rtk $RTK_VERSION" ]] ||
  fail "RTK measured version does not match lock: ${role_version[rtk]} (expected rtk $RTK_VERSION)"

python_version_output="$(receipt_exec_python_unprivileged "${role_execution_command_path[python313]}" --version 2>&1)" || fail 'python3.13 --version failed'
[[ "$python_version_output" == "Python $PYTHON_VERSION" ]] || fail "Python version does not match lock: $python_version_output"
python_probe="$(receipt_exec_python_unprivileged "${role_execution_command_path[python313]}" -c 'import json, os, platform, sys, sysconfig; print(json.dumps({"version": platform.python_version(), "version_info": list(sys.version_info[:5]), "implementation": platform.python_implementation(), "executable": os.path.realpath(sys.executable), "prefix": os.path.realpath(sys.prefix), "base_prefix": os.path.realpath(sys.base_prefix), "stdlib": os.path.realpath(sysconfig.get_path("stdlib"))}, separators=(",", ":"))) ' 2>&1)" || fail 'Python identity probe failed'
python_probe_executable="$(printf '%s' "$python_probe" | "$jq_bin" -r '.executable' 2>/dev/null || true)"
python_probe_prefix="$(printf '%s' "$python_probe" | "$jq_bin" -r '.prefix' 2>/dev/null || true)"
python_probe_base_prefix="$(printf '%s' "$python_probe" | "$jq_bin" -r '.base_prefix' 2>/dev/null || true)"
python_probe_stdlib="$(printf '%s' "$python_probe" | "$jq_bin" -r '.stdlib' 2>/dev/null || true)"
[[ "$python_probe_executable" == "$(/usr/bin/realpath -e -- "${role_execution_command_path[python313]}" 2>/dev/null || true)" ]] || fail 'Python probe executable differs from the stable launcher'
[[ "$python_probe_prefix" == "$user_home/.local" ]] || fail 'Python probe prefix differs from the managed user environment'
[[ "$python_probe_base_prefix" == "$python_runtime_root" ]] || fail 'Python probe base_prefix differs from the locked managed runtime'
[[ "$python_probe_stdlib" == "$python_stdlib_root" ]] || fail 'Python probe stdlib differs from the locked managed runtime'
python_json="$("$jq_bin" -n -cS \
  --arg executable "$python_path" \
  --arg sha256 "$($receipt_sha256_bin "$python_path" | /usr/bin/gawk '{print $1}')" \
  --arg execution_path "${role_execution_path[python313]}" \
  --arg execution_sha256 "${role_execution_hash[python313]}" \
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
  '{executable:$executable, sha256:$sha256, execution_path:$execution_path, execution_sha256:$execution_sha256, version:$version, version_info:$version_info, implementation:$implementation, venv:{path:$venv_path, sha256:$venv_sha256, home:$venv_home, include_system_site_packages:($venv_site == "true"), version:$venv_version}, runtime:{root:$runtime_root, manifest_sha256:$runtime_manifest_sha256, file_count:$runtime_file_count, stdlib_root:$stdlib_root, stdlib_manifest_sha256:$stdlib_manifest_sha256, stdlib_file_count:$stdlib_file_count, prefix:$prefix, base_prefix:$base_prefix, stdlib:$stdlib}}')" || fail 'Python identity probe was not valid JSON'
[[ "$(printf '%s' "$python_probe" | "$jq_bin" -r '.version')" == "$PYTHON_VERSION" ]] || fail 'Python probe version mismatch'
[[ "$(printf '%s' "$python_probe" | "$jq_bin" -r '.implementation')" == CPython ]] || fail 'Python implementation is not CPython'
for role in "${roles[@]}" python313; do
  receipt_assert_source_identity "$role"
done

for role in "${roles[@]}"; do
  role_json="$("$jq_bin" -cn \
    --arg role "$role" \
    --arg executable "${role_path[$role]}" \
    --arg sha256 "$($receipt_sha256_bin "${role_path[$role]}" | /usr/bin/gawk '{print $1}')" \
    --arg execution_path "${role_execution_path[$role]}" \
    --arg execution_sha256 "${role_execution_hash[$role]}" \
    --arg registry_id "${role_registry[$role]}" \
    --arg source_commit_sha "$repo_commit" \
    --arg kind '#961-role-manifest-v1' \
    --arg version "${role_version[$role]}" \
    --arg version_output_sha256 "${role_version_hash[$role]}" \
    --arg implementation "${role_implementation[$role]}" \
    '{($role): {executable:$executable, sha256:$sha256, execution_path:$execution_path, execution_sha256:$execution_sha256, registry_id:$registry_id, source_commit_sha:$source_commit_sha, source_attestation:{kind:$kind, canonical_path:$executable, file_sha256:$sha256}, version:$version, version_argv:["--version"], version_output_sha256:$version_output_sha256, implementation:$implementation}}')"
  printf '%s\n' "$role_json" >> "$role_fragments"
done
role_manifest_json="$("$jq_bin" -sc 'add' "$role_fragments" | "$jq_bin" -cS .)" || fail 'role manifest is not valid JSON'
role_manifest_sha256="$(printf '%s' "$role_manifest_json" | /usr/bin/sha256sum | /usr/bin/gawk '{print $1}')"
rtk_release_json="$("$jq_bin" -cSn \
  --arg version "$RTK_VERSION" \
  --arg url "$RTK_URL" \
  --arg sha256 "$RTK_SHA256" \
  '{version:$version, url:$url, sha256:$sha256, archive:($url | split("/") | last)}')"

issued_at_utc="$(/usr/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
expires_at_utc="$(/usr/bin/date -u -d '+30 days' '+%Y-%m-%dT%H:%M:%SZ')"
receipt_id="issue-961-bootstrap-${repo_commit:0:12}-$(/usr/bin/date -u '+%Y%m%dT%H%M%SZ')"

build_receipt() {
  "$jq_bin" -n -cS \
    --argjson schema_version "$schema_version" \
    --arg receipt_id "$receipt_id" \
    --arg verification_status 'verified' \
    --arg source_commit_sha "$repo_commit" \
    --argjson clean true \
    --argjson python313_lock_verified true \
    --arg payload_manifest_sha256 "$payload_manifest_sha256" \
    --arg bridge_allowlist_sha256 "$allowlist_sha256" \
    --arg platform 'Ubuntu' \
    --arg architecture 'x86_64' \
    --arg issued_at_utc "$issued_at_utc" \
    --arg expires_at_utc "$expires_at_utc" \
    --argjson python313 "$python_json" \
    --argjson role_identities "$role_manifest_json" \
    --argjson rtk_release "$rtk_release_json" \
    --arg role_manifest_sha256 "$role_manifest_sha256" \
    --arg source_root "$source_root" \
    --arg script_sha256 "$script_sha256" \
    '{schema_version:$schema_version, receipt_id:$receipt_id, verification_status:$verification_status, source_commit_sha:$source_commit_sha, clean:$clean, python313_lock_verified:$python313_lock_verified, payload_manifest_sha256:$payload_manifest_sha256, bridge_allowlist_sha256:$bridge_allowlist_sha256, platform:$platform, architecture:$architecture, issued_at_utc:$issued_at_utc, expires_at_utc:$expires_at_utc, python313:$python313, role_identities:$role_identities, rtk_release:$rtk_release, role_manifest_sha256:$role_manifest_sha256, provenance:{authority_id:"#961-installation-authority-v1", producer:"herdr-workstation-bootstrap", source_root:$source_root, source_commit_sha:$source_commit_sha, receipt_authority_script_sha256:$script_sha256, authority_mode:"authoritative", secrets_excluded:true}}'
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
  validate_json_field "$receipt_path" '.schema_version == 1 and .verification_status == "verified" and .clean == true and .python313_lock_verified == true and (.source_commit_sha|test("^[0-9a-f]{40}$")) and .platform == "Ubuntu" and .architecture == "x86_64" and (.role_identities|type == "object") and ((.role_identities|keys) == ["bash","gh","git","node","pwsh","rtk"]) and (.rtk_release|type == "object")'
  validate_json_field "$authority_path" '.schema_version == 1 and .authority_id == "#961-installation-authority-v1" and .verification_status == "verified" and (.source_commit_sha|test("^[0-9a-f]{40}$")) and .platform == "Ubuntu" and .architecture == "x86_64" and (.rtk_release|type == "object")'
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
  [[ "$("$jq_bin" -cS '.rtk_release' "$receipt_path")" == "$rtk_release_json" ]] || fail 'receipt RTK release provenance differs from the lock'
  stored_python="$("$jq_bin" -cS '.python313' "$receipt_path")"
  [[ "$stored_python" == "$python_json" ]] || fail 'receipt Python identity differs from the live regular executable'
  stored_roles="$("$jq_bin" -cS '.role_identities' "$receipt_path")"
  [[ "$stored_roles" == "$role_manifest_json" ]] || fail 'receipt role identities differ from live canonical executables'
  [[ "$("$jq_bin" -r '.provenance.receipt_authority_script_sha256 // empty' "$receipt_path")" == "$script_sha256" ]] || fail 'receipt authority script provenance differs from source'
  [[ "$("$jq_bin" -r '.source_commit_sha' "$authority_path")" == "$repo_commit" ]] || fail 'authority source commit differs from source'
  [[ "$("$jq_bin" -r '.payload_manifest_sha256' "$authority_path")" == "$payload_manifest_sha256" ]] || fail 'authority payload hash differs from source'
  [[ "$("$jq_bin" -r '.bridge_allowlist_sha256' "$authority_path")" == "$allowlist_sha256" ]] || fail 'authority allowlist hash differs from source'
  [[ "$("$jq_bin" -r '.role_manifest_sha256' "$authority_path")" == "$role_manifest_sha256" ]] || fail 'authority role manifest hash differs from receipt'
  [[ "$("$jq_bin" -cS '.rtk_release' "$authority_path")" == "$rtk_release_json" ]] || fail 'authority RTK release provenance differs from the lock'
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
    --argjson rtk_release "$rtk_release_json" \
    --arg role_manifest_sha256 "$role_manifest_sha256" \
    --arg source_root "$source_root" \
    --arg script_sha256 "$script_sha256" \
    '{schema_version:$schema_version, authority_id:$authority_id, receipt_path:$receipt_path, receipt_sha256:$receipt_sha256, receipt_id:$receipt_id, verification_status:$verification_status, source_commit_sha:$source_commit_sha, payload_manifest_sha256:$payload_manifest_sha256, bridge_allowlist_sha256:$bridge_allowlist_sha256, platform:$platform, architecture:$architecture, python313:$python313, rtk_release:$rtk_release, role_manifest_sha256:$role_manifest_sha256, provenance:{source_root:$source_root, source_commit_sha:$source_commit_sha, receipt_authority_script_sha256:$script_sha256, secrets_excluded:true}}' > "$authority_tmp"
  atomic_install_json "$authority_tmp" "$authority_path"
fi

validate_installed_authority
printf 'receipt authority %s: authority=%s receipt=%s source=%s rtk=%s python=%s\n' \
  "$mode" "$authority_path" "$receipt_path" "$repo_commit" "$rtk_path" "$python_path"
