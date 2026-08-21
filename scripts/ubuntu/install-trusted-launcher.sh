#!/usr/bin/env -S -i BASH_ENV= ENV= CDPATH= PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C TZ=UTC /usr/bin/bash
set -euo pipefail
umask 022

# This is the one-time administrative provisioning surface. It renders an
# external launcher and a root-owned policy; it never writes system locations
# unless the administrator explicitly invokes it.
readonly env_bin=/usr/bin/env git_bin=/usr/bin/git realpath_bin=/usr/bin/realpath stat_bin=/usr/bin/stat
readonly awk_bin=/usr/bin/gawk mkdir_bin=/usr/bin/mkdir chmod_bin=/usr/bin/chmod chown_bin=/usr/bin/chown
readonly cp_bin=/usr/bin/cp mv_bin=/usr/bin/mv mktemp_bin=/usr/bin/mktemp rm_bin=/usr/bin/rm id_bin=/usr/bin/id getent_bin=/usr/bin/getent
readonly find_bin=/usr/bin/find
readonly trusted_path=/usr/sbin:/usr/bin:/sbin:/bin
fail() { echo "install-trusted-launcher: $*" >&2; exit 2; }
usage() {
  cat >&2 <<'EOF'
Usage: install-trusted-launcher.sh --source-root PATH --origin HTTPS_URL --commit SHA
  [--run-as-user USER]
  [--fixture-root PATH --fixture-transport PATH --fixture-home PATH]
  [--fixture-policy-ready PATH --fixture-policy-continue PATH]
  [--fixture-entry-ready PATH --fixture-entry-continue PATH]
EOF
  exit 2
}
source_root=''; origin=''; commit=''; run_as_user=''; fixture_root=''; fixture_transport=''; fixture_home=''
policy_ready=''; policy_continue=''; entry_ready=''; entry_continue=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-root) [[ $# -ge 2 ]] || usage; source_root=$2; shift 2 ;;
    --origin) [[ $# -ge 2 ]] || usage; origin=$2; shift 2 ;;
    --commit) [[ $# -ge 2 ]] || usage; commit=$2; shift 2 ;;
    --run-as-user) [[ $# -ge 2 ]] || usage; run_as_user=$2; shift 2 ;;
    --fixture-root) [[ $# -ge 2 ]] || usage; fixture_root=$2; shift 2 ;;
    --fixture-transport) [[ $# -ge 2 ]] || usage; fixture_transport=$2; shift 2 ;;
    --fixture-home) [[ $# -ge 2 ]] || usage; fixture_home=$2; shift 2 ;;
    --fixture-policy-ready) [[ $# -ge 2 ]] || usage; policy_ready=$2; shift 2 ;;
    --fixture-policy-continue) [[ $# -ge 2 ]] || usage; policy_continue=$2; shift 2 ;;
    --fixture-entry-ready) [[ $# -ge 2 ]] || usage; entry_ready=$2; shift 2 ;;
    --fixture-entry-continue) [[ $# -ge 2 ]] || usage; entry_continue=$2; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n $source_root && -n $origin && -n $commit ]] || usage
[[ $source_root == /* && $origin =~ ^https://[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+/[A-Za-z0-9._~-]+(/[A-Za-z0-9._~-]+)*\.git$ && $origin != *..* && $origin != *@* ]] || fail 'origin is not canonical HTTPS Git grammar'
[[ $commit =~ ^[0-9a-f]{40}$ ]] || fail 'commit must be a full lowercase object identifier'
[[ -z $run_as_user || $run_as_user =~ ^[A-Za-z0-9_.-]+$ ]] || fail 'runtime user name is not canonical'
for v in "$source_root" "$fixture_root" "$fixture_transport" "$fixture_home" "$policy_ready" "$policy_continue" "$entry_ready" "$entry_continue"; do
  [[ "$v" != *$'\n'* && "$v" != *$'\r'* && "$v" != *"'"* && "$v" != *'\\'* ]] || fail 'path contains unsupported characters'
done
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
assert_secure_dir() {
  local p="$1" mode owner group
  assert_components "$p" || fail "system path has a symlinked component: $p"
  [[ -d "$p" && ! -L "$p" ]] || fail "system path is not a real directory: $p"
  owner="$($stat_bin -c %u -- "$p")"; group="$($stat_bin -c %g -- "$p")"; mode="$($stat_bin -c %a -- "$p")"
  [[ "$owner" == "$expected_uid" && "$group" == "$expected_gid" && "$mode" == 755 ]] || fail "system path owner or mode is unsafe: $p"
}
path() { printf '%s/%s\n' "$prefix" "${1#/}"; }
origin_check() { :; }
[[ $fixture_root == '' || ( $fixture_root == /* && $fixture_root != / ) ]] || fail 'fixture root must be an absolute non-root path'
if [[ -z $fixture_root ]]; then
  [[ "$($id_bin -u)" == 0 ]] || fail 'production provisioning requires root'
  [[ -n $run_as_user ]] || fail 'production provisioning requires --run-as-user'
  prefix=''; expected_uid=0; expected_gid=0; system_uid=0; system_gid=0
  runtime_uid="$($id_bin -u "$run_as_user" 2>/dev/null || true)"
  runtime_gid="$($id_bin -g "$run_as_user" 2>/dev/null || true)"
  runtime_home="$($getent_bin passwd "$run_as_user" | "$awk_bin" -F: 'NF >= 6 { print $6; found++ } END { exit(found == 1 ? 0 : 1) }' || true)"
  [[ $runtime_uid =~ ^[0-9]+$ && $runtime_gid =~ ^[0-9]+$ && $runtime_uid != 0 && $runtime_home == /* && $runtime_home != / ]] || fail 'runtime user does not resolve to a non-root account with a safe home'
else
  prefix="$($realpath_bin -e -- "$fixture_root" 2>/dev/null || true)"
  [[ $prefix == "$fixture_root" && -d $prefix && ! -L $prefix ]] || fail 'fixture root must be an existing real directory'
  expected_uid="$($id_bin -u)"; expected_gid="$($id_bin -g)"
  runtime_uid="$expected_uid"; runtime_gid="$expected_gid"; runtime_home=''
  system_uid="$($stat_bin -c %u /usr/bin/bash 2>/dev/null || true)"
  system_gid="$($stat_bin -c %g /usr/bin/bash 2>/dev/null || true)"
  [[ $system_uid =~ ^[0-9]+$ && $system_gid =~ ^[0-9]+$ ]] || fail 'fixture system binary owner is unavailable'
fi
assert_components "$source_root" || fail 'source root has a symlinked component'
source_root="$($realpath_bin -e -- "$source_root" 2>/dev/null || true)"
[[ -n $source_root && -d $source_root && ! -L $source_root ]] || fail 'source root is not a real directory'
template="$source_root/scripts/ubuntu/trusted-launcher.sh"
[[ -f $template && ! -L $template && -x $template ]] || fail 'launcher template is missing or not executable'
template="$($realpath_bin -e -- "$template" 2>/dev/null || true)"
[[ $template == "$source_root/scripts/ubuntu/trusted-launcher.sh" ]] || fail 'launcher template path is not canonical'
declare -a installer_git_bound_paths=()
declare -A installer_git_bound_identities=()
installer_git_owner_uid=''; installer_git_owner_gid=''; installer_git_dir=''; installer_common_git_dir=''; installer_worktree_record=''
installer_bind_git_path() {
  local p="$1" owner group mode identity
  [[ -e "$p" && ! -L "$p" ]] || return 1
  owner="$($stat_bin -c %u -- "$p" 2>/dev/null || true)"
  group="$($stat_bin -c %g -- "$p" 2>/dev/null || true)"
  mode="$($stat_bin -c %a -- "$p" 2>/dev/null || true)"
  [[ "$owner" == "$installer_git_owner_uid" && "$group" == "$installer_git_owner_gid" && "$mode" =~ ^[0-7]+$ && $((8#$mode & 022)) == 0 ]] || return 1
  identity="$($stat_bin -Lc '%u:%g:%a:%d:%i:%F' -- "$p" 2>/dev/null || true)"
  [[ -n "$identity" ]] || return 1
  if [[ -z "${installer_git_bound_identities[$p]+x}" ]]; then installer_git_bound_paths+=("$p"); fi
  installer_git_bound_identities["$p"]="$identity"
}
installer_bind_optional_git_path() { [[ -e "$1" ]] || return 0; installer_bind_git_path "$1"; }
installer_assert_git_lifetime() {
  local p i
  local -a identities=()
  ((${#installer_git_bound_paths[@]} > 0)) || return 1
  mapfile -t identities < <("$stat_bin" -Lc '%u:%g:%a:%d:%i:%F' -- "${installer_git_bound_paths[@]}" 2>/dev/null) || return 1
  ((${#identities[@]} == ${#installer_git_bound_paths[@]})) || return 1
  for i in "${!installer_git_bound_paths[@]}"; do
    p="${installer_git_bound_paths[$i]}"
    [[ "${identities[$i]}" == "${installer_git_bound_identities[$p]:-}" ]] || return 1
  done
}
installer_validate_git_layout() {
  local metadata="$source_root/.git" pointer pointer_path commondir_spec record_pointer other_record other_pointer
  [[ -e "$metadata" && ! -L "$metadata" && ( -d "$metadata" || -f "$metadata" ) ]] || return 1
  installer_git_owner_uid="$($stat_bin -c %u -- "$metadata")"
  installer_git_owner_gid="$($stat_bin -c %g -- "$metadata")"
  [[ "$installer_git_owner_uid" =~ ^[0-9]+$ && "$installer_git_owner_gid" =~ ^[0-9]+$ ]] || return 1
  if [[ -d "$metadata" ]]; then
    installer_git_dir="$metadata"; installer_common_git_dir="$metadata"
  else
    pointer="$(< "$metadata")"
    [[ "$pointer" != *$'\n'* && "$pointer" != *$'\r'* && "$pointer" == gitdir:\ /* ]] || return 1
    pointer_path="${pointer#gitdir: }"
    installer_git_dir="$($realpath_bin -e -- "$pointer_path" 2>/dev/null || true)"
    [[ -n "$installer_git_dir" && "$pointer" == "gitdir: $installer_git_dir" && -d "$installer_git_dir" && ! -L "$installer_git_dir" ]] || return 1
    [[ -f "$installer_git_dir/commondir" && ! -L "$installer_git_dir/commondir" ]] || return 1
    commondir_spec="$(< "$installer_git_dir/commondir")"
    [[ "$commondir_spec" == ../.. ]] || return 1
    installer_common_git_dir="$($realpath_bin -e -- "$installer_git_dir/$commondir_spec" 2>/dev/null || true)"
    installer_worktree_record="$installer_common_git_dir/worktrees/${installer_git_dir##*/}"
    [[ -d "$installer_common_git_dir/worktrees" && ! -L "$installer_common_git_dir/worktrees" && \
      "$($realpath_bin -e -- "$installer_worktree_record" 2>/dev/null || true)" == "$installer_git_dir" && \
      -f "$installer_git_dir/gitdir" && ! -L "$installer_git_dir/gitdir" ]] || return 1
    record_pointer="$(< "$installer_git_dir/gitdir")"
    [[ "$record_pointer" != *$'\n'* && "$record_pointer" != *$'\r'* && \
      "$($realpath_bin -e -- "$record_pointer" 2>/dev/null || true)" == "$metadata" ]] || return 1
    while IFS= read -r -d '' other_record; do
      [[ "${other_record%/gitdir}" == "$installer_git_dir" ]] && continue
      other_pointer="$(< "$other_record")"
      [[ "$other_pointer" != *$'\n'* && "$other_pointer" != *$'\r'* && \
        "$($realpath_bin -e -- "$other_pointer" 2>/dev/null || true)" != "$metadata" ]] || return 1
    done < <("$find_bin" -P "$installer_common_git_dir/worktrees" -mindepth 2 -maxdepth 2 -type f -name gitdir -print0 2>/dev/null)
  fi
  [[ -d "$installer_common_git_dir" && ! -L "$installer_common_git_dir" && \
    -d "$installer_common_git_dir/objects" && ! -L "$installer_common_git_dir/objects" && \
    -d "$installer_common_git_dir/refs" && ! -L "$installer_common_git_dir/refs" && \
    -f "$installer_common_git_dir/config" && ! -L "$installer_common_git_dir/config" && \
    -f "$installer_git_dir/index" && ! -L "$installer_git_dir/index" ]] || return 1
  installer_bind_git_path "$source_root" || return 1
  installer_bind_git_path "$metadata" || return 1
  for installer_git_binding_path in "$installer_git_dir" "$installer_common_git_dir" "$installer_common_git_dir/objects" \
    "$installer_common_git_dir/refs" "$installer_common_git_dir/config" "$installer_git_dir/index"; do
    installer_bind_git_path "$installer_git_binding_path" || return 1
  done
  for installer_git_binding_path in "$installer_git_dir/commondir" "$installer_git_dir/gitdir" \
    "$installer_common_git_dir/worktrees" "$installer_git_dir/HEAD" "$installer_common_git_dir/HEAD" \
    "$installer_common_git_dir/packed-refs"; do
    installer_bind_optional_git_path "$installer_git_binding_path" || return 1
  done
  if [[ -n "$installer_worktree_record" ]]; then
    installer_bind_git_path "$installer_worktree_record" || return 1
    installer_bind_git_path "$installer_worktree_record/gitdir" || return 1
  fi
}
installer_trust_git() {
  local status
  installer_assert_git_lifetime || return 70
  if "$env_bin" -i HOME=/nonexistent PATH="$trusted_path" LC_ALL=C TZ=UTC \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_COUNT=0 \
    GIT_OPTIONAL_LOCKS=0 \
    "$git_bin" --no-replace-objects -C "$source_root" --git-dir="$installer_git_dir" --work-tree=. \
    -c core.attributesfile=/dev/null -c core.excludesfile=/dev/null -c core.hooksPath=/dev/null \
    -c core.filemode=true -c core.ignoreCase=false "$@"; then
    status=0
  else
    status=$?
  fi
  installer_assert_git_lifetime || return 70
  return "$status"
}
installer_trust_git_optional() {
  local output status
  output="$(installer_trust_git "$@" 2>/dev/null)" || {
    status=$?
    ((status == 1)) || return "$status"
  }
  printf '%s\n' "$output"
}
installer_validate_git_layout || fail 'source Git metadata is not an owner-bound stable local worktree'
installer_dangerous_config="$(installer_trust_git_optional config --local --no-includes --name-only --get-regexp \
  '^(include|filter\.|diff\..*\.textconv$|merge\..*\.driver$|credential\.|url\..*\.insteadOf$|core\.(attributesfile|excludesfile|fsmonitor|hooksPath|worktree|alternateRefsCommand|askPass|gitProxy|sshCommand)$|extensions\.|remote\..*\.(promisor|partialclonefilter|uploadpack|receivepack)$)')"
[[ -z "$installer_dangerous_config" ]] || fail 'source Git configuration contains executable or indirection settings'
git_clean="$(installer_trust_git status --porcelain --untracked-files=all 2>/dev/null)" || fail 'source Git lifetime failed while reading checkout status'
[[ -z $git_clean ]] || fail 'source root must be clean before provisioning'
source_commit="$(installer_trust_git rev-parse --verify HEAD^{commit} 2>/dev/null)" || fail 'source Git lifetime failed while reading HEAD'
[[ $source_commit == "$commit" ]] || fail 'source HEAD does not equal the approved commit'
source_origin="$(installer_trust_git config --local --no-includes --get remote.origin.url 2>/dev/null)" || fail 'source Git lifetime failed while reading origin'
[[ $source_origin == "$origin" ]] || fail 'source origin does not equal the approved canonical origin'
template_tree="$(installer_trust_git ls-tree "$commit" -- scripts/ubuntu/trusted-launcher.sh 2>/dev/null)" || fail 'source Git lifetime failed while reading the committed launcher template'
[[ $template_tree != *$'\n'* ]] || fail 'launcher template tree lookup was ambiguous'
IFS=$'\t' read -r template_meta template_path <<< "$template_tree"
read -r template_mode template_type template_oid <<< "$template_meta"
[[ $template_path == scripts/ubuntu/trusted-launcher.sh && $template_mode == 100755 && $template_type == blob && $template_oid =~ ^[0-9a-f]{40}$ ]] || fail 'approved commit does not contain an executable launcher template'
installer_trust_git cat-file -e "$template_oid^{blob}" || fail 'approved launcher template blob is unavailable'
template_stage="$($mktemp_bin)"
installer_trust_git cat-file blob "$template_oid" > "$template_stage" || fail 'approved launcher template could not be materialized'
template_materialized_oid="$(installer_trust_git hash-object --no-filters --stdin < "$template_stage")" || fail 'approved launcher template hash could not be verified'
[[ $template_materialized_oid == "$template_oid" ]] || fail 'approved launcher template bytes differ from its committed object'
if [[ -n $fixture_root ]]; then
  [[ -n $fixture_transport && $fixture_transport == "$prefix/"* ]] || fail 'fixture transport must be inside the sealed fixture root'
  assert_components "$fixture_transport"; [[ -d $fixture_transport && ! -L $fixture_transport ]] || fail 'fixture transport is not a directory'
  [[ "$($stat_bin -c %u "$fixture_transport")" == "$expected_uid" && "$($stat_bin -c %g "$fixture_transport")" == "$expected_gid" && "$($stat_bin -c %a "$fixture_transport")" == 700 ]] || fail 'fixture transport is not sealed'
  [[ -n $fixture_home && $fixture_home == "$prefix/"* && -d $fixture_home && ! -L $fixture_home ]] || fail 'fixture home must be inside fixture root'
  runtime_home="$($realpath_bin -e -- "$fixture_home" 2>/dev/null || true)"
  [[ "$($stat_bin -c %u "$runtime_home")" == "$runtime_uid" && "$($stat_bin -c %g "$runtime_home")" == "$runtime_gid" ]] || fail 'fixture home ownership does not match the runtime identity'
else
  [[ -z $fixture_transport && -z $policy_ready && -z $policy_continue && -z $entry_ready && -z $entry_continue ]] || fail 'fixture-only options are not permitted in production'
fi
assert_components "$runtime_home" || fail 'runtime home has a symlinked component'
[[ -d "$runtime_home" && ! -L "$runtime_home" && "$($stat_bin -c %u "$runtime_home")" == "$runtime_uid" && "$($stat_bin -c %g "$runtime_home")" == "$runtime_gid" ]] || fail 'runtime home is not owned by the selected account'
for p in "$policy_ready" "$policy_continue" "$entry_ready" "$entry_continue"; do
  [[ -z $p || ( $p == "$prefix/"* && $p == /* ) ]] || fail 'fixture pause paths must be inside fixture root'
done
policy_dir="$(path /etc/herdr-workstation)"; libexec_dir="$(path /usr/local/libexec)"; stage_root="$(path /var/lib/herdr-workstation/bootstrap/staging)"
launcher_target="$(path /usr/local/libexec/herdr-workstation-bootstrap)"; policy_target="$(path /etc/herdr-workstation/bootstrap-policy.conf)"
for p in "$policy_dir" "$libexec_dir" "$stage_root"; do
  assert_components "$p" || fail "system path has a symlinked component: $p"
  "$mkdir_bin" -p -- "$p"
  "$chmod_bin" 0755 -- "$p"
  [[ -z $fixture_root ]] && "$chown_bin" 0:0 -- "$p"
done
"$chmod_bin" 0755 -- "$stage_root"; [[ -z $fixture_root ]] && "$chown_bin" 0:0 -- "$stage_root"
assert_secure_dir "$policy_dir"; assert_secure_dir "$libexec_dir"; assert_secure_dir "$stage_root"
for target in "$launcher_target" "$policy_target"; do
  [[ ! -e $target && ! -L $target ]] || fail "one-time installation target already exists: $target"
done
rendered="$($mktemp_bin)"
"$awk_bin" -v prefix="$prefix" -v uid="$expected_uid" -v gid="$expected_gid" -v ruid="$runtime_uid" -v rgid="$runtime_gid" -v suid="$system_uid" -v sgid="$system_gid" -v transport="$fixture_transport" -v home="$runtime_home" -v pr="$policy_ready" -v pc="$policy_continue" -v er="$entry_ready" -v ec="$entry_continue" '
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
  { print }
' "$template_stage" >"$rendered"
"$chmod_bin" 0755 -- "$rendered"
publish() {
  local source=$1 target=$2 mode=$3 parent tmp
  parent="${target%/*}"; [[ $parent != "$target" ]] || parent=/
  tmp="$($mktemp_bin "$parent/.herdr-bootstrap-publish.XXXXXX")"
  "$cp_bin" -- "$source" "$tmp"; "$chmod_bin" "$mode" -- "$tmp"; [[ -z $fixture_root ]] && "$chown_bin" 0:0 -- "$tmp"
  # Atomic publication uses the absolute mv_bin -T operation below.
  "$mv_bin" -T -- "$tmp" "$target"
  [[ -f $target && ! -L $target ]] || fail "atomic publication failed: $target"
}
policy_tmp="$($mktemp_bin)"; printf 'herdr-bootstrap-policy-v1\norigin=%s\ncommit=%s\n' "$origin" "$commit" >"$policy_tmp"; "$chmod_bin" 0644 -- "$policy_tmp"; [[ -z $fixture_root ]] && "$chown_bin" 0:0 -- "$policy_tmp"
publish "$policy_tmp" "$policy_target" 0644
publish "$rendered" "$launcher_target" 0755
"$rm_bin" -f -- "$policy_tmp" "$rendered"
"$rm_bin" -f -- "$template_stage"
[[ "$($stat_bin -c '%u:%g:%a' "$policy_target")" == "$expected_uid:$expected_gid:644" && "$($stat_bin -c '%u:%g:%a' "$launcher_target")" == "$expected_uid:$expected_gid:755" ]] || fail 'published ownership/mode changed'
printf 'launcher=%s\npolicy=%s\nstaging=%s\norigin=%s\ncommit=%s\n' "$launcher_target" "$policy_target" "$stage_root" "$origin" "$commit"
