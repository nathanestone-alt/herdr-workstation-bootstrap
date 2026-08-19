#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
fixture_root="$test_root/source"

make_tool_fixtures() {
  local home="$1"
  local uv_version="${FIXTURE_UV_VERSION:-0.12.5}"
  local uv_platform="${FIXTURE_UV_PLATFORM:-x86_64-unknown-linux-gnu}"
  local python_version="${FIXTURE_PYTHON_VERSION:-3.13.15}"
  local py_probe="${FIXTURE_PY_PROBE:-3.13.15|x86_64|linux}"
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

# Successful transactional install, ignored commissioning log allowance and
# deterministic receipt content.
make_fixture
success_home="$(new_home success)"
printf 'local commissioning notes\n' > "$fixture_root/LOCAL-COMMISSIONING-LOG.md"
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
grep -Fqx 'regression_test_count=10' "$receipt"
grep -Fq 'source_payload_sha256.agents-skills/demo/SKILL.md=' "$receipt"
grep -Fq 'installed_payload_sha256.claude-skills/demo/SKILL.md=' "$receipt"
! grep -Eiq 'timestamp|hostname|LOCAL-COMMISSIONING-LOG' "$receipt"

# Locked toolchain provenance is required before any payload destination move.
make_fixture
wrong_uv_home="$(FIXTURE_UV_VERSION=0.0.1 new_home wrong-uv-version)"
expect_blocked wrong-uv-version "$wrong_uv_home" 'managed uv version is not locked'

make_fixture
wrong_platform_home="$(FIXTURE_UV_PLATFORM=aarch64-unknown-linux-gnu new_home wrong-uv-platform)"
expect_blocked wrong-uv-platform "$wrong_platform_home" 'managed uv version is not locked'

make_fixture
wrong_probe_home="$(FIXTURE_PY_PROBE='3.13.15|aarch64|linux' new_home wrong-python-probe)"
expect_blocked wrong-python-probe "$wrong_probe_home" 'managed py platform probe is not locked'

make_fixture
wrong_release_home="$(new_home wrong-python-release)"
sed -i 's/^python_release=.*/python_release=stale-release/' \
  "$wrong_release_home/.local/state/herdr-workstation-bootstrap/toolchain-manifest.txt"
expect_blocked wrong-python-release "$wrong_release_home" 'toolchain receipt mismatch: python_release'

make_fixture
missing_receipt_home="$(new_home missing-toolchain-receipt)"
rm "$missing_receipt_home/.local/state/herdr-workstation-bootstrap/toolchain-manifest.txt"
expect_blocked missing-toolchain-receipt "$missing_receipt_home" 'Missing bootstrap toolchain receipt'

make_fixture
lock_mismatch_home="$(new_home lock-mismatch)"
sed -i 's/^UV_SHA256=.*/UV_SHA256=0000000000000000000000000000000000000000000000000000000000000000/' \
  "$fixture_root/config/ubuntu-toolchain.lock"
git -C "$fixture_root" add config/ubuntu-toolchain.lock
git -C "$fixture_root" commit -qm 'stale toolchain receipt fixture'
expect_blocked lock-mismatch "$lock_mismatch_home" 'toolchain receipt mismatch: lock_sha256'

make_fixture
unmanaged_home="$(new_home unmanaged-toolchain)"
unmanaged_bin="$test_root/unmanaged-bin"
mkdir -p "$unmanaged_bin"
cp "$unmanaged_home/.local/bin/uv" "$unmanaged_home/.local/bin/python3.13" "$unmanaged_home/.local/bin/py" "$unmanaged_bin/"
expect_blocked unmanaged-toolchain "$unmanaged_home" 'uv is not managed' "$unmanaged_bin"

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
