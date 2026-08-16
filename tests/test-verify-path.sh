#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
export HOME="$test_root/home"
managed_bin="$HOME/.local/bin"
mkdir -p "$managed_bin"

checked_commands=(git gh ssh sshd mosh tailscale rustup cargo rtk codex claude herdr bun pwsh mount.cifs)
fixture_commands=("${checked_commands[@]}" systemctl)
for command_name in "${fixture_commands[@]}"; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$managed_bin/$command_name"
  chmod +x "$managed_bin/$command_name"
done

output="$test_root/verify-output.txt"
PATH='/usr/bin:/bin' bash "$repo_root/scripts/ubuntu/verify.sh" > "$output" 2>&1 || true
if grep -q '^FAIL command ' "$output"; then
  cat "$output" >&2
  echo 'verify.sh failed to discover a managed command from a fresh minimal PATH.' >&2
  exit 1
fi
for command_name in "${checked_commands[@]}"; do
  if ! grep -Eq "^PASS command[[:space:]]+${command_name}[[:space:]]+${managed_bin}/${command_name}$" "$output"; then
    cat "$output" >&2
    echo "Missing managed-PATH PASS evidence for $command_name." >&2
    exit 1
  fi
done
echo 'verify.sh managed-PATH regression test passed.'
