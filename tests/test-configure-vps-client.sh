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

echo 'configure-vps-client convergence tests passed.'
