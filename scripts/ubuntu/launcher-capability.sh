# This helper is sourced only by an entrypoint whose fixed descriptors were
# opened by the installed launcher (or by the root receipt transaction). The
# descriptors, not environment markers, are the authorization capability.

launcher_capability_fail() {
  echo "herdr launcher capability: $*" >&2
  exit 24
}

launcher_capability_reject_symlink_components() {
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

launcher_capability_identity() {
  /usr/bin/stat -Lc '%d:%i:%u:%g:%a:%F:%s:%Y' -- "$1" 2>/dev/null || true
}

launcher_capability_realpath() {
  /usr/bin/realpath -e -- "$1" 2>/dev/null || true
}

launcher_capability_owner_mode() {
  local path="$1" expected_uid="$2" expected_gid="$3" expected_mode="$4"
  local uid gid mode
  uid="$(/usr/bin/stat -c '%u' -- "$path" 2>/dev/null || true)"
  gid="$(/usr/bin/stat -c '%g' -- "$path" 2>/dev/null || true)"
  mode="$(/usr/bin/stat -c '%a' -- "$path" 2>/dev/null || true)"
  [[ "$uid" == "$expected_uid" && "$gid" == "$expected_gid" && "$mode" == "$expected_mode" ]]
}

launcher_capability_capture_readonly() {
  local variable="$1" expected="$2"
  if [[ -v "$variable" ]]; then
    [[ "${!variable}" == "$expected" ]] ||
      launcher_capability_fail "captured capability changed: $variable"
  else
    printf -v "$variable" '%s' "$expected"
  fi
  readonly "$variable"
}

launcher_capability_assert_fd() {
  local fd="$1" path="$2" expected_identity="$3"
  [[ -e "/proc/$BASHPID/fd/$fd" ]] || launcher_capability_fail "capability descriptor $fd is unavailable"
  [[ "$(launcher_capability_realpath "/proc/$BASHPID/fd/$fd")" == "$path" ]] || {
    launcher_capability_fail "capability descriptor $fd is not bound to $path"
  }
  [[ "$(launcher_capability_identity "/proc/$BASHPID/fd/$fd")" == "$expected_identity" ]] || {
    launcher_capability_fail "capability descriptor $fd identity changed"
  }
}

launcher_capability_process_has_descriptors() {
  local pid="$1" policy_id="$2" stage_id="$3" launcher_id="$4" parent_capability_id="${5:-}"
  [[ "$(launcher_capability_identity "/proc/$pid/fd/9")" == "$policy_id" &&
    "$(launcher_capability_identity "/proc/$pid/fd/10")" == "$stage_id" &&
    "$(launcher_capability_identity "/proc/$pid/fd/11")" == "$launcher_id" ]] || return 1
  [[ -z "$parent_capability_id" ||
    "$(launcher_capability_identity "/proc/$pid/fd/12")" == "$parent_capability_id" ]]
}

launcher_capability_parent_pid() {
  /usr/bin/gawk '$1 == "PPid:" { print $2; exit }' "/proc/$1/status" 2>/dev/null || true
}

launcher_capability_assert_parent_capability() {
  local kind="$1" expected_uid="$2" expected_gid="$3"
  local fd_path="/proc/$BASHPID/fd/12" identity expected_mode expected_size owner_mode object_size
  case "$kind" in
    installed-launcher)
      expected_mode=600
      expected_size=1
      [[ -e "$fd_path" ]] || launcher_capability_fail 'parent capability descriptor 12 is unavailable'
      identity="$(launcher_capability_identity "$fd_path")"
      [[ "$identity" =~ ^[0-9]+:[0-9]+:[0-9]+:[0-9]+:[0-9]+:regular[[:space:]]file:[0-9]+:[0-9]+$ ]] ||
        launcher_capability_fail 'installed-launcher parent capability is not a regular file'
      ;;
    root-receipt)
      expected_mode=700
      [[ -e "$fd_path" ]] || launcher_capability_fail 'root-receipt capability descriptor 12 is unavailable'
      identity="$(launcher_capability_identity "$fd_path")"
      [[ "$identity" =~ ^[0-9]+:[0-9]+:[0-9]+:[0-9]+:[0-9]+:directory:[0-9]+:[0-9]+$ ]] ||
        launcher_capability_fail 'root-receipt parent capability is not a directory'
      ;;
    *) launcher_capability_fail 'parent capability kind is invalid' ;;
  esac
  owner_mode="$(/usr/bin/stat -Lc '%u:%g:%a' -- "$fd_path" 2>/dev/null || true)"
  [[ "$owner_mode" == "$expected_uid:$expected_gid:$expected_mode" ]] || {
    launcher_capability_fail 'parent capability owner or mode is unsafe'
  }
  if [[ "$kind" == installed-launcher ]]; then
    object_size="$(/usr/bin/stat -Lc '%s' -- "$fd_path" 2>/dev/null || true)"
    [[ "$object_size" == "$expected_size" ]] ||
      launcher_capability_fail 'installed-launcher parent capability size is unsafe'
  fi
  launcher_capability_capture_readonly launcher_capability_parent_capability_kind "$kind"
  launcher_capability_capture_readonly launcher_capability_parent_capability_identity "$identity"
}

launcher_capability_bind_parent() {
  local policy_id="$1" stage_id="$2" launcher_id="$3" launcher_path="$4" payload_mode="$5"
  local owner_uid="$6" owner_gid="$7" parent_capability_kind="$8"
  local pid="$PPID" next depth process_uid current_uid parent_capability_id
  local -a argv=()
  launcher_capability_parent_found=0
  launcher_capability_root_transaction_parent=0
  launcher_capability_assert_parent_capability "$parent_capability_kind" "$owner_uid" "$owner_gid"
  parent_capability_id="$launcher_capability_parent_capability_identity"
  current_uid="$(/usr/bin/id -u 2>/dev/null || true)"
  [[ "$current_uid" =~ ^[0-9]+$ ]] || return 1
  if [[ "$current_uid" != "$owner_uid" ]]; then
    # A dropped child cannot inspect a root-owned parent's /proc fd table.
    # The role-bound, owner-bound fd 12 capability is the direct proof in
    # this branch; same-UID callers retain the ancestry proof below.
    case "$parent_capability_kind" in
      installed-launcher) launcher_capability_parent_found=1 ;;
      root-receipt) launcher_capability_root_transaction_parent=1 ;;
    esac
    return 0
  fi
  for ((depth = 0; depth < 16; depth++)); do
    [[ "$pid" =~ ^[0-9]+$ && "$pid" != 0 ]] || break
    if launcher_capability_process_has_descriptors "$pid" "$policy_id" "$stage_id" "$launcher_id" "$parent_capability_id"; then
      mapfile -d '' -t argv < "/proc/$pid/cmdline" 2>/dev/null || true
      process_uid="$(/usr/bin/stat -c '%u' -- "/proc/$pid" 2>/dev/null || true)"
      if [[ "${argv[0]:-}" == /usr/bin/bash &&
        "$(launcher_capability_realpath "${argv[1]:-}")" == "$launcher_path" ]]; then
        launcher_capability_parent_found=1
        break
      fi
      if [[ "$payload_mode" == 1 && "$process_uid" == 0 &&
        "${argv[0]:-}" == /usr/bin/bash ]]; then
        launcher_capability_root_transaction_parent=1
        break
      fi
    fi
    next="$(launcher_capability_parent_pid "$pid")"
    [[ "$next" != "$pid" ]] || break
    pid="$next"
  done
  [[ "$launcher_capability_parent_found" == 1 ||
    "$launcher_capability_root_transaction_parent" == 1 ]]
}

launcher_capability_parse_policy() {
  local expected_size="${1:-}" line policy_line=0 canonical_size
  [[ "$expected_size" =~ ^[0-9]+$ ]] ||
    launcher_capability_fail 'policy descriptor size is invalid'
  if [[ "${launcher_capability_policy_captured:-0}" == 1 ]]; then
    [[ "$expected_size" == "$launcher_capability_policy_byte_count" ]] ||
      launcher_capability_fail 'policy descriptor size changed'
    return 0
  fi
  launcher_capability_policy_origin=''
  launcher_capability_policy_commit=''
  while :; do
    line=''
    if ! IFS= read -r -u 9 line; then
      [[ -z "$line" ]] || launcher_capability_fail 'policy grammar is not exact'
      break
    fi
    case "$policy_line" in
      0)
        [[ "$line" == 'herdr-bootstrap-policy-v1' ]] ||
          launcher_capability_fail 'policy grammar is not exact'
        policy_line=1
        ;;
      1)
        [[ "$line" == origin=* ]] ||
          launcher_capability_fail 'policy grammar is not exact'
        launcher_capability_policy_origin="${line#origin=}"
        policy_line=2
        ;;
      2)
        [[ "$line" == commit=* ]] ||
          launcher_capability_fail 'policy grammar is not exact'
        launcher_capability_policy_commit="${line#commit=}"
        policy_line=3
        ;;
      *) launcher_capability_fail 'policy grammar is not exact' ;;
    esac
  done
  [[ "$policy_line" == 3 &&
    "$launcher_capability_policy_commit" =~ ^[0-9a-f]{40}$ ]] || {
    launcher_capability_fail 'policy grammar is not exact'
  }
  [[ "$launcher_capability_policy_origin" =~ ^https://[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+/[A-Za-z0-9._~-]+(/[A-Za-z0-9._~-]+)*\.git$ &&
    "$launcher_capability_policy_origin" != *..* &&
    "$launcher_capability_policy_origin" != *@* ]] || {
    launcher_capability_fail 'policy origin is not canonical HTTPS'
  }

  canonical_size="$(
    printf '%s\n' \
      'herdr-bootstrap-policy-v1' \
      "origin=$launcher_capability_policy_origin" \
      "commit=$launcher_capability_policy_commit" |
      /usr/bin/wc -c | /usr/bin/gawk '{print $1}'
  )"
  [[ "$canonical_size" =~ ^[0-9]+$ && "$canonical_size" == "$expected_size" ]] || {
    launcher_capability_fail 'policy bytes are not exact'
  }

  # fd 9 has been consumed directly.  These canonical bytes are exactly the
  # validated three-line policy, so later lifetime checks must not reopen fd 9.
  launcher_capability_policy_hash="$(
    printf '%s\n' \
      'herdr-bootstrap-policy-v1' \
      "origin=$launcher_capability_policy_origin" \
      "commit=$launcher_capability_policy_commit" |
      /usr/bin/sha256sum | /usr/bin/gawk '{print $1}'
  )"
  [[ "$launcher_capability_policy_hash" =~ ^[0-9a-f]{64}$ ]] || {
    launcher_capability_fail 'policy descriptor hash is invalid'
  }
  launcher_capability_capture_readonly launcher_capability_policy_origin \
    "$launcher_capability_policy_origin"
  launcher_capability_capture_readonly launcher_capability_policy_commit \
    "$launcher_capability_policy_commit"
  launcher_capability_capture_readonly launcher_capability_policy_byte_count \
    "$canonical_size"
  launcher_capability_capture_readonly launcher_capability_policy_hash \
    "$launcher_capability_policy_hash"
  launcher_capability_capture_readonly launcher_capability_policy_captured 1
}

launcher_capability_bind() {
  local expected_entry="$1"
  local payload_mode="${2:-0}"
  local payload_arg="${3:-}"
  local entry_source helper_path entry_dir
  local policy_fd_path stage_fd_path launcher_fd_path
  local policy_path policy_dir policy_identity launcher_path launcher_dir launcher_identity
  local policy_size payload_root_value
  local staging_root stage_dir stage_identity entry_path repo_root
  local prefix expected_launcher expected_staging helper_identity
  local policy_uid policy_gid policy_mode stage_mode
  local git_dir git_entry git_mode

  entry_source="${BASH_SOURCE[2]:-${BASH_SOURCE[1]:-}}"
  entry_source="${launcher_capability_entry_source:-$entry_source}"
  entry_path="$(launcher_capability_realpath "$entry_source")"
  [[ -n "$entry_path" ]] || launcher_capability_fail 'entrypoint path is not canonical'
  entry_dir="$(/usr/bin/dirname -- "$entry_path")"
  repo_root="$(launcher_capability_realpath "$entry_dir/../..")"
  [[ -n "$repo_root" &&
    "$entry_path" == "$repo_root/scripts/ubuntu/$expected_entry.sh" ]] || {
    launcher_capability_fail 'entrypoint is not the expected staged blob path'
  }

  policy_fd_path="/proc/$BASHPID/fd/9"
  stage_fd_path="/proc/$BASHPID/fd/10"
  launcher_fd_path="/proc/$BASHPID/fd/11"
  policy_identity="$(launcher_capability_identity "$policy_fd_path")"
  stage_identity="$(launcher_capability_identity "$stage_fd_path")"
  launcher_identity="$(launcher_capability_identity "$launcher_fd_path")"
  policy_size="$(/usr/bin/stat -Lc '%s' -- "$policy_fd_path" 2>/dev/null || true)"
  [[ "$policy_size" =~ ^[0-9]+$ ]] || launcher_capability_fail 'policy descriptor size is unavailable'
  [[ "$policy_identity" =~ ^[0-9]+:[0-9]+:[0-9]+:[0-9]+:[0-9]+:regular[[:space:]]file:[0-9]+:[0-9]+$ &&
    "$stage_identity" =~ ^[0-9]+:[0-9]+:[0-9]+:[0-9]+:[0-9]+:directory:[0-9]+:[0-9]+$ &&
    "$launcher_identity" =~ ^[0-9]+:[0-9]+:[0-9]+:[0-9]+:[0-9]+:regular[[:space:]]file:[0-9]+:[0-9]+$ ]] || {
    launcher_capability_fail 'capability descriptors are not policy, stage, and launcher objects'
  }
  policy_path="$(launcher_capability_realpath "$policy_fd_path")"
  stage_dir="$(launcher_capability_realpath "$stage_fd_path")"
  launcher_path="$(launcher_capability_realpath "$launcher_fd_path")"
  [[ -n "$policy_path" && -n "$stage_dir" && -n "$launcher_path" ]] ||
    launcher_capability_fail 'capability paths are not canonical'

  policy_uid="$(/usr/bin/stat -Lc '%u' -- "$policy_fd_path" 2>/dev/null || true)"
  policy_gid="$(/usr/bin/stat -Lc '%g' -- "$policy_fd_path" 2>/dev/null || true)"
  policy_mode="$(/usr/bin/stat -Lc '%a' -- "$policy_fd_path" 2>/dev/null || true)"
  [[ "$policy_uid" =~ ^[0-9]+$ && "$policy_gid" =~ ^[0-9]+$ &&
    "$policy_mode" == 600 ]] || launcher_capability_fail "policy is not a private owner-bound file: uid=$policy_uid gid=$policy_gid mode=$policy_mode path=$policy_fd_path"
  [[ "$policy_path" == */etc/herdr-workstation/bootstrap-policy.conf ]] ||
    launcher_capability_fail 'policy path is not canonical'
  prefix="${policy_path%/etc/herdr-workstation/bootstrap-policy.conf}"
  [[ "$prefix" != / || "$policy_path" == /etc/herdr-workstation/bootstrap-policy.conf ]] ||
    launcher_capability_fail 'policy prefix is unsafe'
  expected_launcher="$prefix/usr/local/libexec/herdr-workstation-bootstrap"
  expected_staging="$prefix/var/lib/herdr-workstation/bootstrap/staging"
  [[ "$launcher_path" == "$expected_launcher" ]] ||
    launcher_capability_fail 'launcher descriptor is not the installed launcher'

  policy_dir="${policy_path%/bootstrap-policy.conf}"
  launcher_dir="${launcher_path%/herdr-workstation-bootstrap}"
  staging_root="$expected_staging"
  launcher_capability_reject_symlink_components "$policy_path" ||
    launcher_capability_fail 'policy path contains a symlink'
  launcher_capability_reject_symlink_components "$launcher_path" ||
    launcher_capability_fail 'launcher path contains a symlink'
  launcher_capability_reject_symlink_components "$staging_root" ||
    launcher_capability_fail 'staging root contains a symlink'
  launcher_capability_owner_mode "$policy_dir" "$policy_uid" "$policy_gid" 755 ||
    launcher_capability_fail 'policy directory owner or mode is unsafe'
  launcher_capability_owner_mode "$launcher_dir" "$policy_uid" "$policy_gid" 755 ||
    launcher_capability_fail 'launcher directory owner or mode is unsafe'
  launcher_capability_owner_mode "$staging_root" "$policy_uid" "$policy_gid" 755 ||
    launcher_capability_fail 'staging root owner or mode is unsafe'
  launcher_capability_owner_mode "$launcher_path" "$policy_uid" "$policy_gid" 755 ||
    launcher_capability_fail 'installed launcher owner or mode is unsafe'
  if [[ "$prefix" == '' ]]; then
    [[ "$policy_uid" == 0 && "$policy_gid" == 0 ]] ||
      launcher_capability_fail 'production launcher capability is not root-owned'
  fi

  if [[ "$payload_mode" == 1 ]]; then
    [[ "$expected_entry" == receipt-authority && "$(/usr/bin/id -u)" == 0 ]] ||
      launcher_capability_fail 'payload receipt requires root'
    [[ -n "$payload_arg" && "$stage_dir" == "$payload_arg" ]] ||
      launcher_capability_fail 'payload root is not descriptor-bound'
    [[ "$repo_root" == "$stage_dir/source" ]] ||
      launcher_capability_fail 'payload receipt source escaped its root stage'
    [[ "$(/usr/bin/stat -Lc '%u:%g:%a' -- "$stage_fd_path")" == 0:0:700 ]] ||
      launcher_capability_fail 'payload stage is not root-owned and private'
  else
    [[ "$stage_dir" == "$staging_root"/.incoming.* ]] ||
      launcher_capability_fail 'staged repository is not a direct staging child'
    stage_mode="$(/usr/bin/stat -Lc '%a' -- "$stage_fd_path" 2>/dev/null || true)"
    [[ "$stage_mode" == 755 &&
      "$(/usr/bin/stat -Lc '%u:%g' -- "$stage_fd_path")" == "$policy_uid:$policy_gid" ]] ||
      launcher_capability_fail 'staged repository owner or mode is unsafe'
    [[ "$entry_path" == "$stage_dir/scripts/ubuntu/$expected_entry.sh" ]] ||
      launcher_capability_fail 'entrypoint escaped its stage'
  fi
  launcher_capability_owner_mode "$entry_path" "$policy_uid" "$policy_gid" 755 ||
    launcher_capability_fail 'entrypoint owner or mode is unsafe'
  helper_path="$repo_root/scripts/ubuntu/launcher-capability.sh"
  helper_path="$(launcher_capability_realpath "$helper_path")"
  [[ "$helper_path" == "$repo_root/scripts/ubuntu/launcher-capability.sh" ]] ||
    launcher_capability_fail 'capability helper escaped its stage'
  launcher_capability_owner_mode "$helper_path" "$policy_uid" "$policy_gid" 755 ||
    launcher_capability_fail 'capability helper owner or mode is unsafe'

  launcher_capability_parse_policy "$policy_size"
  launcher_capability_capture_readonly launcher_capability_policy_identity "$policy_identity"
  launcher_capability_capture_readonly launcher_capability_stage_identity "$stage_identity"
  launcher_capability_capture_readonly launcher_capability_launcher_identity "$launcher_identity"
  if [[ "$payload_mode" != 1 ]]; then
    [[ "$repo_root" == "$stage_dir" ]] ||
      launcher_capability_fail 'entrypoint repository is not the staged repository'
  fi

  launcher_capability_assert_fd 9 "$policy_path" "$policy_identity"
  launcher_capability_assert_fd 10 "$stage_dir" "$stage_identity"
  launcher_capability_assert_fd 11 "$launcher_path" "$launcher_identity"
  local parent_capability_kind
  if [[ "$expected_entry" == receipt-authority ]]; then
    parent_capability_kind=root-receipt
  else
    parent_capability_kind=installed-launcher
  fi
  launcher_capability_bind_parent "$policy_identity" "$stage_identity" \
    "$launcher_identity" "$launcher_path" "$payload_mode" "$policy_uid" "$policy_gid" \
    "$parent_capability_kind" || {
    launcher_capability_fail 'no capable installed-launcher or root-receipt parent holds the descriptors'
  }
  if [[ "$payload_mode" == 1 ]]; then
    [[ "$launcher_capability_root_transaction_parent" == 1 ]] ||
      launcher_capability_fail 'payload receipt parent is not the root transaction'
  else
    [[ "$launcher_capability_parent_found" == 1 ]] ||
      launcher_capability_fail 'entrypoint parent is not the installed launcher'
  fi

  if [[ -d "$repo_root/.git" ]]; then
    git_dir="$repo_root/.git"
    launcher_capability_owner_mode "$repo_root" "$policy_uid" "$policy_gid" 755 ||
      launcher_capability_fail 'repository root owner or mode is unsafe'
    launcher_capability_owner_mode "$git_dir" "$policy_uid" "$policy_gid" 755 ||
      launcher_capability_fail 'repository Git directory owner or mode is unsafe'
    for git_entry in "$git_dir/objects" "$git_dir/refs" "$git_dir/config" "$git_dir/index"; do
      [[ -e "$git_entry" && ! -L "$git_entry" ]] ||
        launcher_capability_fail "repository Git metadata is missing: $git_entry"
      [[ "$(/usr/bin/stat -c '%u:%g' -- "$git_entry")" == "$policy_uid:$policy_gid" ]] ||
        launcher_capability_fail "repository Git metadata owner is unsafe: $git_entry"
      git_mode="$(/usr/bin/stat -c '%a' -- "$git_entry" 2>/dev/null || true)"
      [[ "$git_mode" =~ ^[0-7]+$ && $((8#$git_mode & 022)) == 0 ]] ||
        launcher_capability_fail "repository Git metadata mode is unsafe: $git_entry"
    done
  fi

  launcher_capability_entry_name="$expected_entry"
  launcher_capability_entry_path="$entry_path"
  launcher_capability_capture_readonly launcher_capability_repo_root "$repo_root"
  launcher_capability_capture_readonly launcher_capability_stage_root "$stage_dir"
  launcher_capability_capture_readonly launcher_capability_policy_path "$policy_path"
  launcher_capability_capture_readonly launcher_capability_owner_uid "$policy_uid"
  launcher_capability_capture_readonly launcher_capability_owner_gid "$policy_gid"
  payload_root_value=''
  [[ "$payload_mode" == 1 ]] && payload_root_value="$stage_dir"
  launcher_capability_capture_readonly launcher_capability_payload_root "$payload_root_value"
  return 0
}

launcher_capability_lifetime() {
  [[ "$(launcher_capability_identity /proc/$BASHPID/fd/9)" == "$launcher_capability_policy_identity" &&
    "$(launcher_capability_identity /proc/$BASHPID/fd/10)" == "$launcher_capability_stage_identity" &&
    "$(launcher_capability_identity /proc/$BASHPID/fd/11)" == "$launcher_capability_launcher_identity" &&
    "$(launcher_capability_identity /proc/$BASHPID/fd/12)" == "$launcher_capability_parent_capability_identity" ]] ||
    launcher_capability_fail 'launcher capability replacement detected'
  [[ "$launcher_capability_policy_hash" == "$(
    printf '%s\n' \
      'herdr-bootstrap-policy-v1' \
      "origin=$launcher_capability_policy_origin" \
      "commit=$launcher_capability_policy_commit" |
      /usr/bin/sha256sum | /usr/bin/gawk '{print $1}'
  )" ]] || launcher_capability_fail 'policy capability capture changed'
}

[[ "$#" -ge 1 && ( "$1" == bootstrap || "$1" == receipt-authority || "$1" == verify ) ]] ||
  launcher_capability_fail 'capability entrypoint selector is invalid'
launcher_capability_bind "$@"
