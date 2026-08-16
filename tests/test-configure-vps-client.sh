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
    printf '256 SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA test (ED25519)\n'
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

echo 'configure-vps-client convergence tests passed.'
