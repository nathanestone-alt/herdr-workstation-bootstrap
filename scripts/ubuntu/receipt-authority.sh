#!/usr/bin/env bash
set -euo pipefail

mode='install'
script_path="$(realpath -e -- "${BASH_SOURCE[0]}")"
repo_root="$(cd -- "$(dirname -- "$script_path")/../.." && pwd -P)"
source_root="$repo_root"
user_home="${HOME:-}"
authority_path='/etc/stmodel/issue-961/receipt-authority.json'
receipt_path='/etc/stmodel/issue-961/receipt.json'
fixture_root=''
default_authority_path='/etc/stmodel/issue-961/receipt-authority.json'
default_receipt_path='/etc/stmodel/issue-961/receipt.json'
authority_id='#961-installation-authority-v1'
schema_version=1
trusted_path='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH="$trusted_path"

usage() {
  cat >&2 <<'EOF'
Usage: receipt-authority.sh [--install|--check] [options]

Options:
  --source-root PATH       Clean bootstrap source checkout.
  --user-home PATH         Managed user home whose tools are attested.
  --authority-path PATH    Authority envelope path (production default is /etc/stmodel/issue-961/receipt-authority.json).
  --receipt-path PATH      Receipt body path (production default is /etc/stmodel/issue-961/receipt.json).
  --fixture-root PATH      Test-only role root; requires non-production output paths.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install) mode='install'; shift ;;
    --check) mode='check'; shift ;;
    --source-root) [[ $# -ge 2 ]] || { usage; exit 2; }; source_root="$2"; shift 2 ;;
    --user-home) [[ $# -ge 2 ]] || { usage; exit 2; }; user_home="$2"; shift 2 ;;
    --authority-path) [[ $# -ge 2 ]] || { usage; exit 2; }; authority_path="$2"; shift 2 ;;
    --receipt-path) [[ $# -ge 2 ]] || { usage; exit 2; }; receipt_path="$2"; shift 2 ;;
    --fixture-root) [[ $# -ge 2 ]] || { usage; exit 2; }; fixture_root="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

fail() {
  echo "receipt authority: $*" >&2
  exit 24
}

[[ "$mode" == install || "$mode" == check ]] || fail "unsupported mode '$mode'"
[[ "$source_root" == /* && "$user_home" == /* && "$authority_path" == /* && "$receipt_path" == /* ]] || {
  fail 'source, home, authority, and receipt paths must be absolute'
}

if [[ -n "$fixture_root" ]]; then
  [[ "$fixture_root" == /* ]] || fail 'fixture root must be absolute'
  [[ "$authority_path" != "$default_authority_path" && "$receipt_path" != "$default_receipt_path" ]] || {
    fail 'fixture mode cannot address production authority paths'
  }
  system_bin="$fixture_root/bin"
else
  [[ "$(id -u)" == 0 ]] || {
    [[ "$mode" == check && "$authority_path" == "$default_authority_path" ]] || fail 'production authority operations require root'
  }
  system_bin='/usr/bin'
fi

jq_bin='/usr/bin/jq'
[[ -x "$jq_bin" ]] || fail 'jq is required at /usr/bin/jq'
[[ -x /usr/bin/git && -x /usr/bin/sha256sum && -x /usr/bin/realpath ]] || fail 'required host utilities are missing'

source_root="$(realpath -e -- "$source_root" 2>/dev/null || true)"
[[ -n "$source_root" && -d "$source_root" ]] || fail 'source root does not exist'
user_home="$(realpath -e -- "$user_home" 2>/dev/null || true)"
[[ -n "$user_home" && -d "$user_home" ]] || fail 'managed user home does not exist'
[[ "$(uname -s)" == 'Linux' && "$(uname -m)" == 'x86_64' ]] || fail 'receipt authority requires Ubuntu x86_64 Linux'
if [[ -z "$fixture_root" ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "\${ID:-}" == 'ubuntu' ]] || fail 'receipt authority requires an Ubuntu host'
fi

reject_symlink_components() {
  local path="$1"
  local current='/'
  local component
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

reject_symlink_components "$user_home" || fail "managed user home contains a symlink: $user_home"
[[ "$(realpath -e -- "$user_home" 2>/dev/null || true)" == "$user_home" ]] || fail "managed user home is not lexically canonical: $user_home"

lock_file="$source_root/config/ubuntu-toolchain.lock"
allowlist_file="$source_root/config/receipt-authority-role-allowlist.txt"
payload_manifest="$source_root/config/payload-manifest.sha256"
[[ -f "$lock_file" && -f "$allowlist_file" && -f "$payload_manifest" ]] || fail 'source authority inputs are incomplete'
# shellcheck disable=SC1090
source "$lock_file"

repo_commit="$(/usr/bin/git -C "$source_root" rev-parse --verify HEAD^{commit} 2>/dev/null || true)"
[[ "$repo_commit" =~ ^[0-9a-f]{40}$ ]] || fail 'source HEAD is not a full commit'
if ! /usr/bin/git -C "$source_root" diff --quiet; then fail 'source worktree has unstaged changes'; fi
if ! /usr/bin/git -C "$source_root" diff --cached --quiet; then fail 'source worktree has staged changes'; fi
[[ -z "$(/usr/bin/git -C "$source_root" status --porcelain --untracked-files=all)" ]] || fail 'source worktree has untracked changes'

payload_manifest_sha256="$(/usr/bin/sha256sum "$payload_manifest" | awk '{print $1}')"
allowlist_sha256="$(/usr/bin/sha256sum "$allowlist_file" | awk '{print $1}')"
script_sha256="$(/usr/bin/sha256sum "$script_path" | awk '{print $1}')"

declare -A role_registry role_names role_argv role_implementation
roles=()
while IFS='|' read -r role registry names version_argv implementation; do
  [[ -z "$role" || "$role" == \#* ]] && continue
  [[ "$role" =~ ^[a-z][a-z0-9-]+$ && "$registry" =~ ^[a-z0-9-]+$ && "$version_argv" == '--version' && -n "$names" && -n "$implementation" ]] || {
    fail "malformed role allowlist entry for '$role'"
  }
  [[ -z "${role_registry[$role]+x}" ]] || fail "duplicate role '$role' in allowlist"
  roles+=("$role")
  role_registry["$role"]="$registry"
  role_names["$role"]="$names"
  role_argv["$role"]="$version_argv"
  role_implementation["$role"]="$implementation"
done < "$allowlist_file"

expected_roles='bash git gh node pwsh rtk'
[[ "${roles[*]}" == "$expected_roles" ]] || fail "role allowlist must be sorted and exactly '$expected_roles'"

declare -A role_path
role_path[python313]="$user_home/.local/bin/python3.13"
role_path[rtk]="$user_home/.cargo/bin/rtk"
role_path[node]="$user_home/.local/lib/node-v${NODE_VERSION}-linux-x64/bin/node"
role_path[git]="$system_bin/git"
role_path[gh]="$system_bin/gh"
role_path[bash]="$system_bin/bash"
if [[ -n "$fixture_root" ]]; then
  role_path[pwsh]="$system_bin/pwsh"
else
  if [[ -x /opt/microsoft/powershell/7/pwsh ]]; then
    role_path[pwsh]='/opt/microsoft/powershell/7/pwsh'
  else
    role_path[pwsh]='/usr/bin/pwsh'
  fi
fi

canonical_executable() {
  local path="$1"
  local label="$2"
  reject_symlink_components "$path" || fail "$label contains a symlinked path component: $path"
  [[ -f "$path" && -x "$path" && ! -L "$path" ]] || fail "$label is not a regular executable: $path"
  local resolved
  resolved="$(realpath -e -- "$path" 2>/dev/null || true)"
  [[ "$resolved" == "$path" ]] || fail "$label is not lexically canonical: $path -> $resolved"
  printf '%s' "$path"
}

for role in "${roles[@]}"; do
  role_path["$role"]="$(canonical_executable "${role_path[$role]}" "$role")"
done
python_path="$(canonical_executable "${role_path[python313]}" 'python3.13')"
rtk_path="${role_path[rtk]}"

if [[ -n "$fixture_root" ]]; then
  rtk_candidates=("$user_home/.local/bin/rtk" "$user_home/.cargo/bin/rtk" "$system_bin/rtk")
else
  rtk_candidates=("$user_home/.local/bin/rtk" "$user_home/.cargo/bin/rtk" /usr/local/bin/rtk /usr/bin/rtk /bin/rtk)
fi
rtk_count=0
for candidate in "${rtk_candidates[@]}"; do
  if [[ -e "$candidate" || -L "$candidate" ]]; then
    reject_symlink_components "$candidate" || fail "RTK candidate is symlinked or unsafe: $candidate"
    [[ "$candidate" == "$rtk_path" ]] || fail "non-canonical RTK candidate is present: $candidate"
    ((rtk_count += 1))
  fi
done
[[ "$rtk_count" == 1 ]] || fail "RTK must have exactly one canonical candidate, found $rtk_count"

version_output_sha256() {
  printf '%s' "$1" | /usr/bin/sha256sum | awk '{print $1}'
}

probe_role_version() {
  local role="$1"
  local path="${role_path[$role]}"
  local output first
  output="$(PATH="$trusted_path" "$path" --version 2>&1)" || fail "$role --version failed"
  [[ -n "$output" ]] || fail "$role --version output is empty"
  first="${output%%$'\n'*}"
  case "$role" in
    bash) [[ "$first" == GNU\ bash,* ]] || fail "unexpected bash version output: $first" ;;
    git) [[ "$first" == git\ version\ * ]] || fail "unexpected git version output: $first" ;;
    gh) [[ "$first" == gh\ version\ * ]] || fail "unexpected gh version output: $first" ;;
    node) [[ "$first" =~ ^v[0-9]+\.[0-9]+\.[0-9]+ ]] || fail "unexpected node version output: $first" ;;
    pwsh) [[ "$first" == PowerShell\ * ]] || fail "unexpected PowerShell version output: $first" ;;
    rtk) [[ "$first" =~ ^rtk\ [0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "unexpected RTK version output: $first" ;;
  esac
  printf '%s\t%s\t%s' "$first" "$(version_output_sha256 "$output")" "$output"
}

declare -A role_version role_version_hash role_version_output
for role in "${roles[@]}"; do
  IFS=$'\t' read -r role_version["$role"] role_version_hash["$role"] role_version_output["$role"] < <(probe_role_version "$role")
done

python_version_output="$(PATH="$trusted_path" "$python_path" --version 2>&1)" || fail 'python3.13 --version failed'
[[ "$python_version_output" == "Python $PYTHON_VERSION" ]] || fail "Python version does not match lock: $python_version_output"
python_probe="$(PYTHONNOUSERSITE=1 PYTHONPATH= PATH="$trusted_path" "$python_path" -c 'import json, platform, sys; print(json.dumps({"version": platform.python_version(), "version_info": list(sys.version_info[:5]), "implementation": platform.python_implementation()}, separators=(",", ":"))) ' 2>&1)" || fail 'Python identity probe failed'
python_json="$("$jq_bin" -cS --arg executable "$python_path" --arg sha256 "$(/usr/bin/sha256sum "$python_path" | awk '{print $1}')" --arg version "$PYTHON_VERSION" --arg implementation "$(printf '%s' "$python_probe" | "$jq_bin" -r '.implementation')" --argjson version_info "$(printf '%s' "$python_probe" | "$jq_bin" -c '.version_info')" '{executable:$executable, sha256:$sha256, version:$version, version_info:$version_info, implementation:$implementation}')" || fail 'Python identity probe was not valid JSON'
[[ "$(printf '%s' "$python_probe" | "$jq_bin" -r '.version')" == "$PYTHON_VERSION" ]] || fail 'Python probe version mismatch'
[[ "$(printf '%s' "$python_probe" | "$jq_bin" -r '.implementation')" == CPython ]] || fail 'Python implementation is not CPython'

role_fragments="$(mktemp)"
receipt_tmp="$(mktemp)"
authority_tmp="$(mktemp)"
cleanup() { rm -f -- "$role_fragments" "$receipt_tmp" "$authority_tmp"; }
trap cleanup EXIT
for role in "${roles[@]}"; do
  role_json="$("$jq_bin" -cn \
    --arg role "$role" \
    --arg executable "${role_path[$role]}" \
    --arg sha256 "$(/usr/bin/sha256sum "${role_path[$role]}" | awk '{print $1}')" \
    --arg registry_id "${role_registry[$role]}" \
    --arg source_commit_sha "$repo_commit" \
    --arg kind '#961-role-manifest-v1' \
    --arg version "${role_version[$role]}" \
    --arg version_output_sha256 "${role_version_hash[$role]}" \
    --arg implementation "${role_implementation[$role]}" \
    '{($role): {executable:$executable, sha256:$sha256, registry_id:$registry_id, source_commit_sha:$source_commit_sha, source_attestation:{kind:$kind, canonical_path:$executable, file_sha256:$sha256}, version:$version, version_argv:["--version"], version_output_sha256:$version_output_sha256, implementation:$implementation}}')"
  printf '%s\n' "$role_json" >> "$role_fragments"
done
role_manifest_json="$("$jq_bin" -sc 'add' "$role_fragments" | "$jq_bin" -cS .)" || fail 'role manifest is not valid JSON'
role_manifest_sha256="$(printf '%s' "$role_manifest_json" | /usr/bin/sha256sum | awk '{print $1}')"

issued_at_utc="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
expires_at_utc="$(date -u -d '+30 days' '+%Y-%m-%dT%H:%M:%SZ')"
receipt_id="issue-961-bootstrap-${repo_commit:0:12}-$(date -u '+%Y%m%dT%H%M%SZ')"

build_receipt() {
  "$jq_bin" -n -cS \
    --argjson schema_version "$schema_version" \
    --arg receipt_id "$receipt_id" \
    --arg verification_status 'verified' \
    --arg source_commit_sha "$repo_commit" \
    --argjson clean true \
    --argjson python313_lock_verified true \
    --arg payload_manifest_sha256 "$payload_manifest_sha256" \
    --arg bridge_allowlist_sha256 "$allowlist_sha256" \
    --arg platform 'Ubuntu' \
    --arg architecture 'x86_64' \
    --arg issued_at_utc "$issued_at_utc" \
    --arg expires_at_utc "$expires_at_utc" \
    --argjson python313 "$python_json" \
    --argjson role_identities "$role_manifest_json" \
    --arg role_manifest_sha256 "$role_manifest_sha256" \
    --arg source_root "$source_root" \
    --arg script_sha256 "$script_sha256" \
    '{schema_version:$schema_version, receipt_id:$receipt_id, verification_status:$verification_status, source_commit_sha:$source_commit_sha, clean:$clean, python313_lock_verified:$python313_lock_verified, payload_manifest_sha256:$payload_manifest_sha256, bridge_allowlist_sha256:$bridge_allowlist_sha256, platform:$platform, architecture:$architecture, issued_at_utc:$issued_at_utc, expires_at_utc:$expires_at_utc, python313:$python313, role_identities:$role_identities, role_manifest_sha256:$role_manifest_sha256, provenance:{authority_id:"#961-installation-authority-v1", producer:"herdr-workstation-bootstrap", source_root:$source_root, source_commit_sha:$source_commit_sha, receipt_authority_script_sha256:$script_sha256, authority_mode:"authoritative", secrets_excluded:true}}'
}

validate_parent_chain() {
  local path="$1"
  local current="$path"
  local owner mode
  [[ "$current" == /* ]] || fail "output parent is not absolute: $path"
  [[ -d "$current" ]] || fail "output parent does not exist: $path"
  reject_symlink_components "$current" || fail "output parent contains a symlink: $path"
  if [[ -z "$fixture_root" ]]; then
    while :; do
      owner="$(stat -c '%u' -- "$current" 2>/dev/null || true)"
      mode="$(stat -c '%a' -- "$current" 2>/dev/null || true)"
      [[ "$owner" == 0 && "$mode" =~ ^[0-7]+$ && $((8#$mode & 22)) == 0 ]] || fail "production output parent is not root-owned and non-writable: $current"
      [[ "$current" == '/' ]] && break
      current="$(dirname -- "$current")"
    done
  fi
}

prepare_parent() {
  local target="$1"
  local parent="${target%/*}"
  [[ "$parent" == "$target" ]] && parent='/'
  if [[ "$mode" == install ]]; then
    reject_symlink_components "$parent" || fail "refusing to create through a symlinked output parent: $parent"
    mkdir -p -- "$parent"
  fi
  validate_parent_chain "$parent"
}

atomic_install_json() {
  local source="$1"
  local target="$2"
  local parent="${target%/*}"
  local stage
  [[ "$parent" != "$target" ]] || parent='/'
  prepare_parent "$target"
  [[ ! -L "$target" ]] || fail "refusing to replace symlink output: $target"
  stage="$(mktemp "$parent/.receipt-authority.XXXXXX")"
  install -m 0644 -- "$source" "$stage"
  if [[ -z "$fixture_root" ]]; then chown 0:0 -- "$stage"; fi
  mv -T -- "$stage" "$target"
  [[ -f "$target" && ! -L "$target" ]] || fail "atomic output did not produce a regular file: $target"
}

validate_json_field() {
  local path="$1"
  local expression="$2"
  "$jq_bin" -e "$expression" "$path" >/dev/null 2>&1 || fail "JSON contract failed for $path"
}

validate_installed_authority() {
  [[ -f "$receipt_path" && ! -L "$receipt_path" ]] || fail "receipt body is missing or symlinked: $receipt_path"
  [[ -f "$authority_path" && ! -L "$authority_path" ]] || fail "authority envelope is missing or symlinked: $authority_path"
  validate_parent_chain "${receipt_path%/*}"
  validate_parent_chain "${authority_path%/*}"
  validate_json_field "$receipt_path" '.schema_version == 1 and .verification_status == "verified" and .clean == true and .python313_lock_verified == true and (.source_commit_sha|test("^[0-9a-f]{40}$")) and .platform == "Ubuntu" and .architecture == "x86_64" and (.role_identities|type == "object") and ((.role_identities|keys) == ["bash","git","gh","node","pwsh","rtk"])'
  validate_json_field "$authority_path" '.schema_version == 1 and .authority_id == "#961-installation-authority-v1" and .verification_status == "verified" and (.source_commit_sha|test("^[0-9a-f]{40}$")) and .platform == "Ubuntu" and .architecture == "x86_64"'
  local stored_receipt_path stored_receipt_sha stored_role_hash stored_source stored_payload stored_allowlist stored_python stored_roles stored_receipt_id
  stored_receipt_path="$("$jq_bin" -r '.receipt_path // empty' "$authority_path")"
  [[ "$stored_receipt_path" == "$receipt_path" ]] || fail 'authority receipt_path does not match the installed receipt'
  stored_receipt_sha="$("$jq_bin" -r '.receipt_sha256 // empty' "$authority_path")"
  [[ "$stored_receipt_sha" == "$(/usr/bin/sha256sum "$receipt_path" | awk '{print $1}')" ]] || fail 'authority receipt hash does not match the receipt body'
  stored_receipt_id="$("$jq_bin" -r '.receipt_id // empty' "$authority_path")"
  [[ -n "$stored_receipt_id" && "$stored_receipt_id" == "$("$jq_bin" -r '.receipt_id // empty' "$receipt_path")" ]] || fail 'authority receipt_id does not match the receipt body'
  stored_source="$("$jq_bin" -r '.source_commit_sha' "$receipt_path")"
  [[ "$stored_source" == "$repo_commit" ]] || fail 'receipt source commit differs from the clean source checkout'
  stored_payload="$("$jq_bin" -r '.payload_manifest_sha256' "$receipt_path")"
  [[ "$stored_payload" == "$payload_manifest_sha256" ]] || fail 'receipt payload manifest hash differs from source'
  stored_allowlist="$("$jq_bin" -r '.bridge_allowlist_sha256' "$receipt_path")"
  [[ "$stored_allowlist" == "$allowlist_sha256" ]] || fail 'receipt role allowlist hash differs from source'
  stored_role_hash="$("$jq_bin" -r '.role_manifest_sha256' "$receipt_path")"
  [[ "$stored_role_hash" == "$role_manifest_sha256" ]] || fail 'receipt role manifest hash differs from live roles'
  stored_python="$("$jq_bin" -cS '.python313' "$receipt_path")"
  [[ "$stored_python" == "$python_json" ]] || fail 'receipt Python identity differs from the live regular executable'
  stored_roles="$("$jq_bin" -cS '.role_identities' "$receipt_path")"
  [[ "$stored_roles" == "$role_manifest_json" ]] || fail 'receipt role identities differ from live canonical executables'
  [[ "$("$jq_bin" -r '.provenance.receipt_authority_script_sha256 // empty' "$receipt_path")" == "$script_sha256" ]] || fail 'receipt authority script provenance differs from source'
  [[ "$("$jq_bin" -r '.source_commit_sha' "$authority_path")" == "$repo_commit" ]] || fail 'authority source commit differs from source'
  [[ "$("$jq_bin" -r '.payload_manifest_sha256' "$authority_path")" == "$payload_manifest_sha256" ]] || fail 'authority payload hash differs from source'
  [[ "$("$jq_bin" -r '.bridge_allowlist_sha256' "$authority_path")" == "$allowlist_sha256" ]] || fail 'authority allowlist hash differs from source'
  [[ "$("$jq_bin" -r '.role_manifest_sha256' "$authority_path")" == "$role_manifest_sha256" ]] || fail 'authority role manifest hash differs from receipt'
  [[ "$("$jq_bin" -cS '.python313' "$authority_path")" == "$python_json" ]] || fail 'authority Python identity differs from receipt'
  [[ "$("$jq_bin" -r '.provenance.receipt_authority_script_sha256 // empty' "$authority_path")" == "$script_sha256" ]] || fail 'authority script provenance differs from source'
  local expires_epoch
  expires_epoch="$(date -u -d "$("$jq_bin" -r '.expires_at_utc' "$receipt_path")" '+%s' 2>/dev/null || true)"
  [[ "$expires_epoch" =~ ^[0-9]+$ && "$expires_epoch" -gt "$(date -u '+%s')" ]] || fail 'receipt is expired or has an invalid expiry'
}

if [[ "$mode" == install ]]; then
  build_receipt > "$receipt_tmp"
  atomic_install_json "$receipt_tmp" "$receipt_path"
  receipt_sha256="$(/usr/bin/sha256sum "$receipt_path" | awk '{print $1}')"
  "$jq_bin" -n -cS \
    --argjson schema_version "$schema_version" \
    --arg authority_id "$authority_id" \
    --arg receipt_path "$receipt_path" \
    --arg receipt_sha256 "$receipt_sha256" \
    --arg receipt_id "$receipt_id" \
    --arg verification_status 'verified' \
    --arg source_commit_sha "$repo_commit" \
    --arg payload_manifest_sha256 "$payload_manifest_sha256" \
    --arg bridge_allowlist_sha256 "$allowlist_sha256" \
    --arg platform 'Ubuntu' \
    --arg architecture 'x86_64' \
    --argjson python313 "$python_json" \
    --arg role_manifest_sha256 "$role_manifest_sha256" \
    --arg source_root "$source_root" \
    --arg script_sha256 "$script_sha256" \
    '{schema_version:$schema_version, authority_id:$authority_id, receipt_path:$receipt_path, receipt_sha256:$receipt_sha256, receipt_id:$receipt_id, verification_status:$verification_status, source_commit_sha:$source_commit_sha, payload_manifest_sha256:$payload_manifest_sha256, bridge_allowlist_sha256:$bridge_allowlist_sha256, platform:$platform, architecture:$architecture, python313:$python313, role_manifest_sha256:$role_manifest_sha256, provenance:{source_root:$source_root, source_commit_sha:$source_commit_sha, receipt_authority_script_sha256:$script_sha256, secrets_excluded:true}}' > "$authority_tmp"
  atomic_install_json "$authority_tmp" "$authority_path"
fi

validate_installed_authority
printf 'receipt authority %s: authority=%s receipt=%s source=%s rtk=%s python=%s\n' \
  "$mode" "$authority_path" "$receipt_path" "$repo_commit" "$rtk_path" "$python_path"
