#!/usr/bin/env bash
set -euo pipefail

phase="all"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase) phase="$2"; shift 2 ;;
    --no-node) echo '--no-node is no longer supported because Codex and Claude use the pinned Node runtime.' >&2; exit 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
lock_file="$repo_root/config/ubuntu-toolchain.lock"
state_dir="${HOME}/.local/state/herdr-workstation-bootstrap"
bin_dir="${HOME}/.local/bin"

[[ -f "$lock_file" ]] || { echo "Missing toolchain lock: $lock_file" >&2; exit 22; }
# shellcheck disable=SC1090
source "$lock_file"
required_lock_keys=(
  UV_VERSION UV_PLATFORM UV_URL UV_SHA256
  PYTHON_VERSION PYTHON_RELEASE PYTHON_PLATFORM PYTHON_ARCHIVE PYTHON_URL PYTHON_SHA256
  RTK_REPO_URL RTK_REF
  POWERSHELL_VERSION POWERSHELL_URL POWERSHELL_SHA256
  TAILSCALE_VERSION TAILSCALE_INSTALLER_URL TAILSCALE_INSTALLER_SHA256
  RUSTUP_VERSION RUSTUP_INIT_URL RUSTUP_INIT_SHA256 RUST_TOOLCHAIN
  NODE_VERSION NODE_URL NODE_SHA256 CODEX_VERSION CLAUDE_VERSION BUN_VERSION
  HERDR_VERSION HERDR_URL HERDR_SHA256
)
for key in "${required_lock_keys[@]}"; do
  [[ -n "${!key:-}" ]] || { echo "Lock key '$key' is empty." >&2; exit 22; }
done
for key in UV_SHA256 PYTHON_SHA256 POWERSHELL_SHA256 TAILSCALE_INSTALLER_SHA256 RUSTUP_INIT_SHA256 NODE_SHA256 HERDR_SHA256; do
  [[ "${!key}" =~ ^[0-9a-f]{64}$ ]] || { echo "Lock key '$key' is not a lowercase SHA-256 value." >&2; exit 22; }
done

path_is_under() {
  local child="$1"
  local parent="$2"
  [[ "$child" == "$parent" || "$child" == "$parent/"* ]]
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
  home_real="$(realpath -e -- "$HOME" 2>/dev/null || true)"
  [[ -n "$home_real" && -d "$home_real" ]] || {
    echo 'Could not resolve the real user home.' >&2
    return 1
  }
  [[ "$(stat -c '%u' -- "$home_real" 2>/dev/null || true)" == "$(id -u)" ]] || {
    echo 'The resolved user home is not owned by the current user.' >&2
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
  normalized="$(realpath -m -- "$path" 2>/dev/null || true)"
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
        mkdir -- "$child" || {
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
  fd_id="$(stat -Lc '%d:%i' -- "/proc/self/fd/$fd" 2>/dev/null || true)"
  live_id="$(stat -Lc '%d:%i' -- "$path" 2>/dev/null || true)"
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

validate_toolchain_lock() {
  for lock_hash_key in UV_SHA256 PYTHON_SHA256 POWERSHELL_SHA256 TAILSCALE_INSTALLER_SHA256 RUSTUP_INIT_SHA256 NODE_SHA256 HERDR_SHA256; do
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
  actual="$("$executable" --version 2>&1)" || return 1
  [[ "$actual" == "$expected" ]]
}

check_python_version() {
  local executable="$1"
  local actual
  actual="$("$executable" --version 2>&1)" || return 1
  [[ "$actual" == "Python $PYTHON_VERSION" ]]
}

check_python_platform() {
  local executable="$1"
  local actual
  actual="$("$executable" -c 'import platform, sys; print(f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}|{platform.machine()}|{sys.platform}")')" || return 1
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
  cat > "$replacement" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || "$1" != '-3.13' ]]; then
  echo 'This managed py command supports only the -3.13 selector.' >&2
  exit 2
fi
shift
wrapper_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
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

download_verified() {
  local url="$1"
  local expected_sha="$2"
  local destination="$3"
  curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
    --retry 3 --connect-timeout 15 --output "$destination" "$url"
  printf '%s  %s\n' "$expected_sha" "$destination" | sha256sum --check --status || {
    echo "SHA-256 verification failed for $url" >&2
    rm -f "$destination"
    exit 23
  }
}

install_locked_tailscale() (
  local installed_tailscale
  local tailscale_temp_dir
  local installer
  local apt_get_shim
  local real_apt_get
  local installer_status

  validate_toolchain_lock || exit 22
  installed_tailscale="$(tailscale version 2>/dev/null | head -n 1 || true)"
  [[ "$installed_tailscale" == "$TAILSCALE_VERSION" ]] && return 0

  tailscale_temp_dir="$(mktemp -d)"
  trap 'rm -rf -- "$tailscale_temp_dir"' EXIT
  installer="$tailscale_temp_dir/install.sh"
  apt_get_shim="$tailscale_temp_dir/apt-get"
  real_apt_get="$(command -v apt-get || true)"
  [[ "$real_apt_get" == /* && -x "$real_apt_get" ]] || {
    echo 'Could not resolve the system apt-get executable.' >&2
    exit 24
  }

  download_verified "$TAILSCALE_INSTALLER_URL" "$TAILSCALE_INSTALLER_SHA256" "$installer"
  cat > "$apt_get_shim" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

real_apt_get="${HERDR_TAILSCALE_REAL_APT_GET:?}"
locked_version="${TAILSCALE_VERSION:?}"
args=("$@")
has_tailscale_package=0
for arg in "${args[@]}"; do
  case "$arg" in
    tailscale|tailscale=*) has_tailscale_package=1 ;;
  esac
done

if (( has_tailscale_package == 1 )); then
  if [[ "${#args[@]}" -eq 4 &&
        "${args[0]}" == 'install' &&
        "${args[1]}" == '-y' &&
        "${args[2]}" == "tailscale=$locked_version" &&
        "${args[3]}" == 'tailscale-archive-keyring' ]]; then
    exec "$real_apt_get" install --allow-downgrades -y "${args[2]}" "${args[3]}"
  fi
  echo 'Unexpected or unlocked Tailscale apt-get invocation.' >&2
  exit 24
fi

exec "$real_apt_get" "${args[@]}"
EOF
  chmod 0755 "$apt_get_shim"

  if sudo env \
    PATH="$tailscale_temp_dir:$PATH" \
    HERDR_TAILSCALE_REAL_APT_GET="$real_apt_get" \
    TAILSCALE_VERSION="$TAILSCALE_VERSION" \
    sh "$installer"; then
    installer_status=0
  else
    installer_status=$?
  fi
  (( installer_status == 0 )) || {
    echo "Tailscale installer failed with exit status $installer_status." >&2
    exit "$installer_status"
  }
  [[ "$(tailscale version | head -n 1)" == "$TAILSCALE_VERSION" ]] || {
    echo "Tailscale version does not match lock ($TAILSCALE_VERSION)." >&2
    exit 24
  }
)

install_python_toolchain() {
  local state_fd
  local bin_fd
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
  local uv_runtime_real
  local python_runtime_real
  validate_toolchain_lock || exit 22
  validate_platform || exit 20

  managed_root="$HOME/.local/lib/herdr-workstation"
  uv_parent="$managed_root/uv"
  python_parent="$managed_root/python"
  uv_dir="$uv_parent/$UV_VERSION/$UV_PLATFORM"
  python_dir="$python_parent/$PYTHON_VERSION-$PYTHON_RELEASE-$PYTHON_PLATFORM"
  validate_managed_paths \
    "$state_dir" "$bin_dir" "$managed_root" "$uv_parent" "$python_parent" \
    "$uv_dir" "$uv_dir/uv" "$python_dir" "$python_dir/bin" "$python_dir/bin/python3.13" || {
      echo 'Managed Python toolchain paths are unsafe.' >&2
      exit 24
    }
  fence_open_directory "$state_dir" state_fd
  fence_open_directory "$bin_dir" bin_fd
  fence_require_directory "$state_dir" "$state_fd" 'toolchain state directory'
  fence_require_directory "$bin_dir" "$bin_fd" 'toolchain bin directory'
  bootstrap_test_pause before-toolchain-directory-mutations
  fence_open_directory "$uv_parent" uv_parent_fd
  uv_parent_anchor="/proc/self/fd/$uv_parent_fd"
  fence_open_directory "$uv_parent/$UV_VERSION" uv_version_parent_fd
  fence_open_directory "$python_parent" python_parent_fd
  python_parent_anchor="/proc/self/fd/$python_parent_fd"

  if [[ ! -x "$uv_dir/uv" ]] || ! check_uv_version "$uv_dir/uv"; then
    uv_archive="$(mktemp --suffix=.tar.gz)"
    uv_stage="$(mktemp -d)"
    download_verified "$UV_URL" "$UV_SHA256" "$uv_archive"
    tar -xzf "$uv_archive" -C "$uv_stage"
    mapfile -t uv_candidates < <(find "$uv_stage" -type f -name uv -perm -u+x -print)
    if (( ${#uv_candidates[@]} != 1 )); then
      echo 'The pinned uv archive did not contain exactly one executable uv.' >&2
      exit 24
    fi
    check_uv_version "${uv_candidates[0]}" || {
      echo "uv artifact version does not match the lock ($UV_VERSION)." >&2
      exit 24
    }
    fence_require_directory "$uv_parent" "$uv_parent_fd" 'uv parent'
    uv_install_stage="$(mktemp -d "$uv_parent_anchor/.install.XXXXXX")"
    install -m 0755 "${uv_candidates[0]}" "$uv_install_stage/uv"
    fence_open_parent "$uv_dir" uv_dir_fd uv_dir_anchor uv_dir_parent "$uv_version_parent_fd"
    bootstrap_test_pause before-uv-publish
    fence_require_parent "$uv_dir_parent" "$uv_dir_fd" 'uv destination parent'
    [[ ! -L "$uv_dir_anchor" ]] || { echo 'Unsafe uv managed destination symlink.' >&2; exit 24; }
    if [[ -e "$uv_dir_anchor" ]]; then rm -rf -- "$uv_dir_anchor"; fi
    mv -T -- "$uv_install_stage" "$uv_dir_anchor"
    fence_require_parent "$uv_dir_parent" "$uv_dir_fd" 'uv destination parent'
    close_fence_fd "$uv_dir_fd"
    rm -rf -- "$uv_stage"
    rm -f -- "$uv_archive"
  fi

  if [[ ! -x "$python_dir/bin/python3.13" ]] || ! check_python_version "$python_dir/bin/python3.13" || ! check_python_platform "$python_dir/bin/python3.13"; then
    python_archive="$(mktemp --suffix=.tar.gz)"
    python_stage="$(mktemp -d)"
    download_verified "$PYTHON_URL" "$PYTHON_SHA256" "$python_archive"
    tar -xzf "$python_archive" -C "$python_stage"
    mapfile -t python_candidates < <(find "$python_stage" -type f -path '*/bin/python3.13' -perm -u+x -print)
    if (( ${#python_candidates[@]} != 1 )); then
      echo 'The pinned CPython archive did not contain exactly one executable python3.13.' >&2
      exit 24
    fi
    check_python_version "${python_candidates[0]}" && check_python_platform "${python_candidates[0]}" || {
      echo "CPython artifact does not match the lock ($PYTHON_VERSION, $PYTHON_PLATFORM)." >&2
      exit 24
    }
    python_source_root="$(cd "$(dirname "${python_candidates[0]}")/.." && pwd)"
    fence_require_directory "$python_parent" "$python_parent_fd" 'Python parent'
    python_install_stage="$(mktemp -d "$python_parent_anchor/.install.XXXXXX")"
    cp -a "$python_source_root"/. "$python_install_stage"/
    check_python_version "$python_install_stage/bin/python3.13" && check_python_platform "$python_install_stage/bin/python3.13" || {
      echo 'Staged CPython runtime failed its exact version/platform check.' >&2
      exit 24
    }
    fence_open_parent "$python_dir" python_dir_fd python_dir_anchor python_dir_parent "$python_parent_fd"
    bootstrap_test_pause before-python-publish
    fence_require_parent "$python_dir_parent" "$python_dir_fd" 'Python destination parent'
    [[ ! -L "$python_dir_anchor" ]] || { echo 'Unsafe Python managed destination symlink.' >&2; exit 24; }
    if [[ -e "$python_dir_anchor" ]]; then rm -rf -- "$python_dir_anchor"; fi
    mv -T -- "$python_install_stage" "$python_dir_anchor"
    fence_require_parent "$python_dir_parent" "$python_dir_fd" 'Python destination parent'
    close_fence_fd "$python_dir_fd"
    rm -rf -- "$python_stage"
    rm -f -- "$python_archive"
  fi

  uv_runtime_real="$(realpath -e -- "$uv_dir/uv" 2>/dev/null || true)"
  python_runtime_real="$(realpath -e -- "$python_dir/bin/python3.13" 2>/dev/null || true)"
  path_is_under "$uv_runtime_real" "$home_real" || { echo 'uv runtime escaped the managed HOME.' >&2; exit 24; }
  path_is_under "$python_runtime_real" "$home_real" || { echo 'Python runtime escaped the managed HOME.' >&2; exit 24; }
  fence_replace_link "$uv_runtime_real" "$bin_dir/uv" before-uv-link-publish "$bin_fd"
  fence_replace_link "$python_runtime_real" "$bin_dir/python3.13" before-python-link-publish "$bin_fd"
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

install_base() {
  local state_fd
  local bin_fd
  local state_anchor
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
  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    apt-transport-https build-essential ca-certificates cifs-utils curl git git-lfs gh gnupg jq mosh \
    openssh-client openssh-server pkg-config ripgrep rsync unzip zip
  git lfs install

  if [[ "$(ps -p 1 -o comm=)" != "systemd" ]]; then
    echo 'PID 1 is not systemd. This bootstrap expects a normal Ubuntu VM boot.' >&2
    exit 21
  fi

  installed_pwsh="$(pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>/dev/null || true)"
  if [[ "$installed_pwsh" != "$POWERSHELL_VERSION" ]]; then
    package="$(mktemp --suffix=.deb)"
    download_verified "$POWERSHELL_URL" "$POWERSHELL_SHA256" "$package"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$package"
    rm -f "$package"
  fi
  [[ "$(pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')" == "$POWERSHELL_VERSION" ]] || {
    echo 'PowerShell version does not match lock.' >&2; exit 24;
  }

  sudo systemctl enable --now ssh
  install_locked_tailscale
  sudo systemctl enable --now tailscaled
  fence_require_directory "$state_dir" "$state_fd" 'base state directory'
  : > "$state_anchor/base-complete"
  fence_require_directory "$state_dir" "$state_fd" 'base state directory'
  close_fence_fd "$state_fd"
  close_fence_fd "$bin_fd"
}

install_tools() {
  local state_fd
  local bin_fd
  local state_anchor
  local src_fd
  local src_anchor
  local profile_dir_fd
  local profile_dir_anchor
  local node_fd
  local node_anchor
  local code_fd
  local manifest_tmp
  profile_dir="$HOME/.config/herdr-workstation"
  node_dir="$HOME/.local/lib/node-v${NODE_VERSION}-linux-x64"
  validate_managed_paths \
    "$state_dir" "$state_dir/base-complete" "$state_dir/toolchain-manifest.txt" \
    "$bin_dir" "$profile_dir" "$profile_dir/profile.sh" "$node_dir" "$node_dir/bin" "$HOME/src" \
    "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.bash_login" || {
      echo 'Managed bootstrap paths are unsafe.' >&2
      exit 24
    }
  fence_open_directory "$state_dir" state_fd
  fence_open_directory "$bin_dir" bin_fd
  fence_open_directory "$profile_dir" profile_dir_fd
  fence_open_directory "$HOME/src" src_fd
  fence_open_directory "$node_dir" node_fd
  fence_open_directory "$HOME/code" code_fd
  state_anchor="/proc/self/fd/$state_fd"
  src_anchor="/proc/self/fd/$src_fd"
  profile_dir_anchor="/proc/self/fd/$profile_dir_fd"
  node_anchor="/proc/self/fd/$node_fd"
  fence_require_directory "$state_dir" "$state_fd" 'tools state directory'
  fence_require_directory "$bin_dir" "$bin_fd" 'tools bin directory'
  fence_require_directory "$profile_dir" "$profile_dir_fd" 'profile directory'
  fence_require_directory "$HOME/src" "$src_fd" 'source directory'
  fence_require_directory "$node_dir" "$node_fd" 'Node directory'
  bootstrap_test_pause before-tools-directory-mutations
  if [[ "$(ps -p 1 -o comm=)" != "systemd" ]]; then
    echo 'systemd is required before the tools phase.' >&2
    exit 21
  fi

  installed_rustup="$(rustup --version 2>/dev/null | awk 'NR == 1 { print $1 " " $2 }' || true)"
  if [[ "$installed_rustup" != "rustup $RUSTUP_VERSION" ]]; then
    rustup_temp_dir="$(mktemp -d)"
    # rustup-init dispatches by argv[0], so its executable basename must remain exact.
    rustup_init="$rustup_temp_dir/rustup-init"
    download_verified "$RUSTUP_INIT_URL" "$RUSTUP_INIT_SHA256" "$rustup_init"
    chmod 0700 "$rustup_init"
    "$rustup_init" -y --no-modify-path --profile minimal --default-toolchain "$RUST_TOOLCHAIN"
    rm -rf "$rustup_temp_dir"
  fi
  if [[ -f "$HOME/.cargo/env" ]]; then
    # shellcheck disable=SC1091
    source "$HOME/.cargo/env"
  fi
  command -v rustup >/dev/null 2>&1 && command -v cargo >/dev/null 2>&1 || {
    echo 'The locked rustup is present but rustup/cargo are not both discoverable. Use the default ~/.cargo layout or set CARGO_HOME before retrying.' >&2
    exit 24
  }
  rustup set auto-self-update disable
  [[ "$(rustup --version | awk 'NR == 1 { print $1 " " $2 }')" == "rustup $RUSTUP_VERSION" ]] || {
    echo "rustup version does not match lock after reinstall ($RUSTUP_VERSION)." >&2; exit 24;
  }
  rustup toolchain install "$RUST_TOOLCHAIN" --profile minimal
  rustup default "$RUST_TOOLCHAIN"
  [[ "$(rustup --version | awk 'NR == 1 { print $1 " " $2 }')" == "rustup $RUSTUP_VERSION" ]] || {
    echo "rustup version changed after toolchain installation ($RUSTUP_VERSION)." >&2; exit 24;
  }

  fence_require_directory "$HOME/src" "$src_fd" 'source directory'
  if [[ ! -d "$src_anchor/rtk/.git" ]]; then
    git clone "$RTK_REPO_URL" "$src_anchor/rtk"
  fi
  fence_require_directory "$HOME/src" "$src_fd" 'source directory'
  git -C "$src_anchor/rtk" remote set-url origin "$RTK_REPO_URL"
  git -C "$src_anchor/rtk" fetch --force origin "$RTK_REF"
  git -C "$src_anchor/rtk" checkout --detach "$RTK_REF"
  [[ "$(git -C "$src_anchor/rtk" rev-parse HEAD)" == "$RTK_REF" ]] || {
    echo 'RTK checkout does not match the locked commit.' >&2; exit 24;
  }
  cargo install --path "$src_anchor/rtk" --locked --force
  for executable in rustup cargo rustc; do
    executable_path="$(command -v "$executable")"
    fence_replace_link "$executable_path" "$bin_dir/$executable" "before-$executable-link-publish" "$bin_fd"
  done
  cargo_home="${CARGO_HOME:-$HOME/.cargo}"
  cargo_install_root="${CARGO_INSTALL_ROOT:-$cargo_home}"
  [[ -x "$cargo_install_root/bin/rtk" ]] || {
    echo "cargo installed RTK outside the expected '$cargo_install_root/bin' directory. Set CARGO_INSTALL_ROOT explicitly and retry." >&2
    exit 24
  }
  fence_replace_link "$cargo_install_root/bin/rtk" "$bin_dir/rtk" before-rtk-link-publish "$bin_fd"

  profile_script_tmp="$(mktemp)"
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
  export PATH="$bin_dir:$node_anchor/bin:$HOME/.cargo/bin:$PATH"
  hash -r
  [[ "$(node --version)" == "v$NODE_VERSION" ]] || { echo 'Node version does not match lock.' >&2; exit 24; }

  "$node_anchor/bin/npm" install --global --save-exact --prefix "$node_anchor" \
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
  download_verified "$HERDR_URL" "$HERDR_SHA256" "$herdr_temp"
  fence_replace_file "$herdr_temp" "$bin_dir/herdr" 0755 before-herdr-publish "$bin_fd"
  herdr_temp=''

  [[ "$(codex --version | awk '{ print $NF }')" == "$CODEX_VERSION" ]] || { echo 'Codex version does not match lock.' >&2; exit 24; }
  [[ "$(claude --version | awk '{ print $1 }')" == "$CLAUDE_VERSION" ]] || { echo 'Claude version does not match lock.' >&2; exit 24; }
  [[ "$(bun --version)" == "$BUN_VERSION" ]] || { echo 'Bun version does not match lock.' >&2; exit 24; }
  [[ "$(herdr --version | awk '{ print $NF }')" == "$HERDR_VERSION" ]] || { echo 'Herdr version does not match lock.' >&2; exit 24; }

  manifest="$state_dir/toolchain-manifest.txt"
  manifest_tmp="$(mktemp "$state_anchor/.toolchain-manifest.XXXXXX")"
  {
    printf 'receipt_format=%s\n' 'issue-961-toolchain-v2'
    printf 'lock_sha256=%s\n' "$(sha256sum "$lock_file" | awk '{print $1}')"
    printf 'host_platform=%s\n' 'linux'
    printf 'host_architecture=%s\n' "$(uname -m)"
    printf 'uv_path=%s\n' "$bin_dir/uv"
    printf 'python3.13_path=%s\n' "$bin_dir/python3.13"
    printf 'py_path=%s\n' "$bin_dir/py"
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
    printf 'tailscale=%s\n' "$(tailscale version | head -n 1)"
    printf 'rustup=%s\n' "$(rustup --version | head -n 1)"
    printf 'rustc=%s\n' "$(rustc --version)"
    printf 'node=%s\n' "$(node --version)"
    printf 'npm=%s\n' "$(npm --version)"
    printf 'codex=%s\n' "$(codex --version)"
    printf 'claude=%s\n' "$(claude --version)"
    printf 'bun=%s\n' "$(bun --version)"
    printf 'herdr=%s\n' "$(herdr --version)"
    printf 'powershell=%s\n' "$(pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')"
    dpkg-query -W -f='apt:${binary:Package}=${Version}\n' \
      cifs-utils curl git git-lfs gh jq mosh openssh-client openssh-server ripgrep rsync
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
  close_fence_fd "$src_fd"
  close_fence_fd "$node_fd"
  close_fence_fd "$code_fd"
  echo "Tool installation complete. Resolved manifest: $manifest"
  echo "The tools are available immediately through $bin_dir. The managed .profile hook, plus any pre-existing .bash_profile or .bash_login chain, makes them available in new Bash login shells."
  echo 'Authentication, Tailscale login, SMB credentials, and Herdr integration validation remain manual.'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "$phase" in
    base) install_base ;;
    validate-lock) validate_toolchain_lock; echo 'Ubuntu toolchain lock validation passed.' ;;
    tools) install_tools ;;
    all) install_base; install_tools ;;
    *) echo "Unsupported phase: $phase" >&2; exit 2 ;;
  esac
fi
