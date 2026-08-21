#!/usr/bin/env -S -i BASH_ENV= ENV= CDPATH= PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C TZ=UTC /usr/bin/bash
set -euo pipefail
umask 022
readonly launcher_system_prefix='__HERDR_LAUNCHER_SYSTEM_PREFIX__'
readonly launcher_expected_uid='__HERDR_LAUNCHER_OWNER_UID__'
readonly launcher_expected_gid='__HERDR_LAUNCHER_OWNER_GID__'
readonly launcher_runtime_uid='__HERDR_LAUNCHER_RUNTIME_UID__'
readonly launcher_runtime_gid='__HERDR_LAUNCHER_RUNTIME_GID__'
readonly launcher_system_uid='__HERDR_LAUNCHER_SYSTEM_UID__'
readonly launcher_system_gid='__HERDR_LAUNCHER_SYSTEM_GID__'
readonly launcher_fixture_transport='__HERDR_LAUNCHER_FIXTURE_TRANSPORT__'
readonly launcher_fixture_home='__HERDR_LAUNCHER_FIXTURE_HOME__'
readonly launcher_policy_pause_ready='__HERDR_LAUNCHER_POLICY_PAUSE_READY__'
readonly launcher_policy_pause_continue='__HERDR_LAUNCHER_POLICY_PAUSE_CONTINUE__'
readonly launcher_entry_pause_ready='__HERDR_LAUNCHER_ENTRY_PAUSE_READY__'
readonly launcher_entry_pause_continue='__HERDR_LAUNCHER_ENTRY_PAUSE_CONTINUE__'
readonly launcher_fixture_receipt_pause_phase='__HERDR_LAUNCHER_RECEIPT_PAUSE_PHASE__'
readonly launcher_fixture_receipt_pause_ready='__HERDR_LAUNCHER_RECEIPT_PAUSE_READY__'
readonly launcher_fixture_receipt_pause_continue='__HERDR_LAUNCHER_RECEIPT_PAUSE_CONTINUE__'
readonly launcher_env_bin=/usr/bin/env launcher_bash_bin=/usr/bin/bash launcher_git_bin=/usr/bin/git
readonly launcher_realpath_bin=/usr/bin/realpath launcher_stat_bin=/usr/bin/stat launcher_sha256_bin=/usr/bin/sha256sum
readonly launcher_awk_bin=/usr/bin/gawk launcher_mktemp_bin=/usr/bin/mktemp launcher_rm_bin=/usr/bin/rm
readonly launcher_find_bin=/usr/bin/find launcher_sleep_bin=/usr/bin/sleep launcher_getent_bin=/usr/bin/getent launcher_id_bin=/usr/bin/id
readonly launcher_chmod_bin=/usr/bin/chmod launcher_setpriv_bin=/usr/bin/setpriv
readonly launcher_trusted_path=/usr/sbin:/usr/bin:/sbin:/bin
fail() { echo "herdr trusted launcher: $*" >&2; exit 24; }
sys_path() { printf '%s/%s\n' "$launcher_system_prefix" "${1#/}"; }
assert_sysbin() {
  local p=$1 r o m
  [[ -f $p && ! -L $p && -x $p ]] || fail "unsafe system binary: $p"
  r="$($launcher_realpath_bin -e -- "$p" 2>/dev/null || true)"
  o="$($launcher_stat_bin -c %u -- "$p" 2>/dev/null || true)"
  m="$($launcher_stat_bin -c %a -- "$p" 2>/dev/null || true)"
  if [[ -z "$launcher_system_prefix" ]]; then
    [[ $o == 0 ]] || fail "unsafe system binary owner: $p"
  else
    [[ $o == "$launcher_system_uid" && "$($launcher_stat_bin -c %g -- "$p" 2>/dev/null || true)" == "$launcher_system_gid" ]] || fail "unsafe fixture system binary owner: $p"
  fi
  [[ $r == "$p" && $m =~ ^[0-7]+$ && $((8#$m & 022)) == 0 ]] || fail "unsafe system binary: $p"
}
assert_components() {
  local p=$1 c cur=/; local -a a
  [[ $p == /* ]] || return 1
  IFS=/ read -r -a a <<< "${p#/}"
  for c in "${a[@]}"; do
    [[ -z $c || $c == . ]] && continue
    [[ $c != .. && $c != */* ]] || return 1
    cur="$cur/$c"; [[ ! -L $cur ]] || return 1
  done
}
assert_dir() {
  local p=$1 want="${2:-}" r o g m
  assert_components "$p" || fail "symlinked directory component: $p"
  [[ -d $p && ! -L $p ]] || fail "unsafe directory: $p"
  r="$($launcher_realpath_bin -e -- "$p" 2>/dev/null || true)"
  o="$($launcher_stat_bin -c %u -- "$p" 2>/dev/null || true)"; g="$($launcher_stat_bin -c %g -- "$p" 2>/dev/null || true)"; m="$($launcher_stat_bin -c %a -- "$p" 2>/dev/null || true)"
  [[ $r == "$p" && $o == "$launcher_expected_uid" && $g == "$launcher_expected_gid" && $m =~ ^[0-7]+$ && $((8#$m & 022)) == 0 && ( -z $want || $m == $want ) ]] || fail "unsafe directory ownership/mode: $p"
}
assert_file() {
  local p=$1 want="${2:-}" r o g m
  assert_components "$p" || fail "symlinked file component: $p"
  [[ -f $p && ! -L $p ]] || fail "unsafe file: $p"
  r="$($launcher_realpath_bin -e -- "$p" 2>/dev/null || true)"
  o="$($launcher_stat_bin -c %u -- "$p" 2>/dev/null || true)"; g="$($launcher_stat_bin -c %g -- "$p" 2>/dev/null || true)"; m="$($launcher_stat_bin -c %a -- "$p" 2>/dev/null || true)"
  [[ $r == "$p" && $o == "$launcher_expected_uid" && $g == "$launcher_expected_gid" && $m =~ ^[0-7]+$ && $((8#$m & 022)) == 0 && ( -z $want || $m == $want ) ]] || fail "unsafe file ownership/mode: $p"
}
for b in "$launcher_env_bin" "$launcher_bash_bin" "$launcher_git_bin" "$launcher_realpath_bin" "$launcher_stat_bin" "$launcher_sha256_bin" "$launcher_awk_bin" "$launcher_mktemp_bin" "$launcher_rm_bin" "$launcher_find_bin" "$launcher_sleep_bin" "$launcher_getent_bin" "$launcher_id_bin" "$launcher_chmod_bin" "$launcher_setpriv_bin"; do assert_sysbin "$b"; done
[[ "$launcher_system_prefix" != __HERDR_LAUNCHER_*__ && "$launcher_expected_uid" =~ ^[0-9]+$ && "$launcher_expected_gid" =~ ^[0-9]+$ && "$launcher_runtime_uid" =~ ^[0-9]+$ && "$launcher_runtime_gid" =~ ^[0-9]+$ && "$launcher_system_uid" =~ ^[0-9]+$ && "$launcher_system_gid" =~ ^[0-9]+$ && "$launcher_fixture_transport" != __HERDR_LAUNCHER_*__ && "$launcher_fixture_home" != __HERDR_LAUNCHER_*__ && "$launcher_fixture_receipt_pause_phase" != __HERDR_LAUNCHER_*__ && "$launcher_fixture_receipt_pause_ready" != __HERDR_LAUNCHER_*__ && "$launcher_fixture_receipt_pause_continue" != __HERDR_LAUNCHER_*__ ]] || fail 'unrendered launcher template'
[[ $launcher_system_prefix == '' || $launcher_system_prefix == /* ]] || fail 'invalid system prefix'
install_path="$(sys_path /usr/local/libexec/herdr-workstation-bootstrap)"; policy_path="$(sys_path /etc/herdr-workstation/bootstrap-policy.conf)"; stage_root="$(sys_path /var/lib/herdr-workstation/bootstrap/staging)"
policy_dir="$(sys_path /etc/herdr-workstation)"; libexec_dir="$(sys_path /usr/local/libexec)"
if [[ -n "$launcher_system_prefix" ]]; then assert_dir "$launcher_system_prefix" 755; fi
assert_dir "$policy_dir" 755; assert_dir "$libexec_dir" 755
[[ "$($launcher_id_bin -u)" == "$launcher_expected_uid" && "$($launcher_id_bin -g)" == "$launcher_expected_gid" ]] || fail 'launcher must run as the installed trust-anchor owner'
assert_file "$install_path" 755; assert_file "$policy_path" 600; assert_dir "$stage_root" 755
[[ "$($launcher_realpath_bin -e -- "$0" 2>/dev/null || true)" == "$install_path" ]] || fail 'launcher path is not the installed canonical path'
exec 11<"$install_path" || fail 'installed launcher capability open failed'
entrypoint=scripts/ubuntu/bootstrap.sh
while [[ $# -gt 0 ]]; do
  case $1 in
    --entrypoint)
      [[ $# -ge 2 ]] || fail '--entrypoint requires a value'
      case $2 in bootstrap) entrypoint=scripts/ubuntu/bootstrap.sh ;; receipt-authority) entrypoint=scripts/ubuntu/receipt-authority.sh ;; verify) entrypoint=scripts/ubuntu/verify.sh ;; *) fail 'unsupported entrypoint' ;; esac
      shift 2 ;;
    --) shift; break ;;
    *) break ;;
  esac
done
policy_pid=$BASHPID; policy_fd_path=''; policy_id=''; policy_hash=''; origin=''; commit=''
policy_identity() { "$launcher_stat_bin" -Lc '%d:%i:%u:%g:%a' -- "$1" 2>/dev/null || true; }
policy_lifetime() {
  local fi pi ph
  fi="$(policy_identity "$policy_fd_path")"; pi="$(policy_identity "$policy_path")"; ph="$($launcher_sha256_bin -- "$policy_path" | "$launcher_awk_bin" '{print $1}')"
  [[ $fi == "$policy_id" && $pi == "$policy_id" && $ph == "$policy_hash" ]] || fail 'policy replacement detected'
}
canonical_origin() {
  [[ "$1" =~ ^https://[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+/[A-Za-z0-9._~-]+(/[A-Za-z0-9._~-]+)*\.git$ && "$1" != *..* && "$1" != *@* ]]
}
pause_at() { [[ -n $1 ]] || return 0; : > "$1"; while [[ ! -e $2 ]]; do "$launcher_sleep_bin" 0.01; done; }
exec 9<"$policy_path" || fail 'policy open failed'
policy_fd_path="/proc/$policy_pid/fd/9"; policy_id="$(policy_identity "$policy_fd_path")"; policy_hash="$($launcher_sha256_bin -- "$policy_fd_path" | "$launcher_awk_bin" '{print $1}')"
[[ $policy_id =~ ^[0-9]+:[0-9]+:[0-9]+:[0-9]+:[0-9]+$ && $policy_hash =~ ^[0-9a-f]{64}$ ]] || fail 'invalid policy descriptor'
hc=0; oc=0; cc=0
while IFS= read -r line; do
  case $line in
    herdr-bootstrap-policy-v1) ((hc+=1)) ;;
    origin=*) ((oc+=1)); [[ -z $origin ]] || fail 'duplicate origin'; origin="${line#origin=}" ;;
    commit=*) ((cc+=1)); [[ -z $commit ]] || fail 'duplicate commit'; commit="${line#commit=}" ;;
    *) fail "malformed policy line: $line" ;;
  esac
done <"$policy_fd_path"
[[ $hc == 1 && $oc == 1 && $cc == 1 && $commit =~ ^[0-9a-f]{40}$ ]] || fail 'policy grammar is not exact'
canonical_origin "$origin" || fail 'policy origin is not canonical HTTPS'
policy_lifetime
pause_at "$launcher_policy_pause_ready" "$launcher_policy_pause_continue"
policy_lifetime
if [[ -n $launcher_fixture_transport ]]; then
  [[ -n $launcher_system_prefix ]] || fail 'fixture transport in production'; assert_dir "$launcher_fixture_transport" 700; fetch_source=$launcher_fixture_transport
else
  fetch_source=$origin
fi
stage_dir="$($launcher_mktemp_bin -d "$stage_root/.incoming.XXXXXX")" || fail 'staging directory creation failed'
exec 10<"$stage_dir" || fail 'staged repository capability open failed'
cleanup() { local s=$1; set +e; [[ -d $stage_dir ]] && "$launcher_rm_bin" -rf -- "$stage_dir"; exec 9<&- 2>/dev/null || true; exec 10<&- 2>/dev/null || true; exec 11<&- 2>/dev/null || true; return "$s"; }
trap 'cleanup "$?"' EXIT
"$launcher_chmod_bin" 0755 -- "$stage_dir" || fail 'staging directory publication failed'
assert_dir "$stage_dir" 755
git_safe() {
  "$launcher_env_bin" -i HOME=/nonexistent PATH="$launcher_trusted_path" LC_ALL=C TZ=UTC GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_COUNT=0 GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/false "$launcher_git_bin" --no-replace-objects -c core.attributesfile=/dev/null -c core.excludesfile=/dev/null -c core.hooksPath=/dev/null -c core.filemode=true -c core.ignoreCase=false -c protocol.file.allow=always "$@"
}
git_safe init --quiet "$stage_dir"; git_safe -C "$stage_dir" remote add origin "$origin"; git_safe -C "$stage_dir" fetch --no-tags --no-auto-gc "$fetch_source" "$commit" >/dev/null; git_safe -C "$stage_dir" checkout --quiet --detach --force "$commit"
[[ "$(git_safe -C "$stage_dir" rev-parse --verify HEAD^{commit} 2>/dev/null || true)" == "$commit" && "$(git_safe -C "$stage_dir" cat-file -t "$commit" 2>/dev/null || true)" == commit ]] || fail 'fetched object is not the exact policy commit'
[[ "$(git_safe -C "$stage_dir" config --local --no-includes --get remote.origin.url 2>/dev/null || true)" == "$origin" ]] || fail 'staged origin differs from policy'
bad="$("$launcher_find_bin" -P "$stage_dir" -path "$stage_dir/.git" -prune -o -type l -print -quit 2>/dev/null || true)"; [[ -z $bad ]] || fail "source closure has a symlink: $bad"
while IFS= read -r -d '' p; do
  [[ -d $p || -f $p ]] || fail "unsupported staged entry: $p"
  o="$($launcher_stat_bin -c %u -- "$p" 2>/dev/null || true)"; g="$($launcher_stat_bin -c %g -- "$p" 2>/dev/null || true)"; m="$($launcher_stat_bin -c %a -- "$p" 2>/dev/null || true)"
  [[ $o == "$launcher_expected_uid" && $g == "$launcher_expected_gid" && $m =~ ^[0-7]+$ && $((8#$m & 022)) == 0 ]] || fail "unsafe staged entry: $p"
done < <("$launcher_find_bin" -P "$stage_dir" -mindepth 1 -print0)
tree="$(git_safe -C "$stage_dir" ls-tree "$commit" -- "$entrypoint" 2>/dev/null || true)"; [[ $tree != *$'\n'* ]] || fail 'ambiguous entrypoint'
IFS=$'\t' read -r meta tree_path <<<"$tree"; read -r mode type oid <<<"$meta"
[[ $tree_path == "$entrypoint" && $type == blob && $mode == 100755 && $oid =~ ^[0-9a-f]{40}$ ]] || fail 'entrypoint is not an executable committed blob'
git_safe -C "$stage_dir" cat-file -e "$oid^{blob}"
entry_path="$stage_dir/$entrypoint"; assert_file "$entry_path" 755; entry_id="$(policy_identity "$entry_path")"; entry_hash="$($launcher_sha256_bin -- "$entry_path" | "$launcher_awk_bin" '{print $1}')"
[[ "$(git_safe -C "$stage_dir" hash-object --no-filters -- "$entry_path")" == "$oid" ]] || fail 'entrypoint materialization hash mismatch'
pause_at "$launcher_entry_pause_ready" "$launcher_entry_pause_continue"
policy_lifetime; assert_dir "$stage_dir" 755; assert_file "$entry_path" 755
[[ "$(policy_identity "$entry_path")" == "$entry_id" && "$($launcher_sha256_bin -- "$entry_path" | "$launcher_awk_bin" '{print $1}')" == "$entry_hash" && "$(git_safe -C "$stage_dir" hash-object --no-filters -- "$entry_path")" == "$oid" ]] || fail 'entrypoint replacement detected'
if [[ -n $launcher_fixture_home ]]; then
  home=$launcher_fixture_home
else
  uid="$($launcher_id_bin -u)"
  home="$($launcher_getent_bin passwd "$uid" | $launcher_awk_bin -F: 'NF >= 6 { print $6; found++ } END { exit(found == 1 ? 0 : 1) }' || true)"
fi
[[ $home == /* && $home != / && "$launcher_runtime_uid" =~ ^[0-9]+$ && "$launcher_runtime_gid" =~ ^[0-9]+$ ]] || fail 'no safe runtime user home or identity'
launcher_env_args=(
  HOME="$home" PATH="$launcher_trusted_path" LC_ALL=C TZ=UTC BASH_ENV= ENV=
)
if [[ -n "$launcher_fixture_receipt_pause_phase" ]]; then
  [[ -n "$launcher_fixture_receipt_pause_ready" && -n "$launcher_fixture_receipt_pause_continue" ]] || fail 'fixture receipt pause binding is incomplete'
  launcher_env_args+=(
    HERDR_RECEIPT_TEST_PAUSE_PHASE="$launcher_fixture_receipt_pause_phase"
    HERDR_RECEIPT_TEST_READY_FILE="$launcher_fixture_receipt_pause_ready"
    HERDR_RECEIPT_TEST_CONTINUE_FILE="$launcher_fixture_receipt_pause_continue"
  )
fi
if [[ "$entrypoint" == scripts/ubuntu/receipt-authority.sh || "$launcher_runtime_uid" == "$launcher_expected_uid" ]]; then
  "$launcher_env_bin" -i "${launcher_env_args[@]}" "$launcher_bash_bin" "$entry_path" "$@"
else
  "$launcher_env_bin" -i "${launcher_env_args[@]}" "$launcher_setpriv_bin" \
    --reuid="$launcher_runtime_uid" --regid="$launcher_runtime_gid" --clear-groups --no-new-privs \
    "$launcher_bash_bin" "$entry_path" "$@"
fi
