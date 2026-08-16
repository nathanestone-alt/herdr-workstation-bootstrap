#!/usr/bin/env bash
set -euo pipefail

phase="all"
install_node="${INSTALL_NODE:-1}"
rtk_repo_url="${RTK_REPO_URL:-https://github.com/nathanestone-alt/rtk.git}"
rtk_ref="${RTK_REF:-c1819ceff1ab8d75b88c1ff7a63f497914e8fe99}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase) phase="$2"; shift 2 ;;
    --no-node) install_node=0; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
state_dir="${HOME}/.local/state/herdr-workstation-bootstrap"
mkdir -p "$state_dir"

install_base() {
  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    apt-transport-https build-essential ca-certificates cifs-utils curl git git-lfs gh gnupg jq mosh \
    openssh-client openssh-server pkg-config ripgrep rsync unzip zip
  git lfs install

  if [[ "$(ps -p 1 -o comm=)" != "systemd" ]]; then
    echo "PID 1 is not systemd. This bootstrap expects a normal Ubuntu VM boot." >&2
    exit 21
  fi

  if ! command -v pwsh >/dev/null 2>&1; then
    source /etc/os-release
    package="packages-microsoft-prod.deb"
    curl -fsSLo "$package" "https://packages.microsoft.com/config/ubuntu/${VERSION_ID}/packages-microsoft-prod.deb"
    sudo dpkg -i "$package"
    rm -f "$package"
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y powershell
  fi

  sudo systemctl enable --now ssh
  if ! command -v tailscale >/dev/null 2>&1; then
    curl -fsSL https://tailscale.com/install.sh | sh
  fi
  sudo systemctl enable --now tailscaled
  touch "$state_dir/base-complete"
}

install_tools() {
  if [[ "$(ps -p 1 -o comm=)" != "systemd" ]]; then
    echo "systemd is required before the tools phase." >&2
    exit 21
  fi
  if ! command -v rustup >/dev/null 2>&1; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  fi
  # shellcheck disable=SC1091
  source "$HOME/.cargo/env"
  rustup default stable

  mkdir -p "$HOME/src"
  if [[ ! -d "$HOME/src/rtk/.git" ]]; then
    git clone "$rtk_repo_url" "$HOME/src/rtk"
  fi
  git -C "$HOME/src/rtk" fetch --all --tags --prune
  git -C "$HOME/src/rtk" checkout "$rtk_ref"
  git -C "$HOME/src/rtk" pull --ff-only || true
  cargo install --path "$HOME/src/rtk" --locked --force

  if ! command -v codex >/dev/null 2>&1; then
    curl -fsSL https://chatgpt.com/codex/install.sh | sh
  fi
  if ! command -v claude >/dev/null 2>&1; then
    curl -fsSL https://claude.ai/install.sh | bash
  fi
  if ! command -v herdr >/dev/null 2>&1; then
    curl -fsSL https://herdr.dev/install.sh | sh
  fi
  if ! command -v bun >/dev/null 2>&1; then
    curl -fsSL https://bun.sh/install | bash
  fi

  if [[ "$install_node" == "1" ]] && ! command -v fnm >/dev/null 2>&1; then
    curl -fsSL https://fnm.vercel.app/install | bash -s -- --skip-shell
  fi
  if [[ "$install_node" == "1" ]]; then
    export PATH="$HOME/.local/share/fnm:$PATH"
    eval "$(fnm env --shell bash)"
    fnm install 24
    fnm default 24
    fnm use 24
  fi
  mkdir -p "$HOME/code"
  touch "$state_dir/tools-complete"
  echo 'Tool installation complete. Authentication, Tailscale login, SMB credentials, and Herdr integration validation remain manual.'
}

case "$phase" in
  base) install_base ;;
  tools) install_tools ;;
  all) install_base; install_tools ;;
  *) echo "Unsupported phase: $phase" >&2; exit 2 ;;
esac
