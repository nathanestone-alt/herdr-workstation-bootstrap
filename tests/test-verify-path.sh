#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
export HOME="$test_root/home"
managed_bin="$HOME/.local/bin"
mkdir -p "$managed_bin"
profile_dir="$HOME/.config/herdr-workstation"
mkdir -p "$profile_dir"
cat > "$profile_dir/profile.sh" <<'EOF'
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
EOF
for profile_file in "$HOME/.profile" "$HOME/.bash_profile"; do
  printf '. "$HOME/.config/herdr-workstation/profile.sh"\n' > "$profile_file"
done
export HERDR_VERIFY_TEST_MODE=1
export HERDR_TEST_LOGIN_PROFILE="$HOME/.bash_profile"

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
for command_name in rtk codex claude herdr; do
  if ! grep -Eq "^PASS login command ${command_name}[[:space:]]+${managed_bin}/${command_name}$" "$output"; then
    cat "$output" >&2
    echo "Missing Bash-login PASS evidence for $command_name." >&2
    exit 1
  fi
done
echo 'verify.sh managed-PATH regression test passed.'
