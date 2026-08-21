#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
fixture_root="$test_root/source"
# shellcheck disable=SC1090
source "$repo_root/config/ubuntu-toolchain.lock"

make_tool_fixtures() {
  local home="$1"
  local uv_version="${FIXTURE_UV_VERSION:-0.12.5}"
  local uv_platform="${FIXTURE_UV_PLATFORM:-x86_64-unknown-linux-gnu}"
  local python_version="${FIXTURE_PYTHON_VERSION:-3.13.15}"
  local py_probe="${FIXTURE_PY_PROBE:-3.13.15|x86_64|linux}"
  local rustup_version="${FIXTURE_RUSTUP_VERSION:-$RUSTUP_VERSION}"
  local rustc_version="${FIXTURE_RUSTC_VERSION:-$RUST_TOOLCHAIN}"
  local node_version="${FIXTURE_NODE_VERSION:-$NODE_VERSION}"
  local npm_version="${FIXTURE_NPM_VERSION:-11.6.0}"
  local codex_version="${FIXTURE_CODEX_VERSION:-$CODEX_VERSION}"
  local claude_version="${FIXTURE_CLAUDE_VERSION:-$CLAUDE_VERSION}"
  local bun_version="${FIXTURE_BUN_VERSION:-$BUN_VERSION}"
  local herdr_version="${FIXTURE_HERDR_VERSION:-$HERDR_VERSION}"
  local powershell_version="${FIXTURE_POWERSHELL_VERSION:-$POWERSHELL_VERSION}"
  mkdir -p "$home/.local/bin"
  cat > "$home/.local/bin/uv" <<EOF
#!/usr/bin/env bash
printf 'uv %s (%s)\\n' '$uv_version' '$uv_platform'
EOF
  cat > "$home/.local/bin/python3.13" <<EOF
#!/usr/bin/env bash
printf 'Python %s\\n' '$python_version'
EOF
  cat > "$home/.local/bin/py" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[[ "\${1:-}" == '-3.13' ]] || exit 2
shift
case "\${1:-}" in
  --version) printf 'Python %s\\n' '$python_version' ;;
  -c) printf '%s\\n' '$py_probe' ;;
  *) exit 2 ;;
esac
EOF
  chmod 0755 "$home/.local/bin/uv" "$home/.local/bin/python3.13" "$home/.local/bin/py"
  cat > "$home/.local/bin/rustup" <<EOF
#!/usr/bin/env bash
printf 'rustup %s (fixturehash 2026-08-19)\\n' '$rustup_version'
EOF
  cat > "$home/.local/bin/rustc" <<EOF
#!/usr/bin/env bash
printf 'rustc %s (fixturehash 2026-08-19)\\n' '$rustc_version'
EOF
  cat > "$home/.local/bin/node" <<EOF
#!/usr/bin/env bash
printf 'v%s\\n' '$node_version'
EOF
  cat > "$home/.local/bin/npm" <<EOF
#!/usr/bin/env bash
printf '%s\\n' '$npm_version'
EOF
  cat > "$home/.local/bin/codex" <<EOF
#!/usr/bin/env bash
printf 'codex-cli %s\\n' '$codex_version'
EOF
  cat > "$home/.local/bin/claude" <<EOF
#!/usr/bin/env bash
printf '%s\\n' '$claude_version'
EOF
  cat > "$home/.local/bin/bun" <<EOF
#!/usr/bin/env bash
printf '%s\\n' '$bun_version'
EOF
  cat > "$home/.local/bin/herdr" <<EOF
#!/usr/bin/env bash
printf 'herdr %s\\n' '$herdr_version'
EOF
  cat > "$home/.local/bin/pwsh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == '-NoProfile' && "\${2:-}" == '-File' ]]; then
  script_path="\${3:-}"
  if [[ -n "\${HERDR_TEST_PWSH_FILE_LOG:-}" ]]; then
    printf '%s\n' "\$*" >> "\$HERDR_TEST_PWSH_FILE_LOG"
  fi
  if [[ "\${HERDR_TEST_PWSH_FILE_RESULT:-pass}" == 'fail' ]]; then
    printf 'fixture PowerShell failure: %s\n' "\$script_path" >&2
    exit 17
  fi
  exit 0
fi
printf '%s\\n' '$powershell_version'
EOF
  cat > "$home/.local/bin/dpkg-query" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
package="${@: -1}"
case "$package" in
  cifs-utils|curl|gawk|git|git-lfs|gh|jq|mosh|openssh-client|openssh-server|ripgrep|rsync)
    printf 'apt:%s=fixture-%s\n' "$package" "$package"
    ;;
  *) exit 1 ;;
esac
EOF
  node_bin="$home/.local/lib/node-v${NODE_VERSION}-linux-x64/bin"
  mkdir -p "$node_bin"
  for node_tool in node npm codex claude bun; do
    mv "$home/.local/bin/$node_tool" "$node_bin/$node_tool"
    ln -s "$node_bin/$node_tool" "$home/.local/bin/$node_tool"
  done
  chmod 0755 \
    "$home/.local/bin/rustup" "$home/.local/bin/rustc" "$home/.local/bin/node" \
    "$home/.local/bin/npm" "$home/.local/bin/codex" "$home/.local/bin/claude" \
    "$home/.local/bin/bun" "$home/.local/bin/herdr" "$home/.local/bin/pwsh" \
    "$home/.local/bin/dpkg-query"
}

make_fixture() {
  rm -rf "$fixture_root"
  mkdir -p \
    "$fixture_root/config" \
    "$fixture_root/scripts/ubuntu" \
    "$fixture_root/payload/agents-skills/demo" \
    "$fixture_root/payload/claude-skills/demo"
  cp "$repo_root/scripts/ubuntu/install-payload.sh" "$fixture_root/scripts/ubuntu/install-payload.sh"
  cp "$repo_root/config/ubuntu-toolchain.lock" "$fixture_root/config/ubuntu-toolchain.lock"
  printf '%s\n' '# fixture agents skill' > "$fixture_root/payload/agents-skills/demo/SKILL.md"
  printf '%s\n' '# fixture claude skill' > "$fixture_root/payload/claude-skills/demo/SKILL.md"
  printf '%s\n' 'LOCAL-COMMISSIONING-LOG.md' > "$fixture_root/.gitignore"
  {
    printf '%s\n' '# Issue #961 fixture manifest.'
    for relative_path in agents-skills/demo/SKILL.md claude-skills/demo/SKILL.md; do
      file_hash="$(sha256sum "$fixture_root/payload/$relative_path" | awk '{print $1}')"
      printf '%s  %s\n' "$file_hash" "$relative_path"
    done
  } > "$fixture_root/config/payload-manifest.sha256"
  git -C "$fixture_root" init -q
  git -C "$fixture_root" config user.name 'Issue 961 hermetic test'
  git -C "$fixture_root" config user.email 'issue-961@example.invalid'
  git -C "$fixture_root" add -A
  git -C "$fixture_root" commit -qm 'fixture source'
}

make_herdr_fixture() {
  local relative_path
  local file_hash
  make_fixture
  cp -a "$repo_root/payload/agents-skills/herdr-coordination" "$fixture_root/payload/agents-skills/"
  {
    printf '%s\n' '# Issue #961 fixture manifest with the canonical herdr-coordination payload.'
    while IFS= read -r relative_path; do
      relative_path="agents-skills/$relative_path"
      file_hash="$(sha256sum "$fixture_root/payload/$relative_path" | awk '{print $1}')"
      printf '%s  %s\n' "$file_hash" "$relative_path"
    done < <(find "$fixture_root/payload/agents-skills" -type f -printf '%P\n' | LC_ALL=C sort)
    while IFS= read -r relative_path; do
      relative_path="claude-skills/$relative_path"
      file_hash="$(sha256sum "$fixture_root/payload/$relative_path" | awk '{print $1}')"
      printf '%s  %s\n' "$file_hash" "$relative_path"
    done < <(find "$fixture_root/payload/claude-skills" -type f -printf '%P\n' | LC_ALL=C sort)
  } > "$fixture_root/config/payload-manifest.sha256"
  git -C "$fixture_root" add -A
  git -C "$fixture_root" commit -qm 'canonical herdr payload fixture'
}

new_home() {
  local home="$test_root/home-$1"
  rm -rf "$home"
  mkdir -p "$home"
  make_tool_fixtures "$home"
  write_toolchain_receipt "$home"
  printf '%s' "$home"
}

write_toolchain_receipt() {
  local home="$1"
  local lock_sha256
  # shellcheck disable=SC1090
  source "$fixture_root/config/ubuntu-toolchain.lock"
  lock_sha256="$(sha256sum "$fixture_root/config/ubuntu-toolchain.lock" | awk '{print $1}')"
  mkdir -p "$home/.local/state/herdr-workstation-bootstrap"
  {
    printf 'receipt_format=issue-961-toolchain-v2\n'
    printf 'lock_sha256=%s\n' "$lock_sha256"
    printf 'host_platform=linux\n'
    printf 'host_architecture=x86_64\n'
    printf 'uv_path=%s\n' "$home/.local/bin/uv"
    printf 'python3.13_path=%s\n' "$home/.local/bin/python3.13"
    printf 'py_path=%s\n' "$home/.local/bin/py"
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
    for package in cifs-utils curl gawk git git-lfs gh jq mosh openssh-client openssh-server ripgrep rsync; do
      printf 'apt:%s=fixture-%s\n' "$package" "$package"
    done
  } > "$home/.local/state/herdr-workstation-bootstrap/toolchain-manifest.txt"
}

expect_blocked() {
  local case_name="$1"
  local home="$2"
  local expected_text="$3"
  local path_prefix="${4:-$home/.local/bin}"
  local output="$test_root/$case_name.out"
  set +e
  HOME="$home" PATH="$path_prefix:$PATH" bash "$fixture_root/scripts/ubuntu/install-payload.sh" > "$output" 2>&1
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || { echo "$case_name unexpectedly passed." >&2; exit 1; }
  grep -Fq "$expected_text" "$output" || { sed -n '1,120p' "$output" >&2; echo "$case_name lacked '$expected_text'." >&2; exit 1; }
}

make_sentinels() {
  local home="$1"
  mkdir -p "$home/.agents/skills" "$home/.claude/skills"
  printf 'keep agents\n' > "$home/.agents/skills/keep.txt"
  printf 'keep claude\n' > "$home/.claude/skills/keep.txt"
}

assert_sentinels() {
  local home="$1"
  [[ "$(< "$home/.agents/skills/keep.txt")" == 'keep agents' ]] || { echo 'agents destination changed after a blocked install.' >&2; exit 1; }
  [[ "$(< "$home/.claude/skills/keep.txt")" == 'keep claude' ]] || { echo 'claude destination changed after a blocked install.' >&2; exit 1; }
}

assert_no_transaction_residue() {
  local home="$1"
  if compgen -G "$home/.local/state/herdr-workstation-bootstrap/.payload-*" > /dev/null; then
    echo "Transaction residue remained in $home." >&2
    find "$home/.local/state/herdr-workstation-bootstrap" -maxdepth 1 -name '.payload-*' -print >&2
    exit 1
  fi
}

write_payload_receipt_sentinel() {
  local home="$1"
  printf 'prior payload receipt\n' > "$home/.local/state/herdr-workstation-bootstrap/payload-runtime-receipt.txt"
}

assert_restored_transaction() {
  local home="$1"
  local receipt_before="${2:-}"
  assert_sentinels "$home"
  assert_no_transaction_residue "$home"
  if [[ -n "$receipt_before" ]]; then
    cmp -s "$receipt_before" "$home/.local/state/herdr-workstation-bootstrap/payload-runtime-receipt.txt" || {
      echo 'Payload receipt changed after rollback.' >&2
      exit 1
    }
  fi
}

expect_receipt_blocked() {
  local case_name="$1"
  local home="$2"
  local expected_text="$3"
  local path_prefix="${4:-$home/.local/bin}"
  make_sentinels "$home"
  expect_blocked "$case_name" "$home" "$expected_text" "$path_prefix"
  assert_sentinels "$home"
  assert_no_transaction_residue "$home"
}

assert_payload_manifest_parity() {
  local expected_paths="$test_root/payload-manifest.expected.paths"
  local actual_paths="$test_root/payload-manifest.actual.paths"
  local file_hash
  local relative_path
  local actual_hash
  {
    find "$repo_root/payload/agents-skills" -type f -printf 'agents-skills/%P\n'
    find "$repo_root/payload/claude-skills" -type f -printf 'claude-skills/%P\n'
  } | LC_ALL=C sort > "$expected_paths"
  awk 'NF == 2 && $1 !~ /^#/ { print $2 }' "$repo_root/config/payload-manifest.sha256" |
    LC_ALL=C sort > "$actual_paths"
  cmp -s "$expected_paths" "$actual_paths" || {
    echo 'Payload manifest paths do not exactly match the installable payload.' >&2
    diff -u "$expected_paths" "$actual_paths" >&2 || true
    exit 1
  }
  while read -r file_hash relative_path; do
    actual_hash="$(sha256sum "$repo_root/payload/$relative_path" | awk '{print $1}')"
    [[ "$actual_hash" == "$file_hash" ]] || {
      echo "Payload manifest hash mismatch: $relative_path" >&2
      exit 1
    }
  done < <(awk 'NF == 2 && $1 !~ /^#/ { print $1, $2 }' "$repo_root/config/payload-manifest.sha256")
}

run_portability_regression_cases() {
  local portability_root="$test_root/herdr-portability"
  local scripts_root="$portability_root/scripts"
  local pass_output="$test_root/herdr-portability-pass.out"
  local failure_output="$test_root/herdr-portability-mutation.out"
  local status
  command -v pwsh >/dev/null 2>&1 || {
    echo 'pwsh is required for the Herdr portability regression cases.' >&2
    exit 1
  }
  mkdir -p "$portability_root"
  cp -a "$repo_root/payload/agents-skills/herdr-coordination/scripts" "$portability_root/"
  [[ -f "$scripts_root/run_ubuntu_portability_manifest.ps1" ]] || exit 1
  grep -Fq '@echo off' "$scripts_root/test_herdr_workflow.ps1"
  grep -Fq '$isWindowsPlatform' "$scripts_root/test_herdr_workflow.ps1"
  env -u HERDR_ENV pwsh -NoProfile -File "$scripts_root/test_ubuntu_portability.ps1" > "$pass_output" 2>&1 || {
    cat "$pass_output" >&2
    echo 'Canonical Ubuntu portability payload unexpectedly failed.' >&2
    exit 1
  }
  grep -Fq 'PASS: Ubuntu portability scan' "$pass_output"
  printf '%s\n' "Write-Output 'C:\\deliberately-nonportable'" >> "$scripts_root/herdr_workflow.ps1"
  set +e
  env -u HERDR_ENV pwsh -NoProfile -File "$scripts_root/test_ubuntu_portability.ps1" > "$failure_output" 2>&1
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || {
    cat "$failure_output" >&2
    echo 'Nonportable production-script mutation unexpectedly passed.' >&2
    exit 1
  }
  grep -Fq 'contains a drive-rooted Windows path in production code' "$failure_output"
}

run_herdr_static_gate_case() {
  local case_name="$1"
  local result="$2"
  local home
  local output="$test_root/$case_name.out"
  local invocation_log="$test_root/$case_name.pwsh.log"
  local status
  make_herdr_fixture
  home="$(new_home "$case_name")"
  if [[ "$result" == 'fail' ]]; then
    make_sentinels "$home"
  fi
  set +e
  HERDR_TEST_PWSH_FILE_RESULT="$result" \
  HERDR_TEST_PWSH_FILE_LOG="$invocation_log" \
  HOME="$home" PATH="$home/.local/bin:$PATH" \
    bash "$fixture_root/scripts/ubuntu/install-payload.sh" > "$output" 2>&1
  status=$?
  set -e
  if [[ "$result" == 'pass' ]]; then
    [[ "$status" == 0 ]] || { cat "$output" >&2; exit 1; }
    grep -Fqx -- "-NoProfile -File $fixture_root/payload/agents-skills/herdr-coordination/scripts/test_ubuntu_portability.ps1" "$invocation_log"
    ! grep -Fq -- 'run_ubuntu_portability_manifest.ps1' "$invocation_log"
    [[ -f "$home/.agents/skills/herdr-coordination/scripts/run_ubuntu_portability_manifest.ps1" ]] || exit 1
  else
    [[ "$status" == 30 ]] || { cat "$output" >&2; exit 1; }
    grep -Fq 'BLOCKED: herdr-coordination Ubuntu portability validator failed' "$output"
    grep -Fq 'fixture PowerShell failure' "$output"
    assert_sentinels "$home"
    assert_no_transaction_residue "$home"
  fi
}

run_herdr_static_missing_case() {
  local case_name='herdr-static-missing'
  local home
  local output="$test_root/$case_name.out"
  local invocation_log="$test_root/$case_name.pwsh.log"
  local validator_path="$fixture_root/payload/agents-skills/herdr-coordination/scripts/test_ubuntu_portability.ps1"
  local status

  make_herdr_fixture
  rm "$validator_path"
  sed -i '\#  agents-skills/herdr-coordination/scripts/test_ubuntu_portability.ps1$#d' \
    "$fixture_root/config/payload-manifest.sha256"
  git -C "$fixture_root" add -A
  git -C "$fixture_root" commit -qm 'fixture without static portability validator'
  home="$(new_home "$case_name")"
  make_sentinels "$home"
  set +e
  env -u HERDR_ENV \
    HERDR_TEST_PWSH_FILE_RESULT=pass \
    HERDR_TEST_PWSH_FILE_LOG="$invocation_log" \
    HOME="$home" PATH="$home/.local/bin:$PATH" \
      bash "$fixture_root/scripts/ubuntu/install-payload.sh" > "$output" 2>&1
  status=$?
  set -e
  [[ "$status" == 31 ]] || { cat "$output" >&2; exit 1; }
  grep -Fq 'BLOCKED: herdr-coordination Ubuntu portability validator is missing' "$output"
  [[ ! -s "$invocation_log" ]] || { cat "$invocation_log" >&2; exit 1; }
  assert_sentinels "$home"
  assert_no_transaction_residue "$home"
}

make_restore_mv_shim() {
  local home="$1"
  cat > "$home/.local/bin/mv" <<'EOF'
#!/usr/bin/env bash
set -u
source_path="${3:-}"
fail_source="${HERDR_TEST_FAIL_MV_SOURCE:-}"
case "$source_path" in
  */backup/agents-skills|*/backup/claude-skills|*/backup/payload-runtime-receipt.txt)
    should_fail=0
    IFS=',' read -r -a fail_sources <<< "$fail_source"
    for configured_source in "${fail_sources[@]}"; do
      if [[ -n "$configured_source" && "$source_path" == *"/backup/$configured_source" ]]; then
        should_fail=1
      fi
    done
    if (( should_fail == 1 )); then
      printf 'injected rollback mv failure: %s\n' "$fail_source" >&2
      if [[ "${HERDR_TEST_MV_SIGNAL:-}" == TERM ]]; then
        kill -TERM "$PPID"
      fi
      exit 73
    fi
    ;;
esac
exec /usr/bin/mv "$@"
EOF
  chmod 0755 "$home/.local/bin/mv"
}

transaction_root() {
  local home="$1"
  find "$home/.local/state/herdr-workstation-bootstrap" -mindepth 1 -maxdepth 1 \
    -type d -name '.payload-transaction.*' -print -quit
}

assert_retained_transaction() {
  local home="$1"
  local root
  local root_count
  root_count="$(find "$home/.local/state/herdr-workstation-bootstrap" -mindepth 1 -maxdepth 1 \
    -type d -name '.payload-transaction.*' -printf x | wc -c)"
  [[ "$root_count" == 1 ]] || { echo "Expected one retained transaction, found $root_count." >&2; exit 1; }
  root="$(transaction_root "$home")"
  [[ -n "$root" && -d "$root/backup" && -f "$root/state" ]] || exit 1
  [[ "$(stat -c '%a' "$root")" == 700 ]] || exit 1
  [[ "$(stat -c '%a' "$root/backup")" == 700 ]] || exit 1
  [[ "$(stat -c '%a' "$root/state")" == 600 ]] || exit 1
  grep -Fqx 'phase=rollback-incomplete' "$root/state"
}

snapshot_tree() {
  local path="$1"
  if [[ ! -e "$path" && ! -L "$path" ]]; then
    printf 'missing|%s\n' "$path"
    return 0
  fi
  find -P "$path" -printf 'entry|%y|%m|%u|%g|%p|%l\n' | LC_ALL=C sort
  while IFS= read -r -d '' file; do
    printf 'content|%s|' "$file"
    sha256sum -- "$file"
  done < <(find -P "$path" -type f -print0 | sort -z)
}

snapshot_install_state() {
  local home="$1"
  local output="$2"
  {
    snapshot_tree "$home/.agents/skills"
    snapshot_tree "$home/.claude/skills"
    snapshot_tree "$home/.local/state/herdr-workstation-bootstrap"
  } > "$output"
}

assert_no_owned_transaction_residue() {
  local home="$1"
  [[ -z "$(transaction_root "$home")" ]] || {
    echo "Owned transaction residue remained in $home." >&2
    exit 1
  }
}

wait_for_file() {
  local path="$1"
  local attempt
  for attempt in $(seq 1 200); do
    [[ -e "$path" ]] && return 0
    sleep 0.01
  done
  echo "Timed out waiting for $path." >&2
  return 1
}

run_payload_signal_case() {
  local case_name="$1"
  local phase="$2"
  local home
  local ready="$test_root/$case_name.ready"
  local continue_file="$test_root/$case_name.continue"
  local output="$test_root/$case_name.out"
  local pid
  local status
  local receipt_before="$test_root/$case_name.receipt.before"

  make_fixture
  home="$(new_home "$case_name")"
  make_sentinels "$home"
  write_payload_receipt_sentinel "$home"
  cp "$home/.local/state/herdr-workstation-bootstrap/payload-runtime-receipt.txt" "$receipt_before"
  HERDR_PAYLOAD_TEST_PAUSE_PHASE="$phase" \
  HERDR_PAYLOAD_TEST_READY_FILE="$ready" \
  HERDR_PAYLOAD_TEST_CONTINUE_FILE="$continue_file" \
  HOME="$home" PATH="$home/.local/bin:$PATH" \
    bash "$fixture_root/scripts/ubuntu/install-payload.sh" > "$output" 2>&1 &
  pid=$!
  wait_for_file "$ready"
  kill -TERM "$pid"
  set +e
  wait "$pid"
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || { cat "$output" >&2; echo "$case_name signal unexpectedly passed." >&2; exit 1; }
  assert_restored_transaction "$home" "$receipt_before"
}

run_payload_committed_signal_case() {
  local case_name="$1"
  local phase="$2"
  local home
  local ready="$test_root/$case_name.ready"
  local continue_file="$test_root/$case_name.continue"
  local output="$test_root/$case_name.out"
  local pid
  local status

  make_fixture
  home="$(new_home "$case_name")"
  make_sentinels "$home"
  HERDR_PAYLOAD_TEST_PAUSE_PHASE="$phase" \
  HERDR_PAYLOAD_TEST_READY_FILE="$ready" \
  HERDR_PAYLOAD_TEST_CONTINUE_FILE="$continue_file" \
  HOME="$home" PATH="$home/.local/bin:$PATH" \
    bash "$fixture_root/scripts/ubuntu/install-payload.sh" > "$output" 2>&1 &
  pid=$!
  wait_for_file "$ready"
  kill -TERM "$pid"
  set +e
  wait "$pid"
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || { cat "$output" >&2; echo "$case_name signal unexpectedly passed." >&2; exit 1; }
  [[ "$(< "$home/.agents/skills/demo/SKILL.md")" == '# fixture agents skill' ]] || exit 1
  [[ "$(< "$home/.claude/skills/demo/SKILL.md")" == '# fixture claude skill' ]] || exit 1
  [[ -s "$home/.local/state/herdr-workstation-bootstrap/payload-runtime-receipt.txt" ]] || exit 1
  residue_count="$(find "$home/.local/state/herdr-workstation-bootstrap" -maxdepth 1 -name '.payload-*' -printf x | wc -c)"
  [[ "$residue_count" -le 2 ]] || { echo "$case_name left unbounded residue." >&2; exit 1; }
}

# The bundled canonical payload passes its native scan, a production mutation
# is rejected, guarded Windows fixtures remain allowed, and the hash manifest
# remains an exact authority for the installable payload.
assert_payload_manifest_parity
run_portability_regression_cases
run_herdr_static_gate_case herdr-static-pass pass
run_herdr_static_gate_case herdr-static-fail fail
run_herdr_static_missing_case

# Signals before the durable commit restore the complete old transaction.
run_payload_signal_case signal-before-commit before-commit
run_payload_signal_case signal-after-agents-commit after-agents-commit

# Signals after rollback disarm never remove committed destinations. Each seam
# is intentionally bounded and may leave only this transaction's cleanup roots.
run_payload_committed_signal_case signal-between-disarm between-rollback-disarm-and-trap-removal
run_payload_committed_signal_case signal-after-traps after-trap-removal
run_payload_committed_signal_case signal-before-cleanup before-cleanup
run_payload_committed_signal_case signal-during-backup-cleanup during-backup-cleanup
run_payload_committed_signal_case signal-after-backup-cleanup after-backup-cleanup

run_payload_parent_swap_case() {
  local case_name="$1"
  local phase="$2"
  local home
  local outside="$test_root/$case_name-outside"
  local ready="$test_root/$case_name.ready"
  local continue_file="$test_root/$case_name.continue"
  local output="$test_root/$case_name.out"
  local pid
  local status

  make_fixture
  home="$(new_home "$case_name")"
  make_sentinels "$home"
  mkdir -p "$outside"
  printf 'outside sentinel\n' > "$outside/sentinel.txt"
  HERDR_PAYLOAD_TEST_PAUSE_PHASE="$phase" \
  HERDR_PAYLOAD_TEST_READY_FILE="$ready" \
  HERDR_PAYLOAD_TEST_CONTINUE_FILE="$continue_file" \
  HOME="$home" PATH="$home/.local/bin:$PATH" \
    bash "$fixture_root/scripts/ubuntu/install-payload.sh" > "$output" 2>&1 &
  pid=$!
  wait_for_file "$ready"
  mv "$home/.agents" "$home/.agents-original"
  ln -s "$outside" "$home/.agents"
  : > "$continue_file"
  set +e
  wait "$pid"
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || { cat "$output" >&2; echo "$case_name namespace swap unexpectedly passed." >&2; exit 1; }
  [[ "$(< "$outside/sentinel.txt")" == 'outside sentinel' ]] || exit 1
  [[ "$(< "$home/.agents-original/skills/keep.txt")" == 'keep agents' ]] || exit 1
  [[ ! -e "$outside/skills/demo/SKILL.md" ]] || { echo "$case_name wrote outside HOME." >&2; exit 1; }
  rm "$home/.agents"
  mv "$home/.agents-original" "$home/.agents"
  assert_no_transaction_residue "$home"
}

# Replacing the validated destination parent after its fd was captured must
# fail closed without following the outside symlink.
run_payload_parent_swap_case payload-parent-swap-r2-before-commit before-commit
run_payload_parent_swap_case payload-parent-swap-before-mutation before-destination-mutations
run_payload_parent_swap_case payload-parent-swap-before-publish before-agents-publish

# Successful transactional install, ignored commissioning log allowance and
# deterministic receipt content. Foreign state is not owned by the installer,
# and a second normal install remains idempotent.
make_fixture
success_home="$(new_home success)"
printf 'local commissioning notes\n' > "$fixture_root/LOCAL-COMMISSIONING-LOG.md"
success_foreign="$success_home/.local/state/herdr-workstation-bootstrap/.payload-foreign"
mkdir -p "$success_foreign"
printf 'foreign success sentinel\n' > "$success_foreign/sentinel.txt"
HOME="$success_home" PATH="$success_home/.local/bin:$PATH" bash "$fixture_root/scripts/ubuntu/install-payload.sh" > "$test_root/success.out"
[[ "$(< "$success_home/.agents/skills/demo/SKILL.md")" == '# fixture agents skill' ]] || { echo 'agents payload was not installed.' >&2; exit 1; }
[[ "$(< "$success_home/.claude/skills/demo/SKILL.md")" == '# fixture claude skill' ]] || { echo 'claude payload was not installed.' >&2; exit 1; }
receipt="$success_home/.local/state/herdr-workstation-bootstrap/payload-runtime-receipt.txt"
source_commit="$(git -C "$fixture_root" rev-parse HEAD)"
manifest_sha256="$(sha256sum "$fixture_root/config/payload-manifest.sha256" | awk '{print $1}')"
grep -Fqx "source_commit=$source_commit" "$receipt"
grep -Fqx "tracked_manifest_sha256=$manifest_sha256" "$receipt"
grep -Fqx 'source_payload_file_count=2' "$receipt"
grep -Fqx 'installed_payload_file_count=2' "$receipt"
grep -Fqx 'tool.uv=uv 0.12.5 (x86_64-unknown-linux-gnu)' "$receipt"
grep -Fqx 'tool.python3.13=Python 3.13.15' "$receipt"
grep -Fqx 'tool.py-3.13=Python 3.13.15' "$receipt"
grep -Fqx 'regression_test_count=13' "$receipt"
grep -Fq 'source_payload_sha256.agents-skills/demo/SKILL.md=' "$receipt"
grep -Fq 'installed_payload_sha256.claude-skills/demo/SKILL.md=' "$receipt"
! grep -Eiq 'timestamp|hostname|LOCAL-COMMISSIONING-LOG' "$receipt"
[[ "$(< "$success_foreign/sentinel.txt")" == 'foreign success sentinel' ]] || exit 1
set +e
HOME="$success_home" PATH="$success_home/.local/bin:$PATH" \
  bash "$fixture_root/scripts/ubuntu/install-payload.sh" > "$test_root/success-idempotent.out" 2>&1
success_idempotent_status=$?
set -e
[[ "$success_idempotent_status" == 0 ]] || { cat "$test_root/success-idempotent.out" >&2; exit 1; }
assert_no_owned_transaction_residue "$success_home"
[[ "$(< "$success_foreign/sentinel.txt")" == 'foreign success sentinel' ]] || exit 1

# The current bootstrap producer emits the complete strict receipt. Prove the
# exact starting consumer rejects that producer-shaped receipt, then prove the
# corrected consumer accepts it without touching a real HOME.
make_fixture
starting_receipt_home="$(new_home producer-shaped-starting)"
make_sentinels "$starting_receipt_home"
starting_script="$fixture_root/scripts/ubuntu/install-payload-starting.sh"
git -C "$repo_root" show 03629049df8e6322e76619e6b92e5213dd3dd6f4:scripts/ubuntu/install-payload.sh > "$starting_script"
chmod 0755 "$starting_script"
git -C "$fixture_root" add scripts/ubuntu/install-payload-starting.sh
git -C "$fixture_root" commit -qm 'starting consumer fixture'
set +e
HOME="$starting_receipt_home" PATH="$starting_receipt_home/.local/bin:$PATH" \
  bash "$starting_script" > "$test_root/producer-shaped-starting.out" 2>&1
starting_receipt_status=$?
set -e
[[ "$starting_receipt_status" -ne 0 ]] || { cat "$test_root/producer-shaped-starting.out" >&2; exit 1; }
grep -Fq 'unknown toolchain receipt key: tailscale' "$test_root/producer-shaped-starting.out" || {
  cat "$test_root/producer-shaped-starting.out" >&2
  exit 1
}
assert_sentinels "$starting_receipt_home"
assert_no_transaction_residue "$starting_receipt_home"

candidate_receipt_home="$(new_home producer-shaped-candidate)"
candidate_receipt_output="$test_root/producer-shaped-candidate.out"
set +e
HOME="$candidate_receipt_home" PATH="$candidate_receipt_home/.local/bin:$PATH" \
  bash "$fixture_root/scripts/ubuntu/install-payload.sh" > "$candidate_receipt_output" 2>&1
candidate_receipt_status=$?
set -e
[[ "$candidate_receipt_status" == 0 ]] || { cat "$candidate_receipt_output" >&2; exit 1; }
[[ "$(< "$candidate_receipt_home/.agents/skills/demo/SKILL.md")" == '# fixture agents skill' ]] || exit 1
[[ "$(< "$candidate_receipt_home/.claude/skills/demo/SKILL.md")" == '# fixture claude skill' ]] || exit 1
assert_no_owned_transaction_residue "$candidate_receipt_home"
printf 'Full toolchain receipt compatibility: starting_status=%s (rejected), candidate_status=%s (accepted).\n' \
  "$starting_receipt_status" "$candidate_receipt_status"

# Every producer field is required exactly once, and runtime/managed-tool
# contracts remain fail-closed before any payload destination mutation.
make_fixture
unknown_receipt_home="$(new_home unknown-receipt-key)"
printf 'future_key=not-allowed\n' >> "$unknown_receipt_home/.local/state/herdr-workstation-bootstrap/toolchain-manifest.txt"
expect_receipt_blocked unknown-receipt-key "$unknown_receipt_home" 'unknown toolchain receipt key: future_key'

make_fixture
missing_receipt_key_home="$(new_home missing-receipt-key)"
sed -i '/^rustc=/d' "$missing_receipt_key_home/.local/state/herdr-workstation-bootstrap/toolchain-manifest.txt"
expect_receipt_blocked missing-receipt-key "$missing_receipt_key_home" 'missing toolchain receipt key: rustc'

make_fixture
duplicate_receipt_key_home="$(new_home duplicate-receipt-key)"
printf 'rustup=rustup %s (fixturehash 2026-08-19)\n' "$RUSTUP_VERSION" >> \
  "$duplicate_receipt_key_home/.local/state/herdr-workstation-bootstrap/toolchain-manifest.txt"
expect_receipt_blocked duplicate-receipt-key "$duplicate_receipt_key_home" 'duplicate toolchain receipt key: rustup'

make_fixture
malformed_receipt_home="$(new_home malformed-receipt)"
printf 'not a receipt assignment\n' >> "$malformed_receipt_home/.local/state/herdr-workstation-bootstrap/toolchain-manifest.txt"
expect_receipt_blocked malformed-receipt "$malformed_receipt_home" 'malformed toolchain receipt line'

make_fixture
extra_apt_receipt_home="$(new_home extra-apt-receipt)"
printf 'apt:future-package=fixture-1\n' >> "$extra_apt_receipt_home/.local/state/herdr-workstation-bootstrap/toolchain-manifest.txt"
expect_receipt_blocked extra-apt-receipt "$extra_apt_receipt_home" 'unknown toolchain receipt key: apt:future-package'

make_fixture
rustup_contract_home="$(FIXTURE_RUSTUP_VERSION=0.0.1 new_home rustup-contract)"
expect_receipt_blocked rustup-contract "$rustup_contract_home" 'rustup receipt value does not match the locked version contract'

make_fixture
node_contract_home="$(FIXTURE_NODE_VERSION=0.0.1 new_home node-contract)"
expect_receipt_blocked node-contract "$node_contract_home" 'Node receipt value does not match the locked version contract'

make_fixture
npm_contract_home="$(FIXTURE_NPM_VERSION=not-a-version new_home npm-contract)"
expect_receipt_blocked npm-contract "$npm_contract_home" 'npm receipt value is not a bounded semantic version'

make_fixture
managed_tool_home="$(new_home managed-tool-path)"
mv "$managed_tool_home/.local/bin/node" "$managed_tool_home/.local/bin/node-missing"
expect_receipt_blocked managed-tool-path "$managed_tool_home" 'managed tool is missing or not executable'

make_fixture
powershell_contract_home="$(FIXTURE_POWERSHELL_VERSION=7.6.4 new_home powershell-contract)"
expect_receipt_blocked powershell-contract "$powershell_contract_home" 'PowerShell receipt value does not match the locked version contract'

# Locked toolchain provenance is required before any payload destination move.
make_fixture
wrong_uv_home="$(FIXTURE_UV_VERSION=0.0.1 new_home wrong-uv-version)"
expect_receipt_blocked wrong-uv-version "$wrong_uv_home" 'managed uv version is not locked'

make_fixture
wrong_platform_home="$(FIXTURE_UV_PLATFORM=aarch64-unknown-linux-gnu new_home wrong-uv-platform)"
expect_receipt_blocked wrong-uv-platform "$wrong_platform_home" 'managed uv version is not locked'

make_fixture
wrong_probe_home="$(FIXTURE_PY_PROBE='3.13.15|aarch64|linux' new_home wrong-python-probe)"
expect_receipt_blocked wrong-python-probe "$wrong_probe_home" 'managed py platform probe is not locked'

make_fixture
wrong_release_home="$(new_home wrong-python-release)"
sed -i 's/^python_release=.*/python_release=stale-release/' \
  "$wrong_release_home/.local/state/herdr-workstation-bootstrap/toolchain-manifest.txt"
expect_receipt_blocked wrong-python-release "$wrong_release_home" 'toolchain receipt mismatch: python_release'

make_fixture
missing_receipt_home="$(new_home missing-toolchain-receipt)"
rm "$missing_receipt_home/.local/state/herdr-workstation-bootstrap/toolchain-manifest.txt"
expect_receipt_blocked missing-toolchain-receipt "$missing_receipt_home" 'Missing bootstrap toolchain receipt'

make_fixture
lock_mismatch_home="$(new_home lock-mismatch)"
sed -i 's/^UV_SHA256=.*/UV_SHA256=0000000000000000000000000000000000000000000000000000000000000000/' \
  "$fixture_root/config/ubuntu-toolchain.lock"
git -C "$fixture_root" add config/ubuntu-toolchain.lock
git -C "$fixture_root" commit -qm 'stale toolchain receipt fixture'
expect_receipt_blocked lock-mismatch "$lock_mismatch_home" 'toolchain receipt mismatch: lock_sha256'

make_fixture
unmanaged_home="$(new_home unmanaged-toolchain)"
unmanaged_bin="$test_root/unmanaged-bin"
mkdir -p "$unmanaged_bin"
cp "$unmanaged_home/.local/bin/uv" "$unmanaged_home/.local/bin/python3.13" "$unmanaged_home/.local/bin/py" "$unmanaged_bin/"
expect_receipt_blocked unmanaged-toolchain "$unmanaged_home" 'uv is not managed' "$unmanaged_bin"

# Toolchain receipts are strict single-assignment maps: duplicates, malformed
# assignments, and unknown keys are all rejected before payload mutation.
make_fixture
duplicate_same_home="$(new_home receipt-duplicate-same)"
duplicate_same_line="$(grep '^uv_version=' "$duplicate_same_home/.local/state/herdr-workstation-bootstrap/toolchain-manifest.txt")"
printf '%s\n' "$duplicate_same_line" >> \
  "$duplicate_same_home/.local/state/herdr-workstation-bootstrap/toolchain-manifest.txt"
expect_receipt_blocked receipt-duplicate-same "$duplicate_same_home" 'duplicate toolchain receipt key: uv_version'

make_fixture
duplicate_conflict_home="$(new_home receipt-duplicate-conflict)"
printf 'uv_version=uv 0.0.0 (x86_64-unknown-linux-gnu)\n' >> \
  "$duplicate_conflict_home/.local/state/herdr-workstation-bootstrap/toolchain-manifest.txt"
expect_receipt_blocked receipt-duplicate-conflict "$duplicate_conflict_home" 'duplicate toolchain receipt key: uv_version'

make_fixture
malformed_receipt_home="$(new_home receipt-malformed)"
printf 'not a receipt assignment\n' >> \
  "$malformed_receipt_home/.local/state/herdr-workstation-bootstrap/toolchain-manifest.txt"
expect_receipt_blocked receipt-malformed "$malformed_receipt_home" 'malformed toolchain receipt line'

make_fixture
unknown_receipt_home="$(new_home receipt-unknown)"
printf 'future_key=not-allowed\n' >> \
  "$unknown_receipt_home/.local/state/herdr-workstation-bootstrap/toolchain-manifest.txt"
expect_receipt_blocked receipt-unknown "$unknown_receipt_home" 'unknown toolchain receipt key: future_key'

make_fixture
missing_tailscale_home="$(new_home receipt-missing-tailscale)"
sed -i '/^tailscale=/d' \
  "$missing_tailscale_home/.local/state/herdr-workstation-bootstrap/toolchain-manifest.txt"
expect_receipt_blocked receipt-missing-tailscale "$missing_tailscale_home" 'missing toolchain receipt key: tailscale'

make_fixture
duplicate_tailscale_home="$(new_home receipt-duplicate-tailscale)"
printf 'tailscale=%s\n' "$TAILSCALE_VERSION" >> \
  "$duplicate_tailscale_home/.local/state/herdr-workstation-bootstrap/toolchain-manifest.txt"
expect_receipt_blocked receipt-duplicate-tailscale "$duplicate_tailscale_home" 'duplicate toolchain receipt key: tailscale'

make_fixture
invalid_tailscale_home="$(new_home receipt-invalid-tailscale)"
sed -i 's/^tailscale=.*/tailscale=not-a-tailscale-version/' \
  "$invalid_tailscale_home/.local/state/herdr-workstation-bootstrap/toolchain-manifest.txt"
expect_receipt_blocked receipt-invalid-tailscale "$invalid_tailscale_home" 'toolchain receipt mismatch: tailscale'

# Dirty tracked source is rejected before any destination mutation.
make_fixture
dirty_home="$(new_home dirty)"
make_sentinels "$dirty_home"
printf 'dirty\n' >> "$fixture_root/payload/agents-skills/demo/SKILL.md"
expect_blocked dirty "$dirty_home" 'unstaged tracked changes'
assert_sentinels "$dirty_home"

# An uncommitted/unidentified source has no authority.
make_fixture
rm -rf "$fixture_root/.git"
git -C "$fixture_root" init -q
unidentified_home="$(new_home unidentified)"
expect_blocked unidentified "$unidentified_home" 'not an identified commit'

# A clean commit whose file content is not in the pinned manifest is rejected.
make_fixture
printf 'changed but committed\n' > "$fixture_root/payload/agents-skills/demo/SKILL.md"
git -C "$fixture_root" add payload/agents-skills/demo/SKILL.md
git -C "$fixture_root" commit -qm 'manifest mismatch fixture'
mismatch_home="$(new_home manifest-mismatch)"
expect_blocked manifest-mismatch "$mismatch_home" 'payload hash mismatch'

# Duplicate manifest paths are rejected before installation.
make_fixture
duplicate_entry="$(awk '/^[0-9a-f]{64}  / { print; exit }' "$fixture_root/config/payload-manifest.sha256")"
printf '%s\n' "$duplicate_entry" >> "$fixture_root/config/payload-manifest.sha256"
git -C "$fixture_root" add config/payload-manifest.sha256
git -C "$fixture_root" commit -qm 'duplicate manifest fixture'
duplicate_home="$(new_home duplicate-manifest)"
expect_blocked duplicate-manifest "$duplicate_home" 'duplicate payload manifest path'

# Missing and unexpected files are both rejected against the tracked manifest.
make_fixture
rm "$fixture_root/payload/agents-skills/demo/SKILL.md"
git -C "$fixture_root" add -A
git -C "$fixture_root" commit -qm 'missing payload fixture'
missing_home="$(new_home missing)"
expect_blocked missing "$missing_home" 'pinned manifest'

make_fixture
printf '%s\n' 'payload/agents-skills/ignored-extra.md' >> "$fixture_root/.gitignore"
git -C "$fixture_root" add .gitignore
git -C "$fixture_root" commit -qm 'ignored extra fixture'
printf 'unexpected\n' > "$fixture_root/payload/agents-skills/ignored-extra.md"
extra_home="$(new_home extra)"
expect_blocked extra "$extra_home" 'unexpected ignored source file'

# A destination that is itself a Git checkout is unsafe.
make_fixture
unsafe_home="$(new_home unsafe-destination)"
mkdir -p "$unsafe_home/.agents/skills"
git -C "$unsafe_home/.agents/skills" init -q
git -C "$unsafe_home/.agents/skills" config user.name 'Issue 961 hermetic test'
git -C "$unsafe_home/.agents/skills" config user.email 'issue-961@example.invalid'
git -C "$unsafe_home/.agents/skills" commit --allow-empty -qm 'unsafe destination'
expect_blocked unsafe-destination "$unsafe_home" 'Git checkout destination'
[[ -d "$unsafe_home/.agents/skills/.git" ]] || { echo 'Unsafe Git destination was mutated.' >&2; exit 1; }

# A destination nested in the source checkout is also unsafe.
make_fixture
overlap_home="$fixture_root"
expect_blocked source-overlap "$overlap_home" 'overlaps the Git source checkout'

# Existing managed parents are symlink-confined before any receipt or payload write.
make_fixture
symlink_local_home="$(new_home symlink-local)"
symlink_local_outside="$test_root/outside-local"
mkdir -p "$symlink_local_outside"
printf 'outside local sentinel\n' > "$symlink_local_outside/sentinel.txt"
rm -rf "$symlink_local_home/.local"
ln -s "$symlink_local_outside" "$symlink_local_home/.local"
expect_blocked symlink-local "$symlink_local_home" 'Managed path'
[[ "$(< "$symlink_local_outside/sentinel.txt")" == 'outside local sentinel' ]] || exit 1
[[ ! -e "$symlink_local_outside/payload-runtime-receipt.txt" ]] || exit 1

make_fixture
symlink_state_home="$(new_home symlink-state)"
symlink_state_outside="$test_root/outside-state"
mkdir -p "$symlink_state_outside"
printf 'outside state sentinel\n' > "$symlink_state_outside/sentinel.txt"
rm -rf "$symlink_state_home/.local/state"
ln -s "$symlink_state_outside" "$symlink_state_home/.local/state"
expect_blocked symlink-state "$symlink_state_home" 'Managed path'
[[ "$(< "$symlink_state_outside/sentinel.txt")" == 'outside state sentinel' ]] || exit 1

make_fixture
symlink_bin_home="$(new_home symlink-bin)"
symlink_bin_outside="$test_root/outside-bin"
mkdir -p "$symlink_bin_outside"
printf 'outside bin sentinel\n' > "$symlink_bin_outside/sentinel.txt"
rm -rf "$symlink_bin_home/.local/bin"
ln -s "$symlink_bin_outside" "$symlink_bin_home/.local/bin"
expect_blocked symlink-bin "$symlink_bin_home" 'Managed path'
[[ "$(< "$symlink_bin_outside/sentinel.txt")" == 'outside bin sentinel' ]] || exit 1

make_fixture
symlink_agents_home="$(new_home symlink-agents)"
symlink_agents_outside="$test_root/outside-agents"
mkdir -p "$symlink_agents_outside"
printf 'outside agents sentinel\n' > "$symlink_agents_outside/sentinel.txt"
ln -s "$symlink_agents_outside" "$symlink_agents_home/.agents"
expect_blocked symlink-agents "$symlink_agents_home" 'Managed path'
[[ "$(< "$symlink_agents_outside/sentinel.txt")" == 'outside agents sentinel' ]] || exit 1

make_fixture
symlink_claude_home="$(new_home symlink-claude)"
symlink_claude_outside="$test_root/outside-claude"
mkdir -p "$symlink_claude_outside"
printf 'outside claude sentinel\n' > "$symlink_claude_outside/sentinel.txt"
ln -s "$symlink_claude_outside" "$symlink_claude_home/.claude"
expect_blocked symlink-claude "$symlink_claude_home" 'Managed path'
[[ "$(< "$symlink_claude_outside/sentinel.txt")" == 'outside claude sentinel' ]] || exit 1

# A failed installed-hash check must roll back both managed destinations.
make_fixture
rollback_home="$(new_home rollback)"
make_sentinels "$rollback_home"
rollback_output="$test_root/rollback.out"
set +e
(
  export HOME="$rollback_home"
  export PATH="$rollback_home/.local/bin:$PATH"
  # shellcheck disable=SC1091
  source "$fixture_root/scripts/ubuntu/install-payload.sh"
  verify_installed_payload() { return 1; }
  main > "$rollback_output" 2>&1
)
rollback_status=$?
set -e
[[ "$rollback_status" -ne 0 ]] || { echo 'Injected installed hash mismatch unexpectedly passed.' >&2; exit 1; }
grep -Fq 'previous destinations were restored' "$rollback_output"
assert_sentinels "$rollback_home"
assert_no_transaction_residue "$rollback_home"

# A failure after the first live move restores both destinations and the prior receipt.
make_fixture
after_move_home="$(new_home failure-after-move)"
make_sentinels "$after_move_home"
write_payload_receipt_sentinel "$after_move_home"
after_move_receipt="$test_root/after-move-receipt.before"
cp "$after_move_home/.local/state/herdr-workstation-bootstrap/payload-runtime-receipt.txt" "$after_move_receipt"
set +e
HERDR_PAYLOAD_TEST_FAIL_PHASE=after-agents-backup \
  HOME="$after_move_home" PATH="$after_move_home/.local/bin:$PATH" \
  bash "$fixture_root/scripts/ubuntu/install-payload.sh" > "$test_root/after-move.out" 2>&1
after_move_status=$?
set -e
[[ "$after_move_status" -ne 0 ]] || exit 1
assert_restored_transaction "$after_move_home" "$after_move_receipt"

# A failure after the first new destination commit removes the new tree and restores the old one.
make_fixture
after_commit_home="$(new_home failure-after-commit)"
make_sentinels "$after_commit_home"
write_payload_receipt_sentinel "$after_commit_home"
after_commit_receipt="$test_root/after-commit-receipt.before"
cp "$after_commit_home/.local/state/herdr-workstation-bootstrap/payload-runtime-receipt.txt" "$after_commit_receipt"
set +e
HERDR_PAYLOAD_TEST_FAIL_PHASE=after-agents-commit \
  HOME="$after_commit_home" PATH="$after_commit_home/.local/bin:$PATH" \
  bash "$fixture_root/scripts/ubuntu/install-payload.sh" > "$test_root/after-commit.out" 2>&1
after_commit_status=$?
set -e
[[ "$after_commit_status" -ne 0 ]] || exit 1
assert_restored_transaction "$after_commit_home" "$after_commit_receipt"

# A receipt-write failure also restores the prior receipt and both destinations.
make_fixture
receipt_failure_home="$(new_home failure-receipt-write)"
make_sentinels "$receipt_failure_home"
write_payload_receipt_sentinel "$receipt_failure_home"
receipt_failure_before="$test_root/receipt-failure.before"
cp "$receipt_failure_home/.local/state/herdr-workstation-bootstrap/payload-runtime-receipt.txt" "$receipt_failure_before"
set +e
HERDR_PAYLOAD_TEST_FAIL_RECEIPT_WRITE=1 \
  HOME="$receipt_failure_home" PATH="$receipt_failure_home/.local/bin:$PATH" \
  bash "$fixture_root/scripts/ubuntu/install-payload.sh" > "$test_root/receipt-failure.out" 2>&1
receipt_failure_status=$?
set -e
[[ "$receipt_failure_status" -ne 0 ]] || exit 1
assert_restored_transaction "$receipt_failure_home" "$receipt_failure_before"

# A restore failure retains only the exact transaction's unrestored backup. A
# later invocation must remain non-mutating even after the restore fault clears.
run_retained_restore_case() {
  local case_name="$1"
  local fail_source="$2"
  local fail_phase="$3"
  local home
  local receipt_before="$test_root/$case_name.receipt.before"
  local output="$test_root/$case_name.out"
  local retry_output="$test_root/$case_name.retry.out"
  local before_retry="$test_root/$case_name.before-retry"
  local root
  local status
  local retry_status
  local foreign_backup

  make_fixture
  home="$(new_home "$case_name")"
  make_sentinels "$home"
  write_payload_receipt_sentinel "$home"
  cp "$home/.local/state/herdr-workstation-bootstrap/payload-runtime-receipt.txt" "$receipt_before"
  foreign_backup="$home/.local/state/herdr-workstation-bootstrap/.payload-backup-foreign"
  mkdir -p "$foreign_backup/agents-skills"
  chmod 0700 "$foreign_backup"
  printf 'foreign backup sentinel\n' > "$foreign_backup/agents-skills/sentinel.txt"
  make_restore_mv_shim "$home"

  set +e
  HERDR_PAYLOAD_TEST_FAIL_PHASE="$fail_phase" \
  HERDR_TEST_FAIL_MV_SOURCE="$fail_source" \
  HOME="$home" PATH="$home/.local/bin:$PATH" \
    bash "$fixture_root/scripts/ubuntu/install-payload.sh" > "$output" 2>&1
  status=$?
  set -e
  [[ "$status" == 31 ]] || { cat "$output" >&2; echo "$case_name expected exit 31, got $status." >&2; exit 1; }
  grep -Fq 'incomplete rollback retained at' "$output"
  assert_retained_transaction "$home"
  root="$(transaction_root "$home")"
  expected_backup_count=1
  [[ "$fail_source" == agents-skills,claude-skills ]] && expected_backup_count=2
  [[ "$(find "$root/backup" -mindepth 1 -maxdepth 1 -printf x | wc -c)" == "$expected_backup_count" ]] || exit 1
  case "$fail_source" in
    agents-skills)
      [[ ! -e "$home/.agents/skills" && ! -L "$home/.agents/skills" ]] || exit 1
      [[ "$(< "$home/.claude/skills/keep.txt")" == 'keep claude' ]] || exit 1
      [[ -f "$root/backup/agents-skills/keep.txt" ]] || exit 1
      [[ ! -e "$root/backup/claude-skills" && ! -e "$root/backup/payload-runtime-receipt.txt" ]] || exit 1
      ;;
    claude-skills)
      [[ "$(< "$home/.agents/skills/keep.txt")" == 'keep agents' ]] || exit 1
      [[ ! -e "$home/.claude/skills" && ! -L "$home/.claude/skills" ]] || exit 1
      [[ -f "$root/backup/claude-skills/keep.txt" ]] || exit 1
      [[ ! -e "$root/backup/agents-skills" && ! -e "$root/backup/payload-runtime-receipt.txt" ]] || exit 1
      ;;
    payload-runtime-receipt.txt)
      [[ "$(< "$home/.agents/skills/keep.txt")" == 'keep agents' ]] || exit 1
      [[ "$(< "$home/.claude/skills/keep.txt")" == 'keep claude' ]] || exit 1
      [[ ! -e "$home/.local/state/herdr-workstation-bootstrap/payload-runtime-receipt.txt" ]] || exit 1
      cmp -s "$receipt_before" "$root/backup/payload-runtime-receipt.txt"
      [[ ! -e "$root/backup/agents-skills" && ! -e "$root/backup/claude-skills" ]] || exit 1
      ;;
    agents-skills,claude-skills)
      [[ ! -e "$home/.agents/skills" && ! -L "$home/.agents/skills" ]] || exit 1
      [[ ! -e "$home/.claude/skills" && ! -L "$home/.claude/skills" ]] || exit 1
      [[ -f "$root/backup/agents-skills/keep.txt" ]] || exit 1
      [[ -f "$root/backup/claude-skills/keep.txt" ]] || exit 1
      [[ ! -e "$root/backup/payload-runtime-receipt.txt" ]] || exit 1
      ;;
    *) exit 1 ;;
  esac
  [[ "$(< "$foreign_backup/agents-skills/sentinel.txt")" == 'foreign backup sentinel' ]] || exit 1

  rm "$home/.local/bin/mv"
  snapshot_install_state "$home" "$before_retry"
  set +e
  HOME="$home" PATH="$home/.local/bin:$PATH" \
    bash "$fixture_root/scripts/ubuntu/install-payload.sh" > "$retry_output" 2>&1
  retry_status=$?
  set -e
  [[ "$retry_status" == 31 ]] || { cat "$retry_output" >&2; echo "$case_name retry expected exit 31, got $retry_status." >&2; exit 1; }
  grep -Fq 'manual operator recovery required' "$retry_output"
  grep -Fq "transaction=$root" "$retry_output"
  snapshot_install_state "$home" "$test_root/$case_name.after-retry"
  cmp -s "$before_retry" "$test_root/$case_name.after-retry" || {
    echo "$case_name changed managed, backup, journal, or transaction state during blocked retry." >&2
    diff -u "$before_retry" "$test_root/$case_name.after-retry" >&2 || true
    exit 1
  }
  assert_retained_transaction "$home"
  [[ "$(< "$foreign_backup/agents-skills/sentinel.txt")" == 'foreign backup sentinel' ]] || exit 1
}

run_retained_restore_case rollback-failed-agents agents-skills after-agents-commit
run_retained_restore_case rollback-failed-claude claude-skills after-claude-commit
run_retained_restore_case rollback-failed-receipt payload-runtime-receipt.txt after-claude-commit
run_retained_restore_case rollback-failed-mixed agents-skills,claude-skills after-claude-commit

new_incomplete_home() {
  local case_name="$1"
  local home
  local status
  make_fixture
  home="$(new_home "$case_name")"
  make_sentinels "$home"
  write_payload_receipt_sentinel "$home"
  make_restore_mv_shim "$home"
  set +e
  HERDR_PAYLOAD_TEST_FAIL_PHASE=after-agents-commit \
  HERDR_TEST_FAIL_MV_SOURCE=agents-skills \
  HOME="$home" PATH="$home/.local/bin:$PATH" \
    bash "$fixture_root/scripts/ubuntu/install-payload.sh" > "$test_root/$case_name.seed.out" 2>&1
  status=$?
  set -e
  [[ "$status" == 31 ]] || { cat "$test_root/$case_name.seed.out" >&2; exit 1; }
  assert_retained_transaction "$home"
  printf '%s\n' "$home"
}

# Malformed or adversarial journals are parsed as inert data and must remain
# byte-for-byte unchanged, with no command substitution or path following.
run_journal_case() {
  local kind="$1"
  local home
  local root
  local state
  local state_dir
  local marker="$test_root/journal-$kind-command-ran"
  local before="$test_root/journal-$kind.before"
  local after="$test_root/journal-$kind.after"
  local output="$test_root/journal-$kind.out"
  local status

  home="$(new_incomplete_home "journal-$kind")"
  rm "$home/.local/bin/mv"
  root="$(transaction_root "$home")"
  state="$root/state"
  state_dir="$home/.local/state/herdr-workstation-bootstrap"
  case "$kind" in
    malformed)
      printf 'not a journal assignment\n' >> "$state"
      ;;
    truncated)
      sed -i '$d' "$state"
      ;;
    duplicate)
      printf 'phase=rollback-incomplete\n' >> "$state"
      ;;
    unknown)
      printf 'future_key=not-allowed\n' >> "$state"
      ;;
    conflicting)
      sed -i "s#^transaction_root=.*#transaction_root=$state_dir/.payload-transaction-conflicting#" "$state"
      ;;
    command-substitution)
      awk -v marker="$marker" '
        BEGIN { replacement = "repo_root=$(touch " marker ")" }
        /^repo_root=/ { print replacement; next }
        { print }
      ' "$state" > "$state.tmp"
      chmod 0600 "$state.tmp"
      mv -T -- "$state.tmp" "$state"
      ;;
    path-traversal)
      sed -i "s#^transaction_root=.*#transaction_root=$state_dir/../outside-transaction#" "$state"
      ;;
    absolute-substitution)
      sed -i 's#^state_dir=.*#state_dir=/tmp/issue-961-absolute-substitution#' "$state"
      ;;
    *)
      echo "unknown journal case: $kind" >&2
      exit 1
      ;;
  esac
  snapshot_install_state "$home" "$before"
  set +e
  HOME="$home" PATH="$home/.local/bin:$PATH" \
    bash "$fixture_root/scripts/ubuntu/install-payload.sh" > "$output" 2>&1
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || { cat "$output" >&2; echo "$kind journal unexpectedly passed." >&2; exit 1; }
  grep -Fq 'BLOCKED:' "$output"
  snapshot_install_state "$home" "$after"
  cmp -s "$before" "$after" || {
    echo "$kind journal changed managed, backup, journal, or transaction state." >&2
    diff -u "$before" "$after" >&2 || true
    exit 1
  }
  [[ ! -e "$marker" ]] || { echo "$kind journal evaluated command substitution." >&2; exit 1; }
}

run_journal_case malformed
run_journal_case truncated
run_journal_case duplicate
run_journal_case unknown
run_journal_case conflicting
run_journal_case command-substitution
run_journal_case path-traversal
run_journal_case absolute-substitution

# A signal during incomplete rollback must leave the journal and every
# unrestored backup in place; a later invocation remains blocked and inert.
make_fixture
signal_recovery_home="$(new_home rollback-signal-during-recovery)"
make_sentinels "$signal_recovery_home"
write_payload_receipt_sentinel "$signal_recovery_home"
make_restore_mv_shim "$signal_recovery_home"
set +e
HERDR_PAYLOAD_TEST_FAIL_PHASE=after-agents-commit \
HERDR_TEST_FAIL_MV_SOURCE=agents-skills \
HERDR_TEST_MV_SIGNAL=TERM \
HOME="$signal_recovery_home" PATH="$signal_recovery_home/.local/bin:$PATH" \
  bash "$fixture_root/scripts/ubuntu/install-payload.sh" > "$test_root/rollback-signal-during-recovery.out" 2>&1
signal_recovery_status=$?
set -e
[[ "$signal_recovery_status" == 143 ]] || {
  cat "$test_root/rollback-signal-during-recovery.out" >&2
  echo "rollback signal expected exit 143, got $signal_recovery_status." >&2
  exit 1
}
signal_recovery_root="$(transaction_root "$signal_recovery_home")"
[[ -n "$signal_recovery_root" && -f "$signal_recovery_root/state" ]] || exit 1
[[ "$(stat -c '%a' "$signal_recovery_root")" == 700 ]] || exit 1
[[ "$(stat -c '%a' "$signal_recovery_root/state")" == 600 ]] || exit 1
[[ -f "$signal_recovery_root/backup/agents-skills/keep.txt" ]] || exit 1
[[ -f "$signal_recovery_root/backup/claude-skills/keep.txt" ]] || exit 1
[[ -f "$signal_recovery_root/backup/payload-runtime-receipt.txt" ]] || exit 1
rm "$signal_recovery_home/.local/bin/mv"
snapshot_install_state "$signal_recovery_home" "$test_root/rollback-signal-during-recovery.before"
set +e
HOME="$signal_recovery_home" PATH="$signal_recovery_home/.local/bin:$PATH" \
  bash "$fixture_root/scripts/ubuntu/install-payload.sh" > "$test_root/rollback-signal-during-recovery.retry.out" 2>&1
signal_recovery_retry_status=$?
set -e
[[ "$signal_recovery_retry_status" == 31 ]] || {
  cat "$test_root/rollback-signal-during-recovery.retry.out" >&2
  exit 1
}
grep -Fq 'manual operator recovery required' "$test_root/rollback-signal-during-recovery.retry.out"
snapshot_install_state "$signal_recovery_home" "$test_root/rollback-signal-during-recovery.after"
cmp -s "$test_root/rollback-signal-during-recovery.before" \
  "$test_root/rollback-signal-during-recovery.after" || exit 1

# Foreign, ambiguous, unsafe, and symlinked transaction shapes fail closed
# without selecting, following, cleaning, or mutating any candidate.
run_transaction_shape_case() {
  local kind="$1"
  local home
  local root
  local state_dir
  local outside="$test_root/shape-$kind-outside"
  local before="$test_root/shape-$kind.before"
  local after="$test_root/shape-$kind.after"
  local output="$test_root/shape-$kind.out"
  local status
  local real_root

  home="$(new_incomplete_home "shape-$kind")"
  rm "$home/.local/bin/mv"
  root="$(transaction_root "$home")"
  state_dir="$home/.local/state/herdr-workstation-bootstrap"
  mkdir -p "$outside"
  printf 'outside shape sentinel\n' > "$outside/sentinel.txt"
  case "$kind" in
    multiple)
      cp -a "$root" "$state_dir/.payload-transaction.second"
      mkdir -p "$state_dir/.payload-foreign"
      printf 'foreign state sentinel\n' > "$state_dir/.payload-foreign/sentinel.txt"
      ;;
    foreign)
      mkdir -p "$state_dir/.payload-foreign"
      printf 'foreign state sentinel\n' > "$state_dir/.payload-foreign/sentinel.txt"
      ;;
    wrong-mode)
      chmod 0755 "$root"
      ;;
    wrong-owner)
      if [[ "$(id -u)" == 0 ]]; then
        chown 65534:65534 "$root"
      else
        chmod 0755 "$root"
      fi
      ;;
    symlink-transaction)
      real_root="$state_dir/.retained-transaction-real"
      mv -T -- "$root" "$real_root"
      ln -s "$outside" "$root"
      ;;
    symlink-journal)
      printf 'outside journal sentinel\n' > "$outside/journal-target"
      mv -T -- "$root/state" "$root/state-real"
      ln -s "$outside/journal-target" "$root/state"
      ;;
    symlink-backup)
      mv -T -- "$root/backup" "$root/backup-real"
      ln -s "$outside" "$root/backup"
      ;;
    symlink-backup-entry)
      mkdir -p "$outside/entry-target"
      printf 'outside backup-entry sentinel\n' > "$outside/entry-target/sentinel.txt"
      mv -T -- "$root/backup/agents-skills" "$root/backup/agents-real"
      ln -s "$outside/entry-target" "$root/backup/agents-skills"
      ;;
    *)
      echo "unknown transaction shape case: $kind" >&2
      exit 1
      ;;
  esac
  snapshot_install_state "$home" "$before"
  set +e
  HOME="$home" PATH="$home/.local/bin:$PATH" \
    bash "$fixture_root/scripts/ubuntu/install-payload.sh" > "$output" 2>&1
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || { cat "$output" >&2; echo "$kind transaction shape unexpectedly passed." >&2; exit 1; }
  grep -Fq 'BLOCKED:' "$output"
  snapshot_install_state "$home" "$after"
  cmp -s "$before" "$after" || {
    echo "$kind transaction shape changed managed, foreign, or transaction state." >&2
    diff -u "$before" "$after" >&2 || true
    exit 1
  }
  [[ "$(< "$outside/sentinel.txt")" == 'outside shape sentinel' ]] || exit 1
  [[ ! -e "$outside/skills" ]] || exit 1
  [[ ! -e "$outside/payload-runtime-receipt.txt" ]] || exit 1
  if [[ "$kind" == foreign || "$kind" == multiple ]]; then
    [[ "$(< "$state_dir/.payload-foreign/sentinel.txt")" == 'foreign state sentinel' ]] || exit 1
  fi
  if [[ "$kind" == symlink-journal ]]; then
    [[ "$(< "$outside/journal-target")" == 'outside journal sentinel' ]] || exit 1
  fi
  if [[ "$kind" == symlink-backup-entry ]]; then
    [[ "$(< "$outside/entry-target/sentinel.txt")" == 'outside backup-entry sentinel' ]] || exit 1
  fi
}

run_transaction_shape_case multiple
run_transaction_shape_case foreign
run_transaction_shape_case wrong-mode
run_transaction_shape_case wrong-owner
run_transaction_shape_case symlink-transaction
run_transaction_shape_case symlink-journal
run_transaction_shape_case symlink-backup
run_transaction_shape_case symlink-backup-entry

# Source drift after staging is detected before the first live mutation.
make_fixture
drift_home="$(new_home source-drift)"
drift_ready="$test_root/source-drift.ready"
drift_continue="$test_root/source-drift.continue"
HERDR_PAYLOAD_TEST_PAUSE_PHASE=before-commit \
HERDR_PAYLOAD_TEST_READY_FILE="$drift_ready" \
HERDR_PAYLOAD_TEST_CONTINUE_FILE="$drift_continue" \
HOME="$drift_home" PATH="$drift_home/.local/bin:$PATH" \
  bash "$fixture_root/scripts/ubuntu/install-payload.sh" > "$test_root/source-drift.out" 2>&1 &
drift_pid=$!
if ! wait_for_file "$drift_ready"; then
  kill "$drift_pid" 2>/dev/null || true
  wait "$drift_pid" 2>/dev/null || true
  exit 1
fi
printf 'source drift after staging\n' >> "$fixture_root/payload/agents-skills/demo/SKILL.md"
: > "$drift_continue"
set +e
wait "$drift_pid"
drift_status=$?
set -e
[[ "$drift_status" -ne 0 ]] || exit 1
grep -Eq 'unstaged tracked changes|commit drifted' "$test_root/source-drift.out"
[[ ! -e "$drift_home/.agents/skills" && ! -e "$drift_home/.claude/skills" ]] || exit 1
assert_no_transaction_residue "$drift_home"

# A second installer cannot enter while the first holds the per-user lock.
make_fixture
concurrent_home="$(new_home concurrent)"
concurrent_ready="$test_root/concurrent.ready"
concurrent_continue="$test_root/concurrent.continue"
HERDR_PAYLOAD_TEST_PAUSE_PHASE=lock-acquired \
HERDR_PAYLOAD_TEST_READY_FILE="$concurrent_ready" \
HERDR_PAYLOAD_TEST_CONTINUE_FILE="$concurrent_continue" \
HOME="$concurrent_home" PATH="$concurrent_home/.local/bin:$PATH" \
  bash "$fixture_root/scripts/ubuntu/install-payload.sh" > "$test_root/concurrent-first.out" 2>&1 &
concurrent_pid=$!
if ! wait_for_file "$concurrent_ready"; then
  kill "$concurrent_pid" 2>/dev/null || true
  wait "$concurrent_pid" 2>/dev/null || true
  exit 1
fi
set +e
HOME="$concurrent_home" PATH="$concurrent_home/.local/bin:$PATH" \
  bash "$fixture_root/scripts/ubuntu/install-payload.sh" > "$test_root/concurrent-second.out" 2>&1
concurrent_second_status=$?
set -e
[[ "$concurrent_second_status" -ne 0 ]] || exit 1
grep -Fq 'another payload installation is already in progress' "$test_root/concurrent-second.out"
: > "$concurrent_continue"
set +e
wait "$concurrent_pid"
concurrent_first_status=$?
set -e
[[ "$concurrent_first_status" -eq 0 ]] || { cat "$test_root/concurrent-first.out" >&2; exit 1; }
[[ -f "$concurrent_home/.agents/skills/demo/SKILL.md" && -f "$concurrent_home/.claude/skills/demo/SKILL.md" ]] || exit 1
assert_no_transaction_residue "$concurrent_home"

echo 'Payload manifest authority, fail-closed and transactional receipt tests passed.'
