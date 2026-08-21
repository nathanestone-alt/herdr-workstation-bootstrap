#!/usr/bin/env bash
set -euo pipefail
umask 022

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
canonical_origin='https://github.com/nathanestone-alt/herdr-workstation-bootstrap.git'

fail_test() { echo "trusted launcher test: $*" >&2; exit 1; }
expect_failure() {
  local label="$1"
  shift
  if "$@" >"$test_root/expect-failure.out" 2>&1; then
    cat "$test_root/expect-failure.out" >&2
    fail_test "$label unexpectedly passed"
  fi
}

make_fixture() {
  local name="$1" pause_kind="${2:-none}"
  fixture_root="$test_root/$name/fixture"
  source_root="$test_root/$name/source"
  fixture_home="$fixture_root/home"
  mkdir -p "$fixture_home" "$source_root/scripts/ubuntu"
  cp -- "$repo_root/scripts/ubuntu/trusted-launcher.sh" "$source_root/scripts/ubuntu/trusted-launcher.sh"
  cat > "$source_root/scripts/ubuntu/bootstrap.sh" <<'EOF'
#!/usr/bin/bash
set -euo pipefail
[[ "${HERDR_BOOTSTRAP_TRUSTED_LAUNCHER:-}" == 1 ]]
[[ "${HERDR_BOOTSTRAP_VERIFIED_ENTRYPOINT:-}" == 1 ]]
: > "$HOME/clean-entrypoint-reached"
EOF
  chmod 0755 "$source_root/scripts/ubuntu/trusted-launcher.sh" "$source_root/scripts/ubuntu/bootstrap.sh"
  git -C "$source_root" init -q
  git -C "$source_root" config user.email fixture@example.invalid
  git -C "$source_root" config user.name fixture
  git -C "$source_root" remote add origin "$canonical_origin"
  git -C "$source_root" add .
  git -C "$source_root" commit -qm 'sealed launcher fixture'
  pinned_commit="$(git -C "$source_root" rev-parse --verify HEAD^{commit})"
  transport="$fixture_root/transport.git"
  mkdir -p "$fixture_root"
  git clone -q --bare "$source_root" "$transport"
  chmod 0700 "$transport"
  install_args=(--source-root "$source_root" --origin "$canonical_origin" --commit "$pinned_commit" --fixture-root "$fixture_root" --fixture-transport "$transport" --fixture-home "$fixture_home")
  if [[ "$pause_kind" == policy ]]; then
    policy_ready="$fixture_root/policy.ready"; policy_continue="$fixture_root/policy.continue"
    install_args+=(--fixture-policy-ready "$policy_ready" --fixture-policy-continue "$policy_continue")
  elif [[ "$pause_kind" == entry ]]; then
    entry_ready="$fixture_root/entry.ready"; entry_continue="$fixture_root/entry.continue"
    install_args+=(--fixture-entry-ready "$entry_ready" --fixture-entry-continue "$entry_continue")
  fi
  /usr/bin/bash "$repo_root/scripts/ubuntu/install-trusted-launcher.sh" "${install_args[@]}" >"$test_root/$name/install.out"
launcher="$fixture_root/usr/local/libexec/herdr-workstation-bootstrap"
policy="$fixture_root/etc/herdr-workstation/bootstrap-policy.conf"
policy_dir="$fixture_root/etc/herdr-workstation"
libexec_dir="$fixture_root/usr/local/libexec"
stage_root="$fixture_root/var/lib/herdr-workstation/bootstrap/staging"
}

run_launcher() {
  local cwd="${1:-$test_root}"
  (cd "$cwd" && PATH="$test_root/hostile-bin:${PATH:-/usr/bin:/bin}" "$launcher")
}

make_fixture clean
[[ -f "$launcher" && ! -L "$launcher" && -x "$launcher" ]] || fail_test 'launcher was not published as an executable regular file'
[[ "$(stat -c '%u:%g:%a' "$launcher")" == "$(id -u):$(id -g):755" ]] || fail_test 'fixture launcher owner/mode is wrong'
[[ "$(stat -c '%u:%g:%a' "$policy")" == "$(id -u):$(id -g):644" ]] || fail_test 'fixture policy owner/mode is wrong'
[[ "$(stat -c '%u:%g:%a' "$stage_root")" == "$(id -u):$(id -g):755" ]] || fail_test 'fixture staging owner/mode is wrong'
expect_failure 'second one-time provisioning' /usr/bin/bash "$repo_root/scripts/ubuntu/install-trusted-launcher.sh" "${install_args[@]}"

mkdir -p "$test_root/hostile-bin"
for command_name in env bash git realpath stat sha256sum gawk mktemp rm find sleep getent id chmod setpriv; do
  cat > "$test_root/hostile-bin/$command_name" <<EOF
#!/usr/bin/bash
: > '$test_root/hostile-$command_name-reached'
exit 99
EOF
  chmod 0755 "$test_root/hostile-bin/$command_name"
done
run_launcher "$test_root"
[[ -f "$fixture_home/clean-entrypoint-reached" ]] || fail_test 'verified committed entrypoint did not execute'
for command_name in env bash git realpath stat sha256sum gawk mktemp rm find sleep getent id chmod setpriv; do
  [[ ! -e "$test_root/hostile-$command_name-reached" ]] || fail_test "launcher resolved hostile PATH command: $command_name"
done

forged_root="$test_root/forged"; forged_marker="$test_root/forged-entrypoint-reached"
mkdir -p "$forged_root/scripts/ubuntu"
cp -- "$source_root/scripts/ubuntu/trusted-launcher.sh" "$forged_root/scripts/ubuntu/trusted-launcher.sh"
cat > "$forged_root/scripts/ubuntu/bootstrap.sh" <<EOF
#!/usr/bin/bash
: > '$forged_marker'
EOF
chmod 0755 "$forged_root/scripts/ubuntu"/*.sh
git -C "$forged_root" init -q
git -C "$forged_root" config user.email forged@example.invalid
git -C "$forged_root" config user.name forged
git -C "$forged_root" remote add origin "$canonical_origin"
git -C "$forged_root" add .; git -C "$forged_root" commit -qm forged
run_launcher "$forged_root"
[[ ! -e "$forged_marker" ]] || fail_test 'forged coherent repository entrypoint executed'

dirty_root="$test_root/dirty"; dirty_marker="$test_root/dirty-entrypoint-reached"
cp -a -- "$forged_root" "$dirty_root"
cat >> "$dirty_root/scripts/ubuntu/bootstrap.sh" <<EOF
: > '$dirty_marker'
EOF
run_launcher "$dirty_root"
[[ ! -e "$dirty_marker" ]] || fail_test 'dirty repository code executed before trust'

forged_commit="$(git -C "$forged_root" rev-parse --verify HEAD^{commit})"
cp -- "$policy" "$test_root/policy.good"
printf 'herdr-bootstrap-policy-v1\norigin=%s\ncommit=%s\n' "$canonical_origin" "$forged_commit" > "$policy"
chmod 0644 "$policy"
expect_failure 'forged policy commit' run_launcher "$test_root"
mv -T -- "$test_root/policy.good" "$policy"
cp -- "$policy" "$test_root/policy.good"
printf 'herdr-bootstrap-policy-v1\nherdr-bootstrap-policy-v1\norigin=%s\ncommit=%s\n' "$canonical_origin" "$pinned_commit" > "$policy"
chmod 0644 "$policy"
expect_failure 'duplicate policy header' run_launcher "$test_root"
mv -T -- "$test_root/policy.good" "$policy"
chmod 0666 "$policy"; expect_failure 'group-writable policy' run_launcher "$test_root"; chmod 0644 "$policy"
chmod 0644 "$launcher"; expect_failure 'non-executable launcher' run_launcher "$test_root"; chmod 0755 "$launcher"
chmod 0775 "$policy_dir"; expect_failure 'unsafe policy parent mode' run_launcher "$test_root"; chmod 0755 "$policy_dir"
chmod 0775 "$libexec_dir"; expect_failure 'unsafe launcher parent mode' run_launcher "$test_root"; chmod 0755 "$libexec_dir"
mv -T -- "$policy" "$test_root/policy.real"; ln -s policy.real "$policy"
expect_failure 'symlinked policy' run_launcher "$test_root"
rm -- "$policy"; mv -T -- "$test_root/policy.real" "$policy"
chmod 0775 "$stage_root"; expect_failure 'unsafe staging root mode' run_launcher "$test_root"; chmod 0755 "$stage_root"
mv -T -- "$launcher" "$test_root/launcher.real"; ln -s launcher.real "$launcher"
expect_failure 'symlinked launcher' run_launcher "$test_root"
rm -- "$launcher"; mv -T -- "$test_root/launcher.real" "$launcher"

make_fixture policy-race policy
policy_race_output="$test_root/policy-race.out"
(run_launcher "$test_root" >"$policy_race_output" 2>&1) & policy_race_pid=$!
for attempt in $(seq 1 1000); do
  [[ -e "$policy_ready" ]] && break
  sleep 0.01
done
[[ -e "$policy_ready" ]] || { cat "$policy_race_output" >&2; kill "$policy_race_pid" 2>/dev/null || true; fail_test 'policy race did not reach its proof pause'; }
mv -T -- "$policy" "$test_root/policy-race.real"
printf 'herdr-bootstrap-policy-v1\norigin=%s\ncommit=%s\n' "$canonical_origin" "$pinned_commit" > "$policy"
chmod 0644 "$policy"; : > "$policy_continue"
set +e; wait "$policy_race_pid"; policy_race_status=$?; set -e
(( policy_race_status != 0 )) || fail_test 'policy replacement race was accepted'
[[ ! -e "$fixture_home/clean-entrypoint-reached" ]] || fail_test 'entrypoint ran after policy replacement'

make_fixture entry-race entry
entry_race_output="$test_root/entry-race.out"
(run_launcher "$test_root" >"$entry_race_output" 2>&1) & entry_race_pid=$!
for attempt in $(seq 1 2000); do
  [[ -e "$entry_ready" ]] && break
  sleep 0.01
done
[[ -e "$entry_ready" ]] || { cat "$entry_race_output" >&2; kill "$entry_race_pid" 2>/dev/null || true; fail_test 'entrypoint race did not reach its proof pause'; }
staged_entry=''
for attempt in $(seq 1 2000); do
  for candidate in "$stage_root"/.incoming.*; do
    [[ -d "$candidate/scripts/ubuntu" ]] || continue
    staged_entry="$candidate/scripts/ubuntu/bootstrap.sh"; break
  done
  [[ -n "$staged_entry" ]] && break
  sleep 0.01
done
[[ -n "$staged_entry" ]] || { kill "$entry_race_pid" 2>/dev/null || true; fail_test 'materialized staging directory was not observable'; }
replacement="$staged_entry.replacement"
cat > "$replacement" <<EOF
#!/usr/bin/bash
: > '$test_root/replacement-entrypoint-reached'
EOF
chmod 0755 "$replacement"; mv -T -- "$replacement" "$staged_entry"; : > "$entry_continue"
set +e; wait "$entry_race_pid"; entry_race_status=$?; set -e
(( entry_race_status != 0 )) || fail_test 'entrypoint replacement race was accepted'
[[ ! -e "$test_root/replacement-entrypoint-reached" ]] || fail_test 'replacement entrypoint executed'

echo 'trusted launcher policy, forged-repository, ownership/mode, and replacement tests passed.'
