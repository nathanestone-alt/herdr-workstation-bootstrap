#!/usr/bin/env bash
set -euo pipefail
umask 022

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

canonical_origin='https://github.com/nathanestone-alt/herdr-workstation-bootstrap.git'
fixture_root="$test_root/fixture"
fixture_home="$fixture_root/home"
source_fixture="$test_root/source"
dirty_source="$test_root/dirty-source"
transport="$fixture_root/transport.git"
mkdir -p "$fixture_root" "$fixture_home"

cp -a -- "$repo_root/." "$source_fixture/"
/usr/bin/rm -rf -- "$source_fixture/.git" "$source_fixture/.agents" "$source_fixture/.codex"
chmod 0755 "$source_fixture"

# Build the managed user fixture first; the committed verify fixture below
# maps only its host-command seam to these binaries. The production verifier
# still runs through the installed launcher and its real capability checks.
fixture_system_bin="$fixture_home/system-bin"
managed_bin="$fixture_home/.local/bin"
mkdir -p "$fixture_system_bin" "$managed_bin" "$fixture_home/.cargo/bin" \
  "$fixture_home/.config/herdr-workstation" "$fixture_home/.local/state/herdr-workstation-bootstrap"
# shellcheck disable=SC1091
source "$source_fixture/config/ubuntu-toolchain.lock"
lock_sha256="$(/usr/bin/sha256sum "$source_fixture/config/ubuntu-toolchain.lock" | /usr/bin/gawk '{print $1}')"
printf 'export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"\n' > "$fixture_home/.profile"

cat > "$fixture_system_bin/bash" <<'EOF'
#!/usr/bin/bash
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
cat > "$fixture_system_bin/grep" <<'EOF'
#!/usr/bin/bash
if [[ "${1:-}" == -qi && "${2:-}" == microsoft ]]; then exit 1; fi
exec /usr/bin/grep "$@"
EOF
cat > "$fixture_system_bin/ps" <<'EOF'
#!/usr/bin/bash
printf 'systemd\n'
EOF
cat > "$fixture_system_bin/uname" <<'EOF'
#!/usr/bin/bash
printf '6.8.0-fixture\n'
EOF
cat > "$fixture_system_bin/systemctl" <<'EOF'
#!/usr/bin/bash
if [[ "${1:-}" == is-active ]]; then exit 0; fi
exit 0
EOF
cat > "$fixture_system_bin/dpkg-query" <<'EOF'
#!/usr/bin/bash
set -euo pipefail
package="${@: -1}"
case "$package" in
  cifs-utils|curl|gawk|git|git-lfs|gh|jq|mosh|openssh-client|openssh-server|ripgrep|rsync)
    printf 'apt:%s=fixture-%s\n' "$package" "$package"
    ;;
  *) exit 1 ;;
esac
EOF
for command_name in git gh ssh sshd mosh tailscale pwsh mount.cifs; do
  cat > "$fixture_system_bin/$command_name" <<EOF
#!/usr/bin/bash
case "${1:-}" in
  version) printf '%s\n' '$TAILSCALE_VERSION' ;;
  --version) printf '%s\n' '$command_name fixture' ;;
  *) exit 0 ;;
esac
EOF
done
cat > "$fixture_system_bin/pwsh" <<EOF
#!/usr/bin/bash
if [[ "${1:-}" == --version ]]; then printf '%s\n' '$POWERSHELL_VERSION'; else printf '%s\n' '$POWERSHELL_VERSION'; fi
EOF
chmod 0755 "$fixture_system_bin"/*

cat > "$managed_bin/uv" <<EOF
#!/usr/bin/bash
printf 'uv %s (%s)\\n' '$UV_VERSION' '$UV_PLATFORM'
EOF
cat > "$managed_bin/python3.13" <<EOF
#!/usr/bin/bash
printf 'Python %s\\n' '$PYTHON_VERSION'
EOF
cat > "$managed_bin/py" <<'EOF'
#!/usr/bin/bash
set -euo pipefail
[[ "${1:-}" == -3.13 ]] || exit 2
shift
case "${1:-}" in
  --version) printf 'Python 3.13.15\n' ;;
  -c) printf '3.13.15|x86_64|linux\n' ;;
  *) exit 2 ;;
esac
EOF
cat > "$managed_bin/rustup" <<EOF
#!/usr/bin/bash
printf 'rustup %s (fixturehash 2026-08-19)\\n' '$RUSTUP_VERSION'
EOF
cat > "$managed_bin/rustc" <<EOF
#!/usr/bin/bash
printf 'rustc %s (fixturehash 2026-08-19)\\n' '$RUST_TOOLCHAIN'
EOF
cat > "$managed_bin/node" <<EOF
#!/usr/bin/bash
printf 'v%s\\n' '$NODE_VERSION'
EOF
cat > "$managed_bin/npm" <<'EOF'
#!/usr/bin/bash
printf '11.6.0\n'
EOF
cat > "$managed_bin/codex" <<EOF
#!/usr/bin/bash
printf 'codex-cli %s\\n' '$CODEX_VERSION'
EOF
cat > "$managed_bin/claude" <<EOF
#!/usr/bin/bash
printf '%s\\n' '$CLAUDE_VERSION'
EOF
cat > "$managed_bin/bun" <<EOF
#!/usr/bin/bash
printf '%s\\n' '$BUN_VERSION'
EOF
cat > "$managed_bin/herdr" <<EOF
#!/usr/bin/bash
printf 'herdr %s\\n' '$HERDR_VERSION'
EOF
chmod 0755 "$managed_bin"/*
for managed_stub in cargo rtk; do
  printf '#!/usr/bin/bash\nexit 0\n' > "$managed_bin/$managed_stub"
  chmod 0755 "$managed_bin/$managed_stub"
done
node_bin="$fixture_home/.local/lib/node-v${NODE_VERSION}-linux-x64/bin"
mkdir -p "$node_bin"
for node_tool in node npm codex claude bun; do
  /usr/bin/mv "$managed_bin/$node_tool" "$node_bin/$node_tool"
  /usr/bin/ln -s "$node_bin/$node_tool" "$managed_bin/$node_tool"
done

# Make the fixture's verify entrypoint use only the disposable host-command
# seam. This override is committed into the fixture transport before the
# launcher is provisioned, so it cannot be injected after the capability gate.
/usr/bin/git -C "$source_fixture" init -q
/usr/bin/git -C "$source_fixture" config user.email fixture@example.invalid
/usr/bin/git -C "$source_fixture" config user.name fixture
/usr/bin/git -C "$source_fixture" remote add origin "$canonical_origin"
/usr/bin/head -n -3 "$source_fixture/scripts/ubuntu/verify.sh" > "$source_fixture/scripts/ubuntu/verify.sh.tmp"
/usr/bin/mv -T "$source_fixture/scripts/ubuntu/verify.sh.tmp" "$source_fixture/scripts/ubuntu/verify.sh"
cat >> "$source_fixture/scripts/ubuntu/verify.sh" <<EOF
verify_system_command_path() {
  case "\$1" in
    bash|git|gh|ssh|sshd|mosh|tailscale|pwsh|mount.cifs|systemctl|dpkg-query|uname|grep|ps)
      printf '%s/%s\\n' '$fixture_system_bin' "\$1"
      ;;
    *) return 1 ;;
  esac
}
verify_assert_system_binary() {
  local path="\$1"
  [[ -f "\$path" && ! -L "\$path" && -x "\$path" ]]
}
if [[ "\${BASH_SOURCE[0]}" == "\$0" ]]; then
  verify_main "\$@"
fi
EOF
chmod 0755 "$source_fixture/scripts/ubuntu/verify.sh"

{
  printf 'receipt_format=issue-961-toolchain-v2\n'
  printf 'lock_sha256=%s\n' "$lock_sha256"
  printf 'host_platform=linux\n'
  printf 'host_architecture=x86_64\n'
  printf 'uv_path=%s\n' "$fixture_home/.local/bin/uv"
  printf 'python3.13_path=%s\n' "$fixture_home/.local/bin/python3.13"
  printf 'py_path=%s\n' "$fixture_home/.local/bin/py"
  printf 'uv_version=uv %s (%s)\n' "$UV_VERSION" "$UV_PLATFORM"
  printf 'python3.13_version=Python %s\n' "$PYTHON_VERSION"
  printf 'py_3.13_version=Python %s\n' "$PYTHON_VERSION"
  printf 'py_3.13_probe=%s|x86_64|linux\n' "$PYTHON_VERSION"
  printf 'uv_platform=%s\n' "$UV_PLATFORM"
  printf 'uv_url=%s\n' "$UV_URL"
  printf 'uv_sha256=%s\n' "$UV_SHA256"
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
  for package in cifs-utils curl gawk git git-lfs gh jq mosh openssh-client openssh-server ripgrep rsync; do
    printf 'apt:%s=fixture-%s\n' "$package" "$package"
  done
} > "$fixture_home/.local/state/herdr-workstation-bootstrap/toolchain-manifest.txt"

/usr/bin/git -C "$source_fixture" add -f .
/usr/bin/git -C "$source_fixture" commit -qm 'verify launcher fixture'
fixture_commit="$(/usr/bin/git -C "$source_fixture" rev-parse --verify HEAD^{commit})"
/usr/bin/git clone -q --bare "$source_fixture" "$transport"
chmod 0700 "$transport"
/usr/bin/bash "$repo_root/scripts/ubuntu/install-trusted-launcher.sh" \
  --origin "$canonical_origin" --commit "$fixture_commit" \
  --fixture-root "$fixture_root" --fixture-transport "$transport" --fixture-home "$fixture_home" \
  > "$test_root/launcher-install.out"
launcher="$fixture_root/usr/local/libexec/herdr-workstation-bootstrap"
[[ -x "$launcher" ]] || { echo 'Verify fixture launcher was not published.' >&2; exit 1; }

hostile_bin="$test_root/hostile-bin"
mkdir -p "$hostile_bin"
for hostile_command in env bash git realpath stat sha256sum gawk; do
  marker="$test_root/path-$hostile_command-reached"
  {
    printf '#!/usr/bin/bash\n'
    printf ': > %q\n' "$marker"
    printf 'exit 99\n'
  } > "$hostile_bin/$hostile_command"
  chmod 0755 "$hostile_bin/$hostile_command"
done
bash_env="$test_root/bash-env"
printf ': > %q\n' "$test_root/bash-env-reached" > "$bash_env"
chmod 0755 "$bash_env"

run_verify() {
  /usr/bin/env -i HOME="$fixture_home" PATH="$hostile_bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    BASH_ENV="$bash_env" ENV= LC_ALL=C TZ=UTC \
    "$launcher" --entrypoint verify --
}
verify_output="$test_root/verify-output"
run_verify > "$verify_output" 2>&1 || {
  cat "$verify_output" >&2
  echo 'End-to-end launcher→verify fixture failed.' >&2
  exit 1
}
grep -Fq 'Ubuntu bootstrap verification passed.' "$verify_output" ||
  { cat "$verify_output" >&2; echo 'Verify fixture did not complete.' >&2; exit 1; }
grep -Fq 'PASS login PATH includes' "$verify_output" ||
  { cat "$verify_output" >&2; echo 'Verify fixture did not exercise login PATH checks.' >&2; exit 1; }
while IFS= read -r login_path; do
  [[ "$login_path" == '/usr/bin:/bin' ]] ||
    { echo "Verifier passed an unsanitized login PATH: $login_path" >&2; exit 1; }
done < "$fixture_home/.login-shell-input-paths"

# A post-provisioning local checkout mutation, including code before line 10,
# must not alter the staged verify bytes selected by the launcher.
cp -a -- "$source_fixture" "$dirty_source"
dirty_marker="$test_root/dirty-verify-before-line-10"
{
  /usr/bin/head -n 8 "$dirty_source/scripts/ubuntu/verify.sh"
  printf ': > %q\n' "$dirty_marker"
  /usr/bin/tail -n +9 "$dirty_source/scripts/ubuntu/verify.sh"
} > "$dirty_source/scripts/ubuntu/verify.sh.tmp"
/usr/bin/mv -T -- "$dirty_source/scripts/ubuntu/verify.sh.tmp" "$dirty_source/scripts/ubuntu/verify.sh"
set +e
run_verify > "$test_root/dirty-verify-output" 2>&1
dirty_status=$?
set -e
(( dirty_status == 0 )) || { cat "$test_root/dirty-verify-output" >&2; exit 1; }
[[ ! -e "$dirty_marker" ]] || { echo 'Dirty verify code before line 10 executed.' >&2; exit 1; }

# Forged legacy markers and a caller-selected user-owned root cannot authorize
# a direct invocation, and the failure retains its capability status.
set +e
/usr/bin/env -i HOME="$fixture_home" PATH=/usr/sbin:/usr/bin:/sbin:/bin BASH_ENV= ENV= \
  HERDR_VERIFY_TRUSTED_LAUNCHER=1 HERDR_VERIFY_VERIFIED_ENTRYPOINT=1 \
  HERDR_VERIFY_REPO_ROOT="$dirty_source" HERDR_VERIFY_GIT_OWNER_UID="$(id -u)" \
  HERDR_VERIFY_GIT_OWNER_GID="$(id -g)" /usr/bin/bash \
  "$source_fixture/scripts/ubuntu/verify.sh" > "$test_root/direct-verify-output" 2>&1
direct_status=$?
set -e
(( direct_status == 24 )) || {
  cat "$test_root/direct-verify-output" >&2
  echo "Direct verify returned $direct_status instead of capability rejection 24." >&2
  exit 1
}
grep -Eqi 'capability|launcher' "$test_root/direct-verify-output" ||
  { cat "$test_root/direct-verify-output" >&2; echo 'Direct verify lacked a capability rejection.' >&2; exit 1; }

for hostile_command in env bash git realpath stat sha256sum gawk; do
  [[ ! -e "$test_root/path-$hostile_command-reached" ]] || {
    echo "Verify resolved a hostile PATH command: $hostile_command" >&2
    exit 1
  }
done
[[ ! -e "$test_root/bash-env-reached" ]] || {
  echo 'BASH_ENV executed in the verify fixture.' >&2
  exit 1
}

echo 'verify launcher boundary, managed-path, receipt, login-shell, and adversarial fixtures passed.'
