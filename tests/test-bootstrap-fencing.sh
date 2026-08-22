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

# The fixture transport is the only source the installed launcher may fetch.
# The mutable checkout below is deliberately outside that transport.
cp -a -- "$repo_root/." "$source_fixture/"
/usr/bin/rm -rf -- "$source_fixture/.git" "$source_fixture/.agents" "$source_fixture/.codex"
chmod 0755 "$source_fixture"
/usr/bin/git -C "$source_fixture" init -q
/usr/bin/git -C "$source_fixture" config user.email fixture@example.invalid
/usr/bin/git -C "$source_fixture" config user.name fixture
/usr/bin/git -C "$source_fixture" remote add origin "$canonical_origin"
/usr/bin/git -C "$source_fixture" add -f .
/usr/bin/git -C "$source_fixture" commit -qm 'clean bootstrap launcher fixture'
fixture_commit="$(/usr/bin/git -C "$source_fixture" rev-parse --verify HEAD^{commit})"
/usr/bin/git clone -q --bare "$source_fixture" "$transport"
chmod 0700 "$transport"

install_args=(--origin "$canonical_origin" --commit "$fixture_commit"
  --fixture-root "$fixture_root" --fixture-transport "$transport" --fixture-home "$fixture_home")
/usr/bin/bash "$repo_root/scripts/ubuntu/install-trusted-launcher.sh" "${install_args[@]}" \
  > "$test_root/launcher-install.out"
launcher="$fixture_root/usr/local/libexec/herdr-workstation-bootstrap"
policy="$fixture_root/etc/herdr-workstation/bootstrap-policy.conf"
stage_root="$fixture_root/var/lib/herdr-workstation/bootstrap/staging"
[[ -x "$launcher" && ! -L "$launcher" ]] || { echo 'Fixture launcher was not published.' >&2; exit 1; }
[[ "$(stat -c '%u:%g:%a' "$policy")" == "$(id -u):$(id -g):600" ]] ||
  { echo 'Fixture policy owner/mode is unsafe.' >&2; exit 1; }
[[ "$(stat -c '%u:%g:%a' "$stage_root")" == "$(id -u):$(id -g):755" ]] ||
  { echo 'Fixture staging owner/mode is unsafe.' >&2; exit 1; }

hostile_bin="$test_root/hostile-bin"
mkdir -p "$hostile_bin"
for hostile_command in env bash git realpath stat sha256sum gawk mktemp rm find sleep getent id chmod; do
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

run_fixture_entrypoint() {
  local entrypoint="$1"
  shift
  /usr/bin/env -i HOME="$fixture_home" PATH="$hostile_bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    BASH_ENV="$bash_env" ENV= LC_ALL=C TZ=UTC \
    "$launcher" --entrypoint "$entrypoint" -- "$@"
}

bootstrap_output="$test_root/bootstrap-output"
if ! run_fixture_entrypoint bootstrap --phase validate-lock > "$bootstrap_output" 2>&1; then
  cat "$bootstrap_output" >&2
  exit 1
fi
grep -Fq 'Ubuntu toolchain lock validation passed.' "$bootstrap_output" ||
  { cat "$bootstrap_output" >&2; echo 'Launcher did not reach bootstrap end to end.' >&2; exit 1; }
if ! run_fixture_entrypoint receipt-authority --help > "$test_root/receipt-help-output" 2>&1; then
  cat "$test_root/receipt-help-output" >&2
  exit 1
fi
grep -Fq 'Usage:' "$test_root/receipt-help-output" ||
  { cat "$test_root/receipt-help-output" >&2; echo 'Launcher did not reach receipt authority end to end.' >&2; exit 1; }

# A checkout can differ after provisioning. The launcher must still materialize
# the exact approved origin commit, so attacker code inserted before line 10
# of each local entrypoint is never executed.
cp -a -- "$source_fixture" "$dirty_source"
for entrypoint in bootstrap receipt-authority verify; do
  dirty_marker="$test_root/dirty-$entrypoint-before-line-10"
  entry_path="$dirty_source/scripts/ubuntu/$entrypoint.sh"
  {
    /usr/bin/head -n 8 "$entry_path"
    printf ': > %q\n' "$dirty_marker"
    /usr/bin/tail -n +9 "$entry_path"
  } > "$entry_path.tmp"
  /usr/bin/mv -T -- "$entry_path.tmp" "$entry_path"
  chmod 0755 "$entry_path"
done
dirty_bootstrap_hash="$(/usr/bin/git -C "$dirty_source" hash-object -- scripts/ubuntu/bootstrap.sh)"
clean_bootstrap_hash="$(/usr/bin/git -C "$source_fixture" hash-object -- scripts/ubuntu/bootstrap.sh)"
[[ "$dirty_bootstrap_hash" != "$clean_bootstrap_hash" ]] ||
  { echo 'Dirty local bootstrap fixture was not changed.' >&2; exit 1; }
run_fixture_entrypoint bootstrap --phase validate-lock > "$test_root/dirty-bootstrap-output" 2>&1
run_fixture_entrypoint receipt-authority --help > "$test_root/dirty-receipt-output" 2>&1
set +e
run_fixture_entrypoint verify > "$test_root/dirty-verify-output" 2>&1
dirty_verify_status=$?
set -e
# The clean fixture reaches verify, then reports its intentionally missing
# managed tools; the capability/repository boundary must still complete first.
(( dirty_verify_status == 1 )) || {
  cat "$test_root/dirty-verify-output" >&2
  echo "Clean verified verify entrypoint returned unexpected status $dirty_verify_status." >&2
  exit 1
}
for entrypoint in bootstrap receipt-authority verify; do
  [[ ! -e "$test_root/dirty-$entrypoint-before-line-10" ]] || {
    echo "Dirty $entrypoint code before line 10 executed." >&2
    exit 1
  }
done

# Direct execution has no descriptor capability. Old environment markers,
# caller-selected roots, and a BASH_ENV file cannot authorize any entrypoint.
for entrypoint in bootstrap receipt-authority verify; do
  direct_output="$test_root/direct-$entrypoint-output"
  direct_args=()
  [[ "$entrypoint" == bootstrap ]] && direct_args=(--phase validate-lock)
  set +e
  /usr/bin/env -i HOME="$fixture_home" PATH=/usr/sbin:/usr/bin:/sbin:/bin BASH_ENV= ENV= \
    HERDR_BOOTSTRAP_TRUSTED_LAUNCHER=1 HERDR_BOOTSTRAP_VERIFIED_ENTRYPOINT=1 \
    HERDR_BOOTSTRAP_REPO_ROOT="$dirty_source" HERDR_BOOTSTRAP_GIT_OWNER_UID="$(id -u)" \
    HERDR_BOOTSTRAP_GIT_OWNER_GID="$(id -g)" HERDR_RECEIPT_TRUSTED_LAUNCHER=1 \
    HERDR_VERIFY_TRUSTED_LAUNCHER=1 /usr/bin/bash \
    "$source_fixture/scripts/ubuntu/$entrypoint.sh" "${direct_args[@]}" > "$direct_output" 2>&1
  direct_status=$?
  set -e
  (( direct_status != 0 )) || {
    cat "$direct_output" >&2
    echo "Direct $entrypoint invocation was accepted." >&2
    exit 1
  }
  grep -Eqi 'capability|launcher' "$direct_output" ||
    { cat "$direct_output" >&2; echo "Direct $entrypoint lacked a capability rejection." >&2; exit 1; }
done

# Preserve the already-resolved fencing invariants in this end-to-end guard.
! /usr/bin/grep -Fq '.cargo/env' "$repo_root/scripts/ubuntu/bootstrap.sh" ||
  { echo 'Bootstrap still sources .cargo/env.' >&2; exit 1; }
/usr/bin/grep -Fq 'rtk_release_install_archive' "$repo_root/scripts/ubuntu/bootstrap.sh"
/usr/bin/grep -Fq 'RTK_SHA256' "$repo_root/scripts/ubuntu/bootstrap.sh"
! /usr/bin/grep -Fq 'RTK_REPO_URL' "$repo_root/scripts/ubuntu/bootstrap.sh" || {
  echo 'Bootstrap still contains the retired RTK repository lock.' >&2
  exit 1
}
/usr/bin/grep -Fq 'proc/${BASHPID}/fd' "$repo_root/scripts/ubuntu/bootstrap.sh"
/usr/bin/grep -Fq 'attestation_cleanup_temporary_paths' "$repo_root/scripts/ubuntu/source-attestation.sh"

for hostile_command in env bash git realpath stat sha256sum gawk mktemp rm find sleep getent id chmod; do
  [[ ! -e "$test_root/path-$hostile_command-reached" ]] || {
    echo "Launcher or bootstrap resolved a hostile PATH command: $hostile_command" >&2
    exit 1
  }
done
[[ ! -e "$test_root/bash-env-reached" ]] || {
  echo 'BASH_ENV executed in the launcher fixture.' >&2
  exit 1
}

echo 'bootstrap launcher fencing, dirty-checkout, forged-marker, and pre-line-10 tests passed.'
