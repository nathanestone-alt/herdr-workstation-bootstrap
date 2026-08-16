#!/usr/bin/env bash
set -euo pipefail

alias_name=""
host_name=""
user_name=""
port="22"
key_path="$HOME/.ssh/hostinger_vps_ed25519"
existing_key=""
host_key_fingerprint=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --alias) alias_name="$2"; shift 2 ;;
    --host) host_name="$2"; shift 2 ;;
    --user) user_name="$2"; shift 2 ;;
    --port) port="$2"; shift 2 ;;
    --existing-key) existing_key="$2"; shift 2 ;;
    --host-key-fingerprint) host_key_fingerprint="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$alias_name" || -z "$host_name" || -z "$user_name" || -z "$host_key_fingerprint" ]]; then
  echo "Usage: $0 --alias NAME --host HOST --user USER --host-key-fingerprint SHA256:... [--port PORT] [--existing-key PATH]" >&2
  exit 2
fi
[[ "$alias_name" =~ ^[A-Za-z0-9._-]+$ ]] || { echo 'Alias contains unsupported characters.' >&2; exit 2; }
[[ "$host_name" != *[[:space:]]* ]] || { echo 'Host must not contain whitespace.' >&2; exit 2; }
[[ "$user_name" =~ ^[A-Za-z_][A-Za-z0-9._-]*$ ]] || { echo 'User contains unsupported characters.' >&2; exit 2; }
[[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || { echo 'Port must be 1-65535.' >&2; exit 2; }
[[ "$host_key_fingerprint" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]] || {
  echo 'Host-key fingerprint must be an independently verified SHA256: value.' >&2; exit 2;
}
if [[ -n "$existing_key" ]]; then
  key_path="${existing_key/#\~/$HOME}"
fi

install -d -m 700 "$HOME/.ssh"
if [[ ! -f "$key_path" ]]; then
  echo "Generating $key_path. Enter a strong passphrase when prompted."
  ssh-keygen -t ed25519 -a 64 -f "$key_path" -C 'herdr-workstation-to-hostinger-vps'
fi
if [[ ! -f "$key_path.pub" ]]; then
  ssh-keygen -y -f "$key_path" > "$key_path.pub"
  chmod 644 "$key_path.pub"
fi

scan_file="$(mktemp)"
desired_block="$(mktemp)"
current_block="$(mktemp)"
replacement="$(mktemp)"
trap 'rm -f "$scan_file" "$desired_block" "$current_block" "$replacement"' EXIT
ssh-keyscan -T 10 -p "$port" -t ed25519 "$host_name" > "$scan_file" 2>/dev/null || {
  echo "Could not retrieve the ED25519 host key from $host_name:$port." >&2; exit 25;
}
actual_fingerprint="$(ssh-keygen -lf "$scan_file" -E sha256 | awk 'NR == 1 { print $2 }')"
[[ "$actual_fingerprint" == "$host_key_fingerprint" ]] || {
  echo "Host-key mismatch for $host_name:$port (expected $host_key_fingerprint, received $actual_fingerprint)." >&2
  exit 25
}

known_hosts="$HOME/.ssh/known_hosts"
touch "$known_hosts"
chmod 600 "$known_hosts"
host_token="$host_name"
if [[ "$port" != "22" ]]; then
  host_token="[$host_name]:$port"
fi
existing_host_keys="$(ssh-keygen -F "$host_token" -f "$known_hosts" 2>/dev/null || true)"
if [[ -n "$existing_host_keys" ]]; then
  if ! printf '%s\n' "$existing_host_keys" | grep -v '^#' > "$current_block" || \
      ! ssh-keygen -lf "$current_block" -E sha256 | awk '{ print $2 }' | grep -Fxq "$host_key_fingerprint"; then
    echo "Existing known_hosts entry for $host_token does not match the verified fingerprint. Resolve it manually." >&2
    exit 25
  fi
else
  cat "$scan_file" >> "$known_hosts"
fi

config="$HOME/.ssh/config"
touch "$config"
chmod 600 "$config"
marker="# BEGIN herdr-bootstrap $alias_name"
end_marker="# END herdr-bootstrap $alias_name"
{
  printf '%s\n' "$marker"
  printf 'Host %s\n' "$alias_name"
  printf '  HostName %s\n' "$host_name"
  printf '  User %s\n' "$user_name"
  printf '  Port %s\n' "$port"
  printf '  IdentityFile %s\n' "$key_path"
  printf '  IdentitiesOnly yes\n'
  printf '  StrictHostKeyChecking yes\n'
  printf '  UserKnownHostsFile ~/.ssh/known_hosts\n'
  printf '  ServerAliveInterval 30\n'
  printf '  ServerAliveCountMax 3\n'
  printf '%s\n' "$end_marker"
} > "$desired_block"

mapfile -t begin_lines < <(grep -nFx "$marker" "$config" | cut -d: -f1)
mapfile -t end_lines < <(grep -nFx "$end_marker" "$config" | cut -d: -f1)
if (( ${#begin_lines[@]} == 0 && ${#end_lines[@]} == 0 )); then
  stamp="$(date +%Y%m%d-%H%M%S)-$$"
  cp "$config" "$config.$stamp.bak"
  if [[ -s "$config" ]]; then printf '\n' >> "$config"; fi
  cat "$desired_block" >> "$config"
elif (( ${#begin_lines[@]} == 1 && ${#end_lines[@]} == 1 && begin_lines[0] < end_lines[0] )); then
  begin="${begin_lines[0]}"
  end="${end_lines[0]}"
  sed -n "${begin},${end}p" "$config" > "$current_block"
  if ! cmp -s "$current_block" "$desired_block"; then
    stamp="$(date +%Y%m%d-%H%M%S)-$$"
    cp "$config" "$config.$stamp.bak"
    if (( begin > 1 )); then head -n "$((begin - 1))" "$config" > "$replacement"; fi
    cat "$desired_block" >> "$replacement"
    tail -n "+$((end + 1))" "$config" >> "$replacement"
    install -m 0600 "$replacement" "$config"
    echo "Updated SSH alias '$alias_name'; backup: $config.$stamp.bak"
  else
    echo "SSH alias '$alias_name' already matches the requested configuration."
  fi
else
  echo "Managed block markers for '$alias_name' are missing, duplicated, or out of order; refusing to rewrite $config." >&2
  exit 26
fi

echo
echo 'Add this PUBLIC key to the intended Hostinger VPS account:'
cat "$key_path.pub"
echo
echo "Verified ED25519 host key: $actual_fingerprint"
echo "After adding the public key, test with: ssh $alias_name"
