#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
export HOME="$test_root/home"
fake_bin="$test_root/bin"
mkdir -p "$HOME/.ssh" "$fake_bin"
printf 'private-test-fixture\n' > "$HOME/.ssh/test-key"
printf 'ssh-ed25519 public-test-fixture\n' > "$HOME/.ssh/test-key.pub"

cat > "$fake_bin/ssh-keyscan" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
port=22
host=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p) port="$2"; shift 2 ;;
    -T|-t) shift 2 ;;
    *) host="$1"; shift ;;
  esac
done
token="$host"
[[ "$port" == 22 ]] || token="[$host]:$port"
printf '%s ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestFixtureOnly\n' "$token"
EOF

cat > "$fake_bin/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  -lf)
    file="$2"
    while IFS= read -r _; do
      printf '256 SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA test (ED25519)\n'
    done < "$file"
    ;;
  -F)
    token="$2"
    shift 2
    [[ "$1" == -f ]]
    file="$2"
    grep -F "$token " "$file" || exit 1
    ;;
  *)
    echo "Unexpected fake ssh-keygen arguments: $*" >&2
    exit 90
    ;;
esac
EOF

cat > "$fake_bin/install" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == -d ]]; then
  shift
  while [[ "$1" == -* ]]; do
    if [[ "$1" == -m ]]; then shift 2; else shift; fi
  done
  mkdir -p "$@"
else
  while [[ "$1" == -* ]]; do
    if [[ "$1" == -m ]]; then shift 2; else shift; fi
  done
  cp "$1" "$2"
fi
EOF
chmod +x "$fake_bin/ssh-keyscan" "$fake_bin/ssh-keygen" "$fake_bin/install"
export PATH="$fake_bin:$PATH"

fingerprint='SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
script="$repo_root/scripts/ubuntu/configure-vps-client.sh"
common=(--alias test-vps --existing-key "$HOME/.ssh/test-key" --host-key-fingerprint "$fingerprint")

bash "$script" "${common[@]}" --host one.example --user admin --port 22 >/dev/null
bash "$script" "${common[@]}" --host one.example --user admin --port 22 >/dev/null
[[ "$(grep -Fc '# BEGIN herdr-bootstrap test-vps' "$HOME/.ssh/config")" == 1 ]]
grep -Fq '  HostName one.example' "$HOME/.ssh/config"

mkdir -p "$HOME/.ssh/key dir"
cp "$HOME/.ssh/test-key" "$HOME/.ssh/key dir/test key"
cp "$HOME/.ssh/test-key.pub" "$HOME/.ssh/key dir/test key.pub"
bash "$script" --alias spaced-vps --host spaced.example --user admin --port 22 \
  --existing-key "$HOME/.ssh/key dir/test key" --host-key-fingerprint "$fingerprint" >/dev/null
grep -Fq "  IdentityFile \"$HOME/.ssh/key dir/test key\"" "$HOME/.ssh/config" || {
  echo 'Spaced IdentityFile path was not emitted as one quoted SSH token.' >&2
  exit 1
}
spaced_effective="$(ssh -G -F "$HOME/.ssh/config" spaced-vps 2>/dev/null | awk '$1 == "identityfile" { $1=""; sub(/^ /, ""); print; exit }')"
[[ "$spaced_effective" == "$HOME/.ssh/key dir/test key" ]] || {
  echo 'Spaced IdentityFile path did not survive OpenSSH effective-config resolution.' >&2
  exit 1
}

config_hash_before_rejections="$(sha256sum "$HOME/.ssh/config" | awk '{print $1}')"
known_hosts_hash_before_rejections="$(sha256sum "$HOME/.ssh/known_hosts" | awk '{print $1}')"
rejected_key_paths=(
  "$HOME/.ssh/bad%key"
  "$HOME/.ssh/bad\"key"
  "$HOME/.ssh/bad\\key"
  "$HOME/.ssh/"$'bad\nkey'
)
for rejected_key_path in "${rejected_key_paths[@]}"; do
  rejection_output="$test_root/rejected-key-${#rejected_key_path}.txt"
  set +e
  bash "$script" --alias rejected-vps --host rejected.example --user admin --port 22 \
    --existing-key "$rejected_key_path" --host-key-fingerprint "$fingerprint" >"$rejection_output" 2>&1
  rejection_status=$?
  set -e
  [[ "$rejection_status" -eq 2 ]] || {
    cat "$rejection_output" >&2
    echo "Rejected IdentityFile path returned status $rejection_status instead of 2." >&2
    exit 1
  }
  grep -Fq 'Identity-file path contains unsupported SSH configuration metacharacters.' "$rejection_output" || {
    cat "$rejection_output" >&2
    echo 'Rejected IdentityFile path did not produce the exact diagnostic.' >&2
    exit 1
  }
  [[ "$(sha256sum "$HOME/.ssh/config" | awk '{print $1}')" == "$config_hash_before_rejections" ]]
  [[ "$(sha256sum "$HOME/.ssh/known_hosts" | awk '{print $1}')" == "$known_hosts_hash_before_rejections" ]]
done

bash "$script" "${common[@]}" --host two.example --user deploy --port 2222 >/dev/null
[[ "$(grep -Fc '# BEGIN herdr-bootstrap test-vps' "$HOME/.ssh/config")" == 1 ]]
grep -Fq '  HostName two.example' "$HOME/.ssh/config"
grep -Fq '  User deploy' "$HOME/.ssh/config"
grep -Fq '  Port 2222' "$HOME/.ssh/config"
grep -Fq '  StrictHostKeyChecking yes' "$HOME/.ssh/config"
compgen -G "$HOME/.ssh/config.*.bak" >/dev/null

if bash "$script" --alias bad-vps --host bad.example --user admin --port 22 \
    --existing-key "$HOME/.ssh/test-key" \
    --host-key-fingerprint 'SHA256:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB' >/dev/null 2>&1; then
  echo 'Expected host-key mismatch to fail.' >&2
  exit 1
fi

printf '\nHost shadow-vps\n  HostName attacker.example\n' >> "$HOME/.ssh/config"
if bash "$script" --alias shadow-vps --host good.example --user admin --port 22 \
    --existing-key "$HOME/.ssh/test-key" --host-key-fingerprint "$fingerprint" >/dev/null 2>&1; then
  echo 'Expected unmanaged matching Host stanza to fail.' >&2
  exit 1
fi

printf 'duplicate.example ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestFixtureOnly\n' >> "$HOME/.ssh/known_hosts"
printf 'duplicate.example ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExtraFixtureOnly\n' >> "$HOME/.ssh/known_hosts"
if bash "$script" --alias duplicate-vps --host duplicate.example --user admin --port 22 \
    --existing-key "$HOME/.ssh/test-key" --host-key-fingerprint "$fingerprint" >/dev/null 2>&1; then
  echo 'Expected duplicate known_hosts keys to fail.' >&2
  exit 1
fi

printf '\nHost *\n  AddKeysToAgent yes\n' >> "$HOME/.ssh/config"
bash "$script" --alias wildcard-vps --host wildcard.example --user admin --port 22 \
  --existing-key "$HOME/.ssh/test-key" --host-key-fingerprint "$fingerprint" >/dev/null
grep -Fq '# BEGIN herdr-bootstrap wildcard-vps' "$HOME/.ssh/config"
mapfile -t managed_aliases < <(sed -n 's/^# BEGIN herdr-bootstrap //p' "$HOME/.ssh/config")
[[ "$(printf '%s\n' "${managed_aliases[@]}")" == "$(printf '%s\n' "${managed_aliases[@]}" | LC_ALL=C sort)" ]] || {
  echo 'Managed SSH alias blocks are not in deterministic order.' >&2
  exit 1
}

mkdir -p "$HOME/.ssh/config.d"
printf 'Host included-vps\n  HostName attacker.example\n  ProxyJump attacker.example\n' > "$HOME/.ssh/config.d/common"
printf '\nInclude config.d/*\nMatch host match-vps\n  HostName attacker.example\nMatch all\n' >> "$HOME/.ssh/config"
bash "$script" --alias included-vps --host included.example --user admin --port 22 \
  --existing-key "$HOME/.ssh/test-key" --host-key-fingerprint "$fingerprint" >/dev/null
bash "$script" --alias match-vps --host match.example --user admin --port 22 \
  --existing-key "$HOME/.ssh/test-key" --host-key-fingerprint "$fingerprint" >/dev/null

multi_common=(--existing-key "$HOME/.ssh/test-key" --host-key-fingerprint "$fingerprint" --user admin --port 22)
bash "$script" --alias alpha-vps --host alpha.example "${multi_common[@]}" >/dev/null
bash "$script" --alias beta-vps --host beta.example "${multi_common[@]}" >/dev/null
config_hash_before="$(sha256sum "$HOME/.ssh/config" | awk '{print $1}')"
backup_count_before="$(find "$HOME/.ssh" -maxdepth 1 -type f -name 'config.*.bak' | wc -l)"
bash "$script" --alias alpha-vps --host alpha.example "${multi_common[@]}" >/dev/null
config_hash_after="$(sha256sum "$HOME/.ssh/config" | awk '{print $1}')"
backup_count_after="$(find "$HOME/.ssh" -maxdepth 1 -type f -name 'config.*.bak' | wc -l)"
[[ "$config_hash_before" == "$config_hash_after" && "$backup_count_before" == "$backup_count_after" ]] || {
  echo 'Re-converging an earlier alias rewrote the deterministic managed region.' >&2
  exit 1
}

safe_config="$test_root/config-before-tamper"
cp "$HOME/.ssh/config" "$safe_config"
sed -i '/# END herdr-bootstrap alpha-vps/i\  LocalForward 7777 127.0.0.1:22' "$HOME/.ssh/config"
tampered_hash="$(sha256sum "$HOME/.ssh/config" | awk '{print $1}')"
tamper_output="$test_root/tamper-output.txt"
if bash "$script" --alias beta-vps --host beta.example "${multi_common[@]}" >"$tamper_output" 2>&1; then
  echo 'Expected a drifted carried managed block to fail.' >&2
  exit 1
fi
grep -Fq "Managed block for 'alpha-vps'" "$tamper_output" || {
  cat "$tamper_output" >&2
  echo 'Managed-block drift failure did not name the carried alias.' >&2
  exit 1
}
[[ "$(sha256sum "$HOME/.ssh/config" | awk '{print $1}')" == "$tampered_hash" ]] || {
  echo 'A failed carried-block validation modified the SSH client configuration.' >&2
  exit 1
}
cp "$safe_config" "$HOME/.ssh/config"

printf '\nHost *\n  DefinitelyNotAnSshOption yes\n' >> "$HOME/.ssh/config"
invalid_hash="$(sha256sum "$HOME/.ssh/config" | awk '{print $1}')"
parse_output="$test_root/parse-output.txt"
if bash "$script" --alias parser-vps --host parser.example "${multi_common[@]}" >"$parse_output" 2>&1; then
  echo 'Expected an OpenSSH parser failure to be reported.' >&2
  exit 1
fi
grep -Eq "OpenSSH could not resolve managed alias '[A-Za-z0-9._-]+'; the client configuration was not changed\." "$parse_output" || {
  cat "$parse_output" >&2
  echo 'OpenSSH parser failure did not provide the required diagnostic.' >&2
  exit 1
}
[[ "$(sha256sum "$HOME/.ssh/config" | awk '{print $1}')" == "$invalid_hash" ]] || {
  echo 'A failed OpenSSH resolution modified the SSH client configuration.' >&2
  exit 1
}
cp "$safe_config" "$HOME/.ssh/config"

system_config="$test_root/system-ssh-config"
printf 'Host *\n  IdentityFile %s\n  SetEnv SYSTEM_UNSAFE=1\n' "$HOME/.ssh/system-attacker-key" > "$system_config"
system_hash="$(sha256sum "$HOME/.ssh/config" | awk '{print $1}')"
system_output="$test_root/system-output.txt"
if HERDR_SYSTEM_SSH_CONFIG="$system_config" bash "$script" --alias system-vps --host system.example "${multi_common[@]}" >"$system_output" 2>&1; then
  echo 'Expected a system-config-only identity/SetEnv value to fail.' >&2
  exit 1
fi
grep -Eq "Effective SSH (configuration for '[A-Za-z0-9._-]+' must contain exactly its one managed IdentityFile|setenv for '[A-Za-z0-9._-]+' contains unmanaged accumulating values)" "$system_output" || {
  cat "$system_output" >&2
  echo 'System SSH configuration was not included in effective-alias validation.' >&2
  exit 1
}
[[ "$(sha256sum "$HOME/.ssh/config" | awk '{print $1}')" == "$system_hash" ]] || {
  echo 'A failed system SSH configuration validation modified the user config.' >&2
  exit 1
}

printf '\nHost *\n  SendEnv UNSAFE_TEST_VALUE\n' >> "$HOME/.ssh/config"
if bash "$script" --alias sendenv-vps --host sendenv.example "${multi_common[@]}" >/dev/null 2>&1; then
  echo 'Expected an unmanaged accumulating SendEnv option to fail.' >&2
  exit 1
fi
printf '\nHost *\n  IdentityFile %s\n  LocalForward 9999 127.0.0.1:22\n' "$HOME/.ssh/attacker-key" >> "$HOME/.ssh/config"
if bash "$script" --alias accumulating-vps --host accumulating.example "${multi_common[@]}" >/dev/null 2>&1; then
  echo 'Expected an unmanaged accumulating identity/forward option to fail.' >&2
  exit 1
fi

cp "$safe_config" "$HOME/.ssh/config"
cat >> "$HOME/.ssh/config" <<'EOF'

Host *
  ForwardAgent yes
  ForwardX11 yes
  ForwardX11Trusted yes
  ControlMaster auto
  ControlPath /tmp/herdr-cm-%r@%h:%p
EOF
bash "$script" --alias isolation-vps --host isolation.example "${multi_common[@]}" >/dev/null
effective_isolation="$(ssh -G -F "$HOME/.ssh/config" isolation-vps 2>/dev/null)"
for disabled_setting in forwardagent forwardx11 forwardx11trusted controlmaster; do
  disabled_value="$(awk -v key="$disabled_setting" '$1 == key { print $2; exit }' <<< "$effective_isolation")"
  [[ "$disabled_value" == no || "$disabled_value" == false ]] || {
    echo "Managed alias did not disable inherited SSH setting '$disabled_setting' (effective value '$disabled_value')." >&2
    exit 1
  }
done
control_path_value="$(awk '$1 == "controlpath" { print $2; exit }' <<< "$effective_isolation")"
[[ -z "$control_path_value" || "$control_path_value" == none ]] || {
  echo "Managed alias did not disable inherited ControlPath (effective value '$control_path_value')." >&2
  exit 1
}

echo 'configure-vps-client convergence tests passed.'
