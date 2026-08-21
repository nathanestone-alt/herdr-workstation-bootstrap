#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

# verify.sh sources the attested bootstrap functions, so run it from a
# disposable clean source fixture rather than treating the mutable test
# checkout as an authority input.
source_fixture="$test_root/source"
cp -a -- "$repo_root/." "$source_fixture/"
rm -rf -- "$source_fixture/.git"
git -C "$source_fixture" init -q
git -C "$source_fixture" config user.email fixture@example.invalid
git -C "$source_fixture" config user.name fixture
git -C "$source_fixture" add -f .
git -C "$source_fixture" commit -qm 'clean verify fixture'
repo_root="$source_fixture"
export HOME="$test_root/home"
# shellcheck disable=SC1091
source "$repo_root/config/ubuntu-toolchain.lock"
lock_sha256="$(sha256sum "$repo_root/config/ubuntu-toolchain.lock" | awk '{print $1}')"
managed_bin="$HOME/.local/bin"
mkdir -p "$managed_bin"
profile_dir="$HOME/.config/herdr-workstation"
mkdir -p "$profile_dir"
cat > "$profile_dir/profile.sh" <<'EOF'
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
EOF
printf '. "$HOME/.config/herdr-workstation/profile.sh"\n' > "$HOME/.profile"

checked_commands=(git gh ssh sshd mosh tailscale rustup cargo rtk codex claude herdr bun pwsh mount.cifs uv python3.13 py)
fixture_commands=("${checked_commands[@]}" systemctl)
for command_name in "${fixture_commands[@]}"; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$managed_bin/$command_name"
  chmod +x "$managed_bin/$command_name"
done
cat > "$managed_bin/uv" <<'EOF'
#!/usr/bin/env bash
printf 'uv 0.12.5 (x86_64-unknown-linux-gnu)\n'
EOF
cat > "$managed_bin/python3.13" <<'EOF'
#!/usr/bin/env bash
printf 'Python 3.13.15\n'
EOF
cat > "$managed_bin/py" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == '-3.13' ]] || exit 2
shift
case "${1:-}" in
  --version) printf 'Python 3.13.15\n' ;;
  -c) printf '3.13.15|x86_64|linux\n' ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$managed_bin/uv" "$managed_bin/python3.13" "$managed_bin/py"
cat > "$managed_bin/rustup" <<EOF
#!/usr/bin/env bash
printf 'rustup %s (fixturehash 2026-08-19)\\n' '$RUSTUP_VERSION'
EOF
cat > "$managed_bin/rustc" <<EOF
#!/usr/bin/env bash
printf 'rustc %s (fixturehash 2026-08-19)\\n' '$RUST_TOOLCHAIN'
EOF
cat > "$managed_bin/node" <<EOF
#!/usr/bin/env bash
printf 'v%s\\n' '$NODE_VERSION'
EOF
cat > "$managed_bin/npm" <<'EOF'
#!/usr/bin/env bash
printf '11.6.0\n'
EOF
cat > "$managed_bin/codex" <<EOF
#!/usr/bin/env bash
printf 'codex-cli %s\\n' '$CODEX_VERSION'
EOF
cat > "$managed_bin/claude" <<EOF
#!/usr/bin/env bash
printf '%s\\n' '$CLAUDE_VERSION'
EOF
cat > "$managed_bin/bun" <<EOF
#!/usr/bin/env bash
printf '%s\\n' '$BUN_VERSION'
EOF
cat > "$managed_bin/herdr" <<EOF
#!/usr/bin/env bash
printf 'herdr %s\\n' '$HERDR_VERSION'
EOF
cat > "$managed_bin/pwsh" <<EOF
#!/usr/bin/env bash
printf '%s\\n' '$POWERSHELL_VERSION'
EOF
cat > "$managed_bin/dpkg-query" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
package="${@: -1}"
case "$package" in
  cifs-utils|curl|git|git-lfs|gh|jq|mosh|openssh-client|openssh-server|ripgrep|rsync)
    printf 'apt:%s=fixture-%s\n' "$package" "$package"
    ;;
  *) exit 1 ;;
esac
EOF
node_bin="$HOME/.local/lib/node-v${NODE_VERSION}-linux-x64/bin"
mkdir -p "$node_bin"
for node_tool in node npm codex claude bun; do
  mv "$managed_bin/$node_tool" "$node_bin/$node_tool"
  ln -s "$node_bin/$node_tool" "$managed_bin/$node_tool"
done
chmod +x \
  "$managed_bin/rustup" "$managed_bin/rustc" "$managed_bin/node" "$managed_bin/npm" \
  "$managed_bin/codex" "$managed_bin/claude" "$managed_bin/bun" "$managed_bin/herdr" \
  "$managed_bin/pwsh" "$managed_bin/dpkg-query"
mkdir -p "$HOME/.local/state/herdr-workstation-bootstrap"
{
  printf 'receipt_format=issue-961-toolchain-v2\n'
  printf 'lock_sha256=%s\n' "$lock_sha256"
  printf 'host_platform=linux\n'
  printf 'host_architecture=x86_64\n'
  printf 'uv_path=%s\n' "$HOME/.local/bin/uv"
  printf 'python3.13_path=%s\n' "$HOME/.local/bin/python3.13"
  printf 'py_path=%s\n' "$HOME/.local/bin/py"
  printf 'uv_version=uv %s (%s)\n' "$UV_VERSION" "$UV_PLATFORM"
  printf 'uv_url=%s\n' "$UV_URL"
  printf 'uv_sha256=%s\n' "$UV_SHA256"
  printf 'python3.13_version=Python %s\n' "$PYTHON_VERSION"
  printf 'py_3.13_version=Python %s\n' "$PYTHON_VERSION"
  printf 'py_3.13_probe=%s|x86_64|linux\n' "$PYTHON_VERSION"
  printf 'uv_platform=%s\n' "$UV_PLATFORM"
  printf 'python_version=%s\n' "$PYTHON_VERSION"
  printf 'python_platform=%s\n' "$PYTHON_PLATFORM"
  printf 'python_release=%s\n' "$PYTHON_RELEASE"
  printf 'python_archive=%s\n' "$PYTHON_ARCHIVE"
  printf 'python_url=%s\n' "$PYTHON_URL"
  printf 'python_sha256=%s\n' "$PYTHON_SHA256"
  printf 'tailscale=%s\n' "$TAILSCALE_VERSION"
  printf 'rustup=rustup %s (fixturehash 2026-08-19)\n' "$RUSTUP_VERSION"
  printf 'rustc=rustc %s (fixturehash 2026-08-19)\n' "$RUST_TOOLCHAIN"
  printf 'node=v%s\n' "$NODE_VERSION"
  printf 'npm=11.6.0\n'
  printf 'codex=codex-cli %s\n' "$CODEX_VERSION"
  printf 'claude=%s\n' "$CLAUDE_VERSION"
  printf 'bun=%s\n' "$BUN_VERSION"
  printf 'herdr=herdr %s\n' "$HERDR_VERSION"
  printf 'powershell=%s\n' "$POWERSHELL_VERSION"
  for package in cifs-utils curl git git-lfs gh jq mosh openssh-client openssh-server ripgrep rsync; do
    printf 'apt:%s=fixture-%s\n' "$package" "$package"
  done
} > "$HOME/.local/state/herdr-workstation-bootstrap/toolchain-manifest.txt"

# Exercise verify.sh's real bash -lc branch without allowing Git Bash's
# machine-wide /etc/profile to replace the fixture HOME. The wrapper still
# passes the exact -lc payload to Bash, so malformed nested quoting fails.
cat > "$managed_bin/bash" <<'EOF'
#!/bin/bash
set -euo pipefail
if [[ "${1:-}" == -lc ]]; then
  shift
  printf '%s\n' "$PATH" >> "$HOME/.login-shell-input-paths"
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
if [[ "${1:-}" == '-qi' && "${2:-}" == 'microsoft' ]]; then
  exit 1
fi
exec /usr/bin/grep "$@"
EOF
cat > "$managed_bin/ps" <<'EOF'
#!/bin/bash
printf 'systemd\n'
EOF
chmod +x "$managed_bin/bash" "$managed_bin/uname" "$managed_bin/grep" "$managed_bin/ps"

run_verify_layout() {
  local layout="$1"
  local output="$test_root/verify-output-$layout.txt"
  rm -f "$HOME/.login-shell-input-paths"
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
  [[ -s "$HOME/.login-shell-input-paths" ]] || {
    echo "Login-shell PATH input was not captured for layout '$layout'." >&2
    exit 1
  }
  while IFS= read -r login_input_path; do
    [[ "$login_input_path" == '/usr/bin:/bin' ]] || {
      echo "verify.sh invoked a login shell with unsanitized PATH '$login_input_path' for layout '$layout'." >&2
      exit 1
    }
  done < "$HOME/.login-shell-input-paths"
}

run_verify_layout profile
run_verify_layout bash-profile
run_verify_layout bash-login

expect_unmanaged_managed_path_failure() {
  local command_name="$1"
  local managed_path="$HOME/.local/bin/$command_name"
  local managed_backup="$test_root/managed-$command_name"
  local unmanaged_bin="$test_root/unmanaged-$command_name"
  local unmanaged_path="$unmanaged_bin/$command_name"
  local output="$test_root/verify-output-unmanaged-$command_name.txt"
  mkdir -p "$unmanaged_bin"
  [[ -e "$managed_path" || -L "$managed_path" ]] || {
    echo "Managed fixture is missing for $command_name." >&2
    exit 1
  }
  mv "$managed_path" "$managed_backup"
  cp -L "$managed_backup" "$unmanaged_path"
  set +e
  PATH="$unmanaged_bin:/usr/bin:/bin" /bin/bash "$repo_root/scripts/ubuntu/verify.sh" > "$output" 2>&1
  local status=$?
  set -e
  mv "$managed_backup" "$managed_path"
  [[ "$status" -ne 0 ]] || {
    cat "$output" >&2
    echo "verify.sh accepted unmanaged $command_name." >&2
    exit 1
  }
  grep -Fq "FAIL managed target $command_name expected $managed_path (got $unmanaged_path)" "$output" || {
    cat "$output" >&2
    echo "verify.sh did not reject unmanaged $command_name." >&2
    exit 1
  }
}

# These fixtures still return the locked-looking values, so only the managed
# executable-path gate can make the negative cases fail.
expect_unmanaged_managed_path_failure rustup
expect_unmanaged_managed_path_failure node

expect_receipt_field_failure() {
  local field="$1"
  local receipt="$HOME/.local/state/herdr-workstation-bootstrap/toolchain-manifest.txt"
  local backup="$test_root/receipt-$field.before"
  local output="$test_root/verify-output-tampered-$field.txt"
  cp "$receipt" "$backup"
  sed -i "/^${field}=/c\\${field}=tampered" "$receipt"
  set +e
  PATH='/usr/bin:/bin' /bin/bash "$repo_root/scripts/ubuntu/verify.sh" > "$output" 2>&1
  local status=$?
  set -e
  mv "$backup" "$receipt"
  [[ "$status" -ne 0 ]] || { cat "$output" >&2; echo "verify.sh accepted tampered $field." >&2; exit 1; }
  grep -Eq '^FAIL receipt (missing|mismatch) ' "$output" || { cat "$output" >&2; echo "verify.sh did not report tampered $field." >&2; exit 1; }
}

receipt_fields=(
  receipt_format lock_sha256 host_platform host_architecture
  uv_path python3.13_path py_path uv_version python3.13_version
  py_3.13_version py_3.13_probe uv_platform uv_url uv_sha256
  python_version python_platform python_release python_archive python_url python_sha256 tailscale
  rustup rustc node npm codex claude bun herdr powershell
)
for receipt_field in "${receipt_fields[@]}"; do
  expect_receipt_field_failure "$receipt_field"
done
expect_receipt_field_failure 'apt:cifs-utils'

expect_receipt_missing_field() {
  local field="$1"
  local receipt="$HOME/.local/state/herdr-workstation-bootstrap/toolchain-manifest.txt"
  local backup="$test_root/receipt-missing-$field.before"
  local output="$test_root/verify-output-missing-$field.txt"
  cp "$receipt" "$backup"
  sed -i "/^${field}=/d" "$receipt"
  set +e
  PATH='/usr/bin:/bin' /bin/bash "$repo_root/scripts/ubuntu/verify.sh" > "$output" 2>&1
  local status=$?
  set -e
  mv "$backup" "$receipt"
  [[ "$status" -ne 0 ]] || { cat "$output" >&2; echo "verify.sh accepted missing $field." >&2; exit 1; }
  grep -Fq "FAIL receipt missing $field" "$output" || {
    cat "$output" >&2
    echo "verify.sh did not report missing $field." >&2
    exit 1
  }
}

expect_receipt_missing_field rustup
expect_receipt_missing_field 'apt:cifs-utils'

expect_receipt_structure_failure() {
  local case_name="$1"
  local extra_line="$2"
  local receipt="$HOME/.local/state/herdr-workstation-bootstrap/toolchain-manifest.txt"
  local backup="$test_root/receipt-$case_name.before"
  local output="$test_root/verify-output-$case_name.txt"
  cp "$receipt" "$backup"
  printf '%s\n' "$extra_line" >> "$receipt"
  set +e
  PATH='/usr/bin:/bin' /bin/bash "$repo_root/scripts/ubuntu/verify.sh" > "$output" 2>&1
  local status=$?
  set -e
  mv "$backup" "$receipt"
  [[ "$status" -ne 0 ]] || { cat "$output" >&2; echo "verify.sh accepted $case_name receipt." >&2; exit 1; }
  grep -Eq '^FAIL receipt (duplicate|malformed|unknown) ' "$output" || {
    cat "$output" >&2
    echo "verify.sh did not report $case_name receipt." >&2
    exit 1
  }
}

expect_receipt_structure_failure duplicate-same "uv_version=uv $UV_VERSION ($UV_PLATFORM)"
expect_receipt_structure_failure duplicate-conflict 'uv_version=uv 0.0.0 (x86_64-unknown-linux-gnu)'
expect_receipt_structure_failure duplicate-tailscale "tailscale=$TAILSCALE_VERSION"
expect_receipt_structure_failure duplicate-rustup "rustup=rustup $RUSTUP_VERSION (fixturehash 2026-08-19)"
expect_receipt_structure_failure malformed 'not a receipt assignment'
expect_receipt_structure_failure unknown 'future_key=not-allowed'
expect_receipt_structure_failure extra-apt 'apt:future-package=fixture-1'

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
