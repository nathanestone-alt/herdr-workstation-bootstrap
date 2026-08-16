#!/usr/bin/env bash
set -euo pipefail
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"

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

printf 'Kernel: %s\n' "$(uname -r)"
if grep -qi microsoft /proc/sys/kernel/osrelease; then
  echo 'FAIL environment is WSL; the primary architecture requires an Ubuntu Hyper-V VM'
  failures=$((failures + 1))
else
  echo 'PASS environment is a standalone Linux VM'
fi
printf 'PID 1: %s\n' "$(ps -p 1 -o comm=)"
[[ "$(ps -p 1 -o comm=)" == "systemd" ]] || failures=$((failures + 1))

for command in git gh ssh sshd mosh tailscale rustup cargo rtk codex claude herdr bun pwsh mount.cifs; do
  check_command "$command"
done
if [[ "${HERDR_VERIFY_TEST_MODE:-0}" == 1 ]]; then
  [[ -f "${HERDR_TEST_LOGIN_PROFILE:-}" ]] || { echo 'FAIL test login profile missing' >&2; exit 2; }
  login_path="$(HOME="$HOME" bash --noprofile --norc -c '. "$1"; printf "%s" "$PATH"' bash "$HERDR_TEST_LOGIN_PROFILE")"
else
  login_path="$(HOME="$HOME" bash -lc 'printf "%s" "$PATH')"
fi
for required_path in "$HOME/.local/bin" "$HOME/.cargo/bin"; do
  if [[ ":$login_path:" == *":$required_path:"* ]]; then
    echo "PASS login PATH includes $required_path"
  else
    echo "FAIL login PATH omits $required_path"
    failures=$((failures + 1))
  fi
done
for command in rtk codex claude herdr; do
  if [[ "${HERDR_VERIFY_TEST_MODE:-0}" == 1 ]]; then
    login_command="$(HOME="$HOME" bash --noprofile --norc -c '. "$1"; command -v "$2"' bash "$HERDR_TEST_LOGIN_PROFILE" "$command" 2>/dev/null || true)"
  else
    login_command="$(HOME="$HOME" bash -lc "command -v $command" 2>/dev/null || true)"
  fi
  if [[ -n "$login_command" ]]; then
    echo "PASS login command $command $login_command"
  else
    echo "FAIL login command $command missing"
    failures=$((failures + 1))
  fi
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
pwsh --version 2>/dev/null || true

if [[ "$failures" -ne 0 ]]; then
  echo "Verification failed: $failures check(s)" >&2
  exit 1
fi
echo 'Ubuntu bootstrap verification passed.'
