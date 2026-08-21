#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

# The authority deliberately validates the same source/RTK relationships as
# production. Build a small clean source checkout and a clean locked RTK
# checkout rather than weakening those predicates for fixture mode.
source "$repo_root/config/ubuntu-toolchain.lock"
fixture_root="$test_root/fixture"
fixture_home="$fixture_root/home"
authority_path="$fixture_root/etc/stmodel/issue-961/receipt-authority.json"
receipt_path="$fixture_root/etc/stmodel/issue-961/receipt.json"
source_root="$test_root/source"
rtk_source_root="$fixture_home/src/rtk"
runtime_root="$fixture_home/.local/lib/herdr-workstation/python/$PYTHON_VERSION-$PYTHON_RELEASE-$PYTHON_PLATFORM"
stdlib_root="$runtime_root/lib/python3.13"
entrypoint_root="$test_root/entrypoint"

mkdir -p \
  "$fixture_root/bin" \
  "$fixture_home/.local/bin" \
  "$fixture_home/.local/lib/node-v$NODE_VERSION-linux-x64/bin" \
  "$fixture_home/.cargo/bin" \
  "$stdlib_root" \
  "$runtime_root/bin" \
  "$rtk_source_root"

make_tool() {
  local path="$1"
  local output="$2"
  cat > "$path" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == '--version' ]]; then
  printf '%s\n' '$output'
else
  exit 2
fi
EOF
  chmod 0755 "$path"
}

make_tool "$fixture_root/bin/bash" 'GNU bash, version 5.2.21(1)-release (x86_64-pc-linux-gnu)'
make_tool "$fixture_root/bin/git" 'git version 2.43.0'
make_tool "$fixture_root/bin/gh" 'gh version 2.45.0 (fixture)'
make_tool "$fixture_root/bin/pwsh" 'PowerShell 7.6.5'
make_tool "$fixture_home/.local/lib/node-v$NODE_VERSION-linux-x64/bin/node" "v$NODE_VERSION"
make_tool "$fixture_home/.cargo/bin/rtk" 'rtk 0.42.4'

export FIXTURE_HOME="$fixture_home"
export FIXTURE_RUNTIME_ROOT="$runtime_root"
cat > "$fixture_home/.local/bin/python3.13" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == '--version' ]]; then
  printf 'Python 3.13.15\n'
elif [[ "${1:-}" == '-c' ]]; then
  printf '{"version":"3.13.15","version_info":[3,13,15,"final",0],"implementation":"CPython","executable":"%s","prefix":"%s/.local","base_prefix":"%s","stdlib":"%s/lib/python3.13"}\n' \
    "$0" "$FIXTURE_HOME" "$FIXTURE_RUNTIME_ROOT" "$FIXTURE_RUNTIME_ROOT"
else
  exit 2
fi
EOF
chmod 0755 "$fixture_home/.local/bin/python3.13"
printf 'runtime executable\n' > "$runtime_root/bin/python3.13"
printf 'stdlib fixture\n' > "$stdlib_root/fixture.py"
ln -s fixture.py "$stdlib_root/fixture-link.py"
cat > "$fixture_home/.local/pyvenv.cfg" <<EOF
home = $runtime_root
include-system-site-packages = false
version = $PYTHON_VERSION
EOF

git -C "$rtk_source_root" init -q
git -C "$rtk_source_root" config user.email fixture@example.invalid
git -C "$rtk_source_root" config user.name fixture
printf 'locked RTK source\n' > "$rtk_source_root/README"
chmod 0644 "$rtk_source_root/README"
git -C "$rtk_source_root" add README
git -C "$rtk_source_root" commit -qm 'fixture RTK source'
rtk_commit="$(git -C "$rtk_source_root" rev-parse HEAD)"
git -C "$rtk_source_root" remote add origin "$RTK_REPO_URL"

mkdir -p "$source_root/config" "$source_root/scripts/ubuntu"
cp "$repo_root/scripts/ubuntu/receipt-authority.sh" "$source_root/scripts/ubuntu/receipt-authority.sh"
cp "$repo_root/scripts/ubuntu/source-attestation.sh" "$source_root/scripts/ubuntu/source-attestation.sh"
cp "$repo_root/config/receipt-authority-role-allowlist.txt" "$source_root/config/receipt-authority-role-allowlist.txt"
cp "$repo_root/config/payload-manifest.sha256" "$source_root/config/payload-manifest.sha256"
cp "$repo_root/config/ubuntu-toolchain.lock" "$source_root/config/ubuntu-toolchain.lock"
chmod 0644 \
  "$source_root/config/receipt-authority-role-allowlist.txt" \
  "$source_root/config/payload-manifest.sha256" \
  "$source_root/config/ubuntu-toolchain.lock"
sed -i "s/^RTK_REF=.*/RTK_REF=$rtk_commit/" "$source_root/config/ubuntu-toolchain.lock"
git -C "$source_root" init -q
git -C "$source_root" config user.email fixture@example.invalid
git -C "$source_root" config user.name fixture
git -C "$source_root" add .
git -C "$source_root" commit -qm 'fixture bootstrap source'

# The entrypoint itself is a separate clean committed fixture.  The source
# checkout below is intentionally mutated by later probes, while the direct
# receipt invocation must continue to prove its own helper before it reads
# that mutable input.
mkdir -p "$entrypoint_root/scripts/ubuntu"
cp "$repo_root/scripts/ubuntu/receipt-authority.sh" "$entrypoint_root/scripts/ubuntu/receipt-authority.sh"
cp "$repo_root/scripts/ubuntu/source-attestation.sh" "$entrypoint_root/scripts/ubuntu/source-attestation.sh"
git -C "$entrypoint_root" init -q
git -C "$entrypoint_root" config user.email fixture@example.invalid
git -C "$entrypoint_root" config user.name fixture
git -C "$entrypoint_root" add .
git -C "$entrypoint_root" commit -qm 'fixture receipt entrypoint'
entrypoint_script="$entrypoint_root/scripts/ubuntu/receipt-authority.sh"

# Direct receipt help must bind the committed helper before sourcing it, and
# must not resolve any integrity or Git seam through a hostile PATH.
receipt_hostile_path="$test_root/receipt-hostile-path"
mkdir -p "$receipt_hostile_path"
for receipt_hostile_command in env git realpath dirname find mktemp chmod stat sha256sum gawk head cp rm; do
  cat > "$receipt_hostile_path/$receipt_hostile_command" <<EOF
#!/usr/bin/bash
: > '$test_root/receipt-path-$receipt_hostile_command-reached'
exit 99
EOF
  chmod 0755 "$receipt_hostile_path/$receipt_hostile_command"
done
if ! /usr/bin/env -i HOME="$fixture_home" PATH="$receipt_hostile_path:/usr/bin:/bin" \
  /usr/bin/bash "$entrypoint_script" --help > "$test_root/receipt-help-output" 2>&1; then
  cat "$test_root/receipt-help-output" >&2
  exit 1
fi
for receipt_hostile_command in env git realpath dirname find mktemp chmod stat sha256sum gawk head cp rm; do
  [[ ! -e "$test_root/receipt-path-$receipt_hostile_command-reached" ]] || {
    echo "Receipt authority resolved hostile PATH command: $receipt_hostile_command" >&2
    exit 1
  }
done

dirty_entrypoint_root="$test_root/dirty-entrypoint"
cp -a -- "$entrypoint_root" "$dirty_entrypoint_root"
dirty_receipt_marker="$test_root/dirty-receipt-top-level"
dirty_receipt_function_marker="$test_root/dirty-receipt-function"
cat >> "$dirty_entrypoint_root/scripts/ubuntu/source-attestation.sh" <<EOF
: > '$dirty_receipt_marker'
attestation_create_git_snapshot() { : > '$dirty_receipt_function_marker'; return 0; }
EOF
if /usr/bin/env -i HOME="$fixture_home" PATH="$receipt_hostile_path:/usr/bin:/bin" \
  /usr/bin/bash "$dirty_entrypoint_root/scripts/ubuntu/receipt-authority.sh" --help \
  > "$test_root/dirty-receipt-output" 2>&1; then
  echo 'Dirty live receipt helper was accepted.' >&2
  exit 1
fi
[[ ! -e "$dirty_receipt_marker" && ! -e "$dirty_receipt_function_marker" ]] || {
  echo 'Dirty receipt helper code executed before attestation.' >&2
  exit 1
}

run_authority() {
  bash "$entrypoint_script" "$@" \
    --source-root "$source_root" \
    --user-home "$fixture_home" \
    --authority-path "$authority_path" \
    --receipt-path "$receipt_path" \
    --rtk-source-root "$rtk_source_root" \
    --fixture-root "$fixture_root"
}

expect_failure() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "$label unexpectedly passed." >&2
    exit 1
  fi
}

run_authority --install
run_authority --check
[[ -f "$authority_path" && ! -L "$authority_path" ]] || exit 1
[[ -f "$receipt_path" && ! -L "$receipt_path" ]] || exit 1
[[ "$(jq -r '.authority_id' "$authority_path")" == '#961-installation-authority-v1' ]] || exit 1
[[ "$(jq -r '.role_identities.rtk.executable' "$receipt_path")" == "$fixture_home/.cargo/bin/rtk" ]] || exit 1
[[ "$(jq -r '.rtk_source.locked_ref' "$receipt_path")" == "$rtk_commit" ]] || exit 1
[[ "$(jq -r '.rtk_source.clean' "$receipt_path")" == true ]] || exit 1
[[ "$(jq -r '.python313.venv.home' "$receipt_path")" == "$runtime_root" ]] || exit 1
[[ "$(jq -r '.python313.runtime.base_prefix' "$receipt_path")" == "$runtime_root" ]] || exit 1
[[ "$(jq -r '.python313.runtime.stdlib' "$receipt_path")" == "$stdlib_root" ]] || exit 1

cp "$authority_path" "$test_root/authority.good"
cp "$receipt_path" "$test_root/receipt.good"

# Root-side source proof rejects ignored and assume-unchanged modifications
# without consulting ordinary status or mutating the caller index.
printf 'ignored-source\n' >> "$source_root/.git/info/exclude"
printf 'ignored source input\n' > "$source_root/ignored-source-input"
expect_failure 'ignored bootstrap source-root input' run_authority --check
rm -- "$source_root/ignored-source-input"
git -C "$source_root" update-index --assume-unchanged scripts/ubuntu/receipt-authority.sh
source_flag_before="$(git -C "$source_root" ls-files -v -- scripts/ubuntu/receipt-authority.sh)"
printf '# source-root assume-unchanged tamper\n' >> "$source_root/scripts/ubuntu/receipt-authority.sh"
expect_failure 'assume-unchanged bootstrap source-root script' run_authority --check
source_flag_after="$(git -C "$source_root" ls-files -v -- scripts/ubuntu/receipt-authority.sh)"
[[ "$source_flag_after" == "$source_flag_before" ]] || {
  echo 'Bootstrap source-root assume-unchanged flag was mutated.' >&2
  exit 1
}
git -C "$source_root" update-index --no-assume-unchanged scripts/ubuntu/receipt-authority.sh
git -C "$source_root" checkout -- scripts/ubuntu/receipt-authority.sh
chmod 0755 "$source_root/scripts/ubuntu/receipt-authority.sh"

# A repository-local filter and a forged Git environment must be rejected
# before any clean/smudge command can execute.
source_filter_marker="$test_root/source-filter-marker"
git -C "$source_root" config filter.attacker.clean "printf SOURCE-FILTER-RAN > '$source_filter_marker'"
printf '*.txt filter=attacker\n' > "$source_root/.gitattributes"
expect_failure 'source-root repository filter' run_authority --check
[[ ! -e "$source_filter_marker" ]] || { echo 'Source-root filter executed.' >&2; exit 1; }
git -C "$source_root" config --unset-all filter.attacker.clean
rm -- "$source_root/.gitattributes"
if (export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.filemode GIT_CONFIG_VALUE_0=false; run_authority --check >/dev/null 2>&1); then
  echo 'Receipt authority accepted GIT_CONFIG_COUNT override.' >&2
  exit 1
fi
if (export GIT_COMMON_DIR="$test_root/external-common"; run_authority --check >/dev/null 2>&1); then
  echo 'Receipt authority accepted GIT_COMMON_DIR override.' >&2
  exit 1
fi

# The receipt is built from the same stable RTK snapshot after the live
# checkout is changed at the validation-to-receipt seam.
receipt_race_ready="$test_root/receipt-race-ready"
receipt_race_continue="$test_root/receipt-race-continue"
(
  export HERDR_RECEIPT_TEST_PAUSE_PHASE=after-rtk-snapshot
  export HERDR_RECEIPT_TEST_READY_FILE="$receipt_race_ready"
  export HERDR_RECEIPT_TEST_CONTINUE_FILE="$receipt_race_continue"
  run_authority --install
) > "$test_root/receipt-race-output" 2>&1 &
receipt_race_pid=$!
while [[ ! -e "$receipt_race_ready" ]]; do sleep 0.01; done
printf 'receipt validation race\n' > "$rtk_source_root/README"
: > "$receipt_race_continue"
wait "$receipt_race_pid"
[[ "$(jq -r '.clean' "$receipt_path")" == true ]] || exit 1
[[ "$(jq -r '.rtk_source.checkout_path' "$receipt_path")" != "$rtk_source_root" ]] || {
  echo 'Receipt retained the mutable RTK checkout path.' >&2
  exit 1
}
printf 'locked RTK source\n' > "$rtk_source_root/README"
chmod 0644 "$rtk_source_root/README"

# The race run intentionally produced a new content-bound receipt pair.  Make
# that pair the baseline for the remaining reconciliation probes.
run_authority --check
cp "$authority_path" "$test_root/authority.good"
cp "$receipt_path" "$test_root/receipt.good"

jq '.receipt_sha256 = ("0" * 64)' "$authority_path" > "$test_root/authority.tampered"
mv -- "$test_root/authority.tampered" "$authority_path"
expect_failure 'tampered authority hash' run_authority --check
cp "$test_root/authority.good" "$authority_path"
chmod 0644 "$authority_path"

cp "$fixture_home/.cargo/bin/rtk" "$test_root/rtk.good"
printf 'tampered\n' >> "$fixture_home/.cargo/bin/rtk"
expect_failure 'tampered RTK executable' run_authority --check
cp "$test_root/rtk.good" "$fixture_home/.cargo/bin/rtk"

printf 'tampered\n' >> "$rtk_source_root/README"
expect_failure 'dirty RTK source checkout' run_authority --check
git -C "$rtk_source_root" checkout -- README
chmod 0644 "$rtk_source_root/README"
printf 'staged tamper\n' >> "$rtk_source_root/README"
git -C "$rtk_source_root" add README
expect_failure 'staged RTK source checkout' run_authority --check
git -C "$rtk_source_root" reset -q HEAD -- README
git -C "$rtk_source_root" checkout -- README
chmod 0644 "$rtk_source_root/README"
printf 'untracked tamper\n' > "$rtk_source_root/untracked"
expect_failure 'untracked RTK source checkout' run_authority --check
rm -- "$rtk_source_root/untracked"

printf 'ignored-input\n' >> "$rtk_source_root/.git/info/exclude"
printf 'ignored RTK build input\n' > "$rtk_source_root/ignored-input"
[[ -z "$(git -C "$rtk_source_root" status --porcelain --untracked-files=all)" ]] || {
  echo 'Ignored RTK fixture is not hidden from ordinary status.' >&2
  exit 1
}
expect_failure 'ignored untracked RTK source checkout' run_authority --check
rm -- "$rtk_source_root/ignored-input"

git -C "$rtk_source_root" update-index --assume-unchanged README
assume_flag_before="$(git -C "$rtk_source_root" ls-files -v -- README)"
printf 'assume-unchanged tamper\n' > "$rtk_source_root/README"
expect_failure 'assume-unchanged RTK source checkout' run_authority --check
assume_flag_after="$(git -C "$rtk_source_root" ls-files -v -- README)"
[[ "$assume_flag_after" == "$assume_flag_before" ]] || {
  echo 'RTK assume-unchanged index flag was mutated.' >&2
  exit 1
}
git -C "$rtk_source_root" update-index --no-assume-unchanged README
git -C "$rtk_source_root" checkout -- README
chmod 0644 "$rtk_source_root/README"

git -C "$rtk_source_root" update-index --skip-worktree README
skip_flag_before="$(git -C "$rtk_source_root" ls-files -v -- README)"
printf 'skip-worktree tamper\n' > "$rtk_source_root/README"
expect_failure 'skip-worktree RTK source checkout' run_authority --check
skip_flag_after="$(git -C "$rtk_source_root" ls-files -v -- README)"
[[ "$skip_flag_after" == "$skip_flag_before" ]] || {
  echo 'RTK skip-worktree index flag was mutated.' >&2
  exit 1
}
git -C "$rtk_source_root" update-index --no-skip-worktree README
git -C "$rtk_source_root" checkout -- README
chmod 0644 "$rtk_source_root/README"
run_authority --check
[[ "$(jq -r '.clean' "$receipt_path")" == true ]] || exit 1

git -C "$rtk_source_root" remote set-url origin https://example.invalid/rtk.git
expect_failure 'RTK source URL mismatch' run_authority --check
git -C "$rtk_source_root" remote set-url origin "$RTK_REPO_URL"

jq '.python313.sha256 = ("0" * 64)' "$receipt_path" > "$test_root/receipt.tampered"
mv -- "$test_root/receipt.tampered" "$receipt_path"
expect_failure 'tampered Python receipt' run_authority --check
cp "$test_root/receipt.good" "$receipt_path"

printf 'tampered\n' >> "$fixture_home/.local/pyvenv.cfg"
expect_failure 'tampered pyvenv.cfg' run_authority --check
cat > "$fixture_home/.local/pyvenv.cfg" <<EOF
home = $runtime_root
include-system-site-packages = false
version = $PYTHON_VERSION
EOF

printf 'tampered\n' >> "$stdlib_root/fixture.py"
expect_failure 'tampered Python runtime' run_authority --check
printf 'stdlib fixture\n' > "$stdlib_root/fixture.py"

chmod 0666 "$receipt_path"
expect_failure 'writable receipt body' run_authority --check
chmod 0644 "$receipt_path"

cp "$fixture_home/.cargo/bin/rtk" "$fixture_root/bin/rtk"
expect_failure 'duplicate RTK executable' run_authority --check
rm -- "$fixture_root/bin/rtk"

mv -- "$authority_path" "$test_root/authority.real"
ln -s "$test_root/authority.real" "$authority_path"
expect_failure 'symlinked authority' run_authority --check
rm -- "$authority_path"
mv -- "$test_root/authority.real" "$authority_path"

printf '# source-root mismatch\n' >> "$source_root/scripts/ubuntu/receipt-authority.sh"
git -C "$source_root" add scripts/ubuntu/receipt-authority.sh
git -C "$source_root" commit -qm 'fixture source script mismatch'
expect_failure 'source-root script mismatch' run_authority --check

echo 'receipt authority install, reconciliation, provenance and fail-closed tamper tests passed.'
