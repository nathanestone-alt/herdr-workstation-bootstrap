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

# uv is published as a symlink into its managed runtime directory, exactly as
# production installs it (fence_replace_link in bootstrap.sh), so the verifier's
# managed-command resolution must accept that location, not just ~/.local/bin.
uv_runtime_dir="$fixture_home/.local/lib/herdr-workstation/uv/$UV_VERSION/$UV_PLATFORM"
mkdir -p "$uv_runtime_dir"
cat > "$uv_runtime_dir/uv" <<EOF
#!/usr/bin/bash
printf 'uv %s (%s)\\n' '$UV_VERSION' '$UV_PLATFORM'
EOF
chmod 0755 "$uv_runtime_dir/uv"
/usr/bin/ln -s -- "$uv_runtime_dir/uv" "$managed_bin/uv"
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
node_root="$fixture_home/.local/lib/node-v$NODE_VERSION-linux-x64"
node_bin="$node_root/bin"
npm_cli="$node_root/lib/node_modules/npm/bin/npm-cli.js"
codex_js="$node_root/lib/node_modules/@openai/codex/bin/codex.js"
pinned_node_marker="$test_root/pinned-node-executions"
mkdir -p "$node_bin" "$(dirname "$npm_cli")" "$(dirname "$codex_js")"
cat > "$node_bin/node" <<EOF
#!/usr/bin/bash
set -euo pipefail
fixture_npm_cli='$npm_cli'
fixture_codex_js='$codex_js'
fixture_marker='$pinned_node_marker'
script="\$1"
if [[ "\$script" == '--version' ]]; then
  printf 'v%s\\n' '$NODE_VERSION'
  exit 0
fi
script_real="\$(/usr/bin/realpath -e -- "\$script" 2>/dev/null || true)"
case "\$script_real" in
  "\$fixture_npm_cli")
    printf '%s\\n' 'pinned-node-executed-npm' >> "\$fixture_marker"
    printf '%s\\n' '11.6.0'
    ;;
  "\$fixture_codex_js")
    printf '%s\\n' 'pinned-node-executed-codex' >> "\$fixture_marker"
    printf 'codex-cli %s\\n' '$CODEX_VERSION'
    ;;
  *)
    echo "Pinned fixture Node received unexpected arguments: \$*" >&2
    exit 24
    ;;
esac
EOF
chmod 0755 "$node_bin/node"
cat > "$npm_cli" <<'EOF'
#!/usr/bin/env node
console.log('11.6.0');
EOF
cat > "$codex_js" <<EOF
#!/usr/bin/env node
console.log('codex-cli $CODEX_VERSION');
EOF
chmod 0755 "$npm_cli" "$codex_js"
/usr/bin/ln -s -- "$npm_cli" "$node_bin/npm"
/usr/bin/ln -s -- "$codex_js" "$node_bin/codex"
cat > "$node_bin/claude" <<EOF
#!/usr/bin/bash
printf '%s\\n' '$CLAUDE_VERSION'
EOF
cat > "$node_bin/bun" <<EOF
#!/usr/bin/bash
printf '%s\\n' '$BUN_VERSION'
EOF
chmod 0755 "$node_bin/claude" "$node_bin/bun"
for node_tool in node npm codex claude bun; do
  /usr/bin/ln -s -- "$node_bin/$node_tool" "$managed_bin/$node_tool"
done
cat > "$managed_bin/herdr" <<EOF
#!/usr/bin/bash
printf 'herdr %s\\n' '$HERDR_VERSION'
EOF
chmod 0755 \
  "$managed_bin/python3.13" "$managed_bin/py" \
  "$managed_bin/rustup" "$managed_bin/rustc" "$managed_bin/herdr"
herdr_binary_sha256="$(/usr/bin/sha256sum -- "$managed_bin/herdr" | /usr/bin/gawk '{print $1}')"
for managed_stub in cargo; do
  printf '#!/usr/bin/bash\nexit 0\n' > "$managed_bin/$managed_stub"
  chmod 0755 "$managed_bin/$managed_stub"
done
cat > "$fixture_home/.cargo/bin/rtk" <<EOF
#!/usr/bin/bash
printf 'rtk %s\\n' '$RTK_VERSION'
EOF
chmod 0755 "$fixture_home/.cargo/bin/rtk"

# Producer-shaped Python evidence: the managed launcher is a regular file, and
# its controlling pyvenv.cfg names the locked managed runtime.
python_runtime_root="$fixture_home/.local/lib/herdr-workstation/python/$PYTHON_VERSION-$PYTHON_RELEASE-$PYTHON_PLATFORM"
cat > "$fixture_home/.local/pyvenv.cfg" <<EOF
home = $python_runtime_root
include-system-site-packages = false
version = $PYTHON_VERSION
EOF
chmod 0644 "$fixture_home/.local/pyvenv.cfg"
python_launcher_sha256="$(/usr/bin/sha256sum -- "$managed_bin/python3.13" | /usr/bin/gawk '{print $1}')"

# Producer-shaped receipt-authority evidence. The fixture publishes its own
# authority envelope and the committed fixture bootstrap seam points at it, so
# the verifier resolves the same path the producer recorded.
fixture_authority_dir="$fixture_root/etc/stmodel/issue-961"
fixture_authority_path="$fixture_authority_dir/receipt-authority.json"
mkdir -p "$fixture_authority_dir"
printf '{"schema_version":1,"authority_id":"#961-installation-authority-v1"}\n' > "$fixture_authority_path"
chmod 0644 "$fixture_authority_path"
authority_sha256="$(/usr/bin/sha256sum -- "$fixture_authority_path" | /usr/bin/gawk '{print $1}')"
cat >> "$source_fixture/scripts/ubuntu/bootstrap.sh" <<EOF
bootstrap_receipt_authority_path() {
  printf '%s\\n' '$fixture_authority_path'
}
EOF

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

toolchain_manifest="$fixture_home/.local/state/herdr-workstation-bootstrap/toolchain-manifest.txt"
{
  printf 'receipt_format=issue-961-toolchain-v2\n'
  printf 'lock_sha256=%s\n' "$lock_sha256"
  printf 'host_platform=linux\n'
  printf 'host_architecture=x86_64\n'
  printf 'uv_path=%s\n' "$fixture_home/.local/bin/uv"
  printf 'python3.13_path=%s\n' "$fixture_home/.local/bin/python3.13"
  printf 'python3.13_kind=regular-file\n'
  printf 'python3.13_sha256=%s\n' "$python_launcher_sha256"
  printf 'python3.13_pyvenv_cfg=%s\n' "$fixture_home/.local/pyvenv.cfg"
  printf 'py_path=%s\n' "$fixture_home/.local/bin/py"
  printf 'rtk_path=%s\n' "$fixture_home/.cargo/bin/rtk"
  printf 'rtk_version=rtk %s\n' "$RTK_VERSION"
  printf 'rtk_url=%s\n' "$RTK_URL"
  printf 'rtk_sha256=%s\n' "$RTK_SHA256"
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
  printf 'herdr_version=%s\n' "$HERDR_VERSION"
  printf 'herdr_sha256=%s\n' "$herdr_binary_sha256"
  printf 'herdr_newer_than_lock=false\n'
  printf 'powershell=%s\n' "$POWERSHELL_VERSION"
  printf 'receipt_authority_path=%s\n' "$fixture_authority_path"
  printf 'receipt_authority_sha256=%s\n' "$authority_sha256"
  for package in cifs-utils curl gawk git git-lfs gh jq mosh openssh-client openssh-server ripgrep rsync; do
    printf 'apt:%s=fixture-%s\n' "$package" "$package"
  done
} > "$toolchain_manifest"

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
grep -Fq 'PASS receipt npm=11.6.0' "$verify_output" ||
  { cat "$verify_output" >&2; echo 'Verify fixture lost npm receipt parity.' >&2; exit 1; }
grep -Fq "PASS receipt codex=codex-cli $CODEX_VERSION" "$verify_output" ||
  { cat "$verify_output" >&2; echo 'Verify fixture lost Codex receipt parity.' >&2; exit 1; }
grep -Fq 'PASS receipt python3.13_kind=regular-file' "$verify_output" ||
  { cat "$verify_output" >&2; echo 'Verify fixture lost Python kind receipt parity.' >&2; exit 1; }
grep -Fq "PASS receipt python3.13_sha256=$python_launcher_sha256" "$verify_output" ||
  { cat "$verify_output" >&2; echo 'Verify fixture lost Python digest receipt parity.' >&2; exit 1; }
grep -Fq "PASS receipt python3.13_pyvenv_cfg=$fixture_home/.local/pyvenv.cfg" "$verify_output" ||
  { cat "$verify_output" >&2; echo 'Verify fixture lost pyvenv.cfg receipt parity.' >&2; exit 1; }
grep -Fq "PASS receipt receipt_authority_path=$fixture_authority_path" "$verify_output" ||
  { cat "$verify_output" >&2; echo 'Verify fixture lost receipt-authority path parity.' >&2; exit 1; }
grep -Fq "PASS receipt receipt_authority_sha256=$authority_sha256" "$verify_output" ||
  { cat "$verify_output" >&2; echo 'Verify fixture lost receipt-authority digest parity.' >&2; exit 1; }
grep -Fq "PASS receipt herdr_version=$HERDR_VERSION" "$verify_output" ||
  { cat "$verify_output" >&2; echo 'Verify fixture lost the locked Herdr version receipt.' >&2; exit 1; }
grep -Fq "PASS receipt herdr_sha256=$herdr_binary_sha256" "$verify_output" ||
  { cat "$verify_output" >&2; echo 'Verify fixture lost the locked Herdr digest receipt.' >&2; exit 1; }
grep -Fq 'PASS receipt herdr_newer_than_lock=false' "$verify_output" ||
  { cat "$verify_output" >&2; echo 'Verify fixture lost the equal-floor Herdr marker.' >&2; exit 1; }

# Differential parity case: a user-managed Herdr newer than the lock must pass
# verification while the manifest records its actual version, digest, and
# newer-than-lock marker.
newer_herdr_version='0.8.3'
cat > "$managed_bin/herdr" <<EOF
#!/usr/bin/bash
printf 'herdr %s\\n' '$newer_herdr_version'
EOF
chmod 0755 "$managed_bin/herdr"
newer_herdr_sha256="$(/usr/bin/sha256sum -- "$managed_bin/herdr" | /usr/bin/gawk '{print $1}')"
/usr/bin/sed -i \
  -e "s|^herdr=.*$|herdr=herdr $newer_herdr_version|" \
  -e "s|^herdr_version=.*$|herdr_version=$newer_herdr_version|" \
  -e "s|^herdr_sha256=.*$|herdr_sha256=$newer_herdr_sha256|" \
  -e 's|^herdr_newer_than_lock=.*$|herdr_newer_than_lock=true|' \
  "$toolchain_manifest"
newer_verify_output="$test_root/verify-newer-output"
run_verify > "$newer_verify_output" 2>&1 || {
  cat "$newer_verify_output" >&2
  echo 'Newer-than-lock Herdr verifier fixture failed.' >&2
  exit 1
}
grep -Fq "PASS receipt herdr=herdr $newer_herdr_version" "$newer_verify_output" ||
  { cat "$newer_verify_output" >&2; echo 'Verifier did not attest the newer Herdr version.' >&2; exit 1; }
grep -Fq "PASS receipt herdr_version=$newer_herdr_version" "$newer_verify_output" ||
  { cat "$newer_verify_output" >&2; echo 'Verifier did not attest the newer Herdr manifest version.' >&2; exit 1; }
grep -Fq "PASS receipt herdr_sha256=$newer_herdr_sha256" "$newer_verify_output" ||
  { cat "$newer_verify_output" >&2; echo 'Verifier did not attest the newer Herdr digest.' >&2; exit 1; }
grep -Fq 'PASS receipt herdr_newer_than_lock=true' "$newer_verify_output" ||
  { cat "$newer_verify_output" >&2; echo 'Verifier did not attest the newer Herdr marker.' >&2; exit 1; }
grep -Fxq 'pinned-node-executed-npm' "$pinned_node_marker" ||
  { cat "$verify_output" >&2; echo 'Pinned Node did not execute npm-cli.js.' >&2; exit 1; }
grep -Fxq 'pinned-node-executed-codex' "$pinned_node_marker" ||
  { cat "$verify_output" >&2; echo 'Pinned Node did not execute codex.js.' >&2; exit 1; }
while IFS= read -r login_path; do
  [[ "$login_path" == '/usr/bin:/bin' ]] ||
    { echo "Verifier passed an unsanitized login PATH: $login_path" >&2; exit 1; }
done < "$fixture_home/.login-shell-input-paths"

expect_ambient_shebang_failure() {
  local name="$1"
  local output="$test_root/ambient-$name-output"
  local status
  set +e
  /usr/bin/env -i HOME="$fixture_home" PATH="$fixture_system_bin" \
    "$managed_bin/$name" --version > "$output" 2>&1
  status=$?
  set -e
  (( status == 127 )) || {
    cat "$output" >&2
    echo "Ambient $name shebang returned $status instead of 127." >&2
    exit 1
  }
}
expect_ambient_shebang_failure npm
expect_ambient_shebang_failure codex

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

# The producer-emitted receipt fields are strictly validated, not ignored, and
# genuinely unknown fields still fail closed.
cp -- "$toolchain_manifest" "$test_root/toolchain-manifest.good"
expect_receipt_rejection() {
  local name="$1"
  local pattern="$2"
  local output="$test_root/receipt-$name-output"
  local status
  set +e
  run_verify > "$output" 2>&1
  status=$?
  set -e
  (( status == 1 )) || {
    cat "$output" >&2
    echo "Verify returned $status instead of receipt rejection 1 for $name." >&2
    exit 1
  }
  grep -Fq "$pattern" "$output" || {
    cat "$output" >&2
    echo "Verify did not report '$pattern' for $name." >&2
    exit 1
  }
  cp -- "$test_root/toolchain-manifest.good" "$toolchain_manifest"
}

printf 'python3.13_kindness=regular-file\n' >> "$toolchain_manifest"
expect_receipt_rejection unknown-key 'FAIL receipt unknown key python3.13_kindness'

/usr/bin/sed -i "s|^python3.13_sha256=.*$|python3.13_sha256=$(printf '0%.0s' {1..64})|" "$toolchain_manifest"
expect_receipt_rejection python-digest 'FAIL receipt mismatch python3.13_sha256'

/usr/bin/sed -i 's|^python3.13_kind=.*$|python3.13_kind=symlink|' "$toolchain_manifest"
expect_receipt_rejection python-kind 'FAIL receipt mismatch python3.13_kind'

/usr/bin/sed -i "s|^python3.13_pyvenv_cfg=.*$|python3.13_pyvenv_cfg=$fixture_home/.local/pyvenv.cfg.decoy|" "$toolchain_manifest"
expect_receipt_rejection pyvenv-path 'FAIL receipt mismatch python3.13_pyvenv_cfg'

/usr/bin/sed -i "s|^receipt_authority_sha256=.*$|receipt_authority_sha256=$(printf '0%.0s' {1..64})|" "$toolchain_manifest"
expect_receipt_rejection authority-digest 'FAIL receipt mismatch receipt_authority_sha256'

/usr/bin/sed -i "s|^receipt_authority_path=.*$|receipt_authority_path=$fixture_authority_dir/decoy-authority.json|" "$toolchain_manifest"
expect_receipt_rejection authority-path 'FAIL receipt mismatch receipt_authority_path'

# Every producer evidence key fails closed when absent, and a repeated
# assignment is rejected as a duplicate rather than silently re-validated.
for evidence_key in python3.13_kind python3.13_sha256 python3.13_pyvenv_cfg \
  receipt_authority_path receipt_authority_sha256; do
  evidence_key_re="${evidence_key//./\\.}"
  /usr/bin/sed -i "/^${evidence_key_re}=/d" "$toolchain_manifest"
  expect_receipt_rejection "missing-${evidence_key}" "FAIL receipt missing $evidence_key"
  duplicate_line="$(grep -m1 -- "^${evidence_key_re}=" "$toolchain_manifest")"
  printf '%s\n' "$duplicate_line" >> "$toolchain_manifest"
  expect_receipt_rejection "duplicate-${evidence_key}" "FAIL receipt duplicate key $evidence_key"
done

# Evidence that no longer matches the producer contract fails closed even when
# the recorded manifest value is untouched.
/usr/bin/mv -T -- "$managed_bin/python3.13" "$managed_bin/python3.13.real"
/usr/bin/ln -s -- "$managed_bin/python3.13.real" "$managed_bin/python3.13"
expect_receipt_rejection python-symlink 'FAIL receipt evidence python3.13 is not a regular file'
/usr/bin/rm -f -- "$managed_bin/python3.13"
/usr/bin/mv -T -- "$managed_bin/python3.13.real" "$managed_bin/python3.13"

/usr/bin/mv -T -- "$fixture_home/.local/pyvenv.cfg" "$test_root/pyvenv.cfg.good"
printf 'home = %s\ninclude-system-site-packages = true\nversion = %s\n' \
  "$python_runtime_root" "$PYTHON_VERSION" > "$fixture_home/.local/pyvenv.cfg"
expect_receipt_rejection pyvenv-contract 'FAIL receipt evidence pyvenv.cfg contract'
# Assignments carrying an extra '=' delimiter are complete values, so the
# strict contract must reject them instead of validating a truncated prefix.
printf 'home = %s=decoy\ninclude-system-site-packages = false\nversion = %s\n' \
  "$python_runtime_root" "$PYTHON_VERSION" > "$fixture_home/.local/pyvenv.cfg"
expect_receipt_rejection pyvenv-home-extra-delimiter 'FAIL receipt evidence pyvenv.cfg contract'
printf 'home = %s\ninclude-system-site-packages = false=true\nversion = %s\n' \
  "$python_runtime_root" "$PYTHON_VERSION" > "$fixture_home/.local/pyvenv.cfg"
expect_receipt_rejection pyvenv-site-extra-delimiter 'FAIL receipt evidence pyvenv.cfg contract'
printf 'home = %s\ninclude-system-site-packages = false\nversion = %s=0\n' \
  "$python_runtime_root" "$PYTHON_VERSION" > "$fixture_home/.local/pyvenv.cfg"
expect_receipt_rejection pyvenv-version-extra-delimiter 'FAIL receipt evidence pyvenv.cfg contract'
# Duplicate, bare, and absent assignments stay rejected with the parser fix.
printf 'home = %s\nhome = %s\ninclude-system-site-packages = false\nversion = %s\n' \
  "$python_runtime_root" "$python_runtime_root" "$PYTHON_VERSION" > "$fixture_home/.local/pyvenv.cfg"
expect_receipt_rejection pyvenv-duplicate-home 'FAIL receipt evidence pyvenv.cfg contract'
printf 'home\ninclude-system-site-packages = false\nversion = %s\n' \
  "$PYTHON_VERSION" > "$fixture_home/.local/pyvenv.cfg"
expect_receipt_rejection pyvenv-bare-home 'FAIL receipt evidence pyvenv.cfg contract'
printf 'include-system-site-packages = false\nversion = %s\n' \
  "$PYTHON_VERSION" > "$fixture_home/.local/pyvenv.cfg"
expect_receipt_rejection pyvenv-missing-home 'FAIL receipt evidence pyvenv.cfg contract'
# CPython site.py folds pyvenv.cfg keys with key.strip().lower() and resolves
# duplicates last-wins, so a case- or whitespace-variant duplicate that a naive
# case-sensitive/ASCII-only reader treats as a single unambiguous line would let
# the runtime enable system-site-packages (or redirect home) while the verifier
# attests isolation. Each variant duplicate must be rejected as ambiguous.
printf 'home = %s\ninclude-system-site-packages = false\nversion = %s\nInclude-System-Site-Packages = true\n' \
  "$python_runtime_root" "$PYTHON_VERSION" > "$fixture_home/.local/pyvenv.cfg"
expect_receipt_rejection pyvenv-case-variant-site 'FAIL receipt evidence pyvenv.cfg contract'
printf 'home = %s\ninclude-system-site-packages = false\nversion = %s\nINCLUDE-SYSTEM-SITE-PACKAGES = true\n' \
  "$python_runtime_root" "$PYTHON_VERSION" > "$fixture_home/.local/pyvenv.cfg"
expect_receipt_rejection pyvenv-upper-variant-site 'FAIL receipt evidence pyvenv.cfg contract'
printf 'home = %s\nHome = /decoy/evil\ninclude-system-site-packages = false\nversion = %s\n' \
  "$python_runtime_root" "$PYTHON_VERSION" > "$fixture_home/.local/pyvenv.cfg"
expect_receipt_rejection pyvenv-case-variant-home 'FAIL receipt evidence pyvenv.cfg contract'
# A non-breaking space (U+00A0) is stripped by Python str.strip() but not by a
# C-locale gawk trim, so 'include-system-site-packages = true' smuggles a
# second directive past a byte-blind reader; a control separator (U+001F) is the
# ASCII-range analogue. Any byte outside printable ASCII/tab/CR must be refused.
printf 'home = %s\ninclude-system-site-packages = false\nversion = %s\ninclude-system-site-packages\xc2\xa0= true\n' \
  "$python_runtime_root" "$PYTHON_VERSION" > "$fixture_home/.local/pyvenv.cfg"
expect_receipt_rejection pyvenv-nbsp-key-site 'FAIL receipt evidence pyvenv.cfg contract'
printf 'home = %s\nhome\x1f = /decoy\ninclude-system-site-packages = false\nversion = %s\n' \
  "$python_runtime_root" "$PYTHON_VERSION" > "$fixture_home/.local/pyvenv.cfg"
expect_receipt_rejection pyvenv-control-key-home 'FAIL receipt evidence pyvenv.cfg contract'
# A carriage return is a line separator to CPython's universal-newline file
# iteration but not to a newline-only reader, so a decoy line + embedded CR +
# smuggled directive would let the runtime enable system-site-packages (or
# redirect home) while a naive reader sees one benign line. The reader must
# split on CR as CPython does, exposing the smuggled key as a duplicate.
printf 'home = %s\ninclude-system-site-packages = false\nversion = %s\ndecoy = 1\rinclude-system-site-packages = true\n' \
  "$python_runtime_root" "$PYTHON_VERSION" > "$fixture_home/.local/pyvenv.cfg"
expect_receipt_rejection pyvenv-embedded-cr-site 'FAIL receipt evidence pyvenv.cfg contract'
printf 'home = %s\ndecoy = 1\rhome = /decoy/evil\ninclude-system-site-packages = false\nversion = %s\n' \
  "$python_runtime_root" "$PYTHON_VERSION" > "$fixture_home/.local/pyvenv.cfg"
expect_receipt_rejection pyvenv-embedded-cr-home 'FAIL receipt evidence pyvenv.cfg contract'
/usr/bin/mv -T -- "$test_root/pyvenv.cfg.good" "$fixture_home/.local/pyvenv.cfg"

/usr/bin/mv -T -- "$fixture_authority_path" "$test_root/receipt-authority.json.good"
expect_receipt_rejection authority-missing 'FAIL receipt evidence receipt authority is not a published regular file'
/usr/bin/mv -T -- "$test_root/receipt-authority.json.good" "$fixture_authority_path"

run_verify > "$test_root/restored-verify-output" 2>&1 || {
  cat "$test_root/restored-verify-output" >&2
  echo 'Restored receipt fixture did not pass again.' >&2
  exit 1
}

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
