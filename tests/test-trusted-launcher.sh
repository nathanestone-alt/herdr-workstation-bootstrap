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
  local name="$1" pause_kind="${2:-none}" runtime_uid_arg="${3:-}" runtime_gid_arg="${4:-}" publish_mode="${5:-none}"
  fixture_root="$test_root/$name/fixture"
  source_root="$test_root/$name/source"
  fixture_home="$fixture_root/home"
  mkdir -p "$fixture_home" "$source_root/scripts/ubuntu"
  cp -- "$repo_root/scripts/ubuntu/trusted-launcher.sh" "$source_root/scripts/ubuntu/trusted-launcher.sh"
  cp -- "$repo_root/scripts/ubuntu/launcher-capability.sh" "$source_root/scripts/ubuntu/launcher-capability.sh"
  cat > "$source_root/scripts/ubuntu/bootstrap.sh" <<'EOF'
#!/usr/bin/bash
set -euo pipefail
entry_path="$(/usr/bin/realpath -e -- "${BASH_SOURCE[0]}")"
repo_path="$(/usr/bin/realpath -e -- "${entry_path%/*}/../..")"
source "$repo_path/scripts/ubuntu/launcher-capability.sh" bootstrap
launcher_capability_lifetime
: > "$HOME/clean-entrypoint-reached"
printf '%s\n' "$(/usr/bin/id -u)" > "$HOME/runtime-uid"
printf '%s\n' "$(/usr/bin/id -g)" > "$HOME/runtime-gid"
/usr/bin/id -G > "$HOME/runtime-groups"
/usr/bin/awk '/^NoNewPrivs:/ { print $2; found++ } END { exit(found == 1 ? 0 : 1) }' /proc/self/status > "$HOME/runtime-no-new-privs"
printf '%s\n' "$launcher_capability_parent_capability_kind" > "$HOME/parent-capability-kind"
/usr/bin/stat -Lc '%u:%g:%a:%F' -- /proc/$BASHPID/fd/12 > "$HOME/parent-capability-stat"
/usr/bin/readlink -- /proc/$BASHPID/fd/12 > "$HOME/parent-capability-link"
EOF
  chmod 0755 "$source_root/scripts/ubuntu/"*.sh
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
  install_args=(--origin "$canonical_origin" --commit "$pinned_commit" --fixture-root "$fixture_root" --fixture-transport "$transport" --fixture-home "$fixture_home")
  if [[ -n "$runtime_uid_arg" || -n "$runtime_gid_arg" ]]; then
    [[ -n "$runtime_uid_arg" && -n "$runtime_gid_arg" ]] || fail_test 'root-drop fixture runtime identity is incomplete'
    chown "$runtime_uid_arg:$runtime_gid_arg" "$fixture_home"
    install_args+=(--fixture-runtime-uid "$runtime_uid_arg" --fixture-runtime-gid "$runtime_gid_arg")
  fi
  if [[ "$pause_kind" == policy ]]; then
    policy_ready="$fixture_root/policy.ready"; policy_continue="$fixture_root/policy.continue"
    install_args+=(--fixture-policy-ready "$policy_ready" --fixture-policy-continue "$policy_continue")
  elif [[ "$pause_kind" == entry ]]; then
    entry_ready="$fixture_root/entry.ready"; entry_continue="$fixture_root/entry.continue"
    install_args+=(--fixture-entry-ready "$entry_ready" --fixture-entry-continue "$entry_continue")
  fi
  if [[ "$publish_mode" == publish-failure || "$publish_mode" == publish-replace ]]; then
    publish_ready="$fixture_root/publish.ready"
    publish_continue="$fixture_root/publish.continue"
    install_args+=(--fixture-publish-pause-ready "$publish_ready" --fixture-publish-pause-continue "$publish_continue")
    [[ "$publish_mode" == publish-failure ]] &&
      install_args+=(--fixture-publish-fail-after-stage)
  elif [[ "$publish_mode" != none ]]; then
    fail_test "unknown publication fixture mode: $publish_mode"
  fi
  if [[ "$publish_mode" == publish-failure || "$publish_mode" == publish-replace ]]; then
    /usr/bin/bash "$repo_root/scripts/ubuntu/install-trusted-launcher.sh" "${install_args[@]}" >"$test_root/$name/install.out" 2>&1 &
    publish_install_pid=$!
  else
    /usr/bin/bash "$repo_root/scripts/ubuntu/install-trusted-launcher.sh" "${install_args[@]}" >"$test_root/$name/install.out"
  fi
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
[[ "$(stat -c '%u:%g:%a' "$policy")" == "$(id -u):$(id -g):600" ]] || fail_test 'fixture policy owner/mode is wrong'
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
set +e
run_launcher "$test_root"
launcher_status=$?
set -e
(( launcher_status == 0 )) || fail_test "clean launcher failed with status $launcher_status"
[[ -f "$fixture_home/clean-entrypoint-reached" ]] || {
  ls -la "$fixture_home" >&2
  fail_test 'verified committed entrypoint did not execute'
}
for command_name in env bash git realpath stat sha256sum gawk mktemp rm find sleep getent id chmod setpriv; do
  [[ ! -e "$test_root/hostile-$command_name-reached" ]] || fail_test "launcher resolved hostile PATH command: $command_name"
done

# Exercise the capability helper directly with a descriptor opened before the
# policy path loses read permission.  This is the boundary that the installed
# launcher crosses when it opens the root-owned policy and then drops identity.
parser_access_root="$test_root/parser-access"
mkdir -p "$parser_access_root"
chmod 0755 "$test_root" "$parser_access_root"
helper_definitions="$parser_access_root/launcher-capability-definitions.sh"
set +e
/usr/bin/awk '
  function has_policy_alias(line) {
    return index(line, "policy_fd_path") ||
      index(line, "policy_path") ||
      index(line, "launcher_capability_policy_path") ||
      index(line, "/etc/herdr-workstation/bootstrap-policy.conf") ||
      index(line, "bootstrap-policy.conf") ||
      index(line, "/proc/$BASHPID/fd/9") ||
      index(line, "/proc/${BASHPID}/fd/9") ||
      index(line, "/proc/$PPID/fd/9") ||
      index(line, "/proc/${PPID}/fd/9") ||
      index(line, "/proc/self/fd/9") ||
      index(line, "/proc/self/fd/09") ||
      index(line, "/proc/$$/fd/9") ||
      index(line, "/proc/$$/fd/09") ||
      index(line, "/dev/fd/9")
  }
  /(^|[[:space:]\/])(sha256sum|cat|tee|dd|od|xxd|hexdump|base64|cmp|diff|awk|gawk|sed|grep|head|tail|wc|tr|sort|strings|python|perl)([[:space:]]|$)/ && has_policy_alias($0) {
    print
    bad=1
  }
  /</ && has_policy_alias($0) {
    print
    bad=1
  }
  END { exit bad }
' "$repo_root/scripts/ubuntu/launcher-capability.sh" > "$parser_access_root/policy-reopen.out"
policy_reopen_audit_status=$?
set -e
(( policy_reopen_audit_status == 0 )) || {
  cat "$parser_access_root/policy-reopen.out" >&2
  fail_test 'capability helper has a policy-content reopen through a path or fd alias'
}
/usr/bin/awk '/^\[\[ "\$#" -ge 1/ { exit } { print }' \
  "$repo_root/scripts/ubuntu/launcher-capability.sh" > "$helper_definitions"
chmod 0644 "$helper_definitions"
inherited_policy=$'herdr-bootstrap-policy-v1\norigin=https://github.com/nathanestone-alt/herdr-workstation-bootstrap.git\ncommit=0123456789012345678901234567890123456789\n'
duplicate_header_policy=$'herdr-bootstrap-policy-v1\nherdr-bootstrap-policy-v1\norigin=https://github.com/nathanestone-alt/herdr-workstation-bootstrap.git\ncommit=0123456789012345678901234567890123456789\n'
malformed_policy=$'herdr-bootstrap-policy-v1\ninvalid-policy-line\norigin=https://github.com/nathanestone-alt/herdr-workstation-bootstrap.git\ncommit=0123456789012345678901234567890123456789\n'
trailing_bytes_policy=$'herdr-bootstrap-policy-v1\norigin=https://github.com/nathanestone-alt/herdr-workstation-bootstrap.git\ncommit=0123456789012345678901234567890123456789\ntrailing-bytes'
parser_drop_uid=''
parser_drop_gid=''
if [[ "$(id -u)" == 0 && -x /usr/bin/setpriv ]]; then
  parser_drop_uid="$(id -u nobody 2>/dev/null || true)"
  parser_drop_gid="$(id -g nobody 2>/dev/null || true)"
  [[ "$parser_drop_uid" =~ ^[0-9]+$ && "$parser_drop_gid" =~ ^[0-9]+$ ]] ||
    fail_test 'root parser fixture could not resolve nobody identity'
fi
parser_command='set -euo pipefail
source "$1"
launcher_capability_parse_policy "$2"
printf "%s\n" "$launcher_capability_policy_hash"'
run_parser_file_fixture() {
  local label="$1" policy="$2" should_pass="$3" expected_hash policy_size parser_output status
  chmod 0600 "$policy"
  expected_hash="$(/usr/bin/sha256sum -- "$policy" | /usr/bin/awk '{print $1}')"
  policy_size="$(/usr/bin/stat -c '%s' -- "$policy")"
  set +e
  parser_output="$(
    (
      set -euo pipefail
      exec 9<"$policy"
      chmod 000 -- "$policy"
      if [[ -n "$parser_drop_uid" ]]; then
        /usr/bin/setpriv --reuid="$parser_drop_uid" --regid="$parser_drop_gid" --clear-groups \
          /usr/bin/bash -c "$parser_command" _ "$helper_definitions" "$policy_size"
      else
        /usr/bin/bash -c "$parser_command" _ "$helper_definitions" "$policy_size"
      fi
    ) 2>&1
  )"
  status=$?
  set -e
  chmod 0600 -- "$policy"
  if [[ "$should_pass" == 1 ]]; then
    (( status == 0 )) || { printf '%s\n' "$parser_output" >&2; fail_test "$label inherited-fd policy parse failed"; }
    [[ "$parser_output" == "$expected_hash" ]] ||
      fail_test "$label policy hash did not cover the inherited descriptor bytes"
  else
    (( status != 0 )) || fail_test "$label malformed policy unexpectedly passed"
  fi
}
run_parser_fixture() {
  local label="$1" policy_contents="$2" should_pass="$3" policy="$parser_access_root/parser-$1"
  printf '%s' "$policy_contents" > "$policy"
  run_parser_file_fixture "$label" "$policy" "$should_pass"
}
run_parser_fixture inherited-fd "$inherited_policy" 1
run_parser_fixture duplicate-header "$duplicate_header_policy" 0
run_parser_fixture malformed-line "$malformed_policy" 0
run_parser_fixture trailing-bytes "$trailing_bytes_policy" 0
nul_embedded_policy="$parser_access_root/parser-nul-embedded"
{
  printf '%s\n' 'herdr-bootstrap-policy-v1'
  printf '%s\0%s\n' 'origin=https://github.com/nathanestone-alt/herdr-workstation-bootstrap.git' ''
  printf '%s\n' 'commit=0123456789012345678901234567890123456789'
} > "$nul_embedded_policy"
run_parser_file_fixture nul-embedded "$nul_embedded_policy" 0
nul_trailing_policy="$parser_access_root/parser-nul-trailing"
{
  printf '%s\n' 'herdr-bootstrap-policy-v1'
  printf '%s\n' 'origin=https://github.com/nathanestone-alt/herdr-workstation-bootstrap.git'
  printf '%s\n' 'commit=0123456789012345678901234567890123456789'
  printf '\0'
} > "$nul_trailing_policy"
run_parser_file_fixture nul-trailing "$nul_trailing_policy" 0

run_descriptor_fixture() {
  local label="$1" action="$2" policy="$test_root/descriptor-$1" replacement="$test_root/descriptor-$1-replacement" status
  printf '%s' "$inherited_policy" > "$policy"
  printf '%s' "$inherited_policy" > "$replacement"
  chmod 0600 "$policy" "$replacement"
  set +e
  (
    set -euo pipefail
    exec 9<"$policy"
    expected_identity="$(/usr/bin/stat -Lc '%d:%i:%u:%g:%a:%F:%s:%Y' -- /proc/$BASHPID/fd/9)"
    # shellcheck disable=SC1090
    source "$helper_definitions"
    case "$action" in
      substitution) exec 9<&-; exec 9<"$replacement" ;;
      absence) exec 9<&- ;;
      *) exit 2 ;;
    esac
    launcher_capability_assert_fd 9 "$policy" "$expected_identity"
  ) > "$test_root/descriptor-$label.out" 2>&1
  status=$?
  set -e
  (( status != 0 )) || { cat "$test_root/descriptor-$label.out" >&2; fail_test "$label descriptor mutation unexpectedly passed"; }
}
run_descriptor_fixture substitution substitution
run_descriptor_fixture absence absence
echo 'inherited policy descriptor, exact-byte, NUL/byte-count, alias-reopen, substitution, and absence tests passed.'

parent_capability_file="$test_root/parent-capability-file"
parent_capability_directory="$test_root/parent-capability-directory"
printf 'L' > "$parent_capability_file"
chmod 0600 "$parent_capability_file"
mkdir "$parent_capability_directory"
chmod 0700 "$parent_capability_directory"
run_parent_capability_fixture() {
  local label="$1" kind="$2" object="$3" should_pass="$4" output status
  set +e
  output="$(
    (
      set -euo pipefail
      exec 12<&- 2>/dev/null || true
      if [[ -n "$object" ]]; then
        exec 12<"$object"
        [[ "$should_pass" == 1 ]] && rm -rf -- "$object"
      fi
      # shellcheck disable=SC1090
      source "$helper_definitions"
      launcher_capability_assert_parent_capability "$kind" "$(/usr/bin/id -u)" "$(/usr/bin/id -g)"
    ) 2>&1
  )"
  status=$?
  set -e
  if [[ "$should_pass" == 1 ]]; then
    (( status == 0 )) || { printf '%s\n' "$output" >&2; fail_test "$label parent capability validation failed"; }
  else
    (( status != 0 )) || fail_test "$label parent capability unexpectedly passed"
  fi
}
run_parent_capability_fixture installed-file installed-launcher "$parent_capability_file" 1
run_parent_capability_fixture root-receipt-directory root-receipt "$parent_capability_directory" 1
printf 'L' > "$parent_capability_file"
chmod 0600 "$parent_capability_file"
mkdir "$parent_capability_directory"
chmod 0700 "$parent_capability_directory"
run_parent_capability_fixture missing installed-launcher '' 0
run_parent_capability_fixture substituted-file-for-receipt root-receipt "$parent_capability_file" 0
run_parent_capability_fixture substituted-directory-for-launcher installed-launcher "$parent_capability_directory" 0
echo 'parent capability positive, missing, substituted, and role-distinction tests passed.'

# The capability entrypoint/helper mode contract is role-specific.  An
# installed-launcher stage is a live checkout that keeps its committed 100755
# blobs writable by their owner (0755).  A payload receipt instead executes the
# hardened source-attestation snapshot, whose files have every write bit
# stripped after materialization (0555).  Each role must accept exactly its own
# mode and reject the other role's mode, any writable-by-group/other variant,
# and any foreign owner.
capability_mode_root="$test_root/capability-mode"
mkdir -p "$capability_mode_root"
chmod 0755 "$capability_mode_root"
capability_mode_entry="$capability_mode_root/receipt-authority.sh"
: > "$capability_mode_entry"
run_capability_mode_fixture() {
  local label="$1" payload_mode="$2" file_mode="$3" expected_uid="$4" should_pass="$5"
  local output status
  chmod "$file_mode" -- "$capability_mode_entry"
  set +e
  output="$(
    (
      set -euo pipefail
      # shellcheck disable=SC1090
      source "$helper_definitions"
      launcher_capability_expected_entry_mode "$payload_mode"
      launcher_capability_owner_mode "$capability_mode_entry" \
        "$expected_uid" "$(/usr/bin/id -g)" "$launcher_capability_entry_mode"
    ) 2>&1
  )"
  status=$?
  set -e
  if [[ "$should_pass" == 1 ]]; then
    (( status == 0 )) || { printf '%s\n' "$output" >&2; fail_test "$label capability mode contract rejected the attested mode"; }
  else
    (( status != 0 )) || fail_test "$label capability mode contract unexpectedly passed"
  fi
}
capability_mode_uid="$(/usr/bin/id -u)"
capability_mode_foreign_uid=$(( capability_mode_uid + 1 ))
run_capability_mode_fixture payload-hardened 1 0555 "$capability_mode_uid" 1
run_capability_mode_fixture payload-owner-writable 1 0755 "$capability_mode_uid" 0
run_capability_mode_fixture payload-group-writable 1 0575 "$capability_mode_uid" 0
run_capability_mode_fixture payload-world-writable 1 0557 "$capability_mode_uid" 0
run_capability_mode_fixture payload-foreign-owner 1 0555 "$capability_mode_foreign_uid" 0
run_capability_mode_fixture launcher-owner-writable 0 0755 "$capability_mode_uid" 1
run_capability_mode_fixture launcher-hardened 0 0555 "$capability_mode_uid" 0
run_capability_mode_fixture launcher-group-writable 0 0775 "$capability_mode_uid" 0
run_capability_mode_fixture launcher-world-writable 0 0757 "$capability_mode_uid" 0
run_capability_mode_fixture launcher-foreign-owner 0 0755 "$capability_mode_foreign_uid" 0
run_capability_mode_fixture invalid-selector 2 0755 "$capability_mode_uid" 0
run_capability_mode_fixture empty-selector '' 0755 "$capability_mode_uid" 0
echo 'capability entrypoint payload/installed-launcher mode contract tests passed.'

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
cp -a -- "$source_root" "$dirty_root"
cat >> "$dirty_root/scripts/ubuntu/bootstrap.sh" <<EOF
: > '$dirty_marker'
EOF
run_launcher "$dirty_root"
[[ ! -e "$dirty_marker" ]] || fail_test 'dirty repository code executed before trust'

direct_attack="$test_root/direct-attack"
mkdir -p "$direct_attack/scripts/ubuntu"
{
  printf '#!/usr/bin/bash\n: > %q\n' "$test_root/direct-before-guard-reached"
  cat "$source_root/scripts/ubuntu/bootstrap.sh"
} > "$direct_attack/scripts/ubuntu/bootstrap.sh"
chmod 0755 "$direct_attack/scripts/ubuntu/bootstrap.sh"
run_launcher "$direct_attack"
[[ ! -e "$test_root/direct-before-guard-reached" ]] || fail_test 'attacker code before direct-entrypoint guard ran'
expect_failure 'direct entrypoint with forged marker' env -i HOME="$fixture_home" PATH=/usr/bin:/bin \
  HERDR_BOOTSTRAP_TRUSTED_LAUNCHER=1 HERDR_BOOTSTRAP_VERIFIED_ENTRYPOINT=1 \
  /usr/bin/bash "$source_root/scripts/ubuntu/bootstrap.sh"

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
chmod 0666 "$policy"; expect_failure 'group-writable policy' run_launcher "$test_root"; chmod 0600 "$policy"
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

# A publication failure after staging must remove only the staging inode it
# created, leaving no root-owned .herdr-bootstrap-publish.* residue.
make_fixture publish-failure none '' '' publish-failure
for attempt in $(seq 1 2000); do
  [[ -e "$publish_ready" ]] && break
  sleep 0.01
done
if [[ ! -e "$publish_ready" ]]; then
  : > "$publish_continue"
  kill "$publish_install_pid" 2>/dev/null || true
  wait "$publish_install_pid" 2>/dev/null || true
  fail_test 'publication failure fixture did not reach its staging pause'
fi
: > "$publish_continue"
set +e
wait "$publish_install_pid"
publish_failure_status=$?
set -e
(( publish_failure_status != 0 )) || fail_test 'publication failure fixture unexpectedly passed'
[[ -z "$(find "$fixture_root" -type f -name '.herdr-bootstrap-publish.*' -print -quit)" ]] ||
  fail_test 'failed publication leaked a staging file'

# If the staging pathname is replaced by an unrelated inode while paused,
# identity-bound cleanup must fail closed and preserve that replacement.
make_fixture publish-replace none '' '' publish-replace
for attempt in $(seq 1 2000); do
  [[ -e "$publish_ready" ]] && break
  sleep 0.01
done
if [[ ! -e "$publish_ready" ]]; then
  : > "$publish_continue"
  kill "$publish_install_pid" 2>/dev/null || true
  wait "$publish_install_pid" 2>/dev/null || true
  fail_test 'publication replacement fixture did not reach its staging pause'
fi
publish_stage_path="$(find "$fixture_root" -type f -name '.herdr-bootstrap-publish.*' -print -quit)"
[[ -n "$publish_stage_path" ]] || {
  : > "$publish_continue"
  kill "$publish_install_pid" 2>/dev/null || true
  wait "$publish_install_pid" 2>/dev/null || true
  fail_test 'publication replacement fixture did not expose its staging file'
}
mv -- "$publish_stage_path" "$test_root/unrelated-publication-file"
printf 'unrelated publication content\n' > "$publish_stage_path"
chmod 0600 "$publish_stage_path"
: > "$publish_continue"
set +e
wait "$publish_install_pid"
publish_replace_status=$?
set -e
(( publish_replace_status != 0 )) || fail_test 'publication replacement fixture unexpectedly passed'
grep -Fqx -- 'install-trusted-launcher: publication staging file was replaced' "$test_root/publish-replace/install.out" ||
  fail_test 'publication replacement fixture emitted the wrong diagnostic'
[[ -f "$publish_stage_path" && "$(< "$publish_stage_path")" == 'unrelated publication content' ]] ||
  fail_test 'failed publication removed an unrelated replacement path'

if [[ "$(id -u)" != 0 ]]; then
  echo "SKIP: root-gated launcher privilege-drop tests (root unavailable; uid=$(id -u))."
else
  root_drop_uid="$(id -u nobody 2>/dev/null || true)"
  root_drop_gid="$(id -g nobody 2>/dev/null || true)"
  if [[ ! "$root_drop_uid" =~ ^[1-9][0-9]*$ || ! "$root_drop_gid" =~ ^[0-9]+$ ]]; then
    echo 'SKIP: root-gated launcher privilege-drop tests (nobody account unavailable).'
  else
    make_fixture root-drop none "$root_drop_uid" "$root_drop_gid"
    set +e
    run_launcher "$test_root"
    root_drop_status=$?
    set -e
    (( root_drop_status == 0 )) || fail_test "root-gated launcher fixture failed with status $root_drop_status"
    [[ "$(< "$fixture_home/runtime-uid")" == "$root_drop_uid" ]] || fail_test 'launcher did not drop to the fixture uid'
    [[ "$(< "$fixture_home/runtime-gid")" == "$root_drop_gid" ]] || fail_test 'launcher did not set the fixture gid'
    [[ "$(tr -d '[:space:]' < "$fixture_home/runtime-groups")" == "$root_drop_gid" ]] || fail_test 'launcher did not clear supplementary groups'
    [[ "$(< "$fixture_home/runtime-no-new-privs")" == 1 ]] || fail_test 'launcher did not set no_new_privs'
    [[ "$root_drop_uid" != "$(id -u)" ]] || fail_test 'root-drop fixture did not cross a uid boundary'
    [[ "$(< "$fixture_home/parent-capability-kind")" == installed-launcher ]] || fail_test 'root-drop fixture used the wrong parent capability role'
    [[ "$(< "$fixture_home/parent-capability-stat")" == '0:0:600:regular file' ]] || fail_test 'root-drop fixture parent capability owner/mode/type is wrong'
    [[ "$(< "$fixture_home/parent-capability-link")" == *' (deleted)' ]] || fail_test 'root-drop fixture parent capability was not unlinked'
    [[ "$(stat -c '%u:%g:%a' "$launcher")" == 0:0:755 ]] || fail_test 'root-gated launcher binary is not root-owned'
    [[ "$(stat -c '%u:%g:%a' "$policy")" == 0:0:600 ]] || fail_test 'root-gated policy is not root-owned and private'
    [[ "$(stat -c '%u:%g:%a' "$stage_root")" == 0:0:755 ]] || fail_test 'root-gated staging root is not root-owned'
    chown "$root_drop_uid:$root_drop_gid" "$stage_root"
    expect_failure 'user-owned staging root' run_launcher "$test_root"
    chown 0:0 "$stage_root"
    echo 'Root-gated launcher privilege-drop tests passed.'
  fi
fi

echo 'trusted launcher policy, forged-repository, ownership/mode, and replacement tests passed.'
