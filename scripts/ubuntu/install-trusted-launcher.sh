#!/usr/bin/env -S -i BASH_ENV= ENV= CDPATH= PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C TZ=UTC /usr/bin/bash
set -euo pipefail
umask 022

# This administrative script must be verified out-of-band before root executes
# it. The approved commit and HTTPS origin are explicit inputs. Local checkout
# bytes and local Git metadata are never an external trust anchor.
readonly env_bin=/usr/bin/env git_bin=/usr/bin/git realpath_bin=/usr/bin/realpath
readonly stat_bin=/usr/bin/stat awk_bin=/usr/bin/gawk mkdir_bin=/usr/bin/mkdir
readonly chmod_bin=/usr/bin/chmod chown_bin=/usr/bin/chown cp_bin=/usr/bin/cp
readonly mv_bin=/usr/bin/mv mktemp_bin=/usr/bin/mktemp rm_bin=/usr/bin/rm
readonly id_bin=/usr/bin/id getent_bin=/usr/bin/getent
readonly trusted_path=/usr/sbin:/usr/bin:/sbin:/bin
fail() { echo "install-trusted-launcher: $*" >&2; exit 2; }
usage() {
  cat >&2 <<'EOF'
Usage: install-trusted-launcher.sh --origin HTTPS_URL --commit SHA
  [--run-as-user USER] [--re-pin]
  [--fixture-root PATH --fixture-transport PATH --fixture-home PATH]
  [--fixture-runtime-uid UID --fixture-runtime-gid GID]
  [--fixture-policy-ready PATH --fixture-policy-continue PATH]
  [--fixture-entry-ready PATH --fixture-entry-continue PATH]
  [--fixture-receipt-pause-phase NAME --fixture-receipt-pause-ready PATH
   --fixture-receipt-pause-continue PATH]
EOF
  exit 2
}
origin=''; commit=''; run_as_user=''; re_pin=0
fixture_root=''; fixture_transport=''; fixture_home=''
fixture_runtime_uid=''; fixture_runtime_gid=''
policy_ready=''; policy_continue=''; entry_ready=''; entry_continue=''
fixture_receipt_pause_phase=''; fixture_receipt_pause_ready=''; fixture_receipt_pause_continue=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --origin) [[ $# -ge 2 ]] || usage; origin="$2"; shift 2 ;;
    --commit) [[ $# -ge 2 ]] || usage; commit="$2"; shift 2 ;;
    --run-as-user) [[ $# -ge 2 ]] || usage; run_as_user="$2"; shift 2 ;;
    --re-pin) re_pin=1; shift ;;
    --fixture-root) [[ $# -ge 2 ]] || usage; fixture_root="$2"; shift 2 ;;
    --fixture-transport) [[ $# -ge 2 ]] || usage; fixture_transport="$2"; shift 2 ;;
    --fixture-home) [[ $# -ge 2 ]] || usage; fixture_home="$2"; shift 2 ;;
    --fixture-runtime-uid) [[ $# -ge 2 ]] || usage; fixture_runtime_uid="$2"; shift 2 ;;
    --fixture-runtime-gid) [[ $# -ge 2 ]] || usage; fixture_runtime_gid="$2"; shift 2 ;;
    --fixture-policy-ready) [[ $# -ge 2 ]] || usage; policy_ready="$2"; shift 2 ;;
    --fixture-policy-continue) [[ $# -ge 2 ]] || usage; policy_continue="$2"; shift 2 ;;
    --fixture-entry-ready) [[ $# -ge 2 ]] || usage; entry_ready="$2"; shift 2 ;;
    --fixture-entry-continue) [[ $# -ge 2 ]] || usage; entry_continue="$2"; shift 2 ;;
    --fixture-receipt-pause-phase) [[ $# -ge 2 ]] || usage; fixture_receipt_pause_phase="$2"; shift 2 ;;
    --fixture-receipt-pause-ready) [[ $# -ge 2 ]] || usage; fixture_receipt_pause_ready="$2"; shift 2 ;;
    --fixture-receipt-pause-continue) [[ $# -ge 2 ]] || usage; fixture_receipt_pause_continue="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$origin" && -n "$commit" ]] || usage
[[ "$origin" =~ ^https://[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+/[A-Za-z0-9._~-]+(/[A-Za-z0-9._~-]+)*\.git$ &&
  "$origin" != *..* && "$origin" != *@* ]] || fail 'origin is not canonical HTTPS Git grammar'
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || fail 'commit must be a full lowercase object identifier'
[[ -z "$run_as_user" || "$run_as_user" =~ ^[A-Za-z0-9_.-]+$ ]] || fail 'runtime user name is not canonical'
[[ -z "$fixture_runtime_uid" || "$fixture_runtime_uid" =~ ^[0-9]+$ ]] || fail 'fixture runtime uid is not numeric'
[[ -z "$fixture_runtime_gid" || "$fixture_runtime_gid" =~ ^[0-9]+$ ]] || fail 'fixture runtime gid is not numeric'
[[ -z "$fixture_receipt_pause_phase" || "$fixture_receipt_pause_phase" =~ ^[A-Za-z0-9._-]+$ ]] ||
  fail 'fixture receipt pause phase is not canonical'
[[ -x "$awk_bin" ]] ||
  fail 'gawk is required before provisioning; install and verify /usr/bin/gawk out of band'
for value in "$fixture_root" "$fixture_transport" "$fixture_home" "$policy_ready" "$policy_continue" "$entry_ready" "$entry_continue" "$fixture_receipt_pause_ready" "$fixture_receipt_pause_continue"; do
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* && "$value" != *"'"* && "$value" != *'\'* ]] ||
    fail 'path contains unsupported characters'
done

assert_components() {
  local path="$1" component current='/'
  local -a components
  [[ "$path" == /* ]] || return 1
  IFS='/' read -r -a components <<< "${path#/}"
  for component in "${components[@]}"; do
    [[ -z "$component" || "$component" == '.' ]] && continue
    [[ "$component" != '..' && "$component" != *'/'* ]] || return 1
    current="$current/$component"
    [[ ! -L "$current" ]] || return 1
  done
}
assert_secure_dir() {
  local path="$1" owner group mode
  assert_components "$path" || fail "system path has a symlinked component: $path"
  [[ -d "$path" && ! -L "$path" ]] || fail "system path is not a real directory: $path"
  owner="$($stat_bin -c %u -- "$path")"; group="$($stat_bin -c %g -- "$path")"; mode="$($stat_bin -c %a -- "$path")"
  [[ "$owner" == "$expected_uid" && "$group" == "$expected_gid" && "$mode" == 755 ]] ||
    fail "system path owner or mode is unsafe: $path"
}
path() { printf '%s/%s\n' "$prefix" "${1#/}"; }

[[ -z "$fixture_root" || ( "$fixture_root" == /* && "$fixture_root" != / ) ]] ||
  fail 'fixture root must be an absolute non-root path'
if [[ -z "$fixture_root" ]]; then
  [[ "$($id_bin -u)" == 0 ]] || fail 'production provisioning requires root'
  [[ -n "$run_as_user" ]] || fail 'production provisioning requires --run-as-user'
  [[ -z "$fixture_transport" && -z "$policy_ready" && -z "$policy_continue" &&
    -z "$entry_ready" && -z "$entry_continue" && -z "$fixture_runtime_uid" &&
    -z "$fixture_runtime_gid" && -z "$fixture_receipt_pause_phase" &&
    -z "$fixture_receipt_pause_ready" && -z "$fixture_receipt_pause_continue" ]] ||
    fail 'fixture-only options are not permitted in production'
  prefix=''; expected_uid=0; expected_gid=0; system_uid=0; system_gid=0
  runtime_uid="$($id_bin -u "$run_as_user" 2>/dev/null || true)"
  runtime_gid="$($id_bin -g "$run_as_user" 2>/dev/null || true)"
  runtime_home="$($getent_bin passwd "$run_as_user" |
    "$awk_bin" -F: 'NF >= 6 { print $6; found++ } END { exit(found == 1 ? 0 : 1) }' || true)"
  [[ "$runtime_uid" =~ ^[0-9]+$ && "$runtime_gid" =~ ^[0-9]+$ && "$runtime_uid" != 0 &&
    "$runtime_home" == /* && "$runtime_home" != / ]] ||
    fail 'runtime user does not resolve to a non-root account with a safe home'
else
  prefix="$($realpath_bin -e -- "$fixture_root" 2>/dev/null || true)"
  [[ "$prefix" == "$fixture_root" && -d "$prefix" && ! -L "$prefix" ]] ||
    fail 'fixture root must be an existing real directory'
  expected_uid="$($id_bin -u)"; expected_gid="$($id_bin -g)"
  runtime_uid="${fixture_runtime_uid:-$expected_uid}"
  runtime_gid="${fixture_runtime_gid:-$expected_gid}"
  runtime_home=''
  system_uid="$($stat_bin -c %u /usr/bin/bash 2>/dev/null || true)"
  system_gid="$($stat_bin -c %g /usr/bin/bash 2>/dev/null || true)"
  [[ "$system_uid" =~ ^[0-9]+$ && "$system_gid" =~ ^[0-9]+$ ]] ||
    fail 'fixture system binary owner is unavailable'
fi
[[ "$runtime_uid" =~ ^[0-9]+$ && "$runtime_gid" =~ ^[0-9]+$ ]] ||
  fail 'runtime identity must be numeric'
if [[ -z "$fixture_root" ]]; then
  [[ "$runtime_uid" != 0 ]] || fail 'production runtime identity must be non-root'
fi

if [[ -n "$fixture_root" ]]; then
  [[ -n "$fixture_transport" && "$fixture_transport" == "$prefix/"* ]] ||
    fail 'fixture transport must be inside the sealed fixture root'
  assert_components "$fixture_transport" || fail 'fixture transport has a symlinked component'
  [[ -d "$fixture_transport" && ! -L "$fixture_transport" ]] ||
    fail 'fixture transport is not a directory'
  [[ "$($stat_bin -c '%u:%g:%a' -- "$fixture_transport")" == "$expected_uid:$expected_gid:700" ]] ||
    fail 'fixture transport is not sealed'
  [[ -n "$fixture_home" && "$fixture_home" == "$prefix/"* &&
    -d "$fixture_home" && ! -L "$fixture_home" ]] || fail 'fixture home is unsafe'
  assert_components "$fixture_home" || fail 'fixture home has a symlinked or non-canonical component'
  runtime_home="$($realpath_bin -e -- "$fixture_home" 2>/dev/null || true)"
  [[ "$runtime_home" == "$prefix/"* && "$runtime_home" != "$prefix" ]] ||
    fail 'fixture home escaped the sealed fixture root'
  [[ "$($stat_bin -c '%u:%g' -- "$runtime_home")" == "$runtime_uid:$runtime_gid" ]] ||
    fail 'fixture home ownership does not match the runtime identity'
fi
runtime_home="$($realpath_bin -e -- "$runtime_home" 2>/dev/null || true)"
[[ "$runtime_home" != *$'\n'* && "$runtime_home" != *$'\r'* &&
  "$runtime_home" != *"'"* && "$runtime_home" != *'\'* ]] ||
  fail 'runtime home contains unsupported characters'
assert_components "$runtime_home" || fail 'runtime home has a symlinked component'
[[ -d "$runtime_home" && ! -L "$runtime_home" &&
  "$($stat_bin -c '%u:%g' -- "$runtime_home")" == "$runtime_uid:$runtime_gid" ]] ||
  fail 'runtime home is not owned by the selected account'
for path_value in "$policy_ready" "$policy_continue" "$entry_ready" "$entry_continue" "$fixture_receipt_pause_ready" "$fixture_receipt_pause_continue"; do
  [[ -z "$path_value" || ( "$path_value" == "$prefix/"* && "$path_value" == /* ) ]] ||
    fail 'fixture pause paths must be inside fixture root'
done
if [[ -n "$fixture_receipt_pause_phase" ]]; then
  [[ -n "$fixture_root" && -n "$fixture_receipt_pause_ready" && -n "$fixture_receipt_pause_continue" ]] ||
    fail 'fixture receipt pause requires a fixture root and synchronization paths'
else
  [[ -z "$fixture_receipt_pause_ready" && -z "$fixture_receipt_pause_continue" ]] ||
    fail 'fixture receipt pause paths require a phase'
fi

policy_dir="$(path /etc/herdr-workstation)"
libexec_dir="$(path /usr/local/libexec)"
stage_root="$(path /var/lib/herdr-workstation/bootstrap/staging)"
launcher_target="$(path /usr/local/libexec/herdr-workstation-bootstrap)"
policy_target="$(path /etc/herdr-workstation/bootstrap-policy.conf)"
for system_dir in "$policy_dir" "$libexec_dir" "$stage_root"; do
  assert_components "$system_dir" || fail "system path has a symlinked component: $system_dir"
  "$mkdir_bin" -p -- "$system_dir"
  "$chmod_bin" 0755 -- "$system_dir"
  [[ -n "$fixture_root" ]] || "$chown_bin" 0:0 -- "$system_dir"
done
assert_secure_dir "$policy_dir"; assert_secure_dir "$libexec_dir"; assert_secure_dir "$stage_root"

if [[ "$re_pin" == 0 ]]; then
  [[ ! -e "$launcher_target" && ! -L "$launcher_target" ]] ||
    fail "one-time installation target already exists: $launcher_target"
  [[ ! -e "$policy_target" && ! -L "$policy_target" ]] ||
    fail "one-time installation target already exists: $policy_target"
else
  [[ -f "$launcher_target" && ! -L "$launcher_target" &&
    "$($stat_bin -c '%u:%g:%a' -- "$launcher_target")" == "$expected_uid:$expected_gid:755" ]] ||
    fail 'existing launcher is not safe to re-pin'
  [[ -f "$policy_target" && ! -L "$policy_target" &&
    "$($stat_bin -c '%u:%g:%a' -- "$policy_target")" == "$expected_uid:$expected_gid:600" ]] ||
    fail 'existing policy is not safe to re-pin'
fi

provision_root="$($mktemp_bin -d "$stage_root/.provision.XXXXXX")"
cleanup() {
  local status="$1"
  set +e
  [[ -n "${provision_root:-}" && -d "$provision_root" ]] && "$rm_bin" -rf -- "$provision_root"
  return "$status"
}
trap 'cleanup "$?"' EXIT
"$chmod_bin" 0700 -- "$provision_root"
[[ -n "$fixture_root" ]] || "$chown_bin" 0:0 -- "$provision_root"

git_safe() {
  "$env_bin" -i HOME=/nonexistent PATH="$trusted_path" LC_ALL=C TZ=UTC \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    GIT_CONFIG_COUNT=0 GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/false \
    "$git_bin" --no-replace-objects -c core.attributesfile=/dev/null \
    -c core.excludesfile=/dev/null -c core.hooksPath=/dev/null \
    -c core.filemode=true -c core.ignoreCase=false -c protocol.file.allow=always "$@"
}

fetch_source="$origin"
if [[ -n "$fixture_root" ]]; then
  [[ -n "$fixture_transport" ]] || fail 'fixture transport is required'
  fetch_source="$fixture_transport"
fi
fetch_repo="$provision_root/fetched"
git_safe init --quiet "$fetch_repo"
git_safe -C "$fetch_repo" remote add origin "$origin"
git_safe -C "$fetch_repo" fetch --no-tags --no-auto-gc "$fetch_source" "$commit" >/dev/null ||
  fail 'approved commit could not be fetched from the supplied origin transport'
fetched_commit="$(git_safe -C "$fetch_repo" rev-parse --verify FETCH_HEAD^{commit} 2>/dev/null || true)"
[[ "$fetched_commit" == "$commit" ]] || fail 'fetched object is not the exact approved commit'
git_safe -C "$fetch_repo" checkout --quiet --detach --force "$commit"
[[ "$(git_safe -C "$fetch_repo" rev-parse --verify HEAD^{commit})" == "$commit" &&
  "$(git_safe -C "$fetch_repo" cat-file -t "$commit")" == commit ]] ||
  fail 'root-owned fetched repository did not materialize the approved commit'
[[ "$($stat_bin -c '%u:%g' -- "$fetch_repo")" == "$expected_uid:$expected_gid" ]] ||
  fail 'fetched repository is not owned by the provisioning owner'
[[ "$($stat_bin -c '%u:%g:%a' -- "$fetch_repo/.git")" == "$expected_uid:$expected_gid:755" ]] ||
  fail 'fetched Git metadata is unsafe'

template_tree="$(git_safe -C "$fetch_repo" ls-tree "$commit" -- scripts/ubuntu/trusted-launcher.sh)"
[[ "$template_tree" != *$'\n'* ]] || fail 'launcher template lookup was ambiguous'
IFS=$'\t' read -r template_meta template_path <<< "$template_tree"
read -r template_mode template_type template_oid <<< "$template_meta"
[[ "$template_path" == scripts/ubuntu/trusted-launcher.sh &&
  "$template_mode" == 100755 && "$template_type" == blob &&
  "$template_oid" =~ ^[0-9a-f]{40}$ ]] || fail 'approved commit lacks an executable launcher template'
git_safe -C "$fetch_repo" cat-file -e "$template_oid^{blob}"
template_stage="$provision_root/trusted-launcher.sh"
git_safe -C "$fetch_repo" cat-file blob "$template_oid" > "$template_stage"
[[ "$(git_safe -C "$fetch_repo" hash-object --no-filters --stdin < "$template_stage")" == "$template_oid" ]] ||
  fail 'fetched launcher bytes differ from the committed blob'
"$chmod_bin" 0755 -- "$template_stage"
[[ "$($stat_bin -c '%u:%g:%a' -- "$template_stage")" == "$expected_uid:$expected_gid:755" ]] ||
  fail 'materialized launcher is not owner-bound'

rendered="$provision_root/rendered-launcher"
"$awk_bin" -v prefix="$prefix" -v uid="$expected_uid" -v gid="$expected_gid" \
  -v ruid="$runtime_uid" -v rgid="$runtime_gid" -v suid="$system_uid" -v sgid="$system_gid" \
  -v transport="$fixture_transport" -v home="$runtime_home" \
  -v pr="$policy_ready" -v pc="$policy_continue" -v er="$entry_ready" -v ec="$entry_continue" \
  -v rpp="$fixture_receipt_pause_phase" -v rpr="$fixture_receipt_pause_ready" -v rpc="$fixture_receipt_pause_continue" '
  /^readonly launcher_system_prefix=/ { printf "readonly launcher_system_prefix='\''%s'\''\n", prefix; next }
  /^readonly launcher_expected_uid=/ { printf "readonly launcher_expected_uid='\''%s'\''\n", uid; next }
  /^readonly launcher_expected_gid=/ { printf "readonly launcher_expected_gid='\''%s'\''\n", gid; next }
  /^readonly launcher_runtime_uid=/ { printf "readonly launcher_runtime_uid='\''%s'\''\n", ruid; next }
  /^readonly launcher_runtime_gid=/ { printf "readonly launcher_runtime_gid='\''%s'\''\n", rgid; next }
  /^readonly launcher_system_uid=/ { printf "readonly launcher_system_uid='\''%s'\''\n", suid; next }
  /^readonly launcher_system_gid=/ { printf "readonly launcher_system_gid='\''%s'\''\n", sgid; next }
  /^readonly launcher_fixture_transport=/ { printf "readonly launcher_fixture_transport='\''%s'\''\n", transport; next }
  /^readonly launcher_fixture_home=/ { printf "readonly launcher_fixture_home='\''%s'\''\n", home; next }
  /^readonly launcher_policy_pause_ready=/ { printf "readonly launcher_policy_pause_ready='\''%s'\''\n", pr; next }
  /^readonly launcher_policy_pause_continue=/ { printf "readonly launcher_policy_pause_continue='\''%s'\''\n", pc; next }
  /^readonly launcher_entry_pause_ready=/ { printf "readonly launcher_entry_pause_ready='\''%s'\''\n", er; next }
  /^readonly launcher_entry_pause_continue=/ { printf "readonly launcher_entry_pause_continue='\''%s'\''\n", ec; next }
  /^readonly launcher_fixture_receipt_pause_phase=/ { printf "readonly launcher_fixture_receipt_pause_phase='\''%s'\''\n", rpp; next }
  /^readonly launcher_fixture_receipt_pause_ready=/ { printf "readonly launcher_fixture_receipt_pause_ready='\''%s'\''\n", rpr; next }
  /^readonly launcher_fixture_receipt_pause_continue=/ { printf "readonly launcher_fixture_receipt_pause_continue='\''%s'\''\n", rpc; next }
  { print }
' "$template_stage" > "$rendered"
"$chmod_bin" 0755 -- "$rendered"

publish() {
  local source="$1" target="$2" mode="$3" parent tmp
  parent="${target%/*}"
  [[ "$parent" != "$target" ]] || parent=/
  tmp="$($mktemp_bin "$parent/.herdr-bootstrap-publish.XXXXXX")"
  "$cp_bin" -- "$source" "$tmp"
  "$chmod_bin" "$mode" -- "$tmp"
  [[ -n "$fixture_root" ]] || "$chown_bin" 0:0 -- "$tmp"
  "$mv_bin" -T -- "$tmp" "$target"
  [[ -f "$target" && ! -L "$target" ]] || fail "atomic publication failed: $target"
}

policy_tmp="$provision_root/bootstrap-policy.conf"
printf 'herdr-bootstrap-policy-v1\norigin=%s\ncommit=%s\n' "$origin" "$commit" > "$policy_tmp"
"$chmod_bin" 0600 -- "$policy_tmp"
[[ -n "$fixture_root" ]] || "$chown_bin" 0:0 -- "$policy_tmp"
publish "$policy_tmp" "$policy_target" 0600
publish "$rendered" "$launcher_target" 0755
[[ "$($stat_bin -c '%u:%g:%a' -- "$policy_target")" == "$expected_uid:$expected_gid:600" &&
  "$($stat_bin -c '%u:%g:%a' -- "$launcher_target")" == "$expected_uid:$expected_gid:755" ]] ||
  fail 'published ownership or mode changed'
printf 'launcher=%s\npolicy=%s\nstaging=%s\norigin=%s\ncommit=%s\n' \
  "$launcher_target" "$policy_target" "$stage_root" "$origin" "$commit"
