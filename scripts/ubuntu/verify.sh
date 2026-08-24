#!/usr/bin/env -S -i BASH_ENV= ENV= CDPATH= PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C TZ=UTC /usr/bin/bash
set -euo pipefail
readonly verify_trusted_path='/usr/sbin:/usr/bin:/sbin:/bin'
readonly verify_getent_bin='/usr/bin/getent'
readonly verify_id_bin='/usr/bin/id'
readonly verify_realpath_bin='/usr/bin/realpath'
readonly verify_stat_bin='/usr/bin/stat'
readonly verify_find_bin='/usr/bin/find'
readonly verify_env_bin='/usr/bin/env'
readonly verify_git_bin='/usr/bin/git'
export PATH="$verify_trusted_path"
verify_reject_dangerous_environment() {
  local verify_env_name
  while IFS= read -r verify_env_name; do
    case "$verify_env_name" in
      BASH_ENV|ENV|CDPATH)
        [[ -z "${!verify_env_name:-}" ]] || {
          echo "verify trust prelude: dangerous caller environment is not permitted: $verify_env_name" >&2
          exit 24
        }
        ;;
      GIT_DIR|GIT_WORK_TREE|GIT_INDEX_FILE|GIT_OBJECT_DIRECTORY|GIT_ALTERNATE_OBJECT_DIRECTORIES|GIT_COMMON_DIR|GIT_CONFIG_*)
        echo "verify trust prelude: caller Git environment override is not permitted: $verify_env_name" >&2
        exit 24
        ;;
    esac
  done < <(compgen -e)
}
verify_reject_dangerous_environment
verify_script_path="$($verify_realpath_bin -e -- "${BASH_SOURCE[0]}" 2>/dev/null || true)"
verify_script_dir="${verify_script_path%/*}"
verify_repo_root="$($verify_realpath_bin -e -- "$verify_script_dir/../.." 2>/dev/null || true)"
verify_capability_helper="$verify_repo_root/scripts/ubuntu/launcher-capability.sh"
[[ "$verify_script_path" == "$verify_repo_root/scripts/ubuntu/verify.sh" &&
  -f "$verify_capability_helper" && ! -L "$verify_capability_helper" ]] || exit 24
# shellcheck disable=SC1090
launcher_capability_entry_source="$verify_script_path"
source "$verify_capability_helper" verify
launcher_capability_lifetime
if [[ -z "${HOME:-}" ]]; then
  verify_launch_home="$($verify_getent_bin passwd "$($verify_id_bin -u)" 2>/dev/null | /usr/bin/gawk -F: 'NF >= 6 { print $6; found++ } END { exit(found == 1 ? 0 : 1) }' || true)"
  [[ "$verify_launch_home" == /* && "$verify_launch_home" != '/' ]] || exit 24
  export HOME="$verify_launch_home"
fi
while IFS= read -r verify_env_name; do
  case "$verify_env_name" in
    GIT_*)
      echo "verify trust prelude: caller Git environment override is not permitted: $verify_env_name" >&2
      exit 24
      ;;
  esac
done < <(compgen -e)
repo_root="$launcher_capability_repo_root"

declare -a verify_git_bound_paths=()
declare -A verify_git_bound_identities=()
verify_git_owner_uid="$launcher_capability_owner_uid"
verify_git_owner_gid="$launcher_capability_owner_gid"
[[ "$verify_git_owner_uid" =~ ^[0-9]+$ && "$verify_git_owner_gid" =~ ^[0-9]+$ ]] || exit 24
verify_bind_git_path() {
  local path="$1" owner group mode identity
  [[ -e "$path" && ! -L "$path" ]] || return 1
  owner="$($verify_stat_bin -c '%u' -- "$path" 2>/dev/null || true)"
  group="$($verify_stat_bin -c '%g' -- "$path" 2>/dev/null || true)"
  mode="$($verify_stat_bin -c '%a' -- "$path" 2>/dev/null || true)"
  [[ "$owner" == "$verify_git_owner_uid" && "$group" == "$verify_git_owner_gid" && "$mode" =~ ^[0-7]+$ && $((8#$mode & 022)) == 0 ]] || return 1
  identity="$($verify_stat_bin -Lc '%d:%i:%u:%g:%a:%F' -- "$path" 2>/dev/null || true)"
  [[ -n "$identity" ]] || return 1
  if [[ -z "${verify_git_bound_identities[$path]+x}" ]]; then
    verify_git_bound_paths+=("$path")
  fi
  verify_git_bound_identities["$path"]="$identity"
}
verify_bind_optional_git_path() {
  [[ -e "$1" ]] || return 0
  verify_bind_git_path "$1"
}
verify_assert_git_lifetime() {
  local path owner group mode identity
  for path in "${verify_git_bound_paths[@]}"; do
    [[ -e "$path" && ! -L "$path" ]] || return 1
    owner="$($verify_stat_bin -c '%u' -- "$path" 2>/dev/null || true)"
    group="$($verify_stat_bin -c '%g' -- "$path" 2>/dev/null || true)"
    mode="$($verify_stat_bin -c '%a' -- "$path" 2>/dev/null || true)"
    identity="$($verify_stat_bin -Lc '%d:%i:%u:%g:%a:%F' -- "$path" 2>/dev/null || true)"
    [[ "$owner" == "$verify_git_owner_uid" && "$group" == "$verify_git_owner_gid" && "$mode" =~ ^[0-7]+$ && $((8#$mode & 022)) == 0 && \
      "$identity" == "${verify_git_bound_identities[$path]:-}" ]] || return 1
  done
}
verify_validate_git_layout() {
  local metadata="$repo_root/.git" pointer pointer_path commondir_spec record='' record_pointer other_record other_pointer
  [[ -e "$metadata" && ! -L "$metadata" && ( -d "$metadata" || -f "$metadata" ) ]] || return 1
  if [[ -d "$metadata" ]]; then
    verify_git_dir="$metadata"
    verify_common_git_dir="$metadata"
  else
    pointer="$(< "$metadata")"
    [[ "$pointer" != *$'\n'* && "$pointer" != *$'\r'* && "$pointer" == gitdir:\ /* ]] || return 1
    pointer_path="${pointer#gitdir: }"
    verify_git_dir="$($verify_realpath_bin -e -- "$pointer_path" 2>/dev/null || true)"
    [[ -n "$verify_git_dir" && "$pointer" == "gitdir: $verify_git_dir" && -d "$verify_git_dir" && ! -L "$verify_git_dir" ]] || return 1
    [[ -f "$verify_git_dir/commondir" && ! -L "$verify_git_dir/commondir" ]] || return 1
    commondir_spec="$(< "$verify_git_dir/commondir")"
    [[ "$commondir_spec" == ../.. ]] || return 1
    verify_common_git_dir="$($verify_realpath_bin -e -- "$verify_git_dir/$commondir_spec" 2>/dev/null || true)"
    record="$verify_common_git_dir/worktrees/${verify_git_dir##*/}"
    [[ -d "$verify_common_git_dir/worktrees" && ! -L "$verify_common_git_dir/worktrees" && \
      "$($verify_realpath_bin -e -- "$record" 2>/dev/null || true)" == "$verify_git_dir" && \
      -f "$verify_git_dir/gitdir" && ! -L "$verify_git_dir/gitdir" ]] || return 1
    record_pointer="$(< "$verify_git_dir/gitdir")"
    [[ "$record_pointer" != *$'\n'* && "$record_pointer" != *$'\r'* && \
      "$($verify_realpath_bin -e -- "$record_pointer" 2>/dev/null || true)" == "$metadata" ]] || return 1
    while IFS= read -r -d '' other_record; do
      [[ "${other_record%/gitdir}" == "$verify_git_dir" ]] && continue
      other_pointer="$(< "$other_record")"
      [[ "$other_pointer" != *$'\n'* && "$other_pointer" != *$'\r'* && \
        "$($verify_realpath_bin -e -- "$other_pointer" 2>/dev/null || true)" != "$metadata" ]] || return 1
    done < <("$verify_find_bin" -P "$verify_common_git_dir/worktrees" -mindepth 2 -maxdepth 2 -type f -name gitdir -print0 2>/dev/null)
  fi
  [[ -d "$verify_common_git_dir" && ! -L "$verify_common_git_dir" && \
    -d "$verify_common_git_dir/objects" && ! -L "$verify_common_git_dir/objects" && \
    -d "$verify_common_git_dir/refs" && ! -L "$verify_common_git_dir/refs" && \
    -f "$verify_common_git_dir/config" && ! -L "$verify_common_git_dir/config" && \
    -f "$verify_git_dir/index" && ! -L "$verify_git_dir/index" ]] || return 1
  verify_bind_git_path "$repo_root" || return 1
  verify_bind_git_path "$metadata" || return 1
  for verify_git_binding_path in "$verify_git_dir" "$verify_common_git_dir" "$verify_common_git_dir/objects" \
    "$verify_common_git_dir/refs" "$verify_common_git_dir/config" "$verify_git_dir/index"; do
    verify_bind_git_path "$verify_git_binding_path" || return 1
  done
  for verify_git_binding_path in "$verify_git_dir/commondir" "$verify_git_dir/gitdir" \
    "$verify_common_git_dir/worktrees" "$verify_git_dir/HEAD" "$verify_common_git_dir/HEAD" \
    "$verify_common_git_dir/packed-refs"; do
    verify_bind_optional_git_path "$verify_git_binding_path" || return 1
  done
  if [[ -n "$record" ]]; then
    verify_bind_git_path "$record" || return 1
    verify_bind_git_path "$record/gitdir" || return 1
  fi
}
verify_trust_git() {
  local status
  verify_assert_git_lifetime || return 70
  if "$verify_env_bin" -i HOME=/nonexistent PATH="$verify_trusted_path" LC_ALL=C TZ=UTC \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_COUNT=0 \
    GIT_OPTIONAL_LOCKS=0 \
    "$verify_git_bin" --no-replace-objects -C "$repo_root" --git-dir="$verify_git_dir" --work-tree=. \
    -c core.attributesfile=/dev/null -c core.excludesfile=/dev/null -c core.hooksPath=/dev/null \
    -c core.filemode=true -c core.ignoreCase=false "$@"; then
    status=0
  else
    status=$?
  fi
  verify_assert_git_lifetime || return 70
  return "$status"
}

verify_system_command_path() {
  case "$1" in
    bash) printf '%s\n' /usr/bin/bash ;;
    git) printf '%s\n' /usr/bin/git ;;
    gh) printf '%s\n' /usr/bin/gh ;;
    ssh) printf '%s\n' /usr/bin/ssh ;;
    sshd) printf '%s\n' /usr/sbin/sshd ;;
    mosh) printf '%s\n' /usr/bin/mosh ;;
    tailscale) printf '%s\n' /usr/bin/tailscale ;;
    pwsh)
      if [[ -x /opt/microsoft/powershell/7/pwsh ]]; then
        printf '%s\n' /opt/microsoft/powershell/7/pwsh
      else
        printf '%s\n' /usr/bin/pwsh
      fi
      ;;
    mount.cifs) printf '%s\n' /usr/sbin/mount.cifs ;;
    systemctl) printf '%s\n' /usr/bin/systemctl ;;
    dpkg-query) printf '%s\n' /usr/bin/dpkg-query ;;
    uname|grep|ps) printf '/usr/bin/%s\n' "$1" ;;
    *) return 1 ;;
  esac
}

verify_assert_system_binary() {
  local path="$1"
  local resolved uid mode
  [[ -f "$path" && ! -L "$path" && -x "$path" ]] || return 1
  resolved="$(/usr/bin/realpath -e -- "$path" 2>/dev/null || true)"
  [[ "$resolved" == "$path" ]] || return 1
  uid="$(/usr/bin/stat -c '%u' -- "$path" 2>/dev/null || true)"
  mode="$(/usr/bin/stat -c '%a' -- "$path" 2>/dev/null || true)"
  [[ "$uid" == 0 && "$mode" =~ ^[0-7]+$ && $((8#$mode & 022)) == 0 ]]
}

verify_host_command_path() {
  local path
  path="$(verify_system_command_path "$1" 2>/dev/null || true)"
  [[ -n "$path" ]] || return 1
  verify_assert_system_binary "$path" || return 1
  printf '%s\n' "$path"
}

verify_home_real=''
verify_resolve_command() {
  local name="$1"
  local candidate
  local resolved
  if candidate="$(verify_system_command_path "$name" 2>/dev/null)"; then
    verify_assert_system_binary "$candidate" || return 1
    printf '%s\n' "$candidate"
    return 0
  fi
  case "$name" in
    rustup|rustc|cargo|rtk|codex|claude|herdr|bun|uv|python3.13|py|node|npm) ;;
    *) return 1 ;;
  esac
  for candidate in "$HOME/.local/bin/$name" "$HOME/.cargo/bin/$name"; do
    if [[ -e "$candidate" || -L "$candidate" ]]; then
      resolved="$(/usr/bin/realpath -e -- "$candidate" 2>/dev/null || true)"
      [[ -n "$verify_home_real" && -f "$resolved" && -x "$resolved" ]] || return 1
      if path_is_under "$resolved" "$HOME/.local/bin" || path_is_under "$resolved" "$HOME/.cargo" || path_is_under "$resolved" "$HOME/.local/lib/node-v$NODE_VERSION-linux-x64"; then
        printf '%s\n' "$candidate"
        return 0
      fi
      return 1
    fi
  done
  return 1
}

verify_run_command() {
  local name="$1"
  local command_path="$2"
  shift 2
  case "$name" in
    npm|codex)
      local node_path
      node_path="$(verify_resolve_command node 2>/dev/null || true)"
      [[ -n "$node_path" ]] || return 1
      "$node_path" "$command_path" "$@"
      ;;
    *)
      "$command_path" "$@"
      ;;
  esac
}

verify_main() {
verify_validate_git_layout || { echo 'Verification repository metadata is not stable or owner-bound.' >&2; exit 24; }
lock_file="$repo_root/config/ubuntu-toolchain.lock"
[[ -f "$lock_file" ]] || { echo "Missing toolchain lock: $lock_file" >&2; exit 22; }
# Bind the bootstrap library to the same committed source object before any
# of its top-level code is sourced.  The live sibling is never executable in
# this verification path.
verify_bootstrap_script="$repo_root/scripts/ubuntu/bootstrap.sh"
verify_bootstrap_commit="$(verify_trust_git rev-parse --verify HEAD^{commit} 2>/dev/null)" || exit 24
[[ "$verify_bootstrap_commit" == "$launcher_capability_policy_commit" ]] || exit 24
verify_bootstrap_oid="$(verify_trust_git rev-parse --verify "$verify_bootstrap_commit:scripts/ubuntu/bootstrap.sh" 2>/dev/null)" || exit 24
[[ "$verify_bootstrap_commit" =~ ^[0-9a-f]{40}$ && "$verify_bootstrap_oid" =~ ^[0-9a-f]{40}$ ]] || {
  echo 'Committed bootstrap object is unavailable.' >&2
  exit 24
}
verify_bootstrap_materialized_oid="$(verify_trust_git hash-object --no-filters --stdin < "$verify_bootstrap_script")"
[[ "$verify_bootstrap_materialized_oid" == "$verify_bootstrap_oid" ]] || {
  echo 'Materialized bootstrap bytes differ from the committed object.' >&2
  exit 24
}
# shellcheck disable=SC1090
source "$verify_bootstrap_script"
launcher_capability_lifetime
# Keep the process PATH system-only.  Managed user tools are resolved below
# through explicitly validated absolute paths instead of a global user-writable
# PATH prefix.
export PATH="$verify_trusted_path"
hash -r
validate_toolchain_lock || { echo 'Toolchain lock validation failed.' >&2; exit 22; }

verify_home_real="$(/usr/bin/realpath -e -- "$HOME" 2>/dev/null || true)"

failures=0
check_command() {
  local name="$1"
  local command_path
  if command_path="$(verify_resolve_command "$name" 2>/dev/null)"; then
    printf 'PASS command %-10s %s\n' "$name" "$command_path"
  else
    printf 'FAIL command %-10s missing\n' "$name"
    failures=$((failures + 1))
  fi
}

verify_uname_path="$(verify_host_command_path uname)" || { echo 'Host uname is unavailable.' >&2; exit 22; }
verify_grep_path="$(verify_host_command_path grep)" || { echo 'Host grep is unavailable.' >&2; exit 22; }
verify_ps_path="$(verify_host_command_path ps)" || { echo 'Host ps is unavailable.' >&2; exit 22; }
printf 'Kernel: %s\n' "$("$verify_uname_path" -r)"
if "$verify_grep_path" -qi microsoft /proc/sys/kernel/osrelease; then
  echo 'FAIL environment is WSL; the primary architecture requires an Ubuntu Hyper-V VM'
  failures=$((failures + 1))
else
  echo 'PASS environment is a standalone Linux VM'
fi
printf 'PID 1: %s\n' "$("$verify_ps_path" -p 1 -o comm=)"
[[ "$("$verify_ps_path" -p 1 -o comm=)" == "systemd" ]] || failures=$((failures + 1))

for command in git gh ssh sshd mosh tailscale rustup cargo rtk codex claude herdr bun pwsh mount.cifs uv python3.13 py; do
  check_command "$command"
done

check_exact_version() {
  local name="$1"
  local expected="$2"
  local actual
  local command_path
  if ! command_path="$(verify_resolve_command "$name" 2>/dev/null)"; then return; fi
  if actual="$(verify_run_command "$name" "$command_path" --version 2>&1)" && [[ "$actual" == "$expected" ]]; then
    printf 'PASS exact version %-10s %s\n' "$name" "$actual"
  else
    printf 'FAIL exact version %-10s expected %s (got %s)\n' "$name" "$expected" "${actual:-unavailable}"
    failures=$((failures + 1))
  fi
}

check_exact_version uv "uv $UV_VERSION ($UV_PLATFORM)"
check_exact_version python3.13 "Python $PYTHON_VERSION"

if uv_path="$(verify_resolve_command uv 2>/dev/null)"; then
  [[ "$uv_path" == "$HOME/.local/bin/uv" ]] || { echo "FAIL uv is not managed: $uv_path"; failures=$((failures + 1)); }
fi
if python_path="$(verify_resolve_command python3.13 2>/dev/null)"; then
  [[ "$python_path" == "$HOME/.local/bin/python3.13" ]] || { echo "FAIL python3.13 is not managed: $python_path"; failures=$((failures + 1)); }
fi
if py_path="$(verify_resolve_command py 2>/dev/null)"; then
  [[ "$py_path" == "$HOME/.local/bin/py" ]] || { echo "FAIL py is not managed: $py_path"; failures=$((failures + 1)); }
  if py_probe="$("$py_path" -3.13 -c 'import platform, sys; print(f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}|{platform.machine()}|{sys.platform}")' 2>&1)" && [[ "$py_probe" == "$PYTHON_VERSION|x86_64|linux" ]]; then
    echo "PASS py -3.13 selects $py_probe"
  else
    echo "FAIL py -3.13 selected '${py_probe:-unavailable}'"
    failures=$((failures + 1))
  fi
  if "$py_path" --list >/dev/null 2>&1; then
    echo 'FAIL py accepted unsupported --list option'
    failures=$((failures + 1))
  else
    py_status=$?
    if [[ "$py_status" -eq 2 ]]; then
      echo 'PASS py rejects unsupported --list option'
    else
      echo "FAIL py rejected --list with unexpected status $py_status"
      failures=$((failures + 1))
    fi
  fi
fi

home_real="$verify_home_real"
check_managed_command_target() {
  local name="$1"
  local expected_path="$2"
  local actual_path
  local resolved_path
  if ! actual_path="$(verify_resolve_command "$name" 2>/dev/null)"; then
    echo "FAIL managed target $name missing (expected $expected_path)"
    failures=$((failures + 1))
    return 1
  fi
  if [[ "$actual_path" != "$expected_path" ]]; then
    echo "FAIL managed target $name expected $expected_path (got $actual_path)"
    failures=$((failures + 1))
    return 1
  fi
  resolved_path="$(/usr/bin/realpath -e -- "$expected_path" 2>/dev/null || true)"
  if path_is_under "$resolved_path" "$home_real"; then
    echo "PASS managed target $name $resolved_path"
  else
    echo "FAIL managed target $name resolves outside HOME: $resolved_path"
    failures=$((failures + 1))
    return 1
  fi
}
check_managed_node_command_target() {
  local name="$1"
  local expected_path="$HOME/.local/bin/$name"
  local node_root="$HOME/.local/lib/node-v${NODE_VERSION}-linux-x64"
  local resolved_path
  if ! check_managed_command_target "$name" "$expected_path"; then
    return 0
  fi
  resolved_path="$(/usr/bin/realpath -e -- "$expected_path" 2>/dev/null || true)"
  if path_is_under "$resolved_path" "$node_root"; then
    echo "PASS locked Node target $name $resolved_path"
  else
    echo "FAIL locked Node target $name resolves outside Node prefix: $resolved_path"
    failures=$((failures + 1))
  fi
}
check_managed_command_target uv "$HOME/.local/bin/uv" || :
check_managed_command_target python3.13 "$HOME/.local/bin/python3.13" || :
check_managed_command_target py "$HOME/.local/bin/py" || :
for managed_tool in rustup rustc herdr; do
  check_managed_command_target "$managed_tool" "$HOME/.local/bin/$managed_tool" || :
done
check_managed_command_target rtk "$HOME/.cargo/bin/rtk" || :
for managed_tool in node npm codex claude bun; do
  check_managed_node_command_target "$managed_tool"
done

toolchain_receipt="$HOME/.local/state/herdr-workstation-bootstrap/toolchain-manifest.txt"
lock_sha256="$(/usr/bin/sha256sum -- "$lock_file" | /usr/bin/gawk '{print $1}')"

record_receipt_command() {
  local key="$1"
  shift
  local command_name="$1"
  shift
  local command_path
  local output
  command_path="$(verify_resolve_command "$command_name" 2>/dev/null || true)"
  if [[ -z "$command_path" ]]; then
    echo "FAIL receipt runtime probe $key"
    receipt_failures=$((receipt_failures + 1))
    return 1
  fi
  if ! output="$(verify_run_command "$command_name" "$command_path" "$@" 2>&1)"; then
    echo "FAIL receipt runtime probe $key"
    receipt_failures=$((receipt_failures + 1))
    return 1
  fi
  if [[ -z "$output" || "$output" == *$'\n'* ]]; then
    echo "FAIL receipt runtime probe malformed $key"
    receipt_failures=$((receipt_failures + 1))
    return 1
  fi
  expected_by_key["$key"]="$output"
}

record_receipt_first_line() {
  local key="$1"
  shift
  local command_name="$1"
  shift
  local command_path
  local output
  command_path="$(verify_resolve_command "$command_name" 2>/dev/null || true)"
  if [[ -z "$command_path" ]]; then
    echo "FAIL receipt runtime probe $key"
    receipt_failures=$((receipt_failures + 1))
    return 1
  fi
  if ! output="$(verify_run_command "$command_name" "$command_path" "$@" 2>&1)"; then
    echo "FAIL receipt runtime probe $key"
    receipt_failures=$((receipt_failures + 1))
    return 1
  fi
  output="${output%%$'\n'*}"
  if [[ -z "$output" || "$output" == *$'\n'* ]]; then
    echo "FAIL receipt runtime probe malformed $key"
    receipt_failures=$((receipt_failures + 1))
    return 1
  fi
  expected_by_key["$key"]="$output"
}

read_receipt_pyvenv_value() {
  local config_path="$1"
  local key="$2"
  /usr/bin/gawk -v key="$key" '
    {
      eq = index($0, "=")
      if (eq == 0) {
        lhs = $0
        sub(/^[[:space:]]+/, "", lhs)
        sub(/[[:space:]]+$/, "", lhs)
        if (lhs == key) count++
        next
      }
      lhs = substr($0, 1, eq - 1)
      sub(/^[[:space:]]+/, "", lhs)
      sub(/[[:space:]]+$/, "", lhs)
      if (lhs != key) next
      value = substr($0, eq + 1)
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      result = value
      count++
    }
    END { if (count == 1) print result; else exit 1 }
  ' "$config_path"
}

record_receipt_python_evidence() {
  local launcher="$HOME/.local/bin/python3.13"
  local pyvenv_config="$HOME/.local/pyvenv.cfg"
  local runtime_root="$HOME/.local/lib/herdr-workstation/python/$PYTHON_VERSION-$PYTHON_RELEASE-$PYTHON_PLATFORM"
  local digest
  local venv_home
  local venv_site
  local venv_version
  if [[ ! -f "$launcher" || -L "$launcher" ]]; then
    echo 'FAIL receipt evidence python3.13 is not a regular file'
    receipt_failures=$((receipt_failures + 1))
    return 1
  fi
  digest="$(/usr/bin/sha256sum -- "$launcher" 2>/dev/null | /usr/bin/gawk '{print $1}' || true)"
  if [[ ! "$digest" =~ ^[0-9a-f]{64}$ ]]; then
    echo 'FAIL receipt evidence python3.13 digest'
    receipt_failures=$((receipt_failures + 1))
    return 1
  fi
  if [[ ! -f "$pyvenv_config" || -L "$pyvenv_config" ]]; then
    echo 'FAIL receipt evidence pyvenv.cfg is not a regular file'
    receipt_failures=$((receipt_failures + 1))
    return 1
  fi
  venv_home="$(read_receipt_pyvenv_value "$pyvenv_config" home 2>/dev/null || true)"
  venv_site="$(read_receipt_pyvenv_value "$pyvenv_config" include-system-site-packages 2>/dev/null || true)"
  venv_version="$(read_receipt_pyvenv_value "$pyvenv_config" version 2>/dev/null || true)"
  if [[ "$venv_home" != "$runtime_root" || "$venv_site" != false || "$venv_version" != "$PYTHON_VERSION" ]]; then
    echo 'FAIL receipt evidence pyvenv.cfg contract'
    receipt_failures=$((receipt_failures + 1))
    return 1
  fi
  expected_by_key[python3.13_kind]='regular-file'
  expected_by_key[python3.13_sha256]="$digest"
  expected_by_key[python3.13_pyvenv_cfg]="$pyvenv_config"
}

record_receipt_authority_evidence() {
  local authority_path
  local digest
  authority_path="$(bootstrap_receipt_authority_path 2>/dev/null || true)"
  if [[ "$authority_path" != /* || ! -f "$authority_path" || -L "$authority_path" ]]; then
    echo 'FAIL receipt evidence receipt authority is not a published regular file'
    receipt_failures=$((receipt_failures + 1))
    return 1
  fi
  digest="$(/usr/bin/sha256sum -- "$authority_path" 2>/dev/null | /usr/bin/gawk '{print $1}' || true)"
  if [[ ! "$digest" =~ ^[0-9a-f]{64}$ ]]; then
    echo 'FAIL receipt evidence receipt authority digest'
    receipt_failures=$((receipt_failures + 1))
    return 1
  fi
  expected_by_key[receipt_authority_path]="$authority_path"
  expected_by_key[receipt_authority_sha256]="$digest"
}

validate_locked_receipt_value() {
  local key="$1"
  local value="${expected_by_key[$key]}"
  local escaped_version
  case "$key" in
    rustup)
      escaped_version="${RUSTUP_VERSION//./\\.}"
      [[ "$value" =~ ^rustup[[:space:]]${escaped_version}([[:space:]]\([^[:space:]]+[[:space:]][0-9]{4}-[0-9]{2}-[0-9]{2}\))?$ ]] || { echo "FAIL receipt locked contract $key"; return 1; }
      ;;
    rustc)
      escaped_version="${RUST_TOOLCHAIN//./\\.}"
      [[ "$value" =~ ^rustc[[:space:]]${escaped_version}([[:space:]]\([^[:space:]]+[[:space:]][0-9]{4}-[0-9]{2}-[0-9]{2}\))?$ ]] || { echo "FAIL receipt locked contract $key"; return 1; }
      ;;
    rtk)
      [[ "$value" == "rtk $RTK_VERSION" ]] || { echo "FAIL receipt locked contract $key"; return 1; }
      ;;
    node)
      [[ "$value" == "v$NODE_VERSION" ]] || { echo "FAIL receipt locked contract $key"; return 1; }
      ;;
    npm)
      [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]] || { echo "FAIL receipt locked contract $key"; return 1; }
      ;;
    codex)
      escaped_version="${CODEX_VERSION//./\\.}"
      [[ "$value" =~ ^[^[:space:]]+[[:space:]]${escaped_version}$ ]] || { echo "FAIL receipt locked contract $key"; return 1; }
      ;;
    claude)
      escaped_version="${CLAUDE_VERSION//./\\.}"
      [[ "$value" =~ ^${escaped_version}([[:space:]]+\([^()]+\))?$ ]] || { echo "FAIL receipt locked contract $key"; return 1; }
      ;;
    bun)
      [[ "$value" == "$BUN_VERSION" ]] || { echo "FAIL receipt locked contract $key"; return 1; }
      ;;
    herdr)
      escaped_version="${HERDR_VERSION//./\\.}"
      [[ "$value" =~ ^[^[:space:]]+[[:space:]]${escaped_version}$ ]] || { echo "FAIL receipt locked contract $key"; return 1; }
      ;;
    powershell)
      [[ "$value" == "$POWERSHELL_VERSION" ]] || { echo "FAIL receipt locked contract $key"; return 1; }
      ;;
  esac
}

append_apt_receipt_expectations() {
  local package
  local apt_line
 local apt_key
 local apt_value
 local apt_arch
  local dpkg_query_path
 local -a apt_packages=(
   cifs-utils curl gawk git git-lfs gh jq mosh openssh-client openssh-server ripgrep rsync
 )
  dpkg_query_path="$(verify_resolve_command dpkg-query 2>/dev/null || true)"
  [[ -n "$dpkg_query_path" ]] || {
    echo 'FAIL receipt runtime probe dpkg-query'
    receipt_failures=$((receipt_failures + 1))
    return 1
  }
 for package in "${apt_packages[@]}"; do
    if ! apt_line="$("$dpkg_query_path" -W -f='apt:${binary:Package}=${Version}\n' "$package" 2>/dev/null)"; then
      echo "FAIL receipt runtime probe apt:$package"
      receipt_failures=$((receipt_failures + 1))
      return 1
    fi
    if [[ "$apt_line" == *$'\n'* || "$apt_line" != apt:* || "$apt_line" != *"="* ]]; then
      echo "FAIL receipt runtime probe malformed apt:$package"
      receipt_failures=$((receipt_failures + 1))
      return 1
    fi
    apt_key="${apt_line%%=*}"
    apt_value="${apt_line#*=}"
    if [[ "$apt_key" != "apt:$package" ]]; then
      apt_arch="${apt_key#apt:$package}"
      if [[ ! "$apt_arch" =~ ^:[A-Za-z0-9_.+-]+$ ]]; then
        echo "FAIL receipt locked contract $apt_key"
        receipt_failures=$((receipt_failures + 1))
        return 1
      fi
    fi
    if [[ -z "$apt_value" || "$apt_value" == *[[:space:]=]* ]]; then
      echo "FAIL receipt runtime probe malformed $apt_key"
      receipt_failures=$((receipt_failures + 1))
      return 1
    fi
    required_keys+=("$apt_key")
    expected_by_key["$apt_key"]="$apt_value"
  done
}

validate_runtime_receipt() {
  local line_number=0
  local line
  local key
  local value
  local expected
  local receipt_failures=0
  local -a required_keys=(
    receipt_format lock_sha256 host_platform host_architecture
    uv_path python3.13_path py_path rtk_path rtk_version rtk_url rtk_sha256 uv_version python3.13_version
    python3.13_kind python3.13_sha256 python3.13_pyvenv_cfg
    receipt_authority_path receipt_authority_sha256
    py_3.13_version py_3.13_probe uv_platform uv_url uv_sha256
    python_version python_platform python_release python_archive python_url python_sha256 tailscale
    rustup rustc node npm codex claude bun herdr powershell
  )
  local -A expected_by_key=()
  local -A seen_keys=()

  expected_by_key[receipt_format]='issue-961-toolchain-v2'
  expected_by_key[lock_sha256]="$lock_sha256"
  expected_by_key[host_platform]='linux'
  expected_by_key[host_architecture]='x86_64'
  expected_by_key[uv_path]="$HOME/.local/bin/uv"
  expected_by_key[python3.13_path]="$HOME/.local/bin/python3.13"
  expected_by_key[py_path]="$HOME/.local/bin/py"
  expected_by_key[rtk_path]="$HOME/.cargo/bin/rtk"
  expected_by_key[rtk_version]="rtk $RTK_VERSION"
  expected_by_key[rtk_url]="$RTK_URL"
  expected_by_key[rtk_sha256]="$RTK_SHA256"
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

  if [[ ! -f "$toolchain_receipt" || -L "$toolchain_receipt" ]]; then
    echo "FAIL receipt missing $toolchain_receipt"
    return 1
  fi
  local runtime_probe_failed=0
  record_receipt_python_evidence || runtime_probe_failed=1
  record_receipt_authority_evidence || runtime_probe_failed=1
  record_receipt_first_line rustup rustup --version || runtime_probe_failed=1
  record_receipt_command rustc rustc --version || runtime_probe_failed=1
  record_receipt_command rtk rtk --version || runtime_probe_failed=1
  record_receipt_command node node --version || runtime_probe_failed=1
  record_receipt_command npm npm --version || runtime_probe_failed=1
  record_receipt_command codex codex --version || runtime_probe_failed=1
  record_receipt_command claude claude --version || runtime_probe_failed=1
  record_receipt_command bun bun --version || runtime_probe_failed=1
  record_receipt_command herdr herdr --version || runtime_probe_failed=1
  record_receipt_command powershell pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' || runtime_probe_failed=1
  if (( runtime_probe_failed )); then
    return 1
  fi
  for runtime_key in rustup rustc rtk node npm codex claude bun herdr powershell; do
    if ! validate_locked_receipt_value "$runtime_key"; then
      receipt_failures=$((receipt_failures + 1))
    fi
  done
  append_apt_receipt_expectations || return 1

  while IFS= read -r line || [[ -n "$line" ]]; do
    line_number=$((line_number + 1))
    if [[ ! "$line" =~ ^([A-Za-z][A-Za-z0-9_.:-]*)=(.*)$ ]]; then
      echo "FAIL receipt malformed line $line_number"
      receipt_failures=$((receipt_failures + 1))
      continue
    fi
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    if [[ -z "${expected_by_key[$key]+present}" ]]; then
      echo "FAIL receipt unknown key $key"
      receipt_failures=$((receipt_failures + 1))
      continue
    fi
    if [[ -n "${seen_keys[$key]+present}" ]]; then
      echo "FAIL receipt duplicate key $key"
      receipt_failures=$((receipt_failures + 1))
      continue
    fi
    expected="${expected_by_key[$key]}"
    if [[ "$value" != "$expected" ]]; then
      echo "FAIL receipt mismatch $key"
      receipt_failures=$((receipt_failures + 1))
      continue
    fi
    seen_keys["$key"]=1
    echo "PASS receipt $key=$value"
  done < "$toolchain_receipt"
  for key in "${required_keys[@]}"; do
    if [[ -z "${seen_keys[$key]+present}" ]]; then
      echo "FAIL receipt missing $key"
      receipt_failures=$((receipt_failures + 1))
    fi
  done
  [[ "$receipt_failures" -eq 0 && "${#seen_keys[@]}" -eq "${#required_keys[@]}" ]]
}

if ! validate_managed_paths "$toolchain_receipt"; then
  echo "FAIL receipt path is not securely confined: $toolchain_receipt"
  failures=$((failures + 1))
fi
if ! validate_runtime_receipt; then
  failures=$((failures + 1))
fi
login_shell="$(verify_resolve_command bash 2>/dev/null || true)"
[[ -n "$login_shell" ]] || { echo 'FAIL login shell bash is unavailable'; failures=$((failures + 1)); login_shell=/usr/bin/bash; }
login_path="$(PATH=/usr/bin:/bin HOME="$HOME" "$login_shell" -lc 'printf "%s" "$PATH"')"
for required_path in "$HOME/.local/bin" "$HOME/.cargo/bin"; do
  if [[ ":$login_path:" == *":$required_path:"* ]]; then
    echo "PASS login PATH includes $required_path"
  else
    echo "FAIL login PATH omits $required_path"
    failures=$((failures + 1))
  fi
done
for command in rtk codex claude herdr; do
  login_command="$(PATH=/usr/bin:/bin HOME="$HOME" "$login_shell" -lc "command -v $command" 2>/dev/null || true)"
  if [[ -n "$login_command" ]]; then
    echo "PASS login command $command $login_command"
  else
    echo "FAIL login command $command missing"
    failures=$((failures + 1))
  fi
done
if systemctl_path="$(verify_resolve_command systemctl 2>/dev/null)"; then
  for service in ssh tailscaled; do
    if "$systemctl_path" is-active --quiet "$service"; then
      echo "PASS service $service active"
    else
      echo "FAIL service $service inactive"
      failures=$((failures + 1))
    fi
  done
fi

printf 'Versions:\n'
for version_command in rtk codex claude herdr; do
  if version_path="$(verify_resolve_command "$version_command" 2>/dev/null)"; then
    verify_run_command "$version_command" "$version_path" --version 2>/dev/null || true
  fi
done
if version_path="$(verify_resolve_command git 2>/dev/null)"; then
  "$version_path" --version 2>/dev/null || true
fi
if version_path="$(verify_resolve_command gh 2>/dev/null)"; then
  "$version_path" --version 2>/dev/null | /usr/bin/head -n 1 || true
fi
if version_path="$(verify_resolve_command mosh 2>/dev/null)"; then
  "$version_path" --version 2>/dev/null | /usr/bin/head -n 1 || true
fi
if pwsh_path="$(verify_resolve_command pwsh 2>/dev/null)"; then
  "$pwsh_path" --version 2>/dev/null || true
fi

if [[ "$failures" -ne 0 ]]; then
  echo "Verification failed: $failures check(s)" >&2
  exit 1
fi
echo 'Ubuntu bootstrap verification passed.'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  verify_main "$@"
fi
