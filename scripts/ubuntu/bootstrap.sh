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
mkdir -p "$state_dir" "$bin_dir"

[[ -f "$lock_file" ]] || { echo "Missing toolchain lock: $lock_file" >&2; exit 22; }
# shellcheck disable=SC1090
source "$lock_file"
required_lock_keys=(
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
for key in POWERSHELL_SHA256 TAILSCALE_INSTALLER_SHA256 RUSTUP_INIT_SHA256 NODE_SHA256 HERDR_SHA256; do
  [[ "${!key}" =~ ^[0-9a-f]{64}$ ]] || { echo "Lock key '$key' is not a lowercase SHA-256 value." >&2; exit 22; }
done

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

install_base() {
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
  if [[ "$(ps -p 1 -o comm=)" != "systemd" ]]; then
    echo 'systemd is required before the tools phase.' >&2
    exit 21
  fi

  if ! command -v rustup >/dev/null 2>&1; then
    rustup_init="$(mktemp)"
    download_verified "$RUSTUP_INIT_URL" "$RUSTUP_INIT_SHA256" "$rustup_init"
    chmod 0700 "$rustup_init"
    "$rustup_init" -y --no-modify-path --profile minimal --default-toolchain "$RUST_TOOLCHAIN"
    rm -f "$rustup_init"
  fi
  # shellcheck disable=SC1091
  source "$HOME/.cargo/env"
  rustup --version | grep -Fq "$RUSTUP_VERSION" || { echo 'rustup version does not match lock.' >&2; exit 24; }
  rustup toolchain install "$RUST_TOOLCHAIN" --profile minimal
  rustup default "$RUST_TOOLCHAIN"

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

  "$node_dir/bin/npm" install --global --save-exact \
    "@openai/codex@$CODEX_VERSION" \
    "@anthropic-ai/claude-code@$CLAUDE_VERSION" \
    "bun@$BUN_VERSION"
  for executable in codex claude bun bunx; do
    ln -sfn "$node_dir/bin/$executable" "$bin_dir/$executable"
  done

  herdr_temp="$(mktemp)"
  download_verified "$HERDR_URL" "$HERDR_SHA256" "$herdr_temp"
  install -m 0755 "$herdr_temp" "$bin_dir/herdr"
  rm -f "$herdr_temp"

  codex --version | grep -Fq "$CODEX_VERSION" || { echo 'Codex version does not match lock.' >&2; exit 24; }
  claude --version | grep -Fq "$CLAUDE_VERSION" || { echo 'Claude version does not match lock.' >&2; exit 24; }
  bun --version | grep -Fxq "$BUN_VERSION" || { echo 'Bun version does not match lock.' >&2; exit 24; }
  herdr --version | grep -Fq "$HERDR_VERSION" || { echo 'Herdr version does not match lock.' >&2; exit 24; }

  manifest="$state_dir/toolchain-manifest.txt"
  {
    printf 'lock_sha256=%s\n' "$(sha256sum "$lock_file" | awk '{print $1}')"
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
  echo 'Authentication, Tailscale login, SMB credentials, and Herdr integration validation remain manual.'
}

case "$phase" in
  base) install_base ;;
  tools) install_tools ;;
  all) install_base; install_tools ;;
  *) echo "Unsupported phase: $phase" >&2; exit 2 ;;
esac
