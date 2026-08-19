#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"

lock_file="$repo_root/config/ubuntu-toolchain.lock"
[[ -f "$lock_file" ]] || { echo "Missing toolchain lock: $lock_file" >&2; exit 22; }
# shellcheck disable=SC1091
source "$repo_root/scripts/ubuntu/bootstrap.sh"
validate_toolchain_lock || { echo 'Toolchain lock validation failed.' >&2; exit 22; }

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

for command in git gh ssh sshd mosh tailscale rustup cargo rtk codex claude herdr bun pwsh mount.cifs uv python3.13 py; do
  check_command "$command"
done

check_exact_version() {
  local name="$1"
  local expected="$2"
  local actual
  if ! command -v "$name" >/dev/null 2>&1; then return; fi
  if actual="$("$name" --version 2>&1)" && [[ "$actual" == "$expected" ]]; then
    printf 'PASS exact version %-10s %s\n' "$name" "$actual"
  else
    printf 'FAIL exact version %-10s expected %s (got %s)\n' "$name" "$expected" "${actual:-unavailable}"
    failures=$((failures + 1))
  fi
}

check_exact_version uv "uv $UV_VERSION ($UV_PLATFORM)"
check_exact_version python3.13 "Python $PYTHON_VERSION"

if command -v uv >/dev/null 2>&1; then
  uv_path="$(command -v uv)"
  [[ "$uv_path" == "$HOME/.local/bin/uv" ]] || { echo "FAIL uv is not managed: $uv_path"; failures=$((failures + 1)); }
fi
if command -v python3.13 >/dev/null 2>&1; then
  python_path="$(command -v python3.13)"
  [[ "$python_path" == "$HOME/.local/bin/python3.13" ]] || { echo "FAIL python3.13 is not managed: $python_path"; failures=$((failures + 1)); }
fi
if command -v py >/dev/null 2>&1; then
  py_path="$(command -v py)"
  [[ "$py_path" == "$HOME/.local/bin/py" ]] || { echo "FAIL py is not managed: $py_path"; failures=$((failures + 1)); }
  if py_probe="$(py -3.13 -c 'import platform, sys; print(f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}|{platform.machine()}|{sys.platform}")' 2>&1)" && [[ "$py_probe" == "$PYTHON_VERSION|x86_64|linux" ]]; then
    echo "PASS py -3.13 selects $py_probe"
  else
    echo "FAIL py -3.13 selected '${py_probe:-unavailable}'"
    failures=$((failures + 1))
  fi
  if py --list >/dev/null 2>&1; then
    echo 'FAIL py accepted unsupported --list option'
    failures=$((failures + 1))
  else
    py_status=$?
    if [[ "$py_status" -eq 2 ]]; then
      echo 'PASS py rejects unsupported --list option'
    else
      echo "FAIL py rejected --list with unexpected status $py_status"
      failures=$((failures + 1))
    fi
  fi
fi

home_real="$(realpath -e -- "$HOME" 2>/dev/null || true)"
check_managed_command_target() {
  local name="$1"
  local expected_path="$2"
  local actual_path
  local resolved_path
  if command -v "$name" >/dev/null 2>&1; then
    actual_path="$(command -v "$name")"
    if [[ "$actual_path" == "$expected_path" ]]; then
      resolved_path="$(realpath -e -- "$expected_path" 2>/dev/null || true)"
      if path_is_under "$resolved_path" "$home_real"; then
        echo "PASS managed target $name $resolved_path"
      else
        echo "FAIL managed target $name resolves outside HOME: $resolved_path"
        failures=$((failures + 1))
      fi
    fi
  fi
}
check_managed_command_target uv "$HOME/.local/bin/uv"
check_managed_command_target python3.13 "$HOME/.local/bin/python3.13"
check_managed_command_target py "$HOME/.local/bin/py"

toolchain_receipt="$HOME/.local/state/herdr-workstation-bootstrap/toolchain-manifest.txt"
lock_sha256="$(sha256sum "$lock_file" | awk '{print $1}')"
if [[ -L "$toolchain_receipt" ]]; then
  echo "FAIL receipt is a symlink: $toolchain_receipt"
  failures=$((failures + 1))
fi
for receipt_line in \
  'receipt_format=issue-961-toolchain-v2' \
  "lock_sha256=$lock_sha256" \
  'host_platform=linux' \
  'host_architecture=x86_64' \
  "uv_path=$HOME/.local/bin/uv" \
  "python3.13_path=$HOME/.local/bin/python3.13" \
  "py_path=$HOME/.local/bin/py" \
  "uv_version=uv $UV_VERSION ($UV_PLATFORM)" \
  "python3.13_version=Python $PYTHON_VERSION" \
  "py_3.13_version=Python $PYTHON_VERSION" \
  "py_3.13_probe=$PYTHON_VERSION|x86_64|linux" \
  "uv_platform=$UV_PLATFORM" \
  "uv_url=$UV_URL" \
  "uv_sha256=$UV_SHA256" \
  "python_version=$PYTHON_VERSION" \
  "python_platform=$PYTHON_PLATFORM" \
  "python_release=$PYTHON_RELEASE" \
  "python_archive=$PYTHON_ARCHIVE" \
  "python_url=$PYTHON_URL" \
  "python_sha256=$PYTHON_SHA256"; do
  if [[ -f "$toolchain_receipt" ]] && grep -Fqx -- "$receipt_line" "$toolchain_receipt"; then
    echo "PASS receipt $receipt_line"
  else
    echo "FAIL receipt missing $receipt_line"
    failures=$((failures + 1))
  fi
done
login_shell="$(command -v bash)"
login_path="$(PATH=/usr/bin:/bin HOME="$HOME" "$login_shell" -lc 'printf "%s" "$PATH"')"
for required_path in "$HOME/.local/bin" "$HOME/.cargo/bin"; do
  if [[ ":$login_path:" == *":$required_path:"* ]]; then
    echo "PASS login PATH includes $required_path"
  else
    echo "FAIL login PATH omits $required_path"
    failures=$((failures + 1))
  fi
done
for command in rtk codex claude herdr; do
  login_command="$(PATH=/usr/bin:/bin HOME="$HOME" "$login_shell" -lc "command -v $command" 2>/dev/null || true)"
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
