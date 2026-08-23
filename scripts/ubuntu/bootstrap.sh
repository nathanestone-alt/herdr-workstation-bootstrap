#!/usr/bin/env -S -i BASH_ENV= ENV= CDPATH= PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C TZ=UTC /usr/bin/bash
set -euo pipefail

# This prelude is deliberately self-contained.  The live source-attestation
# helper is untrusted until its committed Git blob has been independently
# located, materialized into a private directory, and checked by Git and
# SHA-256.  Do not move this proof below the first helper source.
readonly bootstrap_trusted_path='/usr/sbin:/usr/bin:/sbin:/bin'
readonly bootstrap_env_bin='/usr/bin/env'
readonly bootstrap_git_bin='/usr/bin/git'
readonly bootstrap_realpath_bin='/usr/bin/realpath'
readonly bootstrap_dirname_bin='/usr/bin/dirname'
readonly bootstrap_find_bin='/usr/bin/find'
readonly bootstrap_mktemp_bin='/usr/bin/mktemp'
readonly bootstrap_chmod_bin='/usr/bin/chmod'
readonly bootstrap_stat_bin='/usr/bin/stat'
readonly bootstrap_sha256_bin='/usr/bin/sha256sum'
readonly bootstrap_awk_bin='/usr/bin/gawk'
readonly bootstrap_cp_bin='/usr/bin/cp'
readonly bootstrap_rm_bin='/usr/bin/rm'
readonly bootstrap_mkdir_bin='/usr/bin/mkdir'
readonly bootstrap_chown_bin='/usr/bin/chown'
readonly bootstrap_head_bin='/usr/bin/head'
readonly bootstrap_getent_bin='/usr/bin/getent'
readonly bootstrap_id_bin='/usr/bin/id'
readonly bootstrap_bash_bin='/usr/bin/bash'
readonly bootstrap_setpriv_bin='/usr/bin/setpriv'
readonly bootstrap_powershell_canonical_path='/opt/microsoft/powershell/7/pwsh'
readonly bootstrap_powershell_fallback_path='/usr/bin/pwsh'

export PATH="$bootstrap_trusted_path"
export LC_ALL=C
export TZ=UTC
bootstrap_reject_dangerous_environment() {
  local bootstrap_env_name
  while IFS= read -r bootstrap_env_name; do
    case "$bootstrap_env_name" in
      BASH_ENV|ENV|CDPATH)
        [[ -z "${!bootstrap_env_name:-}" ]] && continue
        echo "bootstrap trust prelude: dangerous caller environment is not permitted: $bootstrap_env_name" >&2
        exit 24
        ;;
      IFS|SHELLOPTS|BASHOPTS|GIT_DIR|GIT_WORK_TREE|GIT_INDEX_FILE|GIT_OBJECT_DIRECTORY|GIT_ALTERNATE_OBJECT_DIRECTORIES|GIT_COMMON_DIR|GIT_CONFIG_*|LD_*|DYLD_*|LIBRARY_PATH|CPATH|C_INCLUDE_PATH|CPLUS_INCLUDE_PATH|CMAKE_PREFIX_PATH|CARGO_*|RUSTC|RUSTDOC|RUSTFLAGS|RUSTC_WRAPPER|RUSTC_WORKSPACE_WRAPPER|RUSTUP_TOOLCHAIN|RUSTUP_HOME|NODE_OPTIONS|NODE_PATH|NODE_EXTRA_CA_CERTS|NPM_CONFIG_*|COREPACK_*|PYTHONHOME|PYTHONPATH|PYTHONSTARTUP|PYTHONINSPECT|PYTHONUSERBASE|PYTHONNOUSERSITE|PYTHONWARNINGS|PYTHONBREAKPOINT|CURL_HOME|CURL_CA_BUNDLE|SSL_CERT_FILE|SSL_CERT_DIR|REQUESTS_CA_BUNDLE|HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|NO_PROXY|http_proxy|https_proxy|all_proxy|no_proxy|PERL5OPT|PERL5LIB|RUBYOPT|RUBYLIB|GCONV_PATH|TMPDIR)
        echo "bootstrap trust prelude: dangerous caller environment is not permitted: $bootstrap_env_name" >&2
        exit 24
        ;;
    esac
  done < <(compgen -e)
}
bootstrap_reject_dangerous_environment
if [[ -z "${HOME:-}" ]]; then
  bootstrap_launch_home="$($bootstrap_getent_bin passwd "$($bootstrap_id_bin -u)" 2>/dev/null | "$bootstrap_awk_bin" -F: 'NF >= 6 { print $6; found++ } END { exit(found == 1 ? 0 : 1) }' || true)"
  [[ "$bootstrap_launch_home" == /* && "$bootstrap_launch_home" != '/' ]] || {
    echo 'bootstrap trust prelude: the current user has no safe passwd home' >&2
    exit 24
  }
  export HOME="$bootstrap_launch_home"
fi
while IFS= read -r bootstrap_env_name; do
  case "$bootstrap_env_name" in
    GIT_DIR|GIT_WORK_TREE|GIT_INDEX_FILE|GIT_OBJECT_DIRECTORY|GIT_ALTERNATE_OBJECT_DIRECTORIES|GIT_COMMON_DIR|GIT_CONFIG_*)
      echo "bootstrap trust prelude: caller Git environment override is not permitted: $bootstrap_env_name" >&2
      exit 24
      ;;
  esac
done < <(compgen -e)

bootstrap_capability_entry_path="$($bootstrap_realpath_bin -e -- "${BASH_SOURCE[0]}" 2>/dev/null || true)"
bootstrap_capability_entry_dir="${bootstrap_capability_entry_path%/*}"
bootstrap_capability_repo_root="$($bootstrap_realpath_bin -e -- "$bootstrap_capability_entry_dir/../.." 2>/dev/null || true)"
bootstrap_capability_helper="$bootstrap_capability_repo_root/scripts/ubuntu/launcher-capability.sh"
[[ "$bootstrap_capability_entry_path" == "$bootstrap_capability_repo_root/scripts/ubuntu/bootstrap.sh" &&
  -f "$bootstrap_capability_helper" && ! -L "$bootstrap_capability_helper" ]] ||
  { echo 'bootstrap capability helper is not in the staged repository' >&2; exit 24; }
# shellcheck disable=SC1090
launcher_capability_entry_source="$bootstrap_capability_entry_path"
source "$bootstrap_capability_helper" bootstrap
launcher_capability_lifetime
unset BASH_ENV ENV CDPATH GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_CONFIG_PARAMETERS
while IFS= read -r bootstrap_env_name; do
  case "$bootstrap_env_name" in
    GIT_*) unset "$bootstrap_env_name" ;;
  esac
done < <(compgen -e)

bootstrap_trust_fail() {
  echo "bootstrap trust prelude: $*" >&2
  exit 24
}

bootstrap_trust_reject_symlink_components() {
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

bootstrap_trust_assert_root_owned_parent_chain() {
  local path="$1"
  local current="${path%/*}"
  local owner mode
  [[ -n "$current" ]] || current='/'
  while :; do
    owner="$($bootstrap_stat_bin -c '%u' -- "$current" 2>/dev/null || true)"
    mode="$($bootstrap_stat_bin -c '%a' -- "$current" 2>/dev/null || true)"
    [[ "$owner" == 0 && "$mode" =~ ^[0-7]+$ && $((8#$mode & 022)) == 0 ]] || {
      bootstrap_trust_fail "trusted binary parent is not root-owned and non-writable: $current"
    }
    [[ "$current" == / ]] && break
    current="${current%/*}"
    [[ -n "$current" ]] || current='/'
  done
}

bootstrap_trust_assert_binary() {
  local path="$1"
  local require_root="${2:-0}"
  local resolved mode owner
  [[ -f "$path" && ! -L "$path" && -x "$path" ]] || {
    bootstrap_trust_fail "trusted binary is missing or not a regular executable: $path"
  }
  resolved="$($bootstrap_realpath_bin -e -- "$path" 2>/dev/null || true)"
  [[ "$resolved" == "$path" ]] || {
    bootstrap_trust_fail "trusted binary is not canonical: $path -> $resolved"
  }
  mode="$($bootstrap_stat_bin -c '%a' -- "$path" 2>/dev/null || true)"
  [[ "$mode" =~ ^[0-7]+$ && $((8#$mode & 022)) == 0 ]] || {
    bootstrap_trust_fail "trusted binary is writable by group or other users: $path"
  }
  if [[ "$require_root" == 1 ]]; then
    owner="$($bootstrap_stat_bin -c '%u' -- "$path" 2>/dev/null || true)"
    [[ "$owner" == 0 ]] || {
      bootstrap_trust_fail "trusted binary is not root-owned: $path"
    }
    bootstrap_trust_assert_root_owned_parent_chain "$path"
  fi
}

for bootstrap_trusted_binary in \
  "$bootstrap_env_bin" "$bootstrap_git_bin" "$bootstrap_realpath_bin" \
  "$bootstrap_dirname_bin" "$bootstrap_find_bin" "$bootstrap_mktemp_bin" \
  "$bootstrap_chmod_bin" "$bootstrap_stat_bin" "$bootstrap_sha256_bin" \
  "$bootstrap_awk_bin" "$bootstrap_cp_bin" "$bootstrap_rm_bin" "$bootstrap_mkdir_bin" \
  "$bootstrap_chown_bin" "$bootstrap_head_bin" "$bootstrap_getent_bin" "$bootstrap_id_bin" \
  "$bootstrap_bash_bin" "$bootstrap_setpriv_bin"; do
  bootstrap_trust_assert_binary "$bootstrap_trusted_binary"
done

declare -a bootstrap_cleanup_paths=()
bootstrap_register_cleanup() {
  [[ -n "${1:-}" ]] && bootstrap_cleanup_paths+=("$1")
}

bootstrap_private_helper_dir=''
bootstrap_cleanup() {
  local status="$1"
  set +e
  local cleanup_path
  for cleanup_path in "${bootstrap_cleanup_paths[@]:-}"; do
    [[ -n "$cleanup_path" ]] && "$bootstrap_rm_bin" -rf -- "$cleanup_path"
  done
  if declare -F attestation_cleanup_temporary_paths >/dev/null 2>&1; then
    attestation_cleanup_temporary_paths
  fi
  return "$status"
}
trap 'bootstrap_cleanup "$?"' EXIT

bootstrap_command_path() {
  local name="$1"
  local default_path=''
  local require_root=0
  local resolved
  case "$name" in
    sudo) default_path='/usr/bin/sudo' ;;
    apt-get) default_path='/usr/bin/apt-get' ;;
    systemctl) default_path='/usr/bin/systemctl' ;;
    ps) default_path='/usr/bin/ps' ;;
    pwsh)
      if [[ -x "$bootstrap_powershell_canonical_path" ]]; then
        default_path="$bootstrap_powershell_canonical_path"
        [[ "${launcher_capability_owner_uid:-}" == 0 ]] && require_root=1
      else
        default_path="$bootstrap_powershell_fallback_path"
      fi
      ;;
    tailscale) default_path='/usr/bin/tailscale' ;;
    *) bootstrap_trust_fail "unsupported command seam: $name" ;;
  esac
  bootstrap_trust_assert_binary "$default_path" "$require_root"
  resolved="$($bootstrap_realpath_bin -e -- "$default_path" 2>/dev/null || true)"
  [[ "$resolved" == "$default_path" ]] || bootstrap_trust_fail "command seam is not the canonical system binary: $name"
  printf '%s\n' "$resolved"
}

bootstrap_receipt_authority_path() {
  printf '%s\n' '/etc/stmodel/issue-961/receipt-authority.json'
}

bootstrap_query_apt_manifest() {
  /usr/bin/dpkg-query -W -f='apt:${binary:Package}=${Version}\n' \
    cifs-utils curl gawk git git-lfs gh jq mosh openssh-client openssh-server ripgrep rsync
}

bootstrap_exec_system() {
  local bootstrap_exec_arg
  local -a bootstrap_exec_args=()
  for bootstrap_exec_arg in "$@"; do
    if [[ "$bootstrap_exec_arg" == /proc/self/fd/* ]]; then
      bootstrap_exec_args+=("/proc/${BASHPID}/fd/${bootstrap_exec_arg##*/}")
    else
      bootstrap_exec_args+=("$bootstrap_exec_arg")
    fi
  done
  "$bootstrap_env_bin" -i \
    PATH="$bootstrap_trusted_path" \
    LC_ALL=C \
    TZ=UTC \
    "${bootstrap_exec_args[@]}"
}

bootstrap_exec_privileged() {
  local sudo_bin="$1"
  shift
  if [[ "${bootstrap_root_mode:-0}" == 1 ]]; then
    bootstrap_exec_system "$@"
  else
    bootstrap_exec_system "$sudo_bin" "$@"
  fi
}

bootstrap_runtime_capability_fd=13
bootstrap_run_as_runtime_phase() {
  local runtime_phase="$1"
  local runtime_capability_fd="$bootstrap_runtime_capability_fd"
  [[ "${bootstrap_root_mode:-0}" == 1 ]] || {
    echo "Root bootstrap orchestration is required for runtime phase '$runtime_phase'." >&2
    return 24
  }
  case "$runtime_capability_fd" in
    13|14|15) ;;
    *)
      echo 'Runtime-child launcher capability descriptor pool is exhausted.' >&2
      return 24
      ;;
  esac
  bootstrap_runtime_capability_fd=$((runtime_capability_fd + 1))
  bootstrap_exec_system \
    HOME="$bootstrap_runtime_home" \
    "$bootstrap_setpriv_bin" \
    --reuid="$bootstrap_runtime_uid" --regid="$bootstrap_runtime_gid" \
    --clear-groups --no-new-privs \
    "$bootstrap_bash_bin" -c '
      set -euo pipefail
      case "$1" in
        13) exec 9<&13 ;;
        14) exec 9<&14 ;;
        15) exec 9<&15 ;;
        *) exit 24 ;;
      esac
      exec 13<&- 14<&- 15<&-
      shift
      trusted_bash="$1"
      shift
      exec "$trusted_bash" "$@"
    ' _ "$runtime_capability_fd" "$bootstrap_bash_bin" "$bootstrap_script_path" --phase "$runtime_phase"
}

bootstrap_prepare_runtime_directories() {
  local path
  [[ "${bootstrap_root_mode:-0}" == 1 ]] || return 0
  for path in "$HOME/.local" "$HOME/.local/state" "$state_dir" "$bin_dir"; do
    [[ -d "$path" && ! -L "$path" ]] || {
      echo "Runtime managed directory is not a real directory: $path" >&2
      return 24
    }
    "$bootstrap_chown_bin" --no-dereference "$bootstrap_runtime_uid:$bootstrap_runtime_gid" -- "$path"
    [[ "$(/usr/bin/stat -c '%u:%g' -- "$path")" == "$bootstrap_runtime_uid:$bootstrap_runtime_gid" ]] || {
      echo "Runtime managed directory ownership changed unexpectedly: $path" >&2
      return 24
    }
  done
}

bootstrap_exec_user_runtime() {
  "$bootstrap_env_bin" -i \
    HOME="${HOME:-/nonexistent}" \
    PATH="$bootstrap_trusted_path" \
    LC_ALL=C \
    TZ=UTC \
    BASH_ENV= \
    ENV= \
    "$@"
}

bootstrap_root_home='/root'
bootstrap_exec_root_scoped() {
  [[ "${bootstrap_root_mode:-0}" == 1 ]] || {
    echo 'Root-scoped bootstrap command requested outside root mode.' >&2
    return 24
  }
  bootstrap_exec_system HOME="$bootstrap_root_home" "$@"
}

bootstrap_probe_powershell_version() {
  local pwsh_bin="$1"
  if [[ "${bootstrap_root_mode:-0}" == 1 ]]; then
    bootstrap_exec_root_scoped "$pwsh_bin" -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
  else
    bootstrap_exec_user_runtime "$pwsh_bin" -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
  fi
}

bootstrap_exec_python() {
  "$bootstrap_env_bin" -i \
    HOME="${HOME:-/nonexistent}" \
    PATH="$bootstrap_trusted_path" \
    LC_ALL=C \
    TZ=UTC \
    PYTHONNOUSERSITE=1 \
    PYTHONPATH= \
    PYTHONHOME= \
    PYTHONSTARTUP= \
    "$@"
}

bootstrap_exec_node() {
  "$bootstrap_env_bin" -i \
    HOME="${HOME:-/nonexistent}" \
    PATH="$bootstrap_trusted_path" \
    LC_ALL=C \
    TZ=UTC \
    NODE_OPTIONS= \
    NODE_PATH= \
    NPM_CONFIG_USERCONFIG=/dev/null \
    NPM_CONFIG_GLOBALCONFIG=/dev/null \
    COREPACK_HOME=/nonexistent \
    "$@"
}

bootstrap_exec_cargo() {
  local bootstrap_exec_arg
  local bootstrap_cargo_status
  local bootstrap_cargo_pid
  local -a bootstrap_exec_args=()
  for bootstrap_exec_arg in "$@"; do
    if [[ "$bootstrap_exec_arg" == /proc/self/fd/* ]]; then
      bootstrap_exec_args+=("/proc/${BASHPID}/fd/${bootstrap_exec_arg##*/}")
    else
      bootstrap_exec_args+=("$bootstrap_exec_arg")
    fi
  done
  (
    BASH_ENV= ENV= CDPATH= PATH="$bootstrap_trusted_path" /usr/bin/bash -c 'exec "$@"' _ \
    "$bootstrap_env_bin" -i \
    HOME="$HOME" \
    PATH="$bootstrap_trusted_path" \
    LC_ALL=C \
    TZ=UTC \
    CARGO_HOME="$HOME/.cargo" \
    CARGO_INSTALL_ROOT="$HOME/.cargo" \
    CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-}" \
    RUSTUP_HOME="$HOME/.rustup" \
    RUSTC="${RUSTC:-}" \
    RUSTC_WRAPPER= \
    RUSTC_WORKSPACE_WRAPPER= \
    RUSTFLAGS= \
    "${bootstrap_exec_args[@]}"
  ) &
  bootstrap_cargo_pid=$!
  if wait "$bootstrap_cargo_pid"; then
    bootstrap_cargo_status=0
  else
    bootstrap_cargo_status=$?
  fi
  return "$bootstrap_cargo_status"
}

bootstrap_repo_root="$launcher_capability_repo_root"
bootstrap_script_path="$launcher_capability_entry_path"
bootstrap_script_dir="$bootstrap_repo_root/scripts/ubuntu"
[[ -n "$bootstrap_script_path" && "$bootstrap_script_path" == "$bootstrap_repo_root/scripts/ubuntu/bootstrap.sh" ]] || {
  bootstrap_trust_fail 'bootstrap entrypoint is not at the canonical repository path'
}
[[ -n "$bootstrap_repo_root" && -d "$bootstrap_repo_root" && ! -L "$bootstrap_repo_root" ]] || {
  bootstrap_trust_fail 'bootstrap repository root is not a real directory'
}
bootstrap_trust_reject_symlink_components "$bootstrap_repo_root" || {
  bootstrap_trust_fail 'bootstrap repository root contains a symlinked component'
}
bootstrap_git_metadata="$bootstrap_repo_root/.git"
[[ -e "$bootstrap_git_metadata" && ! -L "$bootstrap_git_metadata" && \
  ( -d "$bootstrap_git_metadata" || -f "$bootstrap_git_metadata" ) ]] || {
  bootstrap_trust_fail 'bootstrap repository metadata is missing or unsafe'
}
if [[ -d "$bootstrap_git_metadata" ]]; then
  bootstrap_git_dir="$bootstrap_git_metadata"
  bootstrap_common_git_dir="$bootstrap_git_dir"
else
  bootstrap_git_pointer="$(< "$bootstrap_git_metadata")"
  [[ "$bootstrap_git_pointer" != *$'\n'* && "$bootstrap_git_pointer" != *$'\r'* && \
    "$bootstrap_git_pointer" == gitdir:\ /* ]] || {
    bootstrap_trust_fail 'bootstrap Git pointer cannot be read safely'
  }
  bootstrap_git_pointer_path="${bootstrap_git_pointer#gitdir: }"
  bootstrap_git_dir="$($bootstrap_realpath_bin -e -- "$bootstrap_git_pointer_path" 2>/dev/null || true)"
  [[ -n "$bootstrap_git_dir" && "$bootstrap_git_pointer" == "gitdir: $bootstrap_git_dir" ]] || {
    bootstrap_trust_fail 'bootstrap Git pointer is not canonical'
  }
  [[ -d "$bootstrap_git_dir" && ! -L "$bootstrap_git_dir" && \
    -f "$bootstrap_git_dir/commondir" && ! -L "$bootstrap_git_dir/commondir" ]] || {
    bootstrap_trust_fail 'bootstrap Git worktree metadata is missing or unsafe'
  }
  bootstrap_commondir_spec="$(< "$bootstrap_git_dir/commondir")"
  [[ "$bootstrap_commondir_spec" == '../..' ]] || {
    bootstrap_trust_fail 'bootstrap Git common directory is not local'
  }
  bootstrap_common_git_dir="$($bootstrap_realpath_bin -e -- "$bootstrap_git_dir/$bootstrap_commondir_spec" 2>/dev/null || true)"
  [[ -n "$bootstrap_common_git_dir" && -d "$bootstrap_common_git_dir" && ! -L "$bootstrap_common_git_dir" ]] || {
    bootstrap_trust_fail 'bootstrap Git common directory is missing or unsafe'
  }
  bootstrap_worktree_record="$bootstrap_common_git_dir/worktrees/${bootstrap_git_dir##*/}"
  [[ -d "$bootstrap_common_git_dir/worktrees" && ! -L "$bootstrap_common_git_dir/worktrees" && \
    "$($bootstrap_realpath_bin -e -- "$bootstrap_worktree_record" 2>/dev/null || true)" == "$bootstrap_git_dir" && \
    -f "$bootstrap_git_dir/gitdir" && ! -L "$bootstrap_git_dir/gitdir" ]] || {
    bootstrap_trust_fail 'bootstrap Git worktree record is not exact and reciprocal'
  }
  bootstrap_worktree_record_pointer="$(< "$bootstrap_git_dir/gitdir")"
  bootstrap_worktree_record_canonical="$($bootstrap_realpath_bin -e -- "$bootstrap_worktree_record_pointer" 2>/dev/null || true)"
  [[ "$bootstrap_worktree_record_pointer" != *$'\n'* && "$bootstrap_worktree_record_pointer" != *$'\r'* && \
    "$bootstrap_worktree_record_canonical" == "$bootstrap_git_metadata" ]] || {
    bootstrap_trust_fail 'bootstrap Git worktree record does not own this source path'
  }
  while IFS= read -r -d '' bootstrap_other_worktree_record; do
    [[ "${bootstrap_other_worktree_record%/gitdir}" == "$bootstrap_git_dir" ]] && continue
    bootstrap_other_worktree_pointer="$(< "$bootstrap_other_worktree_record")"
    [[ "$bootstrap_other_worktree_pointer" != *$'\n'* && "$bootstrap_other_worktree_pointer" != *$'\r'* ]] || {
      bootstrap_trust_fail 'bootstrap Git worktree record contains unsafe text'
    }
    [[ "$($bootstrap_realpath_bin -e -- "$bootstrap_other_worktree_pointer" 2>/dev/null || true)" != "$bootstrap_git_metadata" ]] || {
      bootstrap_trust_fail 'bootstrap Git worktree source ownership is ambiguous'
    }
  done < <("$bootstrap_find_bin" -P "$bootstrap_common_git_dir/worktrees" -mindepth 2 -maxdepth 2 -type f -name gitdir -print0 2>/dev/null)
fi
bootstrap_trust_reject_symlink_components "$bootstrap_git_dir" || {
  bootstrap_trust_fail 'bootstrap Git directory contains a symlinked component'
}
bootstrap_trust_reject_symlink_components "$bootstrap_common_git_dir" || {
  bootstrap_trust_fail 'bootstrap Git common directory contains a symlinked component'
}
[[ -d "$bootstrap_common_git_dir/objects" && ! -L "$bootstrap_common_git_dir/objects" && \
  "$($bootstrap_realpath_bin -e -- "$bootstrap_common_git_dir/objects" 2>/dev/null || true)" == "$bootstrap_common_git_dir/objects" && \
  -d "$bootstrap_common_git_dir/refs" && ! -L "$bootstrap_common_git_dir/refs" && \
  -f "$bootstrap_git_dir/index" && ! -L "$bootstrap_git_dir/index" && \
  -f "$bootstrap_common_git_dir/config" && ! -L "$bootstrap_common_git_dir/config" ]] || {
  bootstrap_trust_fail 'bootstrap repository object, ref, config, or index storage is missing'
}
[[ ! -e "$bootstrap_common_git_dir/shallow" && ! -e "$bootstrap_git_dir/shallow" && \
  ! -e "$bootstrap_common_git_dir/objects/info/alternates" && \
  ! -e "$bootstrap_common_git_dir/objects/info/http-alternates" ]] || {
  bootstrap_trust_fail 'bootstrap repository uses external or shallow Git storage'
}
for bootstrap_git_metadata_root in "$bootstrap_git_dir" "$bootstrap_common_git_dir"; do
  bootstrap_git_metadata_entry="$($bootstrap_find_bin -P "$bootstrap_git_metadata_root" -mindepth 1 \
    \( -type l -o \( ! -type f ! -type d \) \) -print -quit 2>/dev/null || true)"
  [[ -z "$bootstrap_git_metadata_entry" ]] || {
    bootstrap_trust_fail "bootstrap Git metadata contains an unsafe entry: $bootstrap_git_metadata_entry"
  }
done

declare -a bootstrap_git_bound_paths=()
declare -A bootstrap_git_bound_identities=()
bootstrap_git_owner_uid="$launcher_capability_owner_uid"
bootstrap_git_owner_gid="$launcher_capability_owner_gid"
[[ "$bootstrap_git_owner_uid" =~ ^[0-9]+$ && "$bootstrap_git_owner_gid" =~ ^[0-9]+$ ]] || bootstrap_trust_fail 'bootstrap Git owner binding is not numeric'
bootstrap_bind_git_path() {
  local path="$1" owner group mode identity
  [[ -e "$path" && ! -L "$path" ]] || return 1
  owner="$($bootstrap_stat_bin -c '%u' -- "$path" 2>/dev/null || true)"
  mode="$($bootstrap_stat_bin -c '%a' -- "$path" 2>/dev/null || true)"
  group="$($bootstrap_stat_bin -c '%g' -- "$path" 2>/dev/null || true)"
  [[ "$owner" == "$bootstrap_git_owner_uid" && "$group" == "$bootstrap_git_owner_gid" && "$mode" =~ ^[0-7]+$ && $((8#$mode & 022)) == 0 ]] || return 1
  identity="$($bootstrap_stat_bin -Lc '%d:%i:%u:%g:%a:%F' -- "$path" 2>/dev/null || true)"
  [[ -n "$identity" ]] || return 1
  if [[ -z "${bootstrap_git_bound_identities[$path]+x}" ]]; then
    bootstrap_git_bound_paths+=("$path")
  fi
  bootstrap_git_bound_identities["$path"]="$identity"
}
bootstrap_bind_optional_git_path() {
  [[ -e "$1" ]] || return 0
  bootstrap_bind_git_path "$1"
}
for bootstrap_git_binding_path in "$bootstrap_repo_root" "$bootstrap_git_metadata" "$bootstrap_git_dir" \
  "$bootstrap_common_git_dir" "$bootstrap_common_git_dir/objects" "$bootstrap_common_git_dir/refs" \
  "$bootstrap_common_git_dir/config" "$bootstrap_git_dir/index"; do
  bootstrap_bind_git_path "$bootstrap_git_binding_path" || bootstrap_trust_fail 'bootstrap Git topology owner or mode is unsafe'
done
for bootstrap_git_binding_path in "$bootstrap_git_dir/commondir" "$bootstrap_git_dir/gitdir" \
  "$bootstrap_common_git_dir/worktrees" "$bootstrap_git_dir/HEAD" "$bootstrap_common_git_dir/HEAD" \
  "$bootstrap_common_git_dir/packed-refs"; do
  bootstrap_bind_optional_git_path "$bootstrap_git_binding_path" || bootstrap_trust_fail 'bootstrap Git pointer or ref identity is unsafe'
done
if [[ -n "${bootstrap_worktree_record:-}" ]]; then
  bootstrap_bind_git_path "$bootstrap_worktree_record" || bootstrap_trust_fail 'bootstrap Git worktree record identity is unsafe'
  bootstrap_bind_git_path "$bootstrap_worktree_record/gitdir" || bootstrap_trust_fail 'bootstrap Git worktree pointer identity is unsafe'
fi
bootstrap_trust_assert_git_lifetime() {
  local path owner group mode identity
  for path in "${bootstrap_git_bound_paths[@]}"; do
    [[ -e "$path" && ! -L "$path" ]] || return 1
    owner="$($bootstrap_stat_bin -c '%u' -- "$path" 2>/dev/null || true)"
    mode="$($bootstrap_stat_bin -c '%a' -- "$path" 2>/dev/null || true)"
    identity="$($bootstrap_stat_bin -Lc '%d:%i:%u:%g:%a:%F' -- "$path" 2>/dev/null || true)"
    group="$($bootstrap_stat_bin -c '%g' -- "$path" 2>/dev/null || true)"
    [[ "$owner" == "$bootstrap_git_owner_uid" && "$group" == "$bootstrap_git_owner_gid" && "$mode" =~ ^[0-7]+$ && $((8#$mode & 022)) == 0 && \
      "$identity" == "${bootstrap_git_bound_identities[$path]:-}" ]] || return 1
  done
}

bootstrap_trust_git() {
  local bootstrap_git_status
  bootstrap_trust_assert_git_lifetime || return 70
  if "$bootstrap_env_bin" -i \
    HOME=/nonexistent \
    PATH="$bootstrap_trusted_path" \
    LC_ALL=C \
    TZ=UTC \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_SYSTEM=/dev/null \
    GIT_CONFIG_COUNT=0 \
    GIT_OPTIONAL_LOCKS=0 \
    "$bootstrap_git_bin" --no-replace-objects \
    -C "$bootstrap_repo_root" --git-dir="$bootstrap_git_dir" --work-tree=. \
    -c core.attributesfile=/dev/null \
    -c core.excludesfile=/dev/null \
    -c core.hooksPath=/dev/null \
    -c core.filemode=true \
    -c core.ignoreCase=false \
    "$@"; then
    bootstrap_git_status=0
  else
    bootstrap_git_status=$?
  fi
  bootstrap_trust_assert_git_lifetime || return 70
  return "$bootstrap_git_status"
}

bootstrap_trust_git_optional() {
  local output status
  output="$(bootstrap_trust_git "$@" 2>/dev/null)" || {
    status=$?
    ((status == 1)) || return "$status"
  }
  printf '%s\n' "$output"
}

bootstrap_dangerous_config="$(bootstrap_trust_git_optional config --local --no-includes --name-only --get-regexp \
  '^(include|filter\.|diff\..*\.textconv$|merge\..*\.driver$|credential\.|url\..*\.insteadOf$|core\.(attributesfile|excludesfile|fsmonitor|hooksPath|worktree|alternateRefsCommand|askPass|gitProxy|sshCommand)$|extensions\.|remote\..*\.(promisor|partialclonefilter|uploadpack|receivepack)$)' \
  )"
[[ -z "$bootstrap_dangerous_config" ]] || bootstrap_trust_fail 'repository-local Git configuration is unsafe'
bootstrap_sparse_checkout="$(bootstrap_trust_git_optional config --local --no-includes --bool --get core.sparseCheckout)" || bootstrap_trust_fail 'bootstrap Git lifetime failed while reading sparse-checkout configuration'
bootstrap_sparse_index="$(bootstrap_trust_git_optional config --local --no-includes --bool --get index.sparse)" || bootstrap_trust_fail 'bootstrap Git lifetime failed while reading sparse-index configuration'
[[ "$bootstrap_sparse_checkout" != true && \
  "$bootstrap_sparse_index" != true && \
  ! -e "$bootstrap_common_git_dir/info/sparse-checkout" && \
  ! -e "$bootstrap_git_dir/info/sparse-checkout" ]] || {
  bootstrap_trust_fail 'bootstrap repository sparse checkout metadata is unsafe'
}
bootstrap_filemode="$(bootstrap_trust_git_optional config --local --no-includes --bool --get core.filemode)" || bootstrap_trust_fail 'bootstrap Git lifetime failed while reading filemode configuration'
bootstrap_bare="$(bootstrap_trust_git_optional config --local --no-includes --bool --get core.bare)" || bootstrap_trust_fail 'bootstrap Git lifetime failed while reading bare configuration'
bootstrap_format_version="$(bootstrap_trust_git_optional config --local --no-includes --int --get core.repositoryformatversion)" || bootstrap_trust_fail 'bootstrap Git lifetime failed while reading repository format configuration'
bootstrap_ignorecase="$(bootstrap_trust_git_optional config --local --no-includes --bool --get core.ignorecase)" || bootstrap_trust_fail 'bootstrap Git lifetime failed while reading case configuration'
[[ "$bootstrap_filemode" != false && \
  "$bootstrap_bare" != true && \
  "$bootstrap_format_version" == 0 && \
  "$bootstrap_ignorecase" != true ]] || {
  bootstrap_trust_fail 'bootstrap repository format or mode configuration is unsafe'
}
bootstrap_git_top_level="$(bootstrap_trust_git rev-parse --show-toplevel 2>/dev/null)" || bootstrap_trust_fail 'bootstrap Git lifetime failed while reading the worktree root'
bootstrap_git_absolute_dir="$(bootstrap_trust_git rev-parse --absolute-git-dir 2>/dev/null)" || bootstrap_trust_fail 'bootstrap Git lifetime failed while reading the Git directory'
bootstrap_git_inside_worktree="$(bootstrap_trust_git rev-parse --is-inside-work-tree 2>/dev/null)" || bootstrap_trust_fail 'bootstrap Git lifetime failed while reading worktree state'
bootstrap_git_bare="$(bootstrap_trust_git rev-parse --is-bare-repository 2>/dev/null)" || bootstrap_trust_fail 'bootstrap Git lifetime failed while reading bare state'
bootstrap_git_shallow="$(bootstrap_trust_git rev-parse --is-shallow-repository 2>/dev/null)" || bootstrap_trust_fail 'bootstrap Git lifetime failed while reading shallow state'
[[ "$bootstrap_git_top_level" == "$bootstrap_repo_root" && \
  "$bootstrap_git_absolute_dir" == "$bootstrap_git_dir" && \
  "$bootstrap_git_inside_worktree" == true && \
  "$bootstrap_git_bare" == false && \
  "$bootstrap_git_shallow" == false ]] || {
  bootstrap_trust_fail 'bootstrap repository topology is not a local full worktree'
}

bootstrap_commit="$(bootstrap_trust_git rev-parse --verify HEAD^{commit} 2>/dev/null)" || bootstrap_trust_fail 'bootstrap Git lifetime failed while reading HEAD'
[[ "$bootstrap_commit" =~ ^[0-9a-f]{40}$ ]] || bootstrap_trust_fail 'bootstrap HEAD is not a full committed object'
[[ "$bootstrap_commit" == "$launcher_capability_policy_commit" ]] || bootstrap_trust_fail 'bootstrap HEAD does not equal the approved policy commit'
bootstrap_trust_git cat-file -e "$bootstrap_commit^{commit}" || bootstrap_trust_fail 'bootstrap HEAD object is unavailable'
bootstrap_helper_tree="$(bootstrap_trust_git ls-tree "$bootstrap_commit" -- scripts/ubuntu/source-attestation.sh 2>/dev/null)" || bootstrap_trust_fail 'bootstrap Git lifetime failed while reading the committed helper tree'
[[ "$bootstrap_helper_tree" != *$'\n'* ]] || bootstrap_trust_fail 'bootstrap helper tree lookup was ambiguous'
IFS=$'\t' read -r bootstrap_helper_meta bootstrap_helper_path <<< "$bootstrap_helper_tree"
read -r bootstrap_helper_mode bootstrap_helper_type bootstrap_helper_oid <<< "$bootstrap_helper_meta"
[[ "$bootstrap_helper_path" == scripts/ubuntu/source-attestation.sh && "$bootstrap_helper_type" == blob && \
  "$bootstrap_helper_oid" =~ ^[0-9a-f]{40}$ && ( "$bootstrap_helper_mode" == 100644 || "$bootstrap_helper_mode" == 100755 ) ]] || {
  bootstrap_trust_fail 'committed source-attestation helper is not a regular blob'
}
bootstrap_trust_git cat-file -e "$bootstrap_helper_oid^{blob}" || bootstrap_trust_fail 'committed helper blob is unavailable'
bootstrap_private_helper_dir="$($bootstrap_mktemp_bin -d /tmp/herdr-bootstrap-helper.XXXXXX)"
bootstrap_register_cleanup "$bootstrap_private_helper_dir"
"$bootstrap_chmod_bin" 0700 -- "$bootstrap_private_helper_dir"
bootstrap_private_helper="$bootstrap_private_helper_dir/source-attestation.sh"
bootstrap_trust_git cat-file blob "$bootstrap_helper_oid" > "$bootstrap_private_helper" || {
  bootstrap_trust_fail 'committed helper blob could not be materialized'
}
[[ -f "$bootstrap_private_helper" && ! -L "$bootstrap_private_helper" ]] || {
  bootstrap_trust_fail 'materialized helper is not a regular file'
}
bootstrap_helper_mode_value=0644
[[ "$bootstrap_helper_mode" == 100755 ]] && bootstrap_helper_mode_value=0755
"$bootstrap_chmod_bin" "$bootstrap_helper_mode_value" -- "$bootstrap_private_helper"
bootstrap_materialized_oid="$(bootstrap_trust_git hash-object --no-filters --stdin < "$bootstrap_private_helper")"
[[ "$bootstrap_materialized_oid" == "$bootstrap_helper_oid" ]] || {
  bootstrap_trust_fail 'materialized helper bytes do not match the committed blob'
}
bootstrap_private_helper_sha256="$($bootstrap_sha256_bin -- "$bootstrap_private_helper" | "$bootstrap_awk_bin" '{print $1}')"
[[ "$bootstrap_private_helper_sha256" =~ ^[0-9a-f]{64}$ ]] || bootstrap_trust_fail 'materialized helper hash is invalid'

# shellcheck disable=SC1090
attestation_capability_owner_uid="$launcher_capability_owner_uid"
attestation_capability_owner_gid="$launcher_capability_owner_gid"
source "$bootstrap_private_helper"
attestation_create_git_snapshot "$bootstrap_repo_root" '' '' || {
  echo 'Bootstrap source checkout failed exact committed-blob attestation.' >&2
  exit 24
}
bootstrap_source_snapshot="$attestation_snapshot_dir"
# Re-source only the helper that was copied from the committed Git snapshot.
# All subsequent source-derived inputs, including the lock, come from this
# private snapshot; the live helper pathname is never sourced.
# shellcheck disable=SC1090
source "$bootstrap_source_snapshot/scripts/ubuntu/source-attestation.sh"
# The release installer is sourced only from the same private, committed
# snapshot whose complete tree was just attested.
# shellcheck disable=SC1090
source "$bootstrap_source_snapshot/scripts/ubuntu/rtk-release.sh"
attestation_snapshot_dir="$bootstrap_source_snapshot"
attestation_snapshot_manifest="$bootstrap_source_snapshot/.source-attestation"
repo_root="$bootstrap_source_snapshot"

phase="all"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase) [[ $# -ge 2 ]] || { echo '--phase requires a value.' >&2; exit 2; }; phase="$2"; shift 2 ;;
    --no-node) echo '--no-node is no longer supported because Codex and Claude use the pinned Node runtime.' >&2; exit 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

bootstrap_current_uid="$($bootstrap_id_bin -u)"
bootstrap_current_gid="$($bootstrap_id_bin -g)"
bootstrap_runtime_uid="${HERDR_BOOTSTRAP_RUNTIME_UID:-$bootstrap_current_uid}"
bootstrap_runtime_gid="${HERDR_BOOTSTRAP_RUNTIME_GID:-$bootstrap_current_gid}"
bootstrap_runtime_home="${HERDR_BOOTSTRAP_RUNTIME_HOME:-$HOME}"
[[ "$bootstrap_current_uid" =~ ^[0-9]+$ && "$bootstrap_current_gid" =~ ^[0-9]+$ &&
  "$bootstrap_runtime_uid" =~ ^[0-9]+$ && "$bootstrap_runtime_gid" =~ ^[0-9]+$ &&
  "$bootstrap_runtime_home" == /* && "$bootstrap_runtime_home" != / ]] || {
    echo 'Bootstrap runtime identity is not canonical.' >&2
    exit 24
  }
[[ "$HOME" == "$bootstrap_runtime_home" ]] || {
  echo 'Bootstrap HOME does not match the launcher-bound runtime home.' >&2
  exit 24
}
bootstrap_root_mode=0
if [[ "$bootstrap_current_uid" == 0 && "$bootstrap_runtime_uid" != 0 ]]; then
  bootstrap_root_mode=1
fi
lock_file="$repo_root/config/ubuntu-toolchain.lock"
state_dir="${HOME}/.local/state/herdr-workstation-bootstrap"
bin_dir="${HOME}/.local/bin"

[[ -f "$lock_file" ]] || { echo "Missing toolchain lock: $lock_file" >&2; exit 22; }
# shellcheck disable=SC1090
source "$lock_file"
required_lock_keys=(
  UV_VERSION UV_PLATFORM UV_URL UV_SHA256
  PYTHON_VERSION PYTHON_RELEASE PYTHON_PLATFORM PYTHON_ARCHIVE PYTHON_URL PYTHON_SHA256
  RTK_VERSION RTK_URL RTK_SHA256
  POWERSHELL_VERSION POWERSHELL_URL POWERSHELL_SHA256
  TAILSCALE_VERSION TAILSCALE_INSTALLER_URL TAILSCALE_INSTALLER_SHA256
  RUSTUP_VERSION RUSTUP_INIT_URL RUSTUP_INIT_SHA256 RUST_TOOLCHAIN
  NODE_VERSION NODE_URL NODE_SHA256 CODEX_VERSION CLAUDE_VERSION BUN_VERSION
  HERDR_VERSION HERDR_URL HERDR_SHA256
)
for key in "${required_lock_keys[@]}"; do
  [[ -n "${!key:-}" ]] || { echo "Lock key '$key' is empty." >&2; exit 22; }
done
for key in UV_SHA256 PYTHON_SHA256 RTK_SHA256 POWERSHELL_SHA256 TAILSCALE_INSTALLER_SHA256 RUSTUP_INIT_SHA256 NODE_SHA256 HERDR_SHA256; do
  [[ "${!key}" =~ ^[0-9a-f]{64}$ ]] || { echo "Lock key '$key' is not a lowercase SHA-256 value." >&2; exit 22; }
done

path_is_under() {
  local child="$1"
  local parent="$2"
  [[ "$child" == "$parent" || "$child" == "$parent/"* ]]
}

validate_cargo_roots() {
  local expected_root="$HOME/.cargo"
  cargo_home="${CARGO_HOME:-$expected_root}"
  cargo_install_root="${CARGO_INSTALL_ROOT:-$cargo_home}"
  [[ "$cargo_home" == "$expected_root" ]] || {
    echo "CARGO_HOME must be the canonical cargo root '$expected_root', got '$cargo_home'." >&2
    return 1
  }
  [[ "$cargo_install_root" == "$expected_root" ]] || {
    echo "CARGO_INSTALL_ROOT must be the canonical cargo root '$expected_root', got '$cargo_install_root'." >&2
    return 1
  }
  export CARGO_HOME="$expected_root"
  export CARGO_INSTALL_ROOT="$expected_root"
}

install_rtk_release() {
  local download_dir archive
  validate_toolchain_lock || exit 22
  download_dir="$(/usr/bin/mktemp -d /tmp/herdr-rtk-download.XXXXXX)"
  bootstrap_register_cleanup "$download_dir"
  /usr/bin/chmod 0700 -- "$download_dir"
  archive="$download_dir/rtk-x86_64-unknown-linux-musl.tar.gz"
  download_verified "$RTK_URL" "$RTK_SHA256" "$archive"
  /usr/bin/chmod 0600 -- "$archive"
  rtk_release_install_archive "$archive" "$RTK_SHA256" "$RTK_VERSION" \
    "$HOME/.cargo/bin/rtk" bootstrap_test_pause
  /usr/bin/rm -rf -- "$download_dir"
}

install_receipt_from_snapshots() {
  local payload_root payload_manifest expected_payload_sha expected_source_helper_sha
  local sudo_bin
  payload_root="$(/usr/bin/mktemp -d /tmp/herdr-receipt-payload.XXXXXX)"
  bootstrap_register_cleanup "$payload_root"
  /usr/bin/chmod 0700 -- "$payload_root"
  /usr/bin/mkdir -p -- "$payload_root/source"
  /usr/bin/cp -a -- "$bootstrap_source_snapshot/." "$payload_root/source/"
  payload_manifest="$payload_root/.payload-manifest"
  expected_source_helper_sha="$(attestation_snapshot_file_digest \
    "$bootstrap_source_snapshot/.source-attestation" scripts/ubuntu/source-attestation.sh)"
  attestation_build_payload_manifest "$payload_root" "$payload_manifest" || {
    /usr/bin/rm -rf -- "$payload_root"
    return 1
  }
  expected_payload_sha="$(attestation_hash_file "$payload_manifest")"
  if [[ "$bootstrap_root_mode" == 1 ]]; then
    sudo_bin=''
  else
    sudo_bin="$(bootstrap_command_path sudo)"
  fi

  bootstrap_exec_system /usr/bin/tar -C "$payload_root" -cf - . | bootstrap_exec_privileged "$sudo_bin" /usr/bin/bash -c '
    set -euo pipefail
    expected_payload_sha="$1"
    expected_source_helper_sha="$2"
    managed_user_home="$3"
    policy_path=/etc/herdr-workstation/bootstrap-policy.conf
    [[ -f "$policy_path" && ! -L "$policy_path" &&
      "$(/usr/bin/realpath -e -- "$policy_path" 2>/dev/null || true)" == "$policy_path" ]] || exit 24
    for policy_component in /etc /etc/herdr-workstation; do
      [[ ! -L "$policy_component" && -d "$policy_component" ]] || exit 24
      [[ "$(/usr/bin/stat -c '%u:%g:%a' -- "$policy_component")" == 0:0:755 ]] || exit 24
    done
    [[ "$(/usr/bin/stat -c '%u:%g:%a' -- "$policy_path")" == 0:0:600 ]] || exit 24
    exec 9<"$policy_path"
    policy_identity="$(/usr/bin/stat -Lc '%d:%i:%u:%g:%a:%F' -- /proc/$BASHPID/fd/9)"
    [[ "$policy_identity" =~ ^[0-9]+:[0-9]+:0:0:600:regular[[:space:]]file$ ]] || exit 24
    policy_header_count=0
    policy_origin_count=0
    policy_commit_count=0
    policy_origin=''
    policy_commit=''
    while IFS= read -r policy_line; do
      case "$policy_line" in
        herdr-bootstrap-policy-v1) ((policy_header_count += 1)) ;;
        origin=*)
          ((policy_origin_count += 1))
          [[ -z "$policy_origin" ]] || exit 24
          policy_origin="${policy_line#origin=}"
          ;;
        commit=*)
          ((policy_commit_count += 1))
          [[ -z "$policy_commit" ]] || exit 24
          policy_commit="${policy_line#commit=}"
          ;;
        *) exit 24 ;;
      esac
    done < /proc/$BASHPID/fd/9
    [[ "$policy_header_count" == 1 && "$policy_origin_count" == 1 &&
      "$policy_commit_count" == 1 && "$policy_commit" =~ ^[0-9a-f]{40}$ &&
      "$policy_origin" =~ ^https://[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+/[A-Za-z0-9._~-]+(/[A-Za-z0-9._~-]+)*\.git$ &&
      "$policy_origin" != *..* && "$policy_origin" != *@* ]] || exit 24
    stage="$(/usr/bin/mktemp -d /tmp/herdr-root-receipt-payload.XXXXXX)"
    receipt_parent_capability=''
    cleanup_root_payload() {
      /usr/bin/rm -rf -- "$stage"
      [[ -z "$receipt_parent_capability" ]] || /usr/bin/rm -rf -- "$receipt_parent_capability"
    }
    trap cleanup_root_payload EXIT
    /usr/bin/tar --extract --file=- --directory="$stage" --no-same-owner --no-same-permissions
    /usr/bin/chown -R --no-dereference 0:0 -- "$stage"
    exec 10<"$stage"
    [[ "$(/usr/bin/stat -Lc '%d:%i:%u:%g:%a:%F' -- /proc/$BASHPID/fd/10)" =~ ^[0-9]+:[0-9]+:0:0:700:directory$ ]] || exit 24
    receipt_parent_capability="$(/usr/bin/mktemp -d /tmp/herdr-root-receipt-capability.XXXXXX)"
    /usr/bin/chmod 0700 -- "$receipt_parent_capability"
    exec 12<"$receipt_parent_capability"
    [[ "$(/usr/bin/stat -Lc '%d:%i:%u:%g:%a:%F' -- /proc/$BASHPID/fd/12)" =~ ^[0-9]+:[0-9]+:0:0:700:directory$ ]] || exit 24
    /usr/bin/rm -rf -- "$receipt_parent_capability"
    receipt_parent_capability=''
    [[ -f /usr/local/libexec/herdr-workstation-bootstrap &&
      ! -L /usr/local/libexec/herdr-workstation-bootstrap &&
      "$(/usr/bin/realpath -e -- /usr/local/libexec/herdr-workstation-bootstrap 2>/dev/null || true)" == /usr/local/libexec/herdr-workstation-bootstrap &&
      "$(/usr/bin/stat -c '%u:%g:%a' -- /usr/local/libexec/herdr-workstation-bootstrap)" == 0:0:755 ]] || exit 24
    exec 11</usr/local/libexec/herdr-workstation-bootstrap
    [[ "$(/usr/bin/stat -Lc '%d:%i:%u:%g:%a:%F' -- /proc/$BASHPID/fd/11)" =~ ^[0-9]+:[0-9]+:0:0:755:regular[[:space:]]file$ ]] || exit 24
    [[ -f "$stage/.payload-manifest" && ! -L "$stage/.payload-manifest" ]] || exit 24
    root_verify_payload() {
      local root="$1" manifest="$2" expected_hash="$3" expected_commit="$4"
      local line relative full mode digest path actual_mode actual_digest
      local header_count=0 source_commit
      [[ "$root" == /* && -d "$root" && ! -L "$root" && "$manifest" == "$root/.payload-manifest" ]] || return 1
      [[ "$(/usr/bin/stat -c '%u' -- "$root")" == 0 && "$(/usr/bin/stat -c '%a' -- "$root")" =~ ^[0-7]+$ && $((8#$(/usr/bin/stat -c '%a' -- "$root") & 022)) == 0 ]] || return 1
      [[ "$(/usr/bin/stat -c '%u' -- "$manifest")" == 0 && "$(/usr/bin/stat -c '%a' -- "$manifest")" =~ ^[0-7]+$ && $((8#$(/usr/bin/stat -c '%a' -- "$manifest") & 022)) == 0 ]] || return 1
      [[ "$expected_hash" =~ ^[0-9a-f]{64}$ && "$(/usr/bin/sha256sum -- "$manifest" | /usr/bin/gawk '{print $1}')" == "$expected_hash" ]] || return 1
      source_commit="$(/usr/bin/gawk -F= "{ if (\$1 == \"commit\") { print \$2; found++ } END { exit(found == 1 ? 0 : 1) }" "$root/source/.source-attestation" 2>/dev/null || true)"
      [[ "$source_commit" == "$expected_commit" ]] || return 1
      declare -A payload_mode=() payload_sha=() payload_dirs=()
      payload_dirs["."]=1
      while IFS= read -r line; do
        if [[ "$line" == herdr-payload-manifest-v1 ]]; then
          ((header_count += 1))
          continue
        fi
        [[ "${line:0:2}" == "F	" ]] || return 1
        IFS="$(printf "\\t")" read -r _ mode digest path <<< "$line"
        [[ "$path" != /* && "$path" != *..* ]] || return 1
        [[ -n "$path" && "$mode" =~ ^(444|555|644|755)$ && "$digest" =~ ^[0-9a-f]{64}$ && -z "${payload_sha[$path]+x}" ]] || return 1
        payload_mode["$path"]="$mode"
        payload_sha["$path"]="$digest"
        local current='.' component
        IFS='/' read -r -a components <<< "$path"
        for component in "${components[@]}"; do
          [[ -n "$component" && "$component" != . && "$component" != .. ]] || return 1
          current="$current/$component"
          current="${current#./}"
          payload_dirs["$current"]=1
        done
      done < "$manifest"
      [[ "$header_count" == 1 && "${#payload_sha[@]}" -gt 0 ]] || return 1
      while IFS= read -r -d '' full; do
        relative="${full#"$root"/}"
        [[ "$relative" != .payload-manifest ]] || continue
        [[ "$relative" != /* && "$relative" != *..* ]] || return 1
        if [[ -L "$full" ]]; then
          return 1
        elif [[ -d "$full" ]]; then
          [[ -n "${payload_dirs[$relative]+x}" ]] || return 1
        elif [[ -f "$full" ]]; then
          [[ -n "${payload_sha[$relative]+x}" ]] || return 1
          actual_mode="$(/usr/bin/stat -c '%a' -- "$full")"
          [[ "$actual_mode" == "${payload_mode[$relative]}" ]] || return 1
          actual_digest="$(/usr/bin/sha256sum -- "$full" | /usr/bin/gawk "{print \$1}")"
          [[ "$actual_digest" == "${payload_sha[$relative]}" ]] || return 1
        else
          return 1
        fi
      done < <(/usr/bin/find -P "$root" -mindepth 1 -print0)
      for path in "${!payload_sha[@]}"; do
        full="$root/$path"
        [[ -f "$full" && ! -L "$full" ]] || return 1
      done
    }
    root_verify_payload "$stage" "$stage/.payload-manifest" "$expected_payload_sha" "$policy_commit" || exit 24
    [[ "$(/usr/bin/sha256sum -- "$stage/source/scripts/ubuntu/source-attestation.sh" | /usr/bin/gawk "{print \$1}")" == "$expected_source_helper_sha" ]] || exit 24
    # The standalone root verifier binds the payload manifest and source
    # commit before the helper is sourced.  The helper then rechecks every
    # extracted file before the authority script is loaded.
    # shellcheck disable=SC1091
    source "$stage/source/scripts/ubuntu/source-attestation.sh"
    attestation_reject_git_environment
    attestation_verify_payload_manifest "$stage" "$stage/.payload-manifest" "$expected_payload_sha"
    /usr/bin/bash "$stage/source/scripts/ubuntu/receipt-authority.sh" \
      --install \
      --source-root "$stage/source" \
      --source-manifest "$stage/source/.source-attestation" \
      --payload-root "$stage" \
      --payload-manifest "$stage/.payload-manifest" \
      --payload-manifest-sha256 "$expected_payload_sha" \
      --source-commit "$policy_commit" \
      --user-home "$managed_user_home"
  ' -- "$expected_payload_sha" "$expected_source_helper_sha" "$HOME"
  /usr/bin/rm -rf -- "$payload_root"
}

validate_user_home() {
  [[ -n "${HOME:-}" && "$HOME" == /* && "$HOME" != '/' && -d "$HOME" ]] || {
    echo 'HOME is not a safe absolute user directory.' >&2
    return 1
  }
  [[ ! -L "$HOME" ]] || {
    echo 'HOME itself must not be a symlink.' >&2
    return 1
  }
  home_real="$(/usr/bin/realpath -e -- "$HOME" 2>/dev/null || true)"
  [[ -n "$home_real" && -d "$home_real" ]] || {
    echo 'Could not resolve the real user home.' >&2
    return 1
  }
  [[ "$(/usr/bin/stat -c '%u:%g' -- "$home_real" 2>/dev/null || true)" == "$bootstrap_runtime_uid:$bootstrap_runtime_gid" ]] || {
    echo 'The resolved user home is not owned by the selected runtime user.' >&2
    return 1
  }
}

validate_managed_path() {
  local path="$1"
  local normalized
  local relative
  local component
  local component_path
  local -a components

  [[ "$path" == "$HOME" || "$path" == "$HOME/"* ]] || {
    echo "Managed path is outside HOME: $path" >&2
    return 1
  }
  normalized="$(/usr/bin/realpath -m -- "$path" 2>/dev/null || true)"
  path_is_under "$normalized" "$home_real" || {
    echo "Managed path resolves outside the real user home: $path" >&2
    return 1
  }

  [[ "$path" == "$HOME" ]] && return 0
  relative="${path#"$HOME"/}"
  component_path="$HOME"
  IFS='/' read -r -a components <<< "$relative"
  for component in "${components[@]}"; do
    [[ -z "$component" || "$component" == '.' ]] && continue
    component_path="$component_path/$component"
    [[ ! -L "$component_path" ]] || {
      echo "Managed path contains a symlinked component: $component_path" >&2
      return 1
    }
  done
}

validate_managed_paths() {
  validate_user_home || return 1
  local path
  for path in "$@"; do
    validate_managed_path "$path" || return 1
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
  normalized="$(/usr/bin/realpath -m -- "$path" 2>/dev/null || true)"
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

  validate_user_home || exit 24
  fence_components_safe "$path" || {
    echo "Unsafe fenced directory: $path" >&2
    exit 24
  }
  exec {opened_fd}<"$HOME" || { echo 'Could not open fenced HOME directory.' >&2; exit 24; }
  current="/proc/self/fd/$opened_fd"
  relative="${path#"$HOME"}"
  relative="${relative#/}"
  if [[ -n "$relative" ]]; then
    IFS='/' read -r -a components <<< "$relative"
    for component in "${components[@]}"; do
      [[ -n "$component" && "$component" != '.' && "$component" != '..' && "$component" != *'/'* ]] || {
        close_fence_fd "$opened_fd"
        echo "Unsafe fenced path component: $component" >&2
        exit 24
      }
      child="$current/$component"
      [[ ! -L "$child" ]] || {
        close_fence_fd "$opened_fd"
        echo "Fenced directory contains a symlink: $path" >&2
        exit 24
      }
      if [[ ! -e "$child" ]]; then
        /usr/bin/mkdir -- "$child" || {
          close_fence_fd "$opened_fd"
          echo "Could not create fenced directory: $path" >&2
          exit 24
        }
      fi
      [[ -d "$child" && ! -L "$child" ]] || {
        close_fence_fd "$opened_fd"
        echo "Fenced directory is not a real directory: $path" >&2
        exit 24
      }
      exec {next_fd}<"$child" || {
        close_fence_fd "$opened_fd"
        echo "Could not open fenced directory: $path" >&2
        exit 24
      }
      close_fence_fd "$opened_fd"
      opened_fd="$next_fd"
      current="/proc/self/fd/$opened_fd"
    done
  fi
  [[ -d "$current" ]] || {
    close_fence_fd "$opened_fd"
    echo "Fenced path is not a directory: $path" >&2
    exit 24
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
  fd_id="$(/usr/bin/stat -Lc '%d:%i' -- "/proc/self/fd/$fd" 2>/dev/null || true)"
  live_id="$(/usr/bin/stat -Lc '%d:%i' -- "$path" 2>/dev/null || true)"
  [[ -n "$fd_id" && "$fd_id" == "$live_id" ]]
}

fence_require_directory() {
  local path="$1"
  local fd="$2"
  local label="${3:-managed directory}"
  fence_directory_matches "$path" "$fd" || {
    echo "Managed namespace drift detected for $label: $path" >&2
    exit 24
  }
}

fence_open_parent() {
  local path="$1"
  local fd_name="$2"
  local anchor_name="$3"
  local parent_name="$4"
  local expected_fd="${5:-}"
  local fence_open_parent_path="${path%/*}"
  local fence_open_parent_base="${path##*/}"
  local fence_open_parent_fd
  if [[ -n "$expected_fd" ]]; then
    fence_open_parent_fd="$expected_fd"
  else
    fence_open_directory "$fence_open_parent_path" fence_open_parent_fd
  fi
  printf -v "$fd_name" '%s' "$fence_open_parent_fd"
  printf -v "$anchor_name" '/proc/self/fd/%s/%s' "$fence_open_parent_fd" "$fence_open_parent_base"
  printf -v "$parent_name" '%s' "$fence_open_parent_path"
}

fence_require_parent() {
  fence_require_directory "$1" "$2" "${3:-managed parent}"
}

bootstrap_test_pause() {
  local phase="$1"
  local ready_file="${HERDR_BOOTSTRAP_TEST_READY_FILE:-${HERDR_PAYLOAD_TEST_READY_FILE:-}}"
  local continue_file="${HERDR_BOOTSTRAP_TEST_CONTINUE_FILE:-${HERDR_PAYLOAD_TEST_CONTINUE_FILE:-}}"
  [[ "${HERDR_BOOTSTRAP_TEST_PAUSE_PHASE:-}" == "$phase" ]] || return 0
  [[ -n "$ready_file" && -n "$continue_file" ]] || {
    echo "Test pause is missing synchronization files: $phase" >&2
    exit 24
  }
  : > "$ready_file"
  while [[ ! -e "$continue_file" ]]; do sleep 0.01; done
}

fence_replace_link() {
  local source="$1"
  local link_path="$2"
  local phase="$3"
  local expected_fd="${4:-}"
  local fd
  local anchor
  local parent
  local owns_fd=0
  if [[ -n "$expected_fd" ]]; then
    fence_open_parent "$link_path" fd anchor parent "$expected_fd"
  else
    fence_open_parent "$link_path" fd anchor parent
    owns_fd=1
  fi
  fence_require_parent "$parent" "$fd" "link parent for $link_path"
  bootstrap_test_pause "$phase"
  fence_require_parent "$parent" "$fd" "link parent for $link_path"
  [[ ! -e "$anchor" || -L "$anchor" ]] || {
    if (( owns_fd == 1 )); then close_fence_fd "$fd"; fi
    echo "Refusing to replace non-managed path: $link_path" >&2
    exit 24
  }
  ln -sfnT -- "$source" "$anchor"
  fence_require_parent "$parent" "$fd" "link parent for $link_path"
  if (( owns_fd == 1 )); then close_fence_fd "$fd"; fi
}

fence_replace_file() {
  local source="$1"
  local target_path="$2"
  local mode="$3"
  local phase="$4"
  local expected_fd="${5:-}"
  local fd
  local anchor
  local parent
  local owns_fd=0
  if [[ -n "$expected_fd" ]]; then
    fence_open_parent "$target_path" fd anchor parent "$expected_fd"
  else
    fence_open_parent "$target_path" fd anchor parent
    owns_fd=1
  fi
  fence_require_parent "$parent" "$fd" "file parent for $target_path"
  chmod "$mode" "$source"
  bootstrap_test_pause "$phase"
  fence_require_parent "$parent" "$fd" "file parent for $target_path"
  [[ ! -L "$anchor" ]] || {
    if (( owns_fd == 1 )); then close_fence_fd "$fd"; fi
    echo "Managed file path became a symlink: $target_path" >&2
    exit 24
  }
  mv -T -- "$source" "$anchor"
  fence_require_parent "$parent" "$fd" "file parent for $target_path"
  if (( owns_fd == 1 )); then close_fence_fd "$fd"; fi
}

fence_replace_python_launcher() {
  local source="$1"
  local target_path="$2"
  local phase="$3"
  local expected_fd="${4:-}"
  local managed_root="$5"
  local fd
  local anchor
  local parent
  local existing_real
  local owns_fd=0
  if [[ -n "$expected_fd" ]]; then
    fence_open_parent "$target_path" fd anchor parent "$expected_fd"
  else
    fence_open_parent "$target_path" fd anchor parent
    owns_fd=1
  fi
  fence_require_parent "$parent" "$fd" "Python launcher parent for $target_path"
  [[ -f "$source" && ! -L "$source" ]] || {
    if (( owns_fd == 1 )); then close_fence_fd "$fd"; fi
    echo "Python launcher source is not a regular file: $source" >&2
    exit 24
  }
  if [[ -L "$anchor" ]]; then
    existing_real="$(/usr/bin/realpath -e -- "$target_path" 2>/dev/null || true)"
    [[ "$existing_real" == "$managed_root"/python/*/bin/python3.13 ]] || {
      if (( owns_fd == 1 )); then close_fence_fd "$fd"; fi
      echo "Refusing to replace an unmanaged Python launcher symlink: $target_path" >&2
      exit 24
    }
    [[ -f "$existing_real" && ! -L "$existing_real" ]] || {
      if (( owns_fd == 1 )); then close_fence_fd "$fd"; fi
      echo "Managed Python launcher symlink does not target a regular runtime: $target_path" >&2
      exit 24
    }
    fence_components_safe "$existing_real" || {
      if (( owns_fd == 1 )); then close_fence_fd "$fd"; fi
      echo "Managed Python launcher symlink target has unsafe components: $target_path" >&2
      exit 24
    }
  elif [[ -e "$anchor" && ! -f "$anchor" ]]; then
    if (( owns_fd == 1 )); then close_fence_fd "$fd"; fi
    echo "Refusing to replace a non-file Python launcher: $target_path" >&2
    exit 24
  fi
  chmod 0755 "$source"
  bootstrap_test_pause "$phase"
  fence_require_parent "$parent" "$fd" "Python launcher parent for $target_path"
  mv -T -- "$source" "$anchor"
  fence_require_parent "$parent" "$fd" "Python launcher parent for $target_path"
  [[ -f "$anchor" && ! -L "$anchor" ]] || {
    if (( owns_fd == 1 )); then close_fence_fd "$fd"; fi
    echo "Python launcher publication did not produce a regular file: $target_path" >&2
    exit 24
  }
  if (( owns_fd == 1 )); then close_fence_fd "$fd"; fi
}

fence_remove_managed_link() {
  local source="$1"
  local target_path="$2"
  local phase="$3"
  local expected_fd="${4:-}"
  local fd
  local anchor
  local parent
  local expected_real
  local actual_real
  local quarantine_dir
  local quarantine_path
  local detached_real
  local owns_fd=0
  if [[ -n "$expected_fd" ]]; then
    fence_open_parent "$target_path" fd anchor parent "$expected_fd"
  else
    fence_open_parent "$target_path" fd anchor parent
    owns_fd=1
  fi
  fence_require_parent "$parent" "$fd" "managed alias parent for $target_path"
  if [[ -e "$anchor" || -L "$anchor" ]]; then
    [[ -L "$anchor" ]] || {
      if (( owns_fd == 1 )); then close_fence_fd "$fd"; fi
      echo "Refusing to replace a non-managed alias: $target_path" >&2
      exit 24
    }
    expected_real="$(/usr/bin/realpath -e -- "$source" 2>/dev/null || true)"
    actual_real="$(/usr/bin/realpath -e -- "$target_path" 2>/dev/null || true)"
    [[ -n "$expected_real" && "$actual_real" == "$expected_real" ]] || {
      if (( owns_fd == 1 )); then close_fence_fd "$fd"; fi
      echo "Refusing to remove an unmanaged alias: $target_path" >&2
      exit 24
    }
    quarantine_dir="$(/usr/bin/mktemp -d "$parent/.herdr-rtk-remove.XXXXXX")" || {
      if (( owns_fd == 1 )); then close_fence_fd "$fd"; fi
      echo "Could not create the managed alias quarantine: $target_path" >&2
      exit 24
    }
    bootstrap_register_cleanup "$quarantine_dir"
    /usr/bin/chmod 0700 -- "$quarantine_dir"
    quarantine_path="$quarantine_dir/${target_path##*/}"
    bootstrap_test_pause "$phase"
    fence_require_parent "$parent" "$fd" "managed alias parent for $target_path"
    # Detach the name with one atomic no-replace rename.  The object moved to
    # quarantine is then the object whose identity is checked; the target
    # pathname is never checked and later unlinked.  If a replacement won the
    # race, restore that exact replacement when the target name is still free,
    # otherwise leave it quarantined and fail closed without removing it.
    /usr/bin/mv -n -T -- "$anchor" "$quarantine_path" || {
      echo "Managed alias could not be atomically detached: $target_path" >&2
      exit 24
    }
    [[ ! -e "$anchor" && ! -L "$anchor" ]] || {
      echo "Managed alias detach did not produce the expected state: $target_path" >&2
      exit 24
    }
    if [[ ! -L "$quarantine_path" ]]; then
      # A raced regular-file replacement may have won the rename.  Restore
      # that exact object to the public name before failing closed; never
      # quarantine it away from the name an operator or subsequent run sees.
      if [[ ! -e "$anchor" && ! -L "$anchor" ]]; then
        /usr/bin/mv -n -T -- "$quarantine_path" "$anchor" || true
      fi
      if (( owns_fd == 1 )); then close_fence_fd "$fd"; fi
      echo "Managed alias replacement was not a symlink: $target_path" >&2
      exit 24
    fi
    detached_real="$(/usr/bin/realpath -e -- "$quarantine_path" 2>/dev/null || true)"
    if [[ "$detached_real" != "$expected_real" ]]; then
      if [[ ! -e "$anchor" && ! -L "$anchor" ]]; then
        /usr/bin/mv -n -T -- "$quarantine_path" "$anchor" || true
      fi
      if (( owns_fd == 1 )); then close_fence_fd "$fd"; fi
      echo "Managed alias replacement won the removal race: $target_path" >&2
      exit 24
    fi
    # Only the already-detached, identity-verified managed link is removed.
    # A replacement at the public alias path is never a target of this rm.
    /usr/bin/rm -f -- "$quarantine_path"
    /usr/bin/rmdir -- "$quarantine_dir" 2>/dev/null || true
  fi
  fence_require_parent "$parent" "$fd" "managed alias parent for $target_path"
  if (( owns_fd == 1 )); then close_fence_fd "$fd"; fi
}

validate_toolchain_lock() {
  for lock_hash_key in UV_SHA256 PYTHON_SHA256 RTK_SHA256 POWERSHELL_SHA256 TAILSCALE_INSTALLER_SHA256 RUSTUP_INIT_SHA256 NODE_SHA256 HERDR_SHA256; do
    [[ "${!lock_hash_key:-}" =~ ^[0-9a-f]{64}$ ]] || {
      echo "Lock key '$lock_hash_key' is not a lowercase SHA-256 value." >&2
      return 1
    }
  done
  [[ "$UV_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo 'UV_VERSION is not a pinned semantic version.' >&2; return 1;
  }
  [[ "$UV_PLATFORM" == 'x86_64-unknown-linux-gnu' ]] || {
    echo 'UV_PLATFORM is not the supported Ubuntu x86-64 target.' >&2; return 1;
  }
  [[ "$UV_URL" == "https://github.com/astral-sh/uv/releases/download/$UV_VERSION/uv-$UV_PLATFORM.tar.gz" ]] || {
    echo 'UV_URL does not identify the pinned official uv artifact.' >&2; return 1;
  }
  [[ "$PYTHON_VERSION" =~ ^3\.13\.[0-9]+$ ]] || {
    echo 'PYTHON_VERSION is not a pinned Python 3.13 release.' >&2; return 1;
  }
  [[ "$PYTHON_RELEASE" =~ ^[0-9]{8}$ ]] || {
    echo 'PYTHON_RELEASE is not a pinned python-build-standalone release.' >&2; return 1;
  }
  [[ "$PYTHON_PLATFORM" == 'x86_64-unknown-linux-gnu' ]] || {
    echo 'PYTHON_PLATFORM is not the supported Ubuntu x86-64 target.' >&2; return 1;
  }
  expected_python_archive="cpython-$PYTHON_VERSION+$PYTHON_RELEASE-$PYTHON_PLATFORM-install_only_stripped.tar.gz"
  [[ "$PYTHON_ARCHIVE" == "$expected_python_archive" ]] || {
    echo 'PYTHON_ARCHIVE does not match the pinned Python release inputs.' >&2; return 1;
  }
  expected_python_url="https://github.com/astral-sh/python-build-standalone/releases/download/$PYTHON_RELEASE/${PYTHON_ARCHIVE//+/%2B}"
  [[ "$PYTHON_URL" == "$expected_python_url" ]] || {
    echo 'PYTHON_URL does not identify the pinned official CPython artifact.' >&2; return 1;
  }
  [[ "$RTK_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo 'RTK_VERSION is not a pinned semantic version.' >&2; return 1;
  }
  [[ "$RTK_URL" == "https://github.com/rtk-ai/rtk/releases/download/v$RTK_VERSION/rtk-x86_64-unknown-linux-musl.tar.gz" ]] || {
    echo 'RTK_URL does not identify the pinned official x86-64 Linux release artifact.' >&2; return 1;
  }
  [[ "$TAILSCALE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo 'TAILSCALE_VERSION is not a pinned semantic version.' >&2; return 1;
  }
  [[ "$TAILSCALE_INSTALLER_URL" == 'https://tailscale.com/install.sh' ]] || {
    echo 'TAILSCALE_INSTALLER_URL is not the pinned official installer.' >&2
    return 1
  }
  return 0
}

validate_platform() {
  [[ "$(uname -s)" == 'Linux' && "$(uname -m)" == 'x86_64' && "$(getconf LONG_BIT)" == '64' ]] || {
    echo 'This bootstrap lock supports only 64-bit x86 Linux.' >&2
    return 1
  }
}

check_uv_version() {
  local executable="$1"
  local expected="uv $UV_VERSION ($UV_PLATFORM)"
  local actual
  actual="$(bootstrap_exec_user_runtime "$executable" --version 2>&1)" || return 1
  [[ "$actual" == "$expected" ]]
}

check_python_version() {
  local executable="$1"
  local actual
  actual="$(bootstrap_exec_python "$executable" --version 2>&1)" || return 1
  [[ "$actual" == "Python $PYTHON_VERSION" ]]
}

check_python_platform() {
  local executable="$1"
  local actual
  actual="$(bootstrap_exec_python "$executable" -c 'import platform, sys; print(f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}|{platform.machine()}|{sys.platform}")')" || return 1
  [[ "$actual" == "$PYTHON_VERSION|x86_64|linux" ]]
}

write_py_compat() {
  local expected_fd="${1:-}"
  local wrapper="$bin_dir/py"
  local replacement
  local wrapper_fd
  local wrapper_anchor
  local wrapper_parent
  local owns_fd=0
  validate_managed_paths "$wrapper" || {
    echo "Unsafe managed py path: $wrapper" >&2
    exit 24
  }
  if [[ -n "$expected_fd" ]]; then
    fence_open_parent "$wrapper" wrapper_fd wrapper_anchor wrapper_parent "$expected_fd"
  else
    fence_open_parent "$wrapper" wrapper_fd wrapper_anchor wrapper_parent
    owns_fd=1
  fi
  fence_require_parent "$wrapper_parent" "$wrapper_fd" 'managed py parent'
  [[ ! -L "$wrapper_anchor" ]] || {
    if (( owns_fd == 1 )); then close_fence_fd "$wrapper_fd"; fi
    echo "Managed py path is a symlink: $wrapper" >&2
    exit 24
  }
  replacement="$(mktemp)"
  bootstrap_register_cleanup "$replacement"
  cat > "$replacement" <<'EOF'
#!/usr/bin/bash
set -euo pipefail

if [[ $# -lt 1 || "$1" != '-3.13' ]]; then
  echo 'This managed py command supports only the -3.13 selector.' >&2
  exit 2
fi
shift
wrapper_dir="$(cd -- "$(/usr/bin/dirname -- "${BASH_SOURCE[0]}")" && /usr/bin/pwd)"
exec "$wrapper_dir/python3.13" "$@"
EOF
  chmod 0755 "$replacement"
  bootstrap_test_pause before-py-publish
  fence_require_parent "$wrapper_parent" "$wrapper_fd" 'managed py parent'
  if ! cmp -s "$replacement" "$wrapper_anchor" 2>/dev/null; then
    mv -T -- "$replacement" "$wrapper_anchor"
    replacement=''
  fi
  fence_require_parent "$wrapper_parent" "$wrapper_fd" 'managed py parent'
  if (( owns_fd == 1 )); then close_fence_fd "$wrapper_fd"; fi
  [[ -z "$replacement" ]] || rm -f "$replacement"
}

bootstrap_download_transport() {
  local url="$1"
  local destination="$2"
  bootstrap_exec_system /usr/bin/curl --config /dev/null --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
    --retry 3 --connect-timeout 15 --output "$destination" "$url"
}

bootstrap_integrity_check() {
  local expected_sha="$1"
  local destination="$2"
  printf '%s  %s\n' "$expected_sha" "$destination" | bootstrap_exec_system /usr/bin/sha256sum --check --status
}

bootstrap_validate_tailscale_apt_identity() {
  local resolved="$1"
  [[ "$resolved" == /usr/bin/apt-get && -x "$resolved" ]] || {
    echo 'Could not resolve the canonical system apt-get executable.' >&2
    return 1
  }
}

download_verified() {
  local url="$1"
  local expected_sha="$2"
  local destination="$3"
  bootstrap_register_cleanup "$destination"
  bootstrap_download_transport "$url" "$destination"
  bootstrap_integrity_check "$expected_sha" "$destination" || {
    echo "SHA-256 verification failed for $url" >&2
    bootstrap_exec_system /usr/bin/rm -f -- "$destination"
    exit 23
  }
}

install_locked_tailscale() (
  local installed_tailscale
  local tailscale_temp_dir
  local installer
  local root_stage_dir
  local trusted_path='/usr/sbin:/usr/bin:/sbin:/bin'
  local tailscale_bin sudo_bin shell_bin apt_get_bin
  local real_apt_get
  local installer_status

  validate_toolchain_lock || exit 22
  tailscale_bin="$(bootstrap_command_path tailscale)"
  if [[ "$bootstrap_root_mode" == 1 ]]; then
    sudo_bin=''
  else
    sudo_bin="$(bootstrap_command_path sudo)"
  fi
  shell_bin='/usr/bin/dash'
  bootstrap_trust_assert_binary "$shell_bin"
  apt_get_bin="$(bootstrap_command_path apt-get)"
  installed_tailscale="$("$tailscale_bin" version 2>/dev/null | /usr/bin/head -n 1 || true)"
  [[ "$installed_tailscale" == "$TAILSCALE_VERSION" ]] && return 0

  tailscale_temp_dir="$(/usr/bin/mktemp -d /tmp/herdr-tailscale.XXXXXX)"
  bootstrap_register_cleanup "$tailscale_temp_dir"
  trap '/usr/bin/rm -rf -- "$tailscale_temp_dir"' EXIT
  installer="$tailscale_temp_dir/install.sh"
  real_apt_get="$(/usr/bin/realpath -e -- "$apt_get_bin" 2>/dev/null || true)"
  bootstrap_validate_tailscale_apt_identity "$real_apt_get"

  download_verified "$TAILSCALE_INSTALLER_URL" "$TAILSCALE_INSTALLER_SHA256" "$installer"
  root_stage_dir="$(bootstrap_exec_privileged "$sudo_bin" /usr/bin/mktemp -d /tmp/herdr-tailscale-root.XXXXXX)"
  if bootstrap_exec_privileged "$sudo_bin" /usr/bin/bash -s -- \
    "$installer" "$root_stage_dir" "$TAILSCALE_INSTALLER_SHA256" "$TAILSCALE_VERSION" <<'HERDR_TAILSCALE_ROOT'
set -euo pipefail
installer_path="$1"
stage_dir="$2"
expected_sha="$3"
locked_version="$4"
apt_get_path=/usr/bin/apt-get
expected_owner="$(/usr/bin/id -u)"
expected_group="$(/usr/bin/id -g)"
[[ -d "$stage_dir" && ! -L "$stage_dir" ]] || exit 24
[[ "$(/usr/bin/stat -c '%u' -- "$stage_dir")" == "$expected_owner" && \
  "$(/usr/bin/stat -c '%g' -- "$stage_dir")" == "$expected_group" && \
  "$(/usr/bin/stat -c '%a' -- "$stage_dir")" =~ ^[0-7]+$ && \
  $((8#$(/usr/bin/stat -c '%a' -- "$stage_dir") & 022)) == 0 ]] || exit 24
[[ -f "$installer_path" && ! -L "$installer_path" ]] || exit 24
[[ -x "$apt_get_path" && ! -L "$apt_get_path" &&
  "$(/usr/bin/realpath -e -- "$apt_get_path" 2>/dev/null || true)" == "$apt_get_path" &&
  "$(/usr/bin/stat -c '%u:%g:%a' -- "$apt_get_path")" == 0:0:* ]] || exit 24
[[ "$(/usr/bin/stat -c '%a' -- "$apt_get_path")" =~ ^[0-7]+$ &&
  $((8#$(/usr/bin/stat -c '%a' -- "$apt_get_path") & 022)) == 0 ]] || exit 24
exec 8<"$apt_get_path"
apt_fd_path="/proc/$BASHPID/fd/8"
apt_fd_identity="$(/usr/bin/stat -Lc '%d:%i:%u:%g:%a:%F' -- "$apt_fd_path")"
[[ "$(/usr/bin/realpath -e -- "$apt_fd_path" 2>/dev/null || true)" == "$apt_get_path" &&
  "$apt_fd_identity" == "$(/usr/bin/stat -Lc '%d:%i:%u:%g:%a:%F' -- "$apt_get_path")" ]] || exit 24
exec {installer_fd}<"$installer_path"
installer_fd_path="/proc/$BASHPID/fd/$installer_fd"
installer_id="$(/usr/bin/stat -Lc '%d:%i' -- "$installer_fd_path")"
installer_path_id="$(/usr/bin/stat -Lc '%d:%i' -- "$installer_path")"
installer_hash="$(/usr/bin/sha256sum -- "$installer_fd_path" | /usr/bin/gawk '{print $1}')"
[[ "$installer_id" == "$installer_path_id" && "$installer_hash" == "$expected_sha" ]] || exit 24
trap '/usr/bin/rm -rf -- "$stage_dir"' EXIT
/usr/bin/cp -- "$installer_fd_path" "$stage_dir/install.sh"
/usr/bin/chmod 0755 -- "$stage_dir/install.sh"
cat >"$stage_dir/apt-get" <<'HERDR_TAILSCALE_SHIM'
#!/usr/bin/bash
set -euo pipefail
apt_fd_path=/proc/self/fd/8
locked_version="${TAILSCALE_VERSION:?}"
[[ "$(/usr/bin/realpath -e -- "$apt_fd_path" 2>/dev/null || true)" == /usr/bin/apt-get &&
  "$(/usr/bin/stat -c '%u:%g:%a' -- "$apt_fd_path")" == 0:0:* &&
  "$(/usr/bin/stat -c '%a' -- "$apt_fd_path")" =~ ^[0-7]+$ &&
  $((8#$(/usr/bin/stat -c '%a' -- "$apt_fd_path") & 022)) == 0 ]] || exit 24
args=("$@")
has_tailscale_package=0
for arg in "${args[@]}"; do
  case "$arg" in tailscale|tailscale=*) has_tailscale_package=1 ;; esac
done
if (( has_tailscale_package == 1 )); then
  if [[ "${#args[@]}" -eq 4 && "${args[0]}" == install && "${args[1]}" == -y && \
        "${args[2]}" == "tailscale=$locked_version" && "${args[3]}" == tailscale-archive-keyring ]]; then
    exec "$apt_fd_path" install --allow-downgrades -y "${args[2]}" "${args[3]}"
  fi
  echo 'Unexpected or unlocked Tailscale apt-get invocation.' >&2
  exit 24
fi
exec "$apt_fd_path" "${args[@]}"
HERDR_TAILSCALE_SHIM
/usr/bin/chmod 0755 -- "$stage_dir/apt-get"
for object in "$stage_dir/install.sh" "$stage_dir/apt-get"; do
  [[ -f "$object" && ! -L "$object" && "$(/usr/bin/stat -c '%u' -- "$object")" == "$expected_owner" && \
    "$(/usr/bin/stat -c '%g' -- "$object")" == "$expected_group" && \
    $((8#$(/usr/bin/stat -c '%a' -- "$object") & 022)) == 0 ]] || exit 24
done
[[ "$(/usr/bin/sha256sum -- "$stage_dir/install.sh" | /usr/bin/gawk '{print $1}')" == "$installer_hash" ]] || exit 24
[[ "$(/usr/bin/stat -Lc '%d:%i' -- "$installer_path")" == "$installer_id" && \
  "$(/usr/bin/sha256sum -- "$installer_path" | /usr/bin/gawk '{print $1}')" == "$expected_sha" ]] || exit 24
/usr/bin/env -i PATH="$stage_dir:/usr/sbin:/usr/bin:/sbin:/bin" TAILSCALE_VERSION="$locked_version" \
  /usr/bin/dash "$installer_fd_path"
HERDR_TAILSCALE_ROOT
  then
    installer_status=0
  else
    installer_status=$?
  fi
  (( installer_status == 0 )) || {
    echo "Tailscale installer failed with exit status $installer_status." >&2
    exit "$installer_status"
  }
  [[ "$("$tailscale_bin" version | /usr/bin/head -n 1)" == "$TAILSCALE_VERSION" ]] || {
    echo "Tailscale version does not match lock ($TAILSCALE_VERSION)." >&2
    exit 24
  }
)

bootstrap_install_locked_deb() {
  local package_path="$1"
  local expected_sha="$2"
  local sudo_bin="$3"
  local apt_get_bin="$4"
  local root_stage_dir
  root_stage_dir="$(bootstrap_exec_privileged "$sudo_bin" /usr/bin/mktemp -d /tmp/herdr-deb-root.XXXXXX)"
  bootstrap_exec_privileged "$sudo_bin" /usr/bin/bash -s -- \
    "$package_path" "$root_stage_dir" "$expected_sha" "$apt_get_bin" <<'HERDR_DEB_ROOT'
set -euo pipefail
package_path="$1"
stage_dir="$2"
expected_sha="$3"
apt_get_bin="$4"
expected_owner="$(/usr/bin/id -u)"
expected_group="$(/usr/bin/id -g)"
apt_get_path=/usr/bin/apt-get
[[ -d "$stage_dir" && ! -L "$stage_dir" &&
  "$(/usr/bin/stat -c '%u' -- "$stage_dir")" == "$expected_owner" &&
  "$(/usr/bin/stat -c '%g' -- "$stage_dir")" == "$expected_group" &&
  $((8#$(/usr/bin/stat -c '%a' -- "$stage_dir") & 022)) == 0 ]] || exit 24
[[ -f "$package_path" && ! -L "$package_path" ]] || exit 24
exec {package_fd}<"$package_path"
package_fd_path="/proc/$BASHPID/fd/$package_fd"
package_id="$(/usr/bin/stat -Lc '%d:%i' -- "$package_fd_path")"
package_path_id="$(/usr/bin/stat -Lc '%d:%i' -- "$package_path")"
package_hash="$(/usr/bin/sha256sum -- "$package_fd_path" | /usr/bin/gawk '{print $1}')"
[[ "$package_id" == "$package_path_id" && "$package_hash" == "$expected_sha" ]] || exit 24
trap '/usr/bin/rm -rf -- "$stage_dir"' EXIT
/usr/bin/cp -- "$package_fd_path" "$stage_dir/package.deb"
/usr/bin/chmod 0644 -- "$stage_dir/package.deb"
[[ -f "$stage_dir/package.deb" && ! -L "$stage_dir/package.deb" &&
  "$(/usr/bin/stat -c '%u' -- "$stage_dir/package.deb")" == "$expected_owner" &&
  "$(/usr/bin/stat -c '%g' -- "$stage_dir/package.deb")" == "$expected_group" &&
  "$(/usr/bin/sha256sum -- "$stage_dir/package.deb" | /usr/bin/gawk '{print $1}')" == "$package_hash" ]] || exit 24
[[ "$(/usr/bin/stat -Lc '%d:%i' -- "$package_path")" == "$package_id" &&
  "$(/usr/bin/sha256sum -- "$package_path" | /usr/bin/gawk '{print $1}')" == "$expected_sha" ]] || exit 24
[[ "$apt_get_bin" == "$apt_get_path" && -x "$apt_get_path" && ! -L "$apt_get_path" &&
  "$(/usr/bin/realpath -e -- "$apt_get_path" 2>/dev/null || true)" == "$apt_get_path" &&
  "$(/usr/bin/stat -c '%u:%g' -- "$apt_get_path")" == 0:0 &&
  "$(/usr/bin/stat -c '%a' -- "$apt_get_path")" =~ ^[0-7]+$ &&
  $((8#$(/usr/bin/stat -c '%a' -- "$apt_get_path") & 022)) == 0 ]] || exit 24
exec 8<"$apt_get_path"
apt_fd_path="/proc/$BASHPID/fd/8"
apt_identity="$(/usr/bin/stat -Lc '%d:%i:%u:%g:%a:%F' -- "$apt_get_path")"
[[ "$(/usr/bin/realpath -e -- "$apt_fd_path" 2>/dev/null || true)" == "$apt_get_path" &&
  "$(/usr/bin/stat -Lc '%d:%i:%u:%g:%a:%F' -- "$apt_fd_path")" == "$apt_identity" ]] || exit 24
/usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin DEBIAN_FRONTEND=noninteractive \
  /proc/self/fd/8 install -y "$stage_dir/package.deb"
HERDR_DEB_ROOT
}

install_python_toolchain() {
  local state_fd
  local bin_fd
  local local_dir_fd
  local uv_parent_fd
  local uv_version_parent_fd
  local python_parent_fd
  local uv_dir_fd
  local python_dir_fd
  local uv_parent_anchor
  local python_parent_anchor
  local uv_dir_anchor
  local python_dir_anchor
  local uv_dir_parent
  local python_dir_parent
  local bin_dir_anchor
  local local_dir_anchor
  local uv_runtime_real
  local python_runtime_real
  local python_launcher_stage=''
  local python_venv_stage=''
  validate_toolchain_lock || exit 22
  validate_platform || exit 20

  managed_root="$HOME/.local/lib/herdr-workstation"
  uv_parent="$managed_root/uv"
  python_parent="$managed_root/python"
  uv_dir="$uv_parent/$UV_VERSION/$UV_PLATFORM"
  python_dir="$python_parent/$PYTHON_VERSION-$PYTHON_RELEASE-$PYTHON_PLATFORM"
  validate_managed_paths \
    "$state_dir" "$bin_dir" "$managed_root" "$uv_parent" "$python_parent" \
    "$uv_dir" "$uv_dir/uv" "$python_dir" "$python_dir/bin" "$python_dir/bin/python3.13" \
    "$HOME/.local" "$HOME/.local/pyvenv.cfg" || {
      echo 'Managed Python toolchain paths are unsafe.' >&2
      exit 24
    }
  fence_open_directory "$state_dir" state_fd
  fence_open_directory "$bin_dir" bin_fd
  fence_open_directory "$HOME/.local" local_dir_fd
  fence_require_directory "$state_dir" "$state_fd" 'toolchain state directory'
  fence_require_directory "$bin_dir" "$bin_fd" 'toolchain bin directory'
  fence_require_directory "$HOME/.local" "$local_dir_fd" 'local directory'
  bin_dir_anchor="/proc/self/fd/$bin_fd"
  local_dir_anchor="/proc/self/fd/$local_dir_fd"
  bootstrap_test_pause before-toolchain-directory-mutations
  fence_open_directory "$uv_parent" uv_parent_fd
  uv_parent_anchor="/proc/self/fd/$uv_parent_fd"
  fence_open_directory "$uv_parent/$UV_VERSION" uv_version_parent_fd
  fence_open_directory "$python_parent" python_parent_fd
  python_parent_anchor="/proc/self/fd/$python_parent_fd"

  if [[ ! -x "$uv_dir/uv" ]] || ! check_uv_version "$uv_dir/uv"; then
    uv_archive="$(/usr/bin/mktemp --suffix=.tar.gz)"
    bootstrap_register_cleanup "$uv_archive"
    uv_stage="$(/usr/bin/mktemp -d /tmp/herdr-uv-stage.XXXXXX)"
    bootstrap_register_cleanup "$uv_stage"
    download_verified "$UV_URL" "$UV_SHA256" "$uv_archive"
    /usr/bin/tar -xzf "$uv_archive" -C "$uv_stage"
    mapfile -t uv_candidates < <(/usr/bin/find "$uv_stage" -type f -name uv -perm -u+x -print)
    if (( ${#uv_candidates[@]} != 1 )); then
      echo 'The pinned uv archive did not contain exactly one executable uv.' >&2
      exit 24
    fi
    check_uv_version "${uv_candidates[0]}" || {
      echo "uv artifact version does not match the lock ($UV_VERSION)." >&2
      exit 24
    }
    fence_require_directory "$uv_parent" "$uv_parent_fd" 'uv parent'
    uv_install_stage="$(/usr/bin/mktemp -d "$uv_parent_anchor/.install.XXXXXX")"
    bootstrap_register_cleanup "$uv_install_stage"
    /usr/bin/install -m 0755 -- "${uv_candidates[0]}" "$uv_install_stage/uv"
    fence_open_parent "$uv_dir" uv_dir_fd uv_dir_anchor uv_dir_parent "$uv_version_parent_fd"
    bootstrap_test_pause before-uv-publish
    fence_require_parent "$uv_dir_parent" "$uv_dir_fd" 'uv destination parent'
    [[ ! -L "$uv_dir_anchor" ]] || { echo 'Unsafe uv managed destination symlink.' >&2; exit 24; }
    if [[ -e "$uv_dir_anchor" ]]; then /usr/bin/rm -rf -- "$uv_dir_anchor"; fi
    /usr/bin/mv -T -- "$uv_install_stage" "$uv_dir_anchor"
    fence_require_parent "$uv_dir_parent" "$uv_dir_fd" 'uv destination parent'
    close_fence_fd "$uv_dir_fd"
    /usr/bin/rm -rf -- "$uv_stage"
    /usr/bin/rm -f -- "$uv_archive"
  fi

  if [[ ! -x "$python_dir/bin/python3.13" ]] || ! check_python_version "$python_dir/bin/python3.13" || ! check_python_platform "$python_dir/bin/python3.13"; then
    python_archive="$(/usr/bin/mktemp --suffix=.tar.gz)"
    bootstrap_register_cleanup "$python_archive"
    python_stage="$(/usr/bin/mktemp -d /tmp/herdr-python-stage.XXXXXX)"
    bootstrap_register_cleanup "$python_stage"
    download_verified "$PYTHON_URL" "$PYTHON_SHA256" "$python_archive"
    /usr/bin/tar -xzf "$python_archive" -C "$python_stage"
    mapfile -t python_candidates < <(/usr/bin/find "$python_stage" -type f -path '*/bin/python3.13' -perm -u+x -print)
    if (( ${#python_candidates[@]} != 1 )); then
      echo 'The pinned CPython archive did not contain exactly one executable python3.13.' >&2
      exit 24
    fi
    check_python_version "${python_candidates[0]}" && check_python_platform "${python_candidates[0]}" || {
      echo "CPython artifact does not match the lock ($PYTHON_VERSION, $PYTHON_PLATFORM)." >&2
      exit 24
    }
    python_source_root="$(cd "$(/usr/bin/dirname "${python_candidates[0]}")/.." && /usr/bin/pwd -P)"
    fence_require_directory "$python_parent" "$python_parent_fd" 'Python parent'
    python_install_stage="$(/usr/bin/mktemp -d "$python_parent_anchor/.install.XXXXXX")"
    bootstrap_register_cleanup "$python_install_stage"
    /usr/bin/cp -a -- "$python_source_root"/. "$python_install_stage"/
    check_python_version "$python_install_stage/bin/python3.13" && check_python_platform "$python_install_stage/bin/python3.13" || {
      echo 'Staged CPython runtime failed its exact version/platform check.' >&2
      exit 24
    }
    fence_open_parent "$python_dir" python_dir_fd python_dir_anchor python_dir_parent "$python_parent_fd"
    bootstrap_test_pause before-python-publish
    fence_require_parent "$python_dir_parent" "$python_dir_fd" 'Python destination parent'
    [[ ! -L "$python_dir_anchor" ]] || { echo 'Unsafe Python managed destination symlink.' >&2; exit 24; }
    if [[ -e "$python_dir_anchor" ]]; then /usr/bin/rm -rf -- "$python_dir_anchor"; fi
    /usr/bin/mv -T -- "$python_install_stage" "$python_dir_anchor"
    fence_require_parent "$python_dir_parent" "$python_dir_fd" 'Python destination parent'
    close_fence_fd "$python_dir_fd"
    /usr/bin/rm -rf -- "$python_stage"
    /usr/bin/rm -f -- "$python_archive"
  fi

  uv_runtime_real="$(/usr/bin/realpath -e -- "$uv_dir/uv" 2>/dev/null || true)"
  python_runtime_real="$(/usr/bin/realpath -e -- "$python_dir/bin/python3.13" 2>/dev/null || true)"
  path_is_under "$uv_runtime_real" "$home_real" || { echo 'uv runtime escaped the managed HOME.' >&2; exit 24; }
  path_is_under "$python_runtime_real" "$home_real" || { echo 'Python runtime escaped the managed HOME.' >&2; exit 24; }
  [[ -f "$python_runtime_real" && ! -L "$python_runtime_real" ]] || { echo 'Managed Python runtime is not a regular file.' >&2; exit 24; }
  fence_replace_link "$uv_runtime_real" "$bin_dir/uv" before-uv-link-publish "$bin_fd"
  python_launcher_stage="$(/usr/bin/mktemp "$bin_dir_anchor/.python3.13.XXXXXX")"
  bootstrap_register_cleanup "$python_launcher_stage"
  /usr/bin/install -m 0755 -- "$python_runtime_real" "$python_launcher_stage"
  fence_replace_python_launcher "$python_launcher_stage" "$bin_dir/python3.13" before-python-link-publish "$bin_fd" "$managed_root"
  python_launcher_stage=''
  python_venv_stage="$(/usr/bin/mktemp "$local_dir_anchor/.pyvenv.cfg.XXXXXX")"
  bootstrap_register_cleanup "$python_venv_stage"
  cat > "$python_venv_stage" <<EOF
home = $python_dir
include-system-site-packages = false
version = $PYTHON_VERSION
EOF
  fence_replace_file "$python_venv_stage" "$HOME/.local/pyvenv.cfg" 0644 before-python-venv-config-publish "$local_dir_fd"
  python_venv_stage=''
  write_py_compat "$bin_fd"
  check_uv_version "$bin_dir/uv" || { echo 'Managed uv failed its final version check.' >&2; exit 24; }
  check_python_version "$bin_dir/python3.13" && check_python_platform "$bin_dir/python3.13" || {
    echo 'Managed python3.13 failed its final version/platform check.' >&2
    exit 24
  }
  py_probe="$("$bin_dir/py" -3.13 -c 'import platform, sys; print(f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}|{platform.machine()}|{sys.platform}")')"
  [[ "$py_probe" == "$PYTHON_VERSION|x86_64|linux" ]] || {
    echo 'Managed py -3.13 did not select the pinned CPython runtime.' >&2
    exit 24
  }
  fence_require_directory "$state_dir" "$state_fd" 'toolchain state directory'
  fence_require_directory "$bin_dir" "$bin_fd" 'toolchain bin directory'
  close_fence_fd "$uv_version_parent_fd"
  close_fence_fd "$uv_parent_fd"
  close_fence_fd "$python_parent_fd"
  close_fence_fd "$local_dir_fd"
  close_fence_fd "$state_fd"
  close_fence_fd "$bin_fd"
}

converge_profile_hook() {
  local profile_file="$1"
  local chain_profile="${2:-false}"
  local marker='# BEGIN herdr-workstation PATH'
  local end_marker='# END herdr-workstation PATH'
  local replacement
  local profile_fd
  local profile_anchor
  local profile_parent
  local backup_temp=''
  local backup_name
  local backup_anchor
  validate_managed_paths "$profile_file" || {
    echo "Unsafe managed profile path: $profile_file" >&2
    exit 24
  }
  fence_open_parent "$profile_file" profile_fd profile_anchor profile_parent
  fence_require_parent "$profile_parent" "$profile_fd" "profile parent for $profile_file"
  [[ ! -L "$profile_anchor" ]] || {
    close_fence_fd "$profile_fd"
    echo "Managed profile path is a symlink: $profile_file" >&2
    exit 24
  }
  replacement="$(mktemp)"
  bootstrap_register_cleanup "$replacement"
  if [[ ! -e "$profile_anchor" ]]; then : > "$profile_anchor"; fi
  fence_require_parent "$profile_parent" "$profile_fd" "profile parent for $profile_file"
  mapfile -t begin_lines < <(grep -nFx "$marker" "$profile_anchor" | cut -d: -f1)
  mapfile -t end_lines < <(grep -nFx "$end_marker" "$profile_anchor" | cut -d: -f1)
  if (( ${#begin_lines[@]} == 0 && ${#end_lines[@]} == 0 )); then
    cp "$profile_anchor" "$replacement"
  elif (( ${#begin_lines[@]} == 1 && ${#end_lines[@]} == 1 && begin_lines[0] < end_lines[0] )); then
    begin="${begin_lines[0]}"
    end="${end_lines[0]}"
    remove_start="$begin"
    if (( begin > 1 )) && [[ -z "$(sed -n "$((begin - 1))p" "$profile_anchor")" ]]; then
      remove_start=$((begin - 1))
    fi
    if (( remove_start > 1 )); then head -n "$((remove_start - 1))" "$profile_anchor" > "$replacement"; fi
    tail -n "+$((end + 1))" "$profile_anchor" >> "$replacement"
  else
    echo "Managed PATH markers in $profile_file are missing, duplicated, or out of order." >&2
    exit 24
  fi
  if [[ -s "$replacement" ]]; then
    if [[ "$(tail -c 1 "$replacement" | wc -l)" -eq 0 ]]; then printf '\n' >> "$replacement"; fi
    printf '\n' >> "$replacement"
  fi
  {
    printf '%s\n' "$marker"
    if [[ "$chain_profile" == true ]]; then
      printf '%s\n' 'if [[ "${HERDR_PROFILE_SOURCED_PID:-}" != "$$" && "${HERDR_PROFILE_CHAIN_ACTIVE:-0}" != 1 ]]; then'
      printf '%s\n' '  export HERDR_PROFILE_CHAIN_ACTIVE=1'
      printf '%s\n' '  [[ -f "$HOME/.profile" ]] && . "$HOME/.profile"'
      printf '%s\n' '  unset HERDR_PROFILE_CHAIN_ACTIVE'
      printf '%s\n' 'fi'
    else
      printf '%s\n' 'export HERDR_PROFILE_SOURCED_PID="$$"'
      printf '. "$HOME/.config/herdr-workstation/profile.sh"\n'
    fi
    printf '%s\n' "$end_marker"
  } >> "$replacement"
  if ! cmp -s "$profile_anchor" "$replacement"; then
    fence_require_parent "$profile_parent" "$profile_fd" "profile parent for $profile_file"
    backup_name="$(basename "$profile_file").$(date +%Y%m%d-%H%M%S)-$$.bak"
    backup_temp="$(mktemp "/proc/self/fd/$profile_fd/.herdr-profile-backup.XXXXXX")"
    bootstrap_register_cleanup "$backup_temp"
    cp "$profile_anchor" "$backup_temp"
    backup_anchor="/proc/self/fd/$profile_fd/$backup_name"
    mv -T -- "$backup_temp" "$backup_anchor"
    backup_temp=''
    chmod 0644 "$replacement"
    bootstrap_test_pause before-profile-publish
    fence_require_parent "$profile_parent" "$profile_fd" "profile parent for $profile_file"
    [[ ! -L "$profile_anchor" ]] || {
      close_fence_fd "$profile_fd"
      rm -f "$replacement"
      echo "Managed profile path became a symlink: $profile_file" >&2
      exit 24
    }
    mv -T -- "$replacement" "$profile_anchor"
    replacement=''
    fence_require_parent "$profile_parent" "$profile_fd" "profile parent for $profile_file"
  fi
  close_fence_fd "$profile_fd"
  [[ -z "$backup_temp" ]] || rm -f "$backup_temp"
  [[ -z "$replacement" ]] || rm -f "$replacement"
}

install_base_user() {
  local state_fd
  local bin_fd
  local state_anchor
  validate_managed_paths "$state_dir" "$state_dir/base-complete" "$bin_dir" || {
    echo 'Managed bootstrap paths are unsafe.' >&2
    exit 24
  }
  fence_open_directory "$state_dir" state_fd
  fence_open_directory "$bin_dir" bin_fd
  state_anchor="/proc/self/fd/$state_fd"
  fence_require_directory "$state_dir" "$state_fd" 'base state directory'
  fence_require_directory "$bin_dir" "$bin_fd" 'base bin directory'
  bootstrap_test_pause before-base-directory-mutations
  fence_require_directory "$state_dir" "$state_fd" 'base state directory'
  : > "$state_anchor/base-complete"
  fence_require_directory "$state_dir" "$state_fd" 'base state directory'
  close_fence_fd "$state_fd"
  close_fence_fd "$bin_fd"
}

install_base() {
  local state_fd
  local bin_fd
  local state_anchor
  local sudo_bin apt_get_bin ps_bin pwsh_bin systemctl_bin
  if [[ "$bootstrap_root_mode" == 1 ]]; then
    sudo_bin=''
  else
    sudo_bin="$(bootstrap_command_path sudo)"
  fi
  apt_get_bin="$(bootstrap_command_path apt-get)"
  ps_bin="$(bootstrap_command_path ps)"
  pwsh_bin="$(bootstrap_command_path pwsh)"
  systemctl_bin="$(bootstrap_command_path systemctl)"
  validate_toolchain_lock || exit 22
  validate_managed_paths "$state_dir" "$state_dir/base-complete" "$bin_dir" || {
    echo 'Managed bootstrap paths are unsafe.' >&2
    exit 24
  }
  fence_open_directory "$state_dir" state_fd
  fence_open_directory "$bin_dir" bin_fd
  state_anchor="/proc/self/fd/$state_fd"
  fence_require_directory "$state_dir" "$state_fd" 'base state directory'
  fence_require_directory "$bin_dir" "$bin_fd" 'base bin directory'
  bootstrap_test_pause before-base-directory-mutations
  bootstrap_exec_privileged "$sudo_bin" "$apt_get_bin" update
  bootstrap_exec_privileged "$sudo_bin" DEBIAN_FRONTEND=noninteractive "$apt_get_bin" install -y \
    apt-transport-https build-essential ca-certificates cifs-utils curl gawk git git-lfs gh gnupg jq mosh \
    openssh-client openssh-server pkg-config ripgrep rsync unzip zip
  if [[ "$bootstrap_root_mode" == 1 ]]; then
    bootstrap_exec_root_scoped "$bootstrap_git_bin" lfs install --system
  else
    bootstrap_exec_user_runtime "$bootstrap_git_bin" lfs install
  fi

  if [[ "$("$ps_bin" -p 1 -o comm=)" != "systemd" ]]; then
    echo 'PID 1 is not systemd. This bootstrap expects a normal Ubuntu VM boot.' >&2
    exit 21
  fi

  installed_pwsh="$(bootstrap_probe_powershell_version "$pwsh_bin" 2>/dev/null || true)"
  if [[ "$installed_pwsh" != "$POWERSHELL_VERSION" ]]; then
    package="$(/usr/bin/mktemp --suffix=.deb)"
    bootstrap_register_cleanup "$package"
    download_verified "$POWERSHELL_URL" "$POWERSHELL_SHA256" "$package"
    bootstrap_install_locked_deb "$package" "$POWERSHELL_SHA256" "$sudo_bin" "$apt_get_bin"
    /usr/bin/rm -f -- "$package"
  fi
  [[ "$(bootstrap_probe_powershell_version "$pwsh_bin")" == "$POWERSHELL_VERSION" ]] || {
    echo 'PowerShell version does not match lock.' >&2; exit 24;
  }

  bootstrap_exec_privileged "$sudo_bin" "$systemctl_bin" enable --now ssh
  install_locked_tailscale
  bootstrap_exec_privileged "$sudo_bin" "$systemctl_bin" enable --now tailscaled
  fence_require_directory "$state_dir" "$state_fd" 'base state directory'
  if [[ "$bootstrap_root_mode" == 1 ]]; then
    bootstrap_prepare_runtime_directories
    close_fence_fd "$state_fd"
    close_fence_fd "$bin_fd"
    bootstrap_run_as_runtime_phase base-user
    return
  fi
  : > "$state_anchor/base-complete"
  fence_require_directory "$state_dir" "$state_fd" 'base state directory'
  close_fence_fd "$state_fd"
  close_fence_fd "$bin_fd"
}

install_tools_transaction() {
  local state_fd
  local bin_fd
  local state_anchor
  local profile_dir_fd
  local profile_dir_anchor
  local node_fd
  local node_anchor
  local code_fd
  local manifest_tmp
  local ps_bin
  local rtk_existing_target
  local receipt_authority_manifest_path
  ps_bin="$(bootstrap_command_path ps)"
  profile_dir="$HOME/.config/herdr-workstation"
  node_dir="$HOME/.local/lib/node-v${NODE_VERSION}-linux-x64"
  validate_toolchain_lock || exit 22
  validate_cargo_roots || exit 24
  if [[ -L "$HOME/.cargo/bin/rtk" ]]; then
    rtk_existing_target="$(/usr/bin/realpath -e -- "$HOME/.cargo/bin/rtk" 2>/dev/null || true)"
    echo "A pre-existing canonical RTK symlink is not migrated: $HOME/.cargo/bin/rtk -> $rtk_existing_target. Inspect and remove it out of band before rerunning the tools phase." >&2
    exit 24
  fi
  validate_managed_paths \
    "$state_dir" "$state_dir/base-complete" "$state_dir/toolchain-manifest.txt" \
    "$bin_dir" "$profile_dir" "$profile_dir/profile.sh" "$node_dir" "$node_dir/bin" \
    "$HOME/.cargo" "$HOME/.cargo/bin" "$HOME/.cargo/bin/rtk" \
    "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.bash_login" || {
      echo 'Managed bootstrap paths are unsafe.' >&2
      exit 24
    }
  fence_open_directory "$state_dir" state_fd
  fence_open_directory "$bin_dir" bin_fd
  fence_open_directory "$profile_dir" profile_dir_fd
  fence_open_directory "$node_dir" node_fd
  fence_open_directory "$HOME/code" code_fd
  state_anchor="/proc/self/fd/$state_fd"
  profile_dir_anchor="/proc/self/fd/$profile_dir_fd"
  node_anchor="/proc/self/fd/$node_fd"
  fence_require_directory "$state_dir" "$state_fd" 'tools state directory'
  fence_require_directory "$bin_dir" "$bin_fd" 'tools bin directory'
  fence_require_directory "$profile_dir" "$profile_dir_fd" 'profile directory'
  fence_require_directory "$node_dir" "$node_fd" 'Node directory'
  bootstrap_test_pause before-tools-directory-mutations
  if [[ "$("$ps_bin" -p 1 -o comm=)" != "systemd" ]]; then
    echo 'systemd is required before the tools phase.' >&2
    exit 21
  fi

  rustup_path="$HOME/.cargo/bin/rustup"
  installed_rustup=''
  if [[ -x "$rustup_path" ]]; then
    installed_rustup="$("$rustup_path" --version 2>/dev/null | /usr/bin/gawk 'NR == 1 { print $1 " " $2 }' || true)"
  fi
  if [[ "$installed_rustup" != "rustup $RUSTUP_VERSION" ]]; then
    rustup_temp_dir="$(/usr/bin/mktemp -d /tmp/herdr-rustup.XXXXXX)"
    bootstrap_register_cleanup "$rustup_temp_dir"
    # rustup-init dispatches by argv[0], so its executable basename must remain exact.
    rustup_init="$rustup_temp_dir/rustup-init"
    download_verified "$RUSTUP_INIT_URL" "$RUSTUP_INIT_SHA256" "$rustup_init"
    /usr/bin/chmod 0700 -- "$rustup_init"
    "$rustup_init" -y --no-modify-path --profile minimal --default-toolchain "$RUST_TOOLCHAIN"
    /usr/bin/rm -rf -- "$rustup_temp_dir"
  fi
  # Never source executable shell code from the user's Cargo installation.
  # Rustup's canonical binaries are invoked by absolute path below, and the
  # managed Cargo roots are validated independently of user startup files.
  validate_cargo_roots || exit 24
  [[ -x "$rustup_path" ]] && attestation_canonical_cargo "$HOME" >/dev/null || {
    echo 'The locked rustup is present but the canonical ~/.cargo toolchain identities are not both available.' >&2
    exit 24
  }
  "$rustup_path" set auto-self-update disable
  [[ "$("$rustup_path" --version | /usr/bin/gawk 'NR == 1 { print $1 " " $2 }')" == "rustup $RUSTUP_VERSION" ]] || {
    echo "rustup version does not match lock after reinstall ($RUSTUP_VERSION)." >&2; exit 24;
  }
  "$rustup_path" toolchain install "$RUST_TOOLCHAIN" --profile minimal
  "$rustup_path" default "$RUST_TOOLCHAIN"
  [[ "$("$rustup_path" --version | /usr/bin/gawk 'NR == 1 { print $1 " " $2 }')" == "rustup $RUSTUP_VERSION" ]] || {
    echo "rustup version changed after toolchain installation ($RUSTUP_VERSION)." >&2; exit 24;
  }

  install_rtk_release || exit 24
  for executable in rustup cargo rustc; do
    executable_path="$HOME/.cargo/bin/$executable"
    [[ -x "$executable_path" ]] || {
      echo "Canonical Cargo toolchain executable is missing: $executable_path" >&2
      exit 24
    }
    fence_replace_link "$executable_path" "$bin_dir/$executable" "before-$executable-link-publish" "$bin_fd"
  done
  [[ -x "$HOME/.cargo/bin/rtk" ]] || {
    echo "RTK was not published to the expected canonical path '$HOME/.cargo/bin/rtk'." >&2
    exit 24
  }
  [[ -f "$HOME/.cargo/bin/rtk" && ! -L "$HOME/.cargo/bin/rtk" ]] || {
    echo 'Canonical RTK is not a regular executable.' >&2
    exit 24
  }
  fence_remove_managed_link "$HOME/.cargo/bin/rtk" "$bin_dir/rtk" before-rtk-alias-removal "$bin_fd"

  profile_script_tmp="$(mktemp)"
  bootstrap_register_cleanup "$profile_script_tmp"
  {
    printf '%s\n' '# Managed by herdr-workstation-bootstrap.'
    printf '%s\n' 'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac'
    printf '%s\n' 'case ":$PATH:" in *":$HOME/.cargo/bin:"*) ;; *) PATH="$HOME/.cargo/bin:$PATH" ;; esac'
    printf '%s\n' 'export PATH'
  } > "$profile_script_tmp"
  fence_replace_file "$profile_script_tmp" "$profile_dir/profile.sh" 0644 before-profile-script-publish "$profile_dir_fd"
  profile_script_tmp=''
  converge_profile_hook "$HOME/.profile"
  if [[ -e "$HOME/.bash_profile" ]]; then
    converge_profile_hook "$HOME/.bash_profile" true
  fi
  if [[ -e "$HOME/.bash_login" ]]; then
    converge_profile_hook "$HOME/.bash_login" true
  fi

  install_python_toolchain

  fence_require_directory "$node_dir" "$node_fd" 'Node directory'
  if [[ ! -x "$node_anchor/bin/node" ]]; then
    archive="$(mktemp --suffix=.tar.gz)"
    bootstrap_register_cleanup "$archive"
    download_verified "$NODE_URL" "$NODE_SHA256" "$archive"
    bootstrap_test_pause before-node-extract
    fence_require_directory "$node_dir" "$node_fd" 'Node directory'
    tar -xzf "$archive" -C "$node_anchor" --strip-components=1
    fence_require_directory "$node_dir" "$node_fd" 'Node directory'
    rm -f "$archive"
  fi
  for executable in node npm npx corepack; do
    executable_real="$(realpath -e -- "$node_anchor/bin/$executable" 2>/dev/null || true)"
    path_is_under "$executable_real" "$home_real" || { echo "Node executable escaped HOME: $executable" >&2; exit 24; }
    fence_replace_link "$executable_real" "$bin_dir/$executable" "before-$executable-link-publish" "$bin_fd"
  done
  # Keep the process PATH hermetic.  User-local tools are invoked below by
  # their validated absolute paths; no user-writable directory is prepended
  # globally.
  export PATH="$bootstrap_trusted_path"
  hash -r
  [[ "$("$node_anchor/bin/node" --version)" == "v$NODE_VERSION" ]] || { echo 'Node version does not match lock.' >&2; exit 24; }

  "$node_anchor/bin/node" "$node_anchor/bin/npm" install --global --save-exact --prefix "$node_anchor" \
    "@openai/codex@$CODEX_VERSION" \
    "@anthropic-ai/claude-code@$CLAUDE_VERSION" \
    "bun@$BUN_VERSION"
  for package_dir in '@openai/codex' '@anthropic-ai/claude-code' bun; do
    [[ -d "$node_anchor/lib/node_modules/$package_dir" ]] || {
      echo "npm did not install '$package_dir' under the pinned Node prefix '$node_dir'." >&2
      exit 24
    }
  done
  for executable in codex claude bun bunx; do
    executable_real="$(realpath -e -- "$node_anchor/bin/$executable" 2>/dev/null || true)"
    path_is_under "$executable_real" "$home_real" || { echo "Node executable escaped HOME: $executable" >&2; exit 24; }
    fence_replace_link "$executable_real" "$bin_dir/$executable" "before-$executable-link-publish" "$bin_fd"
  done

  herdr_temp="$(mktemp)"
  bootstrap_register_cleanup "$herdr_temp"
  download_verified "$HERDR_URL" "$HERDR_SHA256" "$herdr_temp"
  fence_replace_file "$herdr_temp" "$bin_dir/herdr" 0755 before-herdr-publish "$bin_fd"
  herdr_temp=''

  [[ "$("$node_anchor/bin/node" "$node_anchor/bin/codex" --version | /usr/bin/gawk '{ print $NF }')" == "$CODEX_VERSION" ]] || { echo 'Codex version does not match lock.' >&2; exit 24; }
  [[ "$("$node_anchor/bin/claude" --version | /usr/bin/gawk '{ print $1 }')" == "$CLAUDE_VERSION" ]] || { echo 'Claude version does not match lock.' >&2; exit 24; }
  [[ "$("$node_anchor/bin/bun" --version)" == "$BUN_VERSION" ]] || { echo 'Bun version does not match lock.' >&2; exit 24; }
  [[ "$("$bin_dir/herdr" --version | /usr/bin/gawk '{ print $NF }')" == "$HERDR_VERSION" ]] || { echo 'Herdr version does not match lock.' >&2; exit 24; }

  if [[ "${bootstrap_tools_prepare_only:-0}" == 1 ]]; then
    close_fence_fd "$state_fd"
    close_fence_fd "$bin_fd"
    close_fence_fd "$profile_dir_fd"
    close_fence_fd "$node_fd"
    close_fence_fd "$code_fd"
    return
  fi

  install_receipt_from_snapshots

  manifest="$state_dir/toolchain-manifest.txt"
  receipt_authority_manifest_path="$(bootstrap_receipt_authority_path)"
  [[ "$receipt_authority_manifest_path" == /* && -f "$receipt_authority_manifest_path" &&
    ! -L "$receipt_authority_manifest_path" ]] || {
      echo "Receipt authority handoff is missing its published authority: $receipt_authority_manifest_path" >&2
      exit 24
    }
  manifest_tmp="$(mktemp "$state_anchor/.toolchain-manifest.XXXXXX")"
  bootstrap_register_cleanup "$manifest_tmp"
  {
    printf 'receipt_format=%s\n' 'issue-961-toolchain-v2'
    printf 'lock_sha256=%s\n' "$(/usr/bin/sha256sum "$lock_file" | /usr/bin/gawk '{print $1}')"
    printf 'host_platform=%s\n' 'linux'
    printf 'host_architecture=%s\n' "$(/usr/bin/uname -m)"
    printf 'uv_path=%s\n' "$bin_dir/uv"
    printf 'python3.13_path=%s\n' "$bin_dir/python3.13"
    printf 'python3.13_kind=%s\n' 'regular-file'
    printf 'python3.13_sha256=%s\n' "$(/usr/bin/sha256sum "$bin_dir/python3.13" | /usr/bin/gawk '{print $1}')"
    printf 'python3.13_pyvenv_cfg=%s\n' "$HOME/.local/pyvenv.cfg"
    printf 'py_path=%s\n' "$bin_dir/py"
    printf 'rtk_path=%s\n' "$HOME/.cargo/bin/rtk"
    printf 'rtk_version=%s\n' "$("$HOME/.cargo/bin/rtk" --version 2>&1)"
    printf 'rtk_url=%s\n' "$RTK_URL"
    printf 'rtk_sha256=%s\n' "$RTK_SHA256"
    printf 'uv_version=%s\n' "$("$bin_dir/uv" --version)"
    printf 'uv_url=%s\n' "$UV_URL"
    printf 'uv_sha256=%s\n' "$UV_SHA256"
    printf 'python3.13_version=%s\n' "$("$bin_dir/python3.13" --version 2>&1)"
    printf 'py_3.13_version=%s\n' "$("$bin_dir/py" -3.13 --version 2>&1)"
    printf 'py_3.13_probe=%s\n' "$("$bin_dir/py" -3.13 -c 'import platform, sys; print(f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}|{platform.machine()}|{sys.platform}")')"
    printf 'uv_platform=%s\n' "$UV_PLATFORM"
    printf 'python_version=%s\n' "$PYTHON_VERSION"
    printf 'python_platform=%s\n' "$PYTHON_PLATFORM"
    printf 'python_release=%s\n' "$PYTHON_RELEASE"
    printf 'python_archive=%s\n' "$PYTHON_ARCHIVE"
    printf 'python_url=%s\n' "$PYTHON_URL"
    printf 'python_sha256=%s\n' "$PYTHON_SHA256"
    printf 'tailscale=%s\n' "$("$(bootstrap_command_path tailscale)" version | /usr/bin/head -n 1)"
    printf 'rustup=%s\n' "$("$HOME/.cargo/bin/rustup" --version | /usr/bin/head -n 1)"
    printf 'rustc=%s\n' "$("$HOME/.cargo/bin/rustc" --version)"
    printf 'node=%s\n' "$("$node_anchor/bin/node" --version)"
    printf 'npm=%s\n' "$("$node_anchor/bin/node" "$node_anchor/bin/npm" --version)"
    printf 'codex=%s\n' "$("$node_anchor/bin/node" "$node_anchor/bin/codex" --version)"
    printf 'claude=%s\n' "$("$node_anchor/bin/claude" --version)"
    printf 'bun=%s\n' "$("$node_anchor/bin/bun" --version)"
    printf 'herdr=%s\n' "$("$bin_dir/herdr" --version)"
    printf 'powershell=%s\n' "$("$(bootstrap_command_path pwsh)" -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')"
    printf 'receipt_authority_path=%s\n' "$receipt_authority_manifest_path"
    printf 'receipt_authority_sha256=%s\n' "$(/usr/bin/sha256sum -- "$receipt_authority_manifest_path" | /usr/bin/gawk '{print $1}')"
    bootstrap_query_apt_manifest
  } > "$manifest_tmp"
  fence_require_directory "$state_dir" "$state_fd" 'tools state directory'
  mv -T -- "$manifest_tmp" "$state_anchor/toolchain-manifest.txt"
  manifest_tmp=''
  fence_require_directory "$state_dir" "$state_fd" 'tools state directory'

  fence_require_directory "$HOME/code" "$code_fd" 'code directory'
  fence_require_directory "$state_dir" "$state_fd" 'tools state directory'
  : > "$state_anchor/tools-complete"
  fence_require_directory "$state_dir" "$state_fd" 'tools state directory'
  close_fence_fd "$state_fd"
  close_fence_fd "$bin_fd"
  close_fence_fd "$profile_dir_fd"
  close_fence_fd "$node_fd"
  close_fence_fd "$code_fd"
  echo "Tool installation complete. Resolved manifest: $manifest"
  echo "The tools are available immediately through $bin_dir. The managed .profile hook, plus any pre-existing .bash_profile or .bash_login chain, makes them available in new Bash login shells."
  echo 'Authentication, Tailscale login, SMB credentials, and Herdr integration validation remain manual.'
}

install_tools_finalize() {
  local state_fd
  local bin_fd
  local state_anchor
  local node_fd
  local node_anchor
  local code_fd
  local manifest_tmp
  local manifest
  local receipt_authority_manifest_path
  profile_dir="$HOME/.config/herdr-workstation"
  node_dir="$HOME/.local/lib/node-v${NODE_VERSION}-linux-x64"
  validate_toolchain_lock || exit 22
  validate_cargo_roots || exit 24
  validate_managed_paths \
    "$state_dir" "$state_dir/base-complete" "$state_dir/toolchain-manifest.txt" \
    "$bin_dir" "$profile_dir" "$profile_dir/profile.sh" "$node_dir" "$node_dir/bin" \
    "$HOME/.cargo" "$HOME/.cargo/bin" "$HOME/.cargo/bin/rtk" \
    "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.bash_login" || {
      echo 'Managed bootstrap paths are unsafe.' >&2
      exit 24
    }
  fence_open_directory "$state_dir" state_fd
  fence_open_directory "$bin_dir" bin_fd
  fence_open_directory "$node_dir" node_fd
  fence_open_directory "$HOME/code" code_fd
  state_anchor="/proc/self/fd/$state_fd"
  node_anchor="/proc/self/fd/$node_fd"
  fence_require_directory "$state_dir" "$state_fd" 'tools state directory'
  fence_require_directory "$bin_dir" "$bin_fd" 'tools bin directory'
  fence_require_directory "$node_dir" "$node_fd" 'Node directory'

  manifest="$state_dir/toolchain-manifest.txt"
  receipt_authority_manifest_path="$(bootstrap_receipt_authority_path)"
  [[ "$receipt_authority_manifest_path" == /* && -f "$receipt_authority_manifest_path" &&
    ! -L "$receipt_authority_manifest_path" ]] || {
      echo "Receipt authority handoff is missing its published authority: $receipt_authority_manifest_path" >&2
      exit 24
    }
  manifest_tmp="$(mktemp "$state_anchor/.toolchain-manifest.XXXXXX")"
  bootstrap_register_cleanup "$manifest_tmp"
  {
    printf 'receipt_format=%s\n' 'issue-961-toolchain-v2'
    printf 'lock_sha256=%s\n' "$(/usr/bin/sha256sum "$lock_file" | /usr/bin/gawk '{print $1}')"
    printf 'host_platform=%s\n' 'linux'
    printf 'host_architecture=%s\n' "$(/usr/bin/uname -m)"
    printf 'uv_path=%s\n' "$bin_dir/uv"
    printf 'python3.13_path=%s\n' "$bin_dir/python3.13"
    printf 'python3.13_kind=%s\n' 'regular-file'
    printf 'python3.13_sha256=%s\n' "$(/usr/bin/sha256sum "$bin_dir/python3.13" | /usr/bin/gawk '{print $1}')"
    printf 'python3.13_pyvenv_cfg=%s\n' "$HOME/.local/pyvenv.cfg"
    printf 'py_path=%s\n' "$bin_dir/py"
    printf 'rtk_path=%s\n' "$HOME/.cargo/bin/rtk"
    printf 'rtk_version=%s\n' "$("$HOME/.cargo/bin/rtk" --version 2>&1)"
    printf 'rtk_url=%s\n' "$RTK_URL"
    printf 'rtk_sha256=%s\n' "$RTK_SHA256"
    printf 'uv_version=%s\n' "$("$bin_dir/uv" --version)"
    printf 'uv_url=%s\n' "$UV_URL"
    printf 'uv_sha256=%s\n' "$UV_SHA256"
    printf 'python3.13_version=%s\n' "$("$bin_dir/python3.13" --version 2>&1)"
    printf 'py_3.13_version=%s\n' "$("$bin_dir/py" -3.13 --version 2>&1)"
    printf 'py_3.13_probe=%s\n' "$("$bin_dir/py" -3.13 -c 'import platform, sys; print(f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}|{platform.machine()}|{sys.platform}")')"
    printf 'uv_platform=%s\n' "$UV_PLATFORM"
    printf 'python_version=%s\n' "$PYTHON_VERSION"
    printf 'python_platform=%s\n' "$PYTHON_PLATFORM"
    printf 'python_release=%s\n' "$PYTHON_RELEASE"
    printf 'python_archive=%s\n' "$PYTHON_ARCHIVE"
    printf 'python_url=%s\n' "$PYTHON_URL"
    printf 'python_sha256=%s\n' "$PYTHON_SHA256"
    printf 'tailscale=%s\n' "$("$(bootstrap_command_path tailscale)" version | /usr/bin/head -n 1)"
    printf 'rustup=%s\n' "$("$HOME/.cargo/bin/rustup" --version | /usr/bin/head -n 1)"
    printf 'rustc=%s\n' "$("$HOME/.cargo/bin/rustc" --version)"
    printf 'node=%s\n' "$("$node_anchor/bin/node" --version)"
    printf 'npm=%s\n' "$("$node_anchor/bin/node" "$node_anchor/bin/npm" --version)"
    printf 'codex=%s\n' "$("$node_anchor/bin/node" "$node_anchor/bin/codex" --version)"
    printf 'claude=%s\n' "$("$node_anchor/bin/claude" --version)"
    printf 'bun=%s\n' "$("$node_anchor/bin/bun" --version)"
    printf 'herdr=%s\n' "$("$bin_dir/herdr" --version)"
    printf 'powershell=%s\n' "$("$(bootstrap_command_path pwsh)" -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')"
    printf 'receipt_authority_path=%s\n' "$receipt_authority_manifest_path"
    printf 'receipt_authority_sha256=%s\n' "$(/usr/bin/sha256sum -- "$receipt_authority_manifest_path" | /usr/bin/gawk '{print $1}')"
    bootstrap_query_apt_manifest
  } > "$manifest_tmp"
  fence_require_directory "$state_dir" "$state_fd" 'tools state directory'
  mv -T -- "$manifest_tmp" "$state_anchor/toolchain-manifest.txt"
  manifest_tmp=''
  fence_require_directory "$state_dir" "$state_fd" 'tools state directory'
  fence_require_directory "$HOME/code" "$code_fd" 'code directory'
  fence_require_directory "$state_dir" "$state_fd" 'tools state directory'
  : > "$state_anchor/tools-complete"
  fence_require_directory "$state_dir" "$state_fd" 'tools state directory'
  close_fence_fd "$state_fd"
  close_fence_fd "$bin_fd"
  close_fence_fd "$node_fd"
  close_fence_fd "$code_fd"
  echo "Tool installation complete. Resolved manifest: $manifest"
  echo "The tools are available immediately through $bin_dir. The managed .profile hook, plus any pre-existing .bash_profile or .bash_login chain, makes them available in new Bash login shells."
  echo 'Authentication, Tailscale login, SMB credentials, and Herdr integration validation remain manual.'
}

install_tools() {
  if [[ "$bootstrap_root_mode" == 1 ]]; then
    bootstrap_run_as_runtime_phase tools-prepare
    install_receipt_from_snapshots
    bootstrap_run_as_runtime_phase tools-finalize
    return
  fi
  install_tools_transaction
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "$phase" in
    base) install_base ;;
    validate-lock) validate_toolchain_lock; echo 'Ubuntu toolchain lock validation passed.' ;;
    tools) install_tools ;;
    all) install_base; install_tools ;;
    base-user) [[ "$bootstrap_root_mode" == 0 ]] || { echo 'base-user is runtime-only.' >&2; exit 24; }; install_base_user ;;
    tools-prepare) [[ "$bootstrap_root_mode" == 0 ]] || { echo 'tools-prepare is runtime-only.' >&2; exit 24; }; bootstrap_tools_prepare_only=1; install_tools_transaction ;;
    tools-finalize) [[ "$bootstrap_root_mode" == 0 ]] || { echo 'tools-finalize is runtime-only.' >&2; exit 24; }; install_tools_finalize ;;
    *) echo "Unsupported phase: $phase" >&2; exit 2 ;;
  esac
fi
