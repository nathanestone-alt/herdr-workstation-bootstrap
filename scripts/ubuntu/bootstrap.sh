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
  local wrapper="$bin_dir/py"
  local replacement
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
  if ! cmp -s "$replacement" "$wrapper" 2>/dev/null; then
    install -m 0755 "$replacement" "$wrapper"
  fi
  rm -f "$replacement"
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

install_python_toolchain() {
  validate_toolchain_lock || exit 22
  validate_platform || exit 20
  mkdir -p "$state_dir" "$bin_dir"

  managed_root="$HOME/.local/lib/herdr-workstation"
  uv_parent="$managed_root/uv"
  python_parent="$managed_root/python"
  uv_dir="$uv_parent/$UV_VERSION/$UV_PLATFORM"
  python_dir="$python_parent/$PYTHON_VERSION-$PYTHON_RELEASE-$PYTHON_PLATFORM"
  mkdir -p "$uv_parent/$UV_VERSION" "$python_parent"

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
    uv_install_stage="$(mktemp -d "$uv_parent/.install.XXXXXX")"
    install -m 0755 "${uv_candidates[0]}" "$uv_install_stage/uv"
    [[ "$uv_dir" == "$managed_root/"* ]] || { echo 'Unsafe uv managed path.' >&2; exit 24; }
    if [[ -e "$uv_dir" || -L "$uv_dir" ]]; then rm -rf -- "$uv_dir"; fi
    mv -- "$uv_install_stage" "$uv_dir"
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
    python_install_stage="$(mktemp -d "$python_parent/.install.XXXXXX")"
    cp -a "$python_source_root"/. "$python_install_stage"/
    check_python_version "$python_install_stage/bin/python3.13" && check_python_platform "$python_install_stage/bin/python3.13" || {
      echo 'Staged CPython runtime failed its exact version/platform check.' >&2
      exit 24
    }
    [[ "$python_dir" == "$managed_root/"* ]] || { echo 'Unsafe Python managed path.' >&2; exit 24; }
    if [[ -e "$python_dir" || -L "$python_dir" ]]; then rm -rf -- "$python_dir"; fi
    mv -- "$python_install_stage" "$python_dir"
    rm -rf -- "$python_stage"
    rm -f -- "$python_archive"
  fi

  for managed_link in "$bin_dir/uv" "$bin_dir/python3.13"; do
    if [[ -e "$managed_link" && ! -L "$managed_link" ]]; then
      echo "Refusing to replace non-managed path: $managed_link" >&2
      exit 24
    fi
  done
  ln -sfn "$uv_dir/uv" "$bin_dir/uv"
  ln -sfn "$python_dir/bin/python3.13" "$bin_dir/python3.13"
  write_py_compat
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
}

converge_profile_hook() {
  local profile_file="$1"
  local chain_profile="${2:-false}"
  local marker='# BEGIN herdr-workstation PATH'
  local end_marker='# END herdr-workstation PATH'
  local replacement
  replacement="$(mktemp)"
  touch "$profile_file"
  mapfile -t begin_lines < <(grep -nFx "$marker" "$profile_file" | cut -d: -f1)
  mapfile -t end_lines < <(grep -nFx "$end_marker" "$profile_file" | cut -d: -f1)
  if (( ${#begin_lines[@]} == 0 && ${#end_lines[@]} == 0 )); then
    cp "$profile_file" "$replacement"
  elif (( ${#begin_lines[@]} == 1 && ${#end_lines[@]} == 1 && begin_lines[0] < end_lines[0] )); then
    begin="${begin_lines[0]}"
    end="${end_lines[0]}"
    remove_start="$begin"
    if (( begin > 1 )) && [[ -z "$(sed -n "$((begin - 1))p" "$profile_file")" ]]; then
      remove_start=$((begin - 1))
    fi
    if (( remove_start > 1 )); then head -n "$((remove_start - 1))" "$profile_file" > "$replacement"; fi
    tail -n "+$((end + 1))" "$profile_file" >> "$replacement"
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
  if ! cmp -s "$profile_file" "$replacement"; then
    cp "$profile_file" "$profile_file.$(date +%Y%m%d-%H%M%S)-$$.bak"
    install -m 0644 "$replacement" "$profile_file"
  fi
  rm -f "$replacement"
}

install_base() {
  mkdir -p "$state_dir" "$bin_dir"
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
  installed_tailscale="$(tailscale version 2>/dev/null | head -n 1 || true)"
  if [[ "$installed_tailscale" != "$TAILSCALE_VERSION" ]]; then
    installer="$(mktemp)"
    download_verified "$TAILSCALE_INSTALLER_URL" "$TAILSCALE_INSTALLER_SHA256" "$installer"
    sudo env TAILSCALE_VERSION="$TAILSCALE_VERSION" sh "$installer"
    rm -f "$installer"
  fi
  [[ "$(tailscale version | head -n 1)" == "$TAILSCALE_VERSION" ]] || {
    echo "Tailscale version does not match lock ($TAILSCALE_VERSION)." >&2; exit 24;
  }
  sudo systemctl enable --now tailscaled
  touch "$state_dir/base-complete"
}

install_tools() {
  mkdir -p "$state_dir" "$bin_dir"
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

  mkdir -p "$HOME/src"
  if [[ ! -d "$HOME/src/rtk/.git" ]]; then
    git clone "$RTK_REPO_URL" "$HOME/src/rtk"
  fi
  git -C "$HOME/src/rtk" remote set-url origin "$RTK_REPO_URL"
  git -C "$HOME/src/rtk" fetch --force origin "$RTK_REF"
  git -C "$HOME/src/rtk" checkout --detach "$RTK_REF"
  [[ "$(git -C "$HOME/src/rtk" rev-parse HEAD)" == "$RTK_REF" ]] || {
    echo 'RTK checkout does not match the locked commit.' >&2; exit 24;
  }
  cargo install --path "$HOME/src/rtk" --locked --force
  for executable in rustup cargo rustc; do
    executable_path="$(command -v "$executable")"
    ln -sfn "$executable_path" "$bin_dir/$executable"
  done
  cargo_home="${CARGO_HOME:-$HOME/.cargo}"
  cargo_install_root="${CARGO_INSTALL_ROOT:-$cargo_home}"
  [[ -x "$cargo_install_root/bin/rtk" ]] || {
    echo "cargo installed RTK outside the expected '$cargo_install_root/bin' directory. Set CARGO_INSTALL_ROOT explicitly and retry." >&2
    exit 24
  }
  ln -sfn "$cargo_install_root/bin/rtk" "$bin_dir/rtk"

  profile_dir="$HOME/.config/herdr-workstation"
  mkdir -p "$profile_dir"
  profile_script_tmp="$(mktemp)"
  {
    printf '%s\n' '# Managed by herdr-workstation-bootstrap.'
    printf '%s\n' 'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac'
    printf '%s\n' 'case ":$PATH:" in *":$HOME/.cargo/bin:"*) ;; *) PATH="$HOME/.cargo/bin:$PATH" ;; esac'
    printf '%s\n' 'export PATH'
  } > "$profile_script_tmp"
  install -m 0644 "$profile_script_tmp" "$profile_dir/profile.sh"
  rm -f "$profile_script_tmp"
  converge_profile_hook "$HOME/.profile"
  if [[ -e "$HOME/.bash_profile" ]]; then
    converge_profile_hook "$HOME/.bash_profile" true
  fi
  if [[ -e "$HOME/.bash_login" ]]; then
    converge_profile_hook "$HOME/.bash_login" true
  fi

  install_python_toolchain

  node_dir="$HOME/.local/lib/node-v${NODE_VERSION}-linux-x64"
  if [[ ! -x "$node_dir/bin/node" ]]; then
    archive="$(mktemp --suffix=.tar.gz)"
    download_verified "$NODE_URL" "$NODE_SHA256" "$archive"
    mkdir -p "$node_dir"
    tar -xzf "$archive" -C "$node_dir" --strip-components=1
    rm -f "$archive"
  fi
  for executable in node npm npx corepack; do
    ln -sfn "$node_dir/bin/$executable" "$bin_dir/$executable"
  done
  export PATH="$bin_dir:$node_dir/bin:$HOME/.cargo/bin:$PATH"
  hash -r
  [[ "$(node --version)" == "v$NODE_VERSION" ]] || { echo 'Node version does not match lock.' >&2; exit 24; }

  "$node_dir/bin/npm" install --global --save-exact --prefix "$node_dir" \
    "@openai/codex@$CODEX_VERSION" \
    "@anthropic-ai/claude-code@$CLAUDE_VERSION" \
    "bun@$BUN_VERSION"
  for package_dir in '@openai/codex' '@anthropic-ai/claude-code' bun; do
    [[ -d "$node_dir/lib/node_modules/$package_dir" ]] || {
      echo "npm did not install '$package_dir' under the pinned Node prefix '$node_dir'." >&2
      exit 24
    }
  done
  for executable in codex claude bun bunx; do
    ln -sfn "$node_dir/bin/$executable" "$bin_dir/$executable"
  done

  herdr_temp="$(mktemp)"
  download_verified "$HERDR_URL" "$HERDR_SHA256" "$herdr_temp"
  install -m 0755 "$herdr_temp" "$bin_dir/herdr"
  rm -f "$herdr_temp"

  [[ "$(codex --version | awk '{ print $NF }')" == "$CODEX_VERSION" ]] || { echo 'Codex version does not match lock.' >&2; exit 24; }
  [[ "$(claude --version | awk '{ print $1 }')" == "$CLAUDE_VERSION" ]] || { echo 'Claude version does not match lock.' >&2; exit 24; }
  [[ "$(bun --version)" == "$BUN_VERSION" ]] || { echo 'Bun version does not match lock.' >&2; exit 24; }
  [[ "$(herdr --version | awk '{ print $NF }')" == "$HERDR_VERSION" ]] || { echo 'Herdr version does not match lock.' >&2; exit 24; }

  manifest="$state_dir/toolchain-manifest.txt"
  {
    printf 'lock_sha256=%s\n' "$(sha256sum "$lock_file" | awk '{print $1}')"
    printf 'uv_version=%s\n' "$("$bin_dir/uv" --version)"
    printf 'python3.13_version=%s\n' "$("$bin_dir/python3.13" --version 2>&1)"
    printf 'py_3.13_version=%s\n' "$("$bin_dir/py" -3.13 --version 2>&1)"
    printf 'py_3.13_probe=%s\n' "$("$bin_dir/py" -3.13 -c 'import platform, sys; print(f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}|{platform.machine()}|{sys.platform}")')"
    printf 'uv_platform=%s\n' "$UV_PLATFORM"
    printf 'python_platform=%s\n' "$PYTHON_PLATFORM"
    printf 'python_release=%s\n' "$PYTHON_RELEASE"
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
  } > "$manifest.tmp"
  mv "$manifest.tmp" "$manifest"

  mkdir -p "$HOME/code"
  touch "$state_dir/tools-complete"
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
