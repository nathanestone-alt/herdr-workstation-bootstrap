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
check_managed_node_command_target() {
  local name="$1"
  local expected_path="$HOME/.local/bin/$name"
  local node_root="$HOME/.local/lib/node-v${NODE_VERSION}-linux-x64"
  local actual_path
  local resolved_path
  check_managed_command_target "$name" "$expected_path"
  actual_path="$(command -v "$name" 2>/dev/null || true)"
  if [[ "$actual_path" == "$expected_path" ]]; then
    resolved_path="$(realpath -e -- "$expected_path" 2>/dev/null || true)"
    if path_is_under "$resolved_path" "$node_root"; then
      echo "PASS locked Node target $name $resolved_path"
    else
      echo "FAIL locked Node target $name resolves outside Node prefix: $resolved_path"
      failures=$((failures + 1))
    fi
  fi
}
check_managed_command_target uv "$HOME/.local/bin/uv"
check_managed_command_target python3.13 "$HOME/.local/bin/python3.13"
check_managed_command_target py "$HOME/.local/bin/py"
for managed_tool in rustup rustc herdr; do
  check_managed_command_target "$managed_tool" "$HOME/.local/bin/$managed_tool"
done
for managed_tool in node npm codex claude bun; do
  check_managed_node_command_target "$managed_tool"
done

toolchain_receipt="$HOME/.local/state/herdr-workstation-bootstrap/toolchain-manifest.txt"
lock_sha256="$(sha256sum "$lock_file" | awk '{print $1}')"

record_receipt_command() {
  local key="$1"
  shift
  local output
  if ! output="$("$@" 2>&1)"; then
    echo "FAIL receipt runtime probe $key"
    receipt_failures=$((receipt_failures + 1))
    return 1
  fi
  if [[ -z "$output" || "$output" == *$'\n'* ]]; then
    echo "FAIL receipt runtime probe malformed $key"
    receipt_failures=$((receipt_failures + 1))
    return 1
  fi
  expected_by_key["$key"]="$output"
}

record_receipt_first_line() {
  local key="$1"
  shift
  local output
  if ! output="$("$@" 2>&1)"; then
    echo "FAIL receipt runtime probe $key"
    receipt_failures=$((receipt_failures + 1))
    return 1
  fi
  output="${output%%$'\n'*}"
  if [[ -z "$output" || "$output" == *$'\n'* ]]; then
    echo "FAIL receipt runtime probe malformed $key"
    receipt_failures=$((receipt_failures + 1))
    return 1
  fi
  expected_by_key["$key"]="$output"
}

validate_locked_receipt_value() {
  local key="$1"
  local value="${expected_by_key[$key]}"
  local escaped_version
  case "$key" in
    rustup)
      escaped_version="${RUSTUP_VERSION//./\\.}"
      [[ "$value" =~ ^rustup[[:space:]]${escaped_version}([[:space:]]\([^[:space:]]+[[:space:]][0-9]{4}-[0-9]{2}-[0-9]{2}\))?$ ]] || { echo "FAIL receipt locked contract $key"; return 1; }
      ;;
    rustc)
      escaped_version="${RUST_TOOLCHAIN//./\\.}"
      [[ "$value" =~ ^rustc[[:space:]]${escaped_version}([[:space:]]\([^[:space:]]+[[:space:]][0-9]{4}-[0-9]{2}-[0-9]{2}\))?$ ]] || { echo "FAIL receipt locked contract $key"; return 1; }
      ;;
    node)
      [[ "$value" == "v$NODE_VERSION" ]] || { echo "FAIL receipt locked contract $key"; return 1; }
      ;;
    npm)
      [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]] || { echo "FAIL receipt locked contract $key"; return 1; }
      ;;
    codex)
      escaped_version="${CODEX_VERSION//./\\.}"
      [[ "$value" =~ ^[^[:space:]]+[[:space:]]${escaped_version}$ ]] || { echo "FAIL receipt locked contract $key"; return 1; }
      ;;
    claude)
      escaped_version="${CLAUDE_VERSION//./\\.}"
      [[ "$value" =~ ^${escaped_version}([[:space:]]+\([^()]+\))?$ ]] || { echo "FAIL receipt locked contract $key"; return 1; }
      ;;
    bun)
      [[ "$value" == "$BUN_VERSION" ]] || { echo "FAIL receipt locked contract $key"; return 1; }
      ;;
    herdr)
      escaped_version="${HERDR_VERSION//./\\.}"
      [[ "$value" =~ ^[^[:space:]]+[[:space:]]${escaped_version}$ ]] || { echo "FAIL receipt locked contract $key"; return 1; }
      ;;
    powershell)
      [[ "$value" == "$POWERSHELL_VERSION" ]] || { echo "FAIL receipt locked contract $key"; return 1; }
      ;;
  esac
}

append_apt_receipt_expectations() {
  local package
  local apt_line
  local apt_key
  local apt_value
  local apt_arch
  local -a apt_packages=(
    cifs-utils curl git git-lfs gh jq mosh openssh-client openssh-server ripgrep rsync
  )
  for package in "${apt_packages[@]}"; do
    if ! apt_line="$(dpkg-query -W -f='apt:${binary:Package}=${Version}\n' "$package" 2>/dev/null)"; then
      echo "FAIL receipt runtime probe apt:$package"
      receipt_failures=$((receipt_failures + 1))
      return 1
    fi
    if [[ "$apt_line" == *$'\n'* || "$apt_line" != apt:* || "$apt_line" != *"="* ]]; then
      echo "FAIL receipt runtime probe malformed apt:$package"
      receipt_failures=$((receipt_failures + 1))
      return 1
    fi
    apt_key="${apt_line%%=*}"
    apt_value="${apt_line#*=}"
    if [[ "$apt_key" != "apt:$package" ]]; then
      apt_arch="${apt_key#apt:$package}"
      if [[ ! "$apt_arch" =~ ^:[A-Za-z0-9_.+-]+$ ]]; then
        echo "FAIL receipt locked contract $apt_key"
        receipt_failures=$((receipt_failures + 1))
        return 1
      fi
    fi
    if [[ -z "$apt_value" || "$apt_value" == *[[:space:]=]* ]]; then
      echo "FAIL receipt runtime probe malformed $apt_key"
      receipt_failures=$((receipt_failures + 1))
      return 1
    fi
    required_keys+=("$apt_key")
    expected_by_key["$apt_key"]="$apt_value"
  done
}

validate_runtime_receipt() {
  local line_number=0
  local line
  local key
  local value
  local expected
  local receipt_failures=0
  local -a required_keys=(
    receipt_format lock_sha256 host_platform host_architecture
    uv_path python3.13_path py_path uv_version python3.13_version
    py_3.13_version py_3.13_probe uv_platform uv_url uv_sha256
    python_version python_platform python_release python_archive python_url python_sha256 tailscale
    rustup rustc node npm codex claude bun herdr powershell
  )
  local -A expected_by_key=()
  local -A seen_keys=()

  expected_by_key[receipt_format]='issue-961-toolchain-v2'
  expected_by_key[lock_sha256]="$lock_sha256"
  expected_by_key[host_platform]='linux'
  expected_by_key[host_architecture]='x86_64'
  expected_by_key[uv_path]="$HOME/.local/bin/uv"
  expected_by_key[python3.13_path]="$HOME/.local/bin/python3.13"
  expected_by_key[py_path]="$HOME/.local/bin/py"
  expected_by_key[uv_version]="uv $UV_VERSION ($UV_PLATFORM)"
  expected_by_key[python3.13_version]="Python $PYTHON_VERSION"
  expected_by_key[py_3.13_version]="Python $PYTHON_VERSION"
  expected_by_key[py_3.13_probe]="$PYTHON_VERSION|x86_64|linux"
  expected_by_key[uv_platform]="$UV_PLATFORM"
  expected_by_key[uv_url]="$UV_URL"
  expected_by_key[uv_sha256]="$UV_SHA256"
  expected_by_key[python_version]="$PYTHON_VERSION"
  expected_by_key[python_platform]="$PYTHON_PLATFORM"
  expected_by_key[python_release]="$PYTHON_RELEASE"
  expected_by_key[python_archive]="$PYTHON_ARCHIVE"
  expected_by_key[python_url]="$PYTHON_URL"
  expected_by_key[python_sha256]="$PYTHON_SHA256"
  expected_by_key[tailscale]="$TAILSCALE_VERSION"

  if [[ ! -f "$toolchain_receipt" || -L "$toolchain_receipt" ]]; then
    echo "FAIL receipt missing $toolchain_receipt"
    return 1
  fi
  local runtime_probe_failed=0
  record_receipt_first_line rustup rustup --version || runtime_probe_failed=1
  record_receipt_command rustc rustc --version || runtime_probe_failed=1
  record_receipt_command node node --version || runtime_probe_failed=1
  record_receipt_command npm npm --version || runtime_probe_failed=1
  record_receipt_command codex codex --version || runtime_probe_failed=1
  record_receipt_command claude claude --version || runtime_probe_failed=1
  record_receipt_command bun bun --version || runtime_probe_failed=1
  record_receipt_command herdr herdr --version || runtime_probe_failed=1
  record_receipt_command powershell pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' || runtime_probe_failed=1
  if (( runtime_probe_failed )); then
    return 1
  fi
  for runtime_key in rustup rustc node npm codex claude bun herdr powershell; do
    if ! validate_locked_receipt_value "$runtime_key"; then
      receipt_failures=$((receipt_failures + 1))
    fi
  done
  append_apt_receipt_expectations || return 1

  while IFS= read -r line || [[ -n "$line" ]]; do
    line_number=$((line_number + 1))
    if [[ ! "$line" =~ ^([A-Za-z][A-Za-z0-9_.:-]*)=(.*)$ ]]; then
      echo "FAIL receipt malformed line $line_number"
      receipt_failures=$((receipt_failures + 1))
      continue
    fi
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    if [[ -z "${expected_by_key[$key]+present}" ]]; then
      echo "FAIL receipt unknown key $key"
      receipt_failures=$((receipt_failures + 1))
      continue
    fi
    if [[ -n "${seen_keys[$key]+present}" ]]; then
      echo "FAIL receipt duplicate key $key"
      receipt_failures=$((receipt_failures + 1))
      continue
    fi
    expected="${expected_by_key[$key]}"
    if [[ "$value" != "$expected" ]]; then
      echo "FAIL receipt mismatch $key"
      receipt_failures=$((receipt_failures + 1))
      continue
    fi
    seen_keys["$key"]=1
    echo "PASS receipt $key=$value"
  done < "$toolchain_receipt"
  for key in "${required_keys[@]}"; do
    if [[ -z "${seen_keys[$key]+present}" ]]; then
      echo "FAIL receipt missing $key"
      receipt_failures=$((receipt_failures + 1))
    fi
  done
  [[ "$receipt_failures" -eq 0 && "${#seen_keys[@]}" -eq "${#required_keys[@]}" ]]
}

if ! validate_managed_paths "$toolchain_receipt"; then
  echo "FAIL receipt path is not securely confined: $toolchain_receipt"
  failures=$((failures + 1))
fi
if ! validate_runtime_receipt; then
  failures=$((failures + 1))
fi
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
