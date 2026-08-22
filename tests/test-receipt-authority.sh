#!/usr/bin/env bash
set -euo pipefail
umask 022

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

# The authority deliberately validates the same source and release-lock
# relationships as production. Build a small clean source checkout and a
# canonical release-shaped RTK executable for fixture mode.
source "$repo_root/config/ubuntu-toolchain.lock"
fixture_root="$test_root/fixture"
fixture_home="$fixture_root/home"
authority_path="$fixture_root/etc/stmodel/issue-961/receipt-authority.json"
receipt_path="$fixture_root/etc/stmodel/issue-961/receipt.json"
source_root="$test_root/source"
runtime_root="$fixture_home/.local/lib/herdr-workstation/python/$PYTHON_VERSION-$PYTHON_RELEASE-$PYTHON_PLATFORM"
stdlib_root="$runtime_root/lib/python3.13"
entrypoint_root="$test_root/entrypoint"

mkdir -p \
  "$fixture_root/bin" \
  "$fixture_home/.local/bin" \
  "$fixture_home/.local/lib/node-v$NODE_VERSION-linux-x64/bin" \
  "$fixture_home/.cargo/bin" \
  "$stdlib_root" \
  "$runtime_root/bin"

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
make_tool "$fixture_home/.cargo/bin/rtk" "rtk $RTK_VERSION"

cat > "$fixture_home/.local/bin/python3.13" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == '--version' ]]; then
  printf 'Python 3.13.15\n'
elif [[ "\${1:-}" == '-c' ]]; then
  printf '{"version":"3.13.15","version_info":[3,13,15,"final",0],"implementation":"CPython","executable":"%s","prefix":"%s/.local","base_prefix":"%s","stdlib":"%s/lib/python3.13"}\n' \
    "\$(readlink -f "\$0")" "$fixture_home" "$runtime_root" "$runtime_root"
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

mkdir -p "$source_root/config" "$source_root/scripts/ubuntu"
cp "$repo_root/scripts/ubuntu/receipt-authority.sh" "$source_root/scripts/ubuntu/receipt-authority.sh"
cp "$repo_root/scripts/ubuntu/source-attestation.sh" "$source_root/scripts/ubuntu/source-attestation.sh"
cp "$repo_root/scripts/ubuntu/launcher-capability.sh" "$source_root/scripts/ubuntu/launcher-capability.sh"
cp "$repo_root/scripts/ubuntu/trusted-launcher.sh" "$source_root/scripts/ubuntu/trusted-launcher.sh"
cp "$repo_root/config/receipt-authority-role-allowlist.txt" "$source_root/config/receipt-authority-role-allowlist.txt"
cp "$repo_root/config/payload-manifest.sha256" "$source_root/config/payload-manifest.sha256"
cp "$repo_root/config/ubuntu-toolchain.lock" "$source_root/config/ubuntu-toolchain.lock"
chmod 0644 \
  "$source_root/config/receipt-authority-role-allowlist.txt" \
  "$source_root/config/payload-manifest.sha256" \
  "$source_root/config/ubuntu-toolchain.lock"
chmod 0755 "$source_root/scripts/ubuntu/launcher-capability.sh" \
  "$source_root/scripts/ubuntu/receipt-authority.sh" \
  "$source_root/scripts/ubuntu/source-attestation.sh" \
  "$source_root/scripts/ubuntu/trusted-launcher.sh"
git -C "$source_root" init -q
git -C "$source_root" config user.email fixture@example.invalid
git -C "$source_root" config user.name fixture
git -C "$source_root" remote add origin https://github.com/nathanestone-alt/herdr-workstation-bootstrap.git
git -C "$source_root" add .
git -C "$source_root" commit -qm 'fixture bootstrap source'
source_commit="$(git -C "$source_root" rev-parse --verify HEAD^{commit})"
transport="$fixture_root/transport.git"
git clone -q --bare "$source_root" "$transport"
chmod 0700 "$transport"
/usr/bin/bash "$repo_root/scripts/ubuntu/install-trusted-launcher.sh" \
  --origin https://github.com/nathanestone-alt/herdr-workstation-bootstrap.git \
  --commit "$source_commit" \
  --fixture-root "$fixture_root" \
  --fixture-transport "$transport" \
  --fixture-home "$fixture_home" > "$test_root/launcher-install.out"
launcher="$fixture_root/usr/local/libexec/herdr-workstation-bootstrap"
entrypoint_script="$launcher"
repin_launcher_pause() {
  local phase="$1" ready="$2" continue_file="$3"
  /usr/bin/bash "$repo_root/scripts/ubuntu/install-trusted-launcher.sh" --re-pin \
    --origin https://github.com/nathanestone-alt/herdr-workstation-bootstrap.git \
    --commit "$source_commit" \
    --fixture-root "$fixture_root" \
    --fixture-transport "$transport" \
    --fixture-home "$fixture_home" \
    --fixture-receipt-pause-phase "$phase" \
    --fixture-receipt-pause-ready "$ready" \
    --fixture-receipt-pause-continue "$continue_file" > /dev/null
}

# Direct receipt help must bind the committed helper before sourcing it, and
# must not resolve any integrity or Git seam through a hostile PATH.
receipt_hostile_path="$test_root/receipt-hostile-path"
mkdir -p "$receipt_hostile_path"
receipt_bash_env_marker="$test_root/receipt-bash-env-reached"
receipt_bash_env="$test_root/receipt-bash-env"
printf ': > %q\n' "$receipt_bash_env_marker" > "$receipt_bash_env"
chmod 0755 "$receipt_bash_env"
for receipt_hostile_command in env git realpath dirname find mktemp chmod stat sha256sum gawk head cp rm; do
  cat > "$receipt_hostile_path/$receipt_hostile_command" <<EOF
#!/usr/bin/bash
: > '$test_root/receipt-path-$receipt_hostile_command-reached'
exit 99
EOF
  chmod 0755 "$receipt_hostile_path/$receipt_hostile_command"
done
if ! /usr/bin/env -i HOME="$fixture_home" PATH="$receipt_hostile_path:/usr/bin:/bin" \
  BASH_ENV= ENV= "$launcher" --entrypoint receipt-authority -- --help > "$test_root/receipt-help-output" 2>&1; then
  cat "$test_root/receipt-help-output" >&2
  exit 1
fi
for receipt_hostile_command in env git realpath dirname find mktemp chmod stat sha256sum gawk head cp rm; do
  [[ ! -e "$test_root/receipt-path-$receipt_hostile_command-reached" ]] || {
    echo "Receipt authority resolved hostile PATH command: $receipt_hostile_command" >&2
    exit 1
  }
done
[[ ! -e "$receipt_bash_env_marker" ]] || {
  echo 'Receipt authority direct launch honored caller BASH_ENV.' >&2
  exit 1
}

dirty_entrypoint_root="$test_root/dirty-entrypoint"
cp -a -- "$source_root" "$dirty_entrypoint_root"
dirty_receipt_marker="$test_root/dirty-receipt-top-level"
dirty_receipt_function_marker="$test_root/dirty-receipt-function"
dirty_receipt_entrypoint_marker="$test_root/dirty-receipt-entrypoint"
cat >> "$dirty_entrypoint_root/scripts/ubuntu/source-attestation.sh" <<EOF
: > '$dirty_receipt_marker'
attestation_create_git_snapshot() { : > '$dirty_receipt_function_marker'; return 0; }
EOF
cat >> "$dirty_entrypoint_root/scripts/ubuntu/receipt-authority.sh" <<EOF
: > '$dirty_receipt_entrypoint_marker'
EOF
if /usr/bin/env -i HOME="$fixture_home" PATH="$receipt_hostile_path:/usr/bin:/bin" \
  BASH_ENV="$test_root/receipt-bash-env" "$dirty_entrypoint_root/scripts/ubuntu/receipt-authority.sh" --help \
  > "$test_root/dirty-receipt-output" 2>&1; then
  echo 'Dirty live receipt helper was accepted.' >&2
  exit 1
fi
[[ ! -e "$dirty_receipt_marker" && ! -e "$dirty_receipt_function_marker" && \
   ! -e "$dirty_receipt_entrypoint_marker" ]] || {
  echo 'Dirty receipt helper code executed before attestation.' >&2
  exit 1
}

run_authority() {
  /usr/bin/env -i HOME="$fixture_home" PATH='/usr/sbin:/usr/bin:/sbin:/bin' LC_ALL=C TZ=UTC \
    BASH_ENV= ENV= "$launcher" --entrypoint receipt-authority -- "$@" \
    --source-root "$source_root" \
    --user-home "$fixture_home" \
    --authority-path "$authority_path" \
    --receipt-path "$receipt_path" \
    --fixture-root "$fixture_root"
}

run_authority_with_pause() {
  /usr/bin/env -i \
    HOME="$fixture_home" PATH='/usr/sbin:/usr/bin:/sbin:/bin' LC_ALL=C TZ=UTC \
    BASH_ENV= ENV= \
    HERDR_RECEIPT_TEST_PAUSE_PHASE="${HERDR_RECEIPT_TEST_PAUSE_PHASE:-}" \
    HERDR_RECEIPT_TEST_READY_FILE="${HERDR_RECEIPT_TEST_READY_FILE:-}" \
    HERDR_RECEIPT_TEST_CONTINUE_FILE="${HERDR_RECEIPT_TEST_CONTINUE_FILE:-}" \
    "$launcher" --entrypoint receipt-authority -- "$@" \
    --source-root "$source_root" \
    --user-home "$fixture_home" \
    --authority-path "$authority_path" \
    --receipt-path "$receipt_path" \
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
[[ "$(jq -r '.rtk_release.version' "$receipt_path")" == "$RTK_VERSION" ]] || exit 1
[[ "$(jq -r '.rtk_release.url' "$receipt_path")" == "$RTK_URL" ]] || exit 1
[[ "$(jq -r '.rtk_release.sha256' "$receipt_path")" == "$RTK_SHA256" ]] || exit 1
[[ "$(jq -r '.python313.venv.home' "$receipt_path")" == "$runtime_root" ]] || exit 1
[[ "$(jq -r '.python313.runtime.base_prefix' "$receipt_path")" == "$runtime_root" ]] || exit 1
[[ "$(jq -r '.python313.runtime.stdlib' "$receipt_path")" == "$stdlib_root" ]] || exit 1

# A root-side Python probe must not import a caller-controlled sitecustomize or
# user site. Demonstrate the hostile control first, then exercise the exact
# sanitized interpreter environment used by receipt_exec_python_unprivileged.
python_import_root="$test_root/python-import-root"
python_import_marker="$test_root/python-import-marker"
mkdir -p "$python_import_root"
cat > "$python_import_root/sitecustomize.py" <<EOF
from pathlib import Path
Path('$python_import_marker').write_text('imported')
EOF
/usr/bin/env -i HOME="$fixture_home" PATH='/usr/sbin:/usr/bin:/sbin:/bin' \
  PYTHONPATH="$python_import_root" /usr/bin/python3 -c 'pass'
[[ -f "$python_import_marker" ]] || { echo 'Python import control did not establish the hostile sitecustomize fixture.' >&2; exit 1; }
rm -f -- "$python_import_marker"
/usr/bin/env -i HOME=/nonexistent PATH='/usr/sbin:/usr/bin:/sbin:/bin' \
  PYTHONNOUSERSITE=1 PYTHONSAFEPATH=1 PYTHONPATH= PYTHONHOME= PYTHONSTARTUP= PYTHONINSPECT=0 \
  /usr/bin/python3 -c 'pass'
[[ ! -e "$python_import_marker" ]] || { echo 'Sanitized Python probe imported caller-controlled sitecustomize.' >&2; exit 1; }
grep -Fq 'PYTHONSAFEPATH=1' "$repo_root/scripts/ubuntu/receipt-authority.sh" || {
  echo 'Receipt Python execution path does not enforce PYTHONSAFEPATH.' >&2
  exit 1
}

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
if ! (export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.filemode GIT_CONFIG_VALUE_0=false; run_authority --check >/dev/null 2>&1); then
  echo 'Receipt authority did not sanitize GIT_CONFIG_COUNT override.' >&2
  exit 1
fi
if ! (export GIT_COMMON_DIR="$test_root/external-common"; run_authority --check >/dev/null 2>&1); then
  echo 'Receipt authority did not sanitize GIT_COMMON_DIR override.' >&2
  exit 1
fi

# A same-user replacement of a staged role executable must fail closed without
# executing the replacement. The pause survives the trusted entrypoint
# re-exec because it is explicitly carried only through this test adapter.
role_stage_race_ready="$fixture_root/role-stage-race-ready"
role_stage_race_continue="$fixture_root/role-stage-race-continue"
role_stage_race_marker="$test_root/role-stage-race-hostile"
role_stage_race_hostile="$test_root/role-stage-race-hostile.sh"
repin_launcher_pause after-rtk-staging "$role_stage_race_ready" "$role_stage_race_continue"
cat > "$role_stage_race_hostile" <<EOF
#!/usr/bin/bash
: > '$role_stage_race_marker'
printf 'rtk %s\n' '$RTK_VERSION'
EOF
chmod 0755 "$role_stage_race_hostile"
(
  export HERDR_RECEIPT_TEST_PAUSE_PHASE=after-rtk-staging
  export HERDR_RECEIPT_TEST_READY_FILE="$role_stage_race_ready"
  export HERDR_RECEIPT_TEST_CONTINUE_FILE="$role_stage_race_continue"
  run_authority_with_pause --install
) > "$test_root/role-stage-race-output" 2>&1 &
role_stage_race_pid=$!
while [[ ! -e "$role_stage_race_ready" ]]; do sleep 0.01; done
role_stage_race_replaced=0
for role_stage_dir in /tmp/herdr-receipt-exec.*; do
  [[ -f "$role_stage_dir/rtk" ]] || continue
  mv -- "$role_stage_dir/rtk" "$role_stage_dir/rtk-original"
  cp -- "$role_stage_race_hostile" "$role_stage_dir/rtk"
  role_stage_race_replaced=1
done
(( role_stage_race_replaced == 1 )) || { echo 'Receipt staged-role race did not find its stage.' >&2; exit 1; }
: > "$role_stage_race_continue"
set +e
wait "$role_stage_race_pid"
role_stage_race_status=$?
set -e
(( role_stage_race_status == 0 )) || { echo 'Receipt stable staged-role replacement did not complete safely.' >&2; exit 1; }
[[ ! -e "$role_stage_race_marker" ]] || { echo 'Receipt staged-role replacement executed an attacker payload.' >&2; exit 1; }

# A manifest/tree supplied without the root-bound payload hash and commit is
# self-authenticating and must not be allowed to source authority inputs.
while IFS= read -r receipt_test_git_var; do
  unset "$receipt_test_git_var"
done < <(compgen -e | /usr/bin/grep '^GIT_')
source "$repo_root/scripts/ubuntu/source-attestation.sh"
attestation_create_git_snapshot "$source_root" '' ''
unbound_source_snapshot="$attestation_snapshot_dir"
unbound_source_manifest="$attestation_snapshot_manifest"
duplicate_source_manifest="$test_root/duplicate-source-attestation"
{
  printf 'herdr-source-snapshot-v2\n'
  cat "$unbound_source_manifest"
} > "$duplicate_source_manifest"
if attestation_verify_snapshot "$unbound_source_snapshot" "$duplicate_source_manifest"; then
  echo 'Duplicate source-manifest header was accepted.' >&2
  exit 1
fi
expect_failure 'unsigned source manifest' /usr/bin/env -i \
  HOME="$fixture_home" PATH='/usr/sbin:/usr/bin:/sbin:/bin' LC_ALL=C TZ=UTC BASH_ENV= ENV= \
  "$launcher" --entrypoint receipt-authority -- --check \
  --source-root "$unbound_source_snapshot" --source-manifest "$unbound_source_manifest" \
  --user-home "$fixture_home" --authority-path "$authority_path" --receipt-path "$receipt_path" \
  --fixture-root "$fixture_root"
payload_probe="$test_root/payload-probe"
mkdir -p "$payload_probe/source"
cp -a -- "$unbound_source_snapshot/." "$payload_probe/source/"
chmod -R u+w "$payload_probe"
payload_probe_manifest="$payload_probe/.payload-manifest"
attestation_build_payload_manifest "$payload_probe" "$payload_probe_manifest"
payload_probe_hash="$(attestation_hash_file "$payload_probe_manifest")"
expect_payload_failure() {
  local label="$1"
  shift
  expect_failure "$label" /usr/bin/env -i \
    HOME="$fixture_home" PATH='/usr/sbin:/usr/bin:/sbin:/bin' LC_ALL=C TZ=UTC \
    BASH_ENV= ENV= "$launcher" --entrypoint receipt-authority -- "$@" \
    --source-root "$payload_probe/source" \
    --source-manifest "$payload_probe/source/.source-attestation" \
    --payload-root "$payload_probe" \
    --payload-manifest "$payload_probe_manifest" \
    --user-home "$fixture_home" --authority-path "$authority_path" --receipt-path "$receipt_path" \
    --fixture-root "$fixture_root"
}
expect_payload_failure 'unsigned payload source commit'
expect_payload_failure 'unsigned payload manifest hash' --source-commit "$attestation_snapshot_commit"

# This payload is internally coherent: it is a real second Git commit, its
# source snapshot is freshly attested, and its payload manifest hash is bound.
# It must still fail because the installed policy approves source_commit, not
# merely any self-consistent payload commit.
alternate_source_checkout="$test_root/alternate-source"
git clone -q "$source_root" "$alternate_source_checkout"
git -C "$alternate_source_checkout" config user.email fixture@example.invalid
git -C "$alternate_source_checkout" config user.name fixture
printf '%s\n' 'alternate coherent payload commit' > "$alternate_source_checkout/alternate.txt"
git -C "$alternate_source_checkout" add alternate.txt
git -C "$alternate_source_checkout" commit -qm 'alternate coherent payload commit'
attestation_create_git_snapshot "$alternate_source_checkout" '' ''
alternate_payload_probe="$test_root/alternate-payload-probe"
mkdir -p "$alternate_payload_probe/source"
cp -a -- "$attestation_snapshot_dir/." "$alternate_payload_probe/source/"
chmod -R u+w "$alternate_payload_probe"
alternate_payload_manifest="$alternate_payload_probe/.payload-manifest"
attestation_build_payload_manifest "$alternate_payload_probe" "$alternate_payload_manifest"
alternate_payload_hash="$(attestation_hash_file "$alternate_payload_manifest")"
alternate_source_commit="$attestation_snapshot_commit"
[[ "$alternate_source_commit" != "$source_commit" ]] || {
  echo 'Alternate coherent payload did not receive a different commit.' >&2
  exit 1
}
expect_failure 'coherent payload with non-policy source commit' /usr/bin/env -i \
  HOME="$fixture_home" PATH='/usr/sbin:/usr/bin:/sbin:/bin' LC_ALL=C TZ=UTC \
  BASH_ENV= ENV= "$launcher" --entrypoint receipt-authority -- --check \
  --source-root "$alternate_payload_probe/source" \
  --source-manifest "$alternate_payload_probe/source/.source-attestation" \
  --payload-root "$alternate_payload_probe" \
  --payload-manifest "$alternate_payload_manifest" \
  --payload-manifest-sha256 "$alternate_payload_hash" \
  --source-commit "$alternate_source_commit" \
  --user-home "$fixture_home" --authority-path "$authority_path" --receipt-path "$receipt_path" \
  --fixture-root "$fixture_root"
printf 'payload tamper\n' >> "$payload_probe/source/README"
expect_failure 'tampered payload tree' /usr/bin/env -i \
  HOME="$fixture_home" PATH='/usr/sbin:/usr/bin:/sbin:/bin' LC_ALL=C TZ=UTC \
  BASH_ENV= ENV= "$launcher" --entrypoint receipt-authority -- --check \
  --source-root "$payload_probe/source" --source-manifest "$payload_probe/source/.source-attestation" \
  --payload-root "$payload_probe" --payload-manifest "$payload_probe_manifest" \
  --payload-manifest-sha256 "$payload_probe_hash" --source-commit "$attestation_snapshot_commit" \
  --user-home "$fixture_home" --authority-path "$authority_path" --receipt-path "$receipt_path" \
  --fixture-root "$fixture_root"
attestation_cleanup_temporary_paths

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
