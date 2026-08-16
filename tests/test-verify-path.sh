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
printf '. "$HOME/.config/herdr-workstation/profile.sh"\n' > "$HOME/.profile"

checked_commands=(git gh ssh sshd mosh tailscale rustup cargo rtk codex claude herdr bun pwsh mount.cifs)
fixture_commands=("${checked_commands[@]}" systemctl)
for command_name in "${fixture_commands[@]}"; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$managed_bin/$command_name"
  chmod +x "$managed_bin/$command_name"
done

# Exercise verify.sh's real bash -lc branch without allowing Git Bash's
# machine-wide /etc/profile to replace the fixture HOME. The wrapper still
# passes the exact -lc payload to Bash, so malformed nested quoting fails.
cat > "$managed_bin/bash" <<'EOF'
#!/bin/bash
set -euo pipefail
if [[ "${1:-}" == -lc ]]; then
  shift
  export PATH='/usr/bin:/bin'
  for startup_file in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
    if [[ -f "$startup_file" ]]; then
      . "$startup_file"
      break
    fi
  done
  exec /bin/bash --noprofile --norc -c "$1"
fi
exec /bin/bash "$@"
EOF
cat > "$managed_bin/uname" <<'EOF'
#!/bin/bash
printf '6.8.0-test\n'
EOF
cat > "$managed_bin/grep" <<'EOF'
#!/bin/bash
exit 1
EOF
cat > "$managed_bin/ps" <<'EOF'
#!/bin/bash
printf 'systemd\n'
EOF
chmod +x "$managed_bin/bash" "$managed_bin/uname" "$managed_bin/grep" "$managed_bin/ps"

run_verify_layout() {
  local layout="$1"
  local output="$test_root/verify-output-$layout.txt"
  rm -f "$HOME/.bash_profile" "$HOME/.bash_login"
  case "$layout" in
    profile) ;;
    bash-profile) printf '. "$HOME/.profile"\n' > "$HOME/.bash_profile" ;;
    bash-login) printf '. "$HOME/.profile"\n' > "$HOME/.bash_login" ;;
    *) echo "Unknown fixture layout: $layout" >&2; exit 1 ;;
  esac
  set +e
  PATH='/usr/bin:/bin' /bin/bash "$repo_root/scripts/ubuntu/verify.sh" > "$output" 2>&1
  status=$?
  set -e
  if [[ "$status" -ne 0 ]]; then
    cat "$output" >&2
    echo "verify.sh exited non-zero for login layout '$layout' (status=$status)." >&2
    exit 1
  fi
  if grep -q '^FAIL command ' "$output"; then
    cat "$output" >&2
    echo "verify.sh failed to discover a managed command for login layout '$layout'." >&2
    exit 1
  fi
  for command_name in "${checked_commands[@]}"; do
    if ! grep -Eq "^PASS command[[:space:]]+${command_name}[[:space:]]+${managed_bin}/${command_name}$" "$output"; then
      cat "$output" >&2
      echo "Missing managed-PATH PASS evidence for $command_name in layout '$layout'." >&2
      exit 1
    fi
  done
  for command_name in rtk codex claude herdr; do
    if ! grep -Eq "^PASS login command ${command_name}[[:space:]]+${managed_bin}/${command_name}$" "$output"; then
      cat "$output" >&2
      echo "Missing Bash-login PASS evidence for $command_name in layout '$layout'." >&2
      exit 1
    fi
  done
}

run_verify_layout profile
run_verify_layout bash-profile
run_verify_layout bash-login

rm -f "$HOME/.bash_profile" "$HOME/.bash_login"
: > "$HOME/.profile"
negative_output="$test_root/verify-output-missing-hook.txt"
if PATH='/usr/bin:/bin' /bin/bash "$repo_root/scripts/ubuntu/verify.sh" > "$negative_output" 2>&1; then
  cat "$negative_output" >&2
  echo 'verify.sh passed even though the managed login-shell PATH hook was absent.' >&2
  exit 1
fi
grep -q '^FAIL login PATH omits ' "$negative_output" || {
  cat "$negative_output" >&2
  echo 'Missing-hook negative case did not fail the login PATH gate.' >&2
  exit 1
}
echo 'verify.sh managed-PATH regression test passed.'
