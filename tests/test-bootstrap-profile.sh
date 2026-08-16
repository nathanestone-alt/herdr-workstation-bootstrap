#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
export HOME="$test_root/home"
mkdir -p "$HOME/.config/herdr-workstation"
printf 'export PATH="$HOME/.local/bin:$PATH"\n' > "$HOME/.config/herdr-workstation/profile.sh"
printf 'export HERDR_BASHRC_CHAINED=1\n' > "$HOME/.bashrc"
printf '[[ -f "$HOME/.bashrc" ]] && . "$HOME/.bashrc"\n' > "$HOME/.profile"

# Source the production function without executing a bootstrap phase.
# shellcheck disable=SC1091
source "$repo_root/scripts/ubuntu/bootstrap.sh"
converge_profile_hook "$HOME/.profile"
[[ ! -e "$HOME/.bash_profile" ]] || {
  echo 'Bootstrap created .bash_profile and shadowed the stock .profile chain.' >&2
  exit 1
}
[[ ! -e "$HOME/.bash_login" ]] || {
  echo 'Bootstrap created .bash_login and shadowed the stock .profile chain.' >&2
  exit 1
}
/bin/bash --noprofile --norc -c '. "$HOME/.profile"; [[ "$HERDR_BASHRC_CHAINED" == 1 ]]; [[ ":$PATH:" == *":$HOME/.local/bin:"* ]]'

printf 'export HERDR_BASH_PROFILE_PRESERVED=1\n' > "$HOME/.bash_profile"
converge_profile_hook "$HOME/.bash_profile" true
before="$(sha256sum "$HOME/.bash_profile" | awk '{print $1}')"
converge_profile_hook "$HOME/.bash_profile" true
after="$(sha256sum "$HOME/.bash_profile" | awk '{print $1}')"
[[ "$before" == "$after" ]] || { echo '.bash_profile convergence is not byte-idempotent.' >&2; exit 1; }
/bin/bash --noprofile --norc -c '. "$HOME/.bash_profile"; [[ "$HERDR_BASH_PROFILE_PRESERVED" == 1 ]]; [[ "$HERDR_BASHRC_CHAINED" == 1 ]]'

rm -f "$HOME/.bash_profile"
printf 'export HERDR_BASH_LOGIN_PRESERVED=1\n' > "$HOME/.bash_login"
converge_profile_hook "$HOME/.bash_login" true
before="$(sha256sum "$HOME/.bash_login" | awk '{print $1}')"
converge_profile_hook "$HOME/.bash_login" true
after="$(sha256sum "$HOME/.bash_login" | awk '{print $1}')"
[[ "$before" == "$after" ]] || { echo '.bash_login convergence is not byte-idempotent.' >&2; exit 1; }
/bin/bash --noprofile --norc -c '. "$HOME/.bash_login"; [[ "$HERDR_BASH_LOGIN_PRESERVED" == 1 ]]; [[ "$HERDR_BASHRC_CHAINED" == 1 ]]'

echo 'bootstrap profile-chain regression tests passed.'
