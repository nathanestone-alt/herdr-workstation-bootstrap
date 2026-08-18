#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
fixture_root="$test_root/source"
tool_home="$test_root/tools"
mkdir -p "$tool_home/.local/bin"

make_tool_fixtures() {
  local home="$1"
  mkdir -p "$home/.local/bin"
  cat > "$home/.local/bin/uv" <<'EOF'
#!/usr/bin/env bash
echo 'uv 0.12.5 (x86_64-unknown-linux-gnu)'
EOF
  cat > "$home/.local/bin/python3.13" <<'EOF'
#!/usr/bin/env bash
echo 'Python 3.13.15'
EOF
  cat > "$home/.local/bin/py" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == '-3.13' ]] || exit 2
shift
[[ "${1:-}" == '--version' ]] || exit 2
echo 'Python 3.13.15'
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
  printf '%s' "$home"
}

expect_blocked() {
  local case_name="$1"
  local home="$2"
  local expected_text="$3"
  local output="$test_root/$case_name.out"
  set +e
  HOME="$home" PATH="$tool_home/.local/bin:$PATH" bash "$fixture_root/scripts/ubuntu/install-payload.sh" > "$output" 2>&1
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

# A failed installed-hash check must roll back both managed destinations.
make_fixture
rollback_home="$(new_home rollback)"
make_sentinels "$rollback_home"
rollback_output="$test_root/rollback.out"
set +e
(
  export HOME="$rollback_home"
  export PATH="$tool_home/.local/bin:$PATH"
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

echo 'Payload manifest authority, fail-closed and transactional receipt tests passed.'
