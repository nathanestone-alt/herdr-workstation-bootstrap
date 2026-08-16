#!/usr/bin/env bash
set -euo pipefail

failures=0
check_command() {
  local name="$1"
  if command -v "$name" >/dev/null 2>&1; then
    printf 'PASS command %-10s %s\n' "$name" "$(command -v "$name")"
  else
    printf 'FAIL command %-10s missing\n' "$name"
    failures=$((failures + 1))
  fi
}

printf 'WSL kernel: %s\n' "$(uname -r)"
printf 'PID 1: %s\n' "$(ps -p 1 -o comm=)"
[[ "$(ps -p 1 -o comm=)" == "systemd" ]] || failures=$((failures + 1))

for command in git gh ssh sshd mosh tailscale rustup cargo rtk codex claude herdr bun; do
  check_command "$command"
done
if command -v systemctl >/dev/null 2>&1; then
  for service in ssh tailscaled; do
    if systemctl is-active --quiet "$service"; then
      echo "PASS service $service active"
    else
      echo "FAIL service $service inactive"
      failures=$((failures + 1))
    fi
  done
fi

printf 'Versions:\n'
rtk --version 2>/dev/null || true
codex --version 2>/dev/null || true
claude --version 2>/dev/null || true
herdr --version 2>/dev/null || true
git --version 2>/dev/null || true
gh --version 2>/dev/null | head -n 1 || true
mosh --version 2>/dev/null | head -n 1 || true

if [[ "$failures" -ne 0 ]]; then
  echo "Verification failed: $failures check(s)" >&2
  exit 1
fi
echo 'Ubuntu bootstrap verification passed.'

