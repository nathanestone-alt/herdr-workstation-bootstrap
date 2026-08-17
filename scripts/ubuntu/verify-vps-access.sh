#!/usr/bin/env bash
set -euo pipefail

alias_name="${1:-hostinger-vps}"
ssh_error="$(mktemp)"
trap 'rm -f "$ssh_error"' EXIT
if ! effective_config="$(ssh -G "$alias_name" 2>"$ssh_error")"; then
  echo "OpenSSH could not resolve alias '$alias_name'; VPS access was not attempted." >&2
  sed 's/^/ssh: /' "$ssh_error" >&2
  exit 20
fi
identity_file="$(awk '$1 == "identityfile" { $1=""; sub(/^[[:space:]]+/, ""); print; exit }' <<< "$effective_config")"
[[ -n "$identity_file" ]] || { echo "Alias '$alias_name' has no effective IdentityFile; rerun configure-vps-client.sh." >&2; exit 20; }
identity_file="${identity_file/#\~/$HOME}"
if [[ -z "${SSH_AUTH_SOCK:-}" ]] || ! ssh-add -l >/dev/null 2>&1; then
  echo "No usable ssh-agent identity is loaded. Run: eval \"\$(ssh-agent -s)\"; ssh-add '$identity_file'" >&2
  exit 20
fi
[[ -f "$identity_file.pub" ]] || {
  echo "Expected public key '$identity_file.pub' is missing; rerun configure-vps-client.sh." >&2
  exit 20
}
expected_public_key="$(awk 'NR == 1 { print $1 " " $2 }' "$identity_file.pub")"
if ! ssh-add -L 2>/dev/null | awk '{ print $1 " " $2 }' | grep -Fxq "$expected_public_key"; then
  echo "The configured identity is not loaded in ssh-agent. Run: ssh-add '$identity_file'" >&2
  exit 20
fi
echo "Testing non-interactive key authentication to $alias_name"
ssh -o BatchMode=yes -o ConnectTimeout=10 "$alias_name" \
  'printf "user=%s\nhost=%s\nkernel=%s\n" "$(id -un)" "$(hostname)" "$(uname -sr)"; uptime'
echo "PASS: SSH key access to $alias_name"
