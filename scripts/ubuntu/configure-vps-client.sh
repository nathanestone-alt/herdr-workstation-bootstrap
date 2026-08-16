#!/usr/bin/env bash
set -euo pipefail

alias_name=""
host_name=""
user_name=""
port="22"
key_path="$HOME/.ssh/hostinger_vps_ed25519"
existing_key=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --alias) alias_name="$2"; shift 2 ;;
    --host) host_name="$2"; shift 2 ;;
    --user) user_name="$2"; shift 2 ;;
    --port) port="$2"; shift 2 ;;
    --existing-key) existing_key="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$alias_name" || -z "$host_name" || -z "$user_name" ]]; then
  echo "Usage: $0 --alias NAME --host HOST --user USER [--port PORT] [--existing-key PATH]" >&2
  exit 2
fi
if [[ -n "$existing_key" ]]; then
  key_path="${existing_key/#\~/$HOME}"
fi

install -d -m 700 "$HOME/.ssh"
if [[ ! -f "$key_path" ]]; then
  echo "Generating $key_path. Enter a strong passphrase when prompted."
  ssh-keygen -t ed25519 -a 64 -f "$key_path" -C "herdr-workstation-to-hostinger-vps"
fi
if [[ ! -f "$key_path.pub" ]]; then
  ssh-keygen -y -f "$key_path" > "$key_path.pub"
  chmod 644 "$key_path.pub"
fi

config="$HOME/.ssh/config"
touch "$config"
chmod 600 "$config"
marker="# BEGIN herdr-bootstrap $alias_name"
if grep -Fq "$marker" "$config"; then
  echo "SSH alias '$alias_name' already exists in $config; no change made." >&2
else
  stamp="$(date +%Y%m%d-%H%M%S)"
  cp "$config" "$config.$stamp.bak"
  {
    printf '\n%s\n' "$marker"
    printf 'Host %s\n' "$alias_name"
    printf '  HostName %s\n' "$host_name"
    printf '  User %s\n' "$user_name"
    printf '  Port %s\n' "$port"
    printf '  IdentityFile %s\n' "$key_path"
    printf '  IdentitiesOnly yes\n'
    printf '  ServerAliveInterval 30\n'
    printf '  ServerAliveCountMax 3\n'
    printf '# END herdr-bootstrap %s\n' "$alias_name"
  } >> "$config"
fi

echo
echo 'Add this PUBLIC key to the intended Hostinger VPS account:'
cat "$key_path.pub"
echo
echo "After adding it, test with: ssh $alias_name"

