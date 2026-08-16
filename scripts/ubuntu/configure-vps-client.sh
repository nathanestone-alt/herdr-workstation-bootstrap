#!/usr/bin/env bash
set -euo pipefail

alias_name=""
host_name=""
user_name=""
port="22"
key_path="$HOME/.ssh/hostinger_vps_ed25519"
existing_key=""
host_key_fingerprint=""
system_ssh_config="${HERDR_SYSTEM_SSH_CONFIG:-/etc/ssh/ssh_config}"

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
[[ "$system_ssh_config" == /* ]] || { echo 'System SSH configuration path must be absolute.' >&2; exit 2; }
if [[ -n "${HERDR_SYSTEM_SSH_CONFIG:-}" && ! -r "$system_ssh_config" ]]; then
  echo "Requested system SSH configuration '$system_ssh_config' is not readable." >&2
  exit 2
fi
if [[ -n "$existing_key" ]]; then
  key_path="${existing_key/#\~/$HOME}"
fi
case "$key_path" in
  *$'\n'*|*$'\r'*|*'"'*|*'%'*|*\\*)
    echo 'Identity-file path contains unsupported SSH configuration metacharacters.' >&2
    exit 2
    ;;
esac

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
unmanaged_config="$(mktemp)"
validation_config="$(mktemp)"
ssh_error="$(mktemp)"
managed_blocks_dir="$(mktemp -d)"
trap 'rm -f "$scan_file" "$desired_block" "$current_block" "$replacement" "$unmanaged_config" "$validation_config" "$ssh_error"; rm -rf "$managed_blocks_dir"' EXIT
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
  printf '%s\n' "$existing_host_keys" | grep -v '^#' > "$current_block" || true
  mapfile -t recorded_fingerprints < <(ssh-keygen -lf "$current_block" -E sha256 | awk '{ print $2 }')
  if (( ${#recorded_fingerprints[@]} != 1 )) || [[ "${recorded_fingerprints[0]:-}" != "$host_key_fingerprint" ]]; then
    recorded_types="$(awk '!/^#/ { print $2 }' "$current_block" | sort -u | paste -sd, -)"
    echo "known_hosts must contain exactly one verified key for $host_token; recorded key types: ${recorded_types:-unknown}." >&2
    echo "After independently re-verifying the fingerprint, remove all entries with: ssh-keygen -R '$host_token' -f '$known_hosts' ; then rerun this script to install the verified ED25519 key." >&2
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
  printf '  IdentityFile "%s"\n' "$key_path"
  printf '  IdentitiesOnly yes\n'
  printf '  StrictHostKeyChecking yes\n'
  printf '  UserKnownHostsFile ~/.ssh/known_hosts\n'
  printf '  GlobalKnownHostsFile none\n'
  printf '  UpdateHostKeys no\n'
  printf '  ProxyCommand none\n'
  printf '  ProxyJump none\n'
  printf '  CanonicalizeHostname no\n'
  printf '  PermitLocalCommand no\n'
  printf '  RemoteCommand none\n'
  printf '  KnownHostsCommand none\n'
  printf '  ClearAllForwardings yes\n'
  printf '  ServerAliveInterval 30\n'
  printf '  ServerAliveCountMax 3\n'
  printf 'Host *\n'
  printf '%s\n' "$end_marker"
} > "$desired_block"

managed_alias=""
managed_file=""
line_number=0
while IFS= read -r config_line || [[ -n "$config_line" ]]; do
  line_number=$((line_number + 1))
  if [[ -z "$managed_alias" && "$config_line" =~ ^#\ BEGIN\ herdr-bootstrap\ ([A-Za-z0-9._-]+)$ ]]; then
    managed_alias="${BASH_REMATCH[1]}"
    managed_file="$managed_blocks_dir/$managed_alias.block"
    [[ ! -e "$managed_file" ]] || {
      echo "Managed block for '$managed_alias' is duplicated at $config:$line_number." >&2
      exit 26
    }
    printf '%s\n' "$config_line" > "$managed_file"
    continue
  fi
  if [[ -n "$managed_alias" ]]; then
    [[ ! "$config_line" =~ ^#\ BEGIN\ herdr-bootstrap\ ([A-Za-z0-9._-]+)$ ]] || {
      echo "Managed block for '$managed_alias' is nested or missing its end marker before $config:$line_number." >&2
      exit 26
    }
    printf '%s\n' "$config_line" >> "$managed_file"
    if [[ "$config_line" == "# END herdr-bootstrap $managed_alias" ]]; then
      managed_alias=""
      managed_file=""
    fi
    continue
  fi
  printf '%s\n' "$config_line" >> "$unmanaged_config"
done < "$config"
[[ -z "$managed_alias" ]] || {
  echo "Managed block for '$managed_alias' is missing its end marker in $config." >&2
  exit 26
}
awk '
  BEGIN { started=0; pending="" }
  {
    if (!started && $0 == "") next
    if ($0 == "") { pending=pending "\n"; next }
    if (pending != "") { printf "%s", pending; pending="" }
    print
    started=1
  }
' "$unmanaged_config" > "$current_block"
mv "$current_block" "$unmanaged_config"
cp "$desired_block" "$managed_blocks_dir/$alias_name.block"

line_number=0
while IFS= read -r config_line || [[ -n "$config_line" ]]; do
  line_number=$((line_number + 1))
  if [[ "$config_line" =~ ^[[:space:]]*[Hh][Oo][Ss][Tt][[:space:]]+(.+)$ ]]; then
    read -r -a host_patterns <<< "${BASH_REMATCH[1]}"
    for host_pattern in "${host_patterns[@]}"; do
      normalized="${host_pattern,,}"
      if [[ "$normalized" != '!'* && "$normalized" == "${alias_name,,}" ]]; then
        echo "Unmanaged exact Host stanza at $config:$line_number duplicates alias '$alias_name'; rename or remove it before retrying." >&2
        exit 26
      fi
    done
  fi
done < "$unmanaged_config"

mapfile -t managed_block_files < <(find "$managed_blocks_dir" -maxdepth 1 -type f -name '*.block' -print | LC_ALL=C sort)
validate_managed_block_shape() {
  local block_file="$1"
  local block_alias="$2"
  local block_line=""
  local -a required_patterns=(
    "HostName " "User " "Port " "IdentityFile " "IdentitiesOnly yes" "StrictHostKeyChecking yes"
    "UserKnownHostsFile ~/.ssh/known_hosts" "GlobalKnownHostsFile none" "UpdateHostKeys no"
    "ProxyCommand none" "ProxyJump none" "CanonicalizeHostname no" "PermitLocalCommand no"
    "RemoteCommand none" "KnownHostsCommand none" "ClearAllForwardings yes"
    "ServerAliveInterval 30" "ServerAliveCountMax 3"
  )
  [[ "$(head -n 1 "$block_file")" == "# BEGIN herdr-bootstrap $block_alias" &&
      "$(tail -n 1 "$block_file")" == "# END herdr-bootstrap $block_alias" &&
      "$(sed -n '2p' "$block_file")" == "Host $block_alias" &&
      "$(tail -n 2 "$block_file" | head -n 1)" == 'Host *' ]] || {
    echo "Managed block for '$block_alias' does not match the required marker/Host template; the client configuration was not changed." >&2
    exit 26
  }
  while IFS= read -r block_line || [[ -n "$block_line" ]]; do
    case "$block_line" in
      "# BEGIN herdr-bootstrap $block_alias"|"# END herdr-bootstrap $block_alias"|"Host $block_alias"|'Host *') ;;
      '  HostName '*|'  User '*|'  Port '*|'  IdentityFile '*|'  IdentitiesOnly yes'|'  StrictHostKeyChecking yes'|'  UserKnownHostsFile ~/.ssh/known_hosts'|'  GlobalKnownHostsFile none'|'  UpdateHostKeys no'|'  ProxyCommand none'|'  ProxyJump none'|'  CanonicalizeHostname no'|'  PermitLocalCommand no'|'  RemoteCommand none'|'  KnownHostsCommand none'|'  ClearAllForwardings yes'|'  ServerAliveInterval 30'|'  ServerAliveCountMax 3') ;;
      *) echo "Managed block for '$block_alias' contains unexpected content '$block_line'; the client configuration was not changed." >&2; exit 26 ;;
    esac
  done < "$block_file"
  for required_pattern in "${required_patterns[@]}"; do
    if [[ "$required_pattern" == *' ' ]]; then
      required_regex="${required_pattern% }"
      required_count="$(grep -Ec "^[[:space:]]+${required_regex//./\\.}[[:space:]]+[^[:space:]].*$" "$block_file")"
    else
      required_count="$(grep -Ec "^[[:space:]]+${required_pattern//./\\.}$" "$block_file")"
    fi
    [[ "$required_count" == 1 ]] || {
      echo "Managed block for '$block_alias' must contain exactly one '$required_pattern' directive; the client configuration was not changed." >&2
      exit 26
    }
  done
}
for managed_block_file in "${managed_block_files[@]}"; do
  managed_block_alias="$(basename "$managed_block_file" .block)"
  validate_managed_block_shape "$managed_block_file" "$managed_block_alias"
done
: > "$replacement"
for block_index in "${!managed_block_files[@]}"; do
  (( block_index == 0 )) || printf '\n' >> "$replacement"
  cat "${managed_block_files[$block_index]}" >> "$replacement"
done
if [[ -s "$unmanaged_config" ]]; then
  printf '\n' >> "$replacement"
  cat "$unmanaged_config" >> "$replacement"
fi

cp "$replacement" "$validation_config"
if [[ -r "$system_ssh_config" ]]; then
  printf '\nHost *\nMatch all\nInclude "%s"\n' "$system_ssh_config" >> "$validation_config"
fi

validate_effective_alias() {
  local checked_alias="$1"
  local block_file="$2"
  local expected_host expected_user expected_port expected_key effective_config effective_strict
  local unsafe_option unsafe_value accumulating_option accumulating_values sendenv_line sendenv_value
  local -a effective_identity_files
  expected_host="$(awk '$1 == "HostName" { print $2; exit }' "$block_file")"
  expected_user="$(awk '$1 == "User" { print $2; exit }' "$block_file")"
  expected_port="$(awk '$1 == "Port" { print $2; exit }' "$block_file")"
  expected_key="$(awk '$1 == "IdentityFile" { $1=""; sub(/^[[:space:]]+/, ""); print; exit }' "$block_file")"
  if [[ "$expected_key" == \"*\" ]]; then
    expected_key="${expected_key:1:${#expected_key}-2}"
  fi
  : > "$ssh_error"
  if ! effective_config="$(ssh -G -F "$validation_config" "$checked_alias" 2>"$ssh_error")"; then
    echo "OpenSSH could not resolve managed alias '$checked_alias'; the client configuration was not changed." >&2
    sed 's/^/ssh: /' "$ssh_error" >&2
    exit 26
  fi
  effective_value() { awk -v key="$1" '$1 == key { $1=""; sub(/^ /, ""); print; exit }' <<< "$effective_config"; }
  [[ "$(effective_value hostname)" == "$expected_host" ]] || { echo "Effective SSH HostName for '$checked_alias' does not match its managed block." >&2; exit 26; }
  [[ "$(effective_value user)" == "$expected_user" ]] || { echo "Effective SSH User for '$checked_alias' does not match its managed block." >&2; exit 26; }
  [[ "$(effective_value port)" == "$expected_port" ]] || { echo "Effective SSH Port for '$checked_alias' does not match its managed block." >&2; exit 26; }
  mapfile -t effective_identity_files < <(awk '$1 == "identityfile" { $1=""; sub(/^ /, ""); print }' <<< "$effective_config")
  (( ${#effective_identity_files[@]} == 1 )) && [[ "${effective_identity_files[0]}" == "$expected_key" ]] || {
    echo "Effective SSH configuration for '$checked_alias' must contain exactly its one managed IdentityFile." >&2
    exit 26
  }
  [[ "$(effective_value identitiesonly)" == yes ]] || { echo "Effective SSH IdentitiesOnly for '$checked_alias' is not yes." >&2; exit 26; }
  [[ "$(effective_value clearallforwardings)" == yes ]] || { echo "Effective SSH ClearAllForwardings for '$checked_alias' is not yes." >&2; exit 26; }
  effective_strict="$(effective_value stricthostkeychecking)"
  [[ "$effective_strict" == yes || "$effective_strict" == true ]] || { echo "Effective SSH StrictHostKeyChecking for '$checked_alias' is not enabled." >&2; exit 26; }
  for unsafe_option in proxycommand proxyjump hostkeyalias; do
    unsafe_value="$(effective_value "$unsafe_option")"
    [[ -z "$unsafe_value" || "$unsafe_value" == none ]] || {
      echo "Effective SSH $unsafe_option for '$checked_alias' is '$unsafe_value'; refusing unmanaged redirection." >&2
      exit 26
    }
  done
  for accumulating_option in certificatefile localforward remoteforward dynamicforward setenv; do
    accumulating_values="$(awk -v key="$accumulating_option" '$1 == key { print }' <<< "$effective_config")"
    if [[ -n "$accumulating_values" && "$accumulating_values" != "$accumulating_option none" ]]; then
      echo "Effective SSH $accumulating_option for '$checked_alias' contains unmanaged accumulating values; refusing the alias." >&2
      exit 26
    fi
  done
  while IFS= read -r sendenv_line; do
    [[ -z "$sendenv_line" || "$sendenv_line" == 'sendenv none' ]] && continue
    read -r -a sendenv_values <<< "${sendenv_line#sendenv }"
    for sendenv_value in "${sendenv_values[@]}"; do
      [[ "$sendenv_value" == 'LANG' || "$sendenv_value" == 'LC_*' ]] || {
        echo "Effective SSH SendEnv for '$checked_alias' contains nonstandard value '$sendenv_value'; refusing the alias." >&2
        exit 26
      }
    done
  done < <(awk '$1 == "sendenv" { print }' <<< "$effective_config")
}

for managed_block_file in "${managed_block_files[@]}"; do
  managed_block_alias="$(basename "$managed_block_file" .block)"
  validate_effective_alias "$managed_block_alias" "$managed_block_file"
done

if ! cmp -s "$config" "$replacement"; then
  stamp="$(date +%Y%m%d-%H%M%S)-$$"
  cp "$config" "$config.$stamp.bak"
  install -m 0600 "$replacement" "$config"
  echo "Updated and prepended SSH alias '$alias_name'; backup: $config.$stamp.bak"
else
  echo "SSH alias '$alias_name' already matches the requested top-precedence configuration."
fi

echo
echo 'Add this PUBLIC key to the intended Hostinger VPS account:'
cat "$key_path.pub"
echo
echo "Verified ED25519 host key: $actual_fingerprint"
echo "After adding the public key, test with: ssh $alias_name"
