#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
fake_bin="$test_root/bin"
mkdir -p "$fake_bin"

cat > "$fake_bin/ssh" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == -G ]]; then
  echo 'synthetic parser failure' >&2
  exit 255
fi
echo 'Unexpected network attempt in verify-vps-access regression.' >&2
exit 99
EOF
chmod +x "$fake_bin/ssh"

output="$test_root/output.txt"
if PATH="$fake_bin:$PATH" bash "$repo_root/scripts/ubuntu/verify-vps-access.sh" broken-vps >"$output" 2>&1; then
  echo 'Expected malformed effective SSH configuration to fail.' >&2
  exit 1
fi
grep -Fq "OpenSSH could not resolve alias 'broken-vps'; VPS access was not attempted." "$output" || {
  cat "$output" >&2
  echo 'Missing explicit OpenSSH resolution diagnostic.' >&2
  exit 1
}
grep -Fq 'ssh: synthetic parser failure' "$output" || {
  cat "$output" >&2
  echo 'Missing captured OpenSSH stderr.' >&2
  exit 1
}
echo 'verify-vps-access diagnostic regression test passed.'
