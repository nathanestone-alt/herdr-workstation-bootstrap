#!/usr/bin/bash
set -euo pipefail

# This prelude is deliberately self-contained.  The live source-attestation
# helper is untrusted until its committed Git blob has been independently
# located, materialized into a private directory, and checked by Git and
# SHA-256.  Do not move this proof below the first helper source.
readonly bootstrap_trusted_path='/usr/sbin:/usr/bin:/sbin:/bin'
readonly bootstrap_env_bin='/usr/bin/env'
readonly bootstrap_git_bin='/usr/bin/git'
readonly bootstrap_realpath_bin='/usr/bin/realpath'
readonly bootstrap_dirname_bin='/usr/bin/dirname'
readonly bootstrap_find_bin='/usr/bin/find'
readonly bootstrap_mktemp_bin='/usr/bin/mktemp'
readonly bootstrap_chmod_bin='/usr/bin/chmod'
readonly bootstrap_stat_bin='/usr/bin/stat'
readonly bootstrap_sha256_bin='/usr/bin/sha256sum'
readonly bootstrap_awk_bin='/usr/bin/gawk'
readonly bootstrap_cp_bin='/usr/bin/cp'
readonly bootstrap_rm_bin='/usr/bin/rm'
readonly bootstrap_mkdir_bin='/usr/bin/mkdir'
readonly bootstrap_head_bin='/usr/bin/head'

export PATH="$bootstrap_trusted_path"
export LC_ALL=C
export TZ=UTC
while IFS= read -r bootstrap_env_name; do
  case "$bootstrap_env_name" in
    GIT_DIR|GIT_WORK_TREE|GIT_INDEX_FILE|GIT_OBJECT_DIRECTORY|GIT_ALTERNATE_OBJECT_DIRECTORIES|GIT_COMMON_DIR|GIT_CONFIG_*)
      echo "bootstrap trust prelude: caller Git environment override is not permitted: $bootstrap_env_name" >&2
      exit 24
      ;;
  esac
done < <(compgen -e)
unset BASH_ENV ENV CDPATH GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_CONFIG_PARAMETERS
while IFS= read -r bootstrap_env_name; do
  case "$bootstrap_env_name" in
    GIT_*) unset "$bootstrap_env_name" ;;
  esac
done < <(compgen -e)

bootstrap_trust_fail() {
  echo "bootstrap trust prelude: $*" >&2
  exit 24
}

bootstrap_trust_reject_symlink_components() {
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

bootstrap_trust_assert_binary() {
  local path="$1"
  local resolved mode
  [[ -f "$path" && ! -L "$path" && -x "$path" ]] || {
    bootstrap_trust_fail "trusted binary is missing or not a regular executable: $path"
  }
  resolved="$($bootstrap_realpath_bin -e -- "$path" 2>/dev/null || true)"
  [[ "$resolved" == "$path" ]] || {
    bootstrap_trust_fail "trusted binary is not canonical: $path -> $resolved"
  }
  mode="$($bootstrap_stat_bin -c '%a' -- "$path" 2>/dev/null || true)"
  [[ "$mode" =~ ^[0-7]+$ && $((8#$mode & 022)) == 0 ]] || {
    bootstrap_trust_fail "trusted binary is writable by group or other users: $path"
  }
}

for bootstrap_trusted_binary in \
  "$bootstrap_env_bin" "$bootstrap_git_bin" "$bootstrap_realpath_bin" \
  "$bootstrap_dirname_bin" "$bootstrap_find_bin" "$bootstrap_mktemp_bin" \
  "$bootstrap_chmod_bin" "$bootstrap_stat_bin" "$bootstrap_sha256_bin" \
  "$bootstrap_awk_bin" "$bootstrap_cp_bin" "$bootstrap_rm_bin" "$bootstrap_mkdir_bin" \
  "$bootstrap_head_bin"; do
  bootstrap_trust_assert_binary "$bootstrap_trusted_binary"
done

declare -a bootstrap_cleanup_paths=()
bootstrap_register_cleanup() {
  [[ -n "${1:-}" ]] && bootstrap_cleanup_paths+=("$1")
}

bootstrap_private_helper_dir=''
bootstrap_cleanup() {
  local status="$1"
  set +e
  local cleanup_path
  for cleanup_path in "${bootstrap_cleanup_paths[@]:-}"; do
    [[ -n "$cleanup_path" ]] && "$bootstrap_rm_bin" -rf -- "$cleanup_path"
  done
  if declare -F attestation_cleanup_temporary_paths >/dev/null 2>&1; then
    attestation_cleanup_temporary_paths
  fi
  return "$status"
}
trap 'bootstrap_cleanup "$?"' EXIT

bootstrap_command_path() {
  local name="$1"
  local override_name=''
  local default_path=''
  local candidate resolved
  case "$name" in
    sudo) override_name='HERDR_BOOTSTRAP_TEST_SUDO'; default_path='/usr/bin/sudo' ;;
    apt-get) override_name='HERDR_BOOTSTRAP_TEST_APT_GET'; default_path='/usr/bin/apt-get' ;;
    systemctl) override_name='HERDR_BOOTSTRAP_TEST_SYSTEMCTL'; default_path='/usr/bin/systemctl' ;;
    ps) override_name='HERDR_BOOTSTRAP_TEST_PS'; default_path='/usr/bin/ps' ;;
    pwsh) override_name='HERDR_BOOTSTRAP_TEST_PWSH'; default_path='/usr/bin/pwsh' ;;
    tailscale) override_name='HERDR_BOOTSTRAP_TEST_TAILSCALE'; default_path='/usr/bin/tailscale' ;;
    *) bootstrap_trust_fail "unsupported command seam: $name" ;;
  esac
  candidate="$default_path"
  if [[ "${HERDR_BOOTSTRAP_TEST_MODE:-0}" == 1 && -n "${!override_name:-}" ]]; then
    candidate="${!override_name}"
  fi
  [[ "$candidate" == /* ]] || bootstrap_trust_fail "command seam is not absolute: $name"
  bootstrap_trust_assert_binary "$candidate"
  resolved="$($bootstrap_realpath_bin -e -- "$candidate" 2>/dev/null || true)"
  if [[ "${HERDR_BOOTSTRAP_TEST_MODE:-0}" != 1 ]]; then
    [[ "$resolved" == "$default_path" ]] || bootstrap_trust_fail "command seam is not the canonical system binary: $name"
  fi
  printf '%s\n' "$resolved"
}

bootstrap_script_path="$($bootstrap_realpath_bin -e -- "${BASH_SOURCE[0]}" 2>/dev/null || true)"
bootstrap_script_dir="$($bootstrap_dirname_bin -- "$bootstrap_script_path")"
bootstrap_repo_root="$($bootstrap_realpath_bin -e -- "$bootstrap_script_dir/../.." 2>/dev/null || true)"
[[ -n "$bootstrap_script_path" && "$bootstrap_script_path" == "$bootstrap_repo_root/scripts/ubuntu/bootstrap.sh" ]] || {
  bootstrap_trust_fail 'bootstrap entrypoint is not at the canonical repository path'
}
[[ -n "$bootstrap_repo_root" && -d "$bootstrap_repo_root" && ! -L "$bootstrap_repo_root" ]] || {
  bootstrap_trust_fail 'bootstrap repository root is not a real directory'
}
bootstrap_trust_reject_symlink_components "$bootstrap_repo_root" || {
  bootstrap_trust_fail 'bootstrap repository root contains a symlinked component'
}
bootstrap_git_metadata="$bootstrap_repo_root/.git"
[[ -e "$bootstrap_git_metadata" && ! -L "$bootstrap_git_metadata" && \
  ( -d "$bootstrap_git_metadata" || -f "$bootstrap_git_metadata" ) ]] || {
  bootstrap_trust_fail 'bootstrap repository metadata is missing or unsafe'
}
if [[ -d "$bootstrap_git_metadata" ]]; then
  bootstrap_git_dir="$bootstrap_git_metadata"
  bootstrap_common_git_dir="$bootstrap_git_dir"
else
  bootstrap_git_pointer="$(< "$bootstrap_git_metadata")"
  [[ "$bootstrap_git_pointer" != *$'\n'* && "$bootstrap_git_pointer" != *$'\r'* && \
    "$bootstrap_git_pointer" == gitdir:\ /* ]] || {
    bootstrap_trust_fail 'bootstrap Git pointer cannot be read safely'
  }
  bootstrap_git_pointer_path="${bootstrap_git_pointer#gitdir: }"
  bootstrap_git_dir="$($bootstrap_realpath_bin -e -- "$bootstrap_git_pointer_path" 2>/dev/null || true)"
  [[ -n "$bootstrap_git_dir" && "$bootstrap_git_pointer" == "gitdir: $bootstrap_git_dir" ]] || {
    bootstrap_trust_fail 'bootstrap Git pointer is not canonical'
  }
  [[ -d "$bootstrap_git_dir" && ! -L "$bootstrap_git_dir" && \
    -f "$bootstrap_git_dir/commondir" && ! -L "$bootstrap_git_dir/commondir" ]] || {
    bootstrap_trust_fail 'bootstrap Git worktree metadata is missing or unsafe'
  }
  bootstrap_commondir_spec="$(< "$bootstrap_git_dir/commondir")"
  [[ "$bootstrap_commondir_spec" == '../..' ]] || {
    bootstrap_trust_fail 'bootstrap Git common directory is not local'
  }
  bootstrap_common_git_dir="$($bootstrap_realpath_bin -e -- "$bootstrap_git_dir/$bootstrap_commondir_spec" 2>/dev/null || true)"
  [[ -n "$bootstrap_common_git_dir" && -d "$bootstrap_common_git_dir" && ! -L "$bootstrap_common_git_dir" ]] || {
    bootstrap_trust_fail 'bootstrap Git common directory is missing or unsafe'
  }
fi
bootstrap_trust_reject_symlink_components "$bootstrap_git_dir" || {
  bootstrap_trust_fail 'bootstrap Git directory contains a symlinked component'
}
bootstrap_trust_reject_symlink_components "$bootstrap_common_git_dir" || {
  bootstrap_trust_fail 'bootstrap Git common directory contains a symlinked component'
}
[[ -d "$bootstrap_common_git_dir/objects" && ! -L "$bootstrap_common_git_dir/objects" && \
  -d "$bootstrap_common_git_dir/refs" && ! -L "$bootstrap_common_git_dir/refs" && \
  -f "$bootstrap_git_dir/index" && ! -L "$bootstrap_git_dir/index" && \
  -f "$bootstrap_common_git_dir/config" && ! -L "$bootstrap_common_git_dir/config" ]] || {
  bootstrap_trust_fail 'bootstrap repository object, ref, config, or index storage is missing'
}
[[ ! -e "$bootstrap_common_git_dir/shallow" && ! -e "$bootstrap_git_dir/shallow" && \
  ! -e "$bootstrap_common_git_dir/objects/info/alternates" && \
  ! -e "$bootstrap_common_git_dir/objects/info/http-alternates" ]] || {
  bootstrap_trust_fail 'bootstrap repository uses external or shallow Git storage'
}
for bootstrap_git_metadata_root in "$bootstrap_git_dir" "$bootstrap_common_git_dir"; do
  bootstrap_git_metadata_entry="$($bootstrap_find_bin -P "$bootstrap_git_metadata_root" -mindepth 1 \
    \( -type l -o \( ! -type f ! -type d \) \) -print -quit 2>/dev/null || true)"
  [[ -z "$bootstrap_git_metadata_entry" ]] || {
    bootstrap_trust_fail "bootstrap Git metadata contains an unsafe entry: $bootstrap_git_metadata_entry"
  }
done

bootstrap_trust_git() {
  "$bootstrap_env_bin" -i \
    HOME=/nonexistent \
    PATH="$bootstrap_trusted_path" \
    LC_ALL=C \
    TZ=UTC \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_SYSTEM=/dev/null \
    GIT_CONFIG_COUNT=0 \
    "$bootstrap_git_bin" --no-replace-objects \
    -C "$bootstrap_repo_root" --git-dir="$bootstrap_git_dir" --work-tree=. \
    -c core.attributesfile=/dev/null \
    -c core.excludesfile=/dev/null \
    -c core.hooksPath=/dev/null \
    -c core.filemode=true \
    -c core.ignoreCase=false \
    "$@"
}

bootstrap_dangerous_config="$(bootstrap_trust_git config --local --no-includes --name-only --get-regexp \
  '^(include|filter\.|diff\..*\.textconv$|merge\..*\.driver$|credential\.|url\..*\.insteadOf$|core\.(attributesfile|excludesfile|fsmonitor|hooksPath|worktree|alternateRefsCommand|askPass|gitProxy|sshCommand)$|extensions\.|remote\..*\.(promisor|partialclonefilter|uploadpack|receivepack)$)' \
  2>/dev/null || true)"
[[ -z "$bootstrap_dangerous_config" ]] || bootstrap_trust_fail 'repository-local Git configuration is unsafe'
[[ "$(bootstrap_trust_git config --local --no-includes --bool --get core.sparseCheckout 2>/dev/null || true)" != true && \
  "$(bootstrap_trust_git config --local --no-includes --bool --get index.sparse 2>/dev/null || true)" != true && \
  ! -e "$bootstrap_common_git_dir/info/sparse-checkout" && \
  ! -e "$bootstrap_git_dir/info/sparse-checkout" ]] || {
  bootstrap_trust_fail 'bootstrap repository sparse checkout metadata is unsafe'
}
[[ "$(bootstrap_trust_git config --local --no-includes --bool --get core.filemode 2>/dev/null || true)" != false && \
  "$(bootstrap_trust_git config --local --no-includes --bool --get core.bare 2>/dev/null || true)" != true && \
  "$(bootstrap_trust_git config --local --no-includes --int --get core.repositoryformatversion 2>/dev/null || true)" == 0 && \
  "$(bootstrap_trust_git config --local --no-includes --bool --get core.ignorecase 2>/dev/null || true)" != true ]] || {
  bootstrap_trust_fail 'bootstrap repository format or mode configuration is unsafe'
}
[[ "$(bootstrap_trust_git rev-parse --show-toplevel 2>/dev/null || true)" == "$bootstrap_repo_root" && \
  "$(bootstrap_trust_git rev-parse --absolute-git-dir 2>/dev/null || true)" == "$bootstrap_git_dir" && \
  "$(bootstrap_trust_git rev-parse --is-inside-work-tree 2>/dev/null || true)" == true && \
  "$(bootstrap_trust_git rev-parse --is-bare-repository 2>/dev/null || true)" == false && \
  "$(bootstrap_trust_git rev-parse --is-shallow-repository 2>/dev/null || true)" == false ]] || {
  bootstrap_trust_fail 'bootstrap repository topology is not a local full worktree'
}

bootstrap_commit="$(bootstrap_trust_git rev-parse --verify HEAD^{commit} 2>/dev/null || true)"
[[ "$bootstrap_commit" =~ ^[0-9a-f]{40}$ ]] || bootstrap_trust_fail 'bootstrap HEAD is not a full committed object'
bootstrap_trust_git cat-file -e "$bootstrap_commit^{commit}" || bootstrap_trust_fail 'bootstrap HEAD object is unavailable'
bootstrap_helper_tree="$(bootstrap_trust_git ls-tree "$bootstrap_commit" -- scripts/ubuntu/source-attestation.sh 2>/dev/null || true)"
[[ "$bootstrap_helper_tree" != *$'\n'* ]] || bootstrap_trust_fail 'bootstrap helper tree lookup was ambiguous'
IFS=$'\t' read -r bootstrap_helper_meta bootstrap_helper_path <<< "$bootstrap_helper_tree"
read -r bootstrap_helper_mode bootstrap_helper_type bootstrap_helper_oid <<< "$bootstrap_helper_meta"
[[ "$bootstrap_helper_path" == scripts/ubuntu/source-attestation.sh && "$bootstrap_helper_type" == blob && \
  "$bootstrap_helper_oid" =~ ^[0-9a-f]{40}$ && ( "$bootstrap_helper_mode" == 100644 || "$bootstrap_helper_mode" == 100755 ) ]] || {
  bootstrap_trust_fail 'committed source-attestation helper is not a regular blob'
}
bootstrap_trust_git cat-file -e "$bootstrap_helper_oid^{blob}" || bootstrap_trust_fail 'committed helper blob is unavailable'
bootstrap_private_helper_dir="$($bootstrap_mktemp_bin -d /tmp/herdr-bootstrap-helper.XXXXXX)"
bootstrap_register_cleanup "$bootstrap_private_helper_dir"
"$bootstrap_chmod_bin" 0700 -- "$bootstrap_private_helper_dir"
bootstrap_private_helper="$bootstrap_private_helper_dir/source-attestation.sh"
bootstrap_trust_git cat-file blob "$bootstrap_helper_oid" > "$bootstrap_private_helper" || {
  bootstrap_trust_fail 'committed helper blob could not be materialized'
}
[[ -f "$bootstrap_private_helper" && ! -L "$bootstrap_private_helper" ]] || {
  bootstrap_trust_fail 'materialized helper is not a regular file'
}
bootstrap_helper_mode_value=0644
[[ "$bootstrap_helper_mode" == 100755 ]] && bootstrap_helper_mode_value=0755
"$bootstrap_chmod_bin" "$bootstrap_helper_mode_value" -- "$bootstrap_private_helper"
bootstrap_materialized_oid="$($bootstrap_env_bin -i HOME=/nonexistent PATH="$bootstrap_trusted_path" \
  LC_ALL=C TZ=UTC GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_COUNT=0 \
  "$bootstrap_git_bin" --no-replace-objects --git-dir="$bootstrap_git_dir" \
  hash-object --no-filters --stdin < "$bootstrap_private_helper")"
[[ "$bootstrap_materialized_oid" == "$bootstrap_helper_oid" ]] || {
  bootstrap_trust_fail 'materialized helper bytes do not match the committed blob'
}
bootstrap_private_helper_sha256="$($bootstrap_sha256_bin -- "$bootstrap_private_helper" | "$bootstrap_awk_bin" '{print $1}')"
[[ "$bootstrap_private_helper_sha256" =~ ^[0-9a-f]{64}$ ]] || bootstrap_trust_fail 'materialized helper hash is invalid'

# shellcheck disable=SC1090
source "$bootstrap_private_helper"
attestation_create_git_snapshot "$bootstrap_repo_root" '' '' || {
  echo 'Bootstrap source checkout failed exact committed-blob attestation.' >&2
  exit 24
}
bootstrap_source_snapshot="$attestation_snapshot_dir"
# Re-source only the helper that was copied from the committed Git snapshot.
# All subsequent source-derived inputs, including the lock, come from this
# private snapshot; the live helper pathname is never sourced.
# shellcheck disable=SC1090
source "$bootstrap_source_snapshot/scripts/ubuntu/source-attestation.sh"
attestation_snapshot_dir="$bootstrap_source_snapshot"
attestation_snapshot_manifest="$bootstrap_source_snapshot/.source-attestation"
repo_root="$bootstrap_source_snapshot"

phase="all"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase) [[ $# -ge 2 ]] || { echo '--phase requires a value.' >&2; exit 2; }; phase="$2"; shift 2 ;;
    --no-node) echo '--no-node is no longer supported because Codex and Claude use the pinned Node runtime.' >&2; exit 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
lock_file="$repo_root/config/ubuntu-toolchain.lock"
state_dir="${HOME}/.local/state/herdr-workstation-bootstrap"
bin_dir="${HOME}/.local/bin"

[[ -f "$lock_file" ]] || { echo "Missing toolchain lock: $lock_file" >&2; exit 22; }
# shellcheck disable=SC1090
source "$lock_file"
required_lock_keys=(
  UV_VERSION UV_PLATFORM UV_URL UV_SHA256
  PYTHON_VERSION PYTHON_RELEASE PYTHON_PLATFORM PYTHON_ARCHIVE PYTHON_URL PYTHON_SHA256
  RTK_REPO_URL RTK_REF
  POWERSHELL_VERSION POWERSHELL_URL POWERSHELL_SHA256
  TAILSCALE_VERSION TAILSCALE_INSTALLER_URL TAILSCALE_INSTALLER_SHA256
  RUSTUP_VERSION RUSTUP_INIT_URL RUSTUP_INIT_SHA256 RUST_TOOLCHAIN
  NODE_VERSION NODE_URL NODE_SHA256 CODEX_VERSION CLAUDE_VERSION BUN_VERSION
  HERDR_VERSION HERDR_URL HERDR_SHA256
)
for key in "${required_lock_keys[@]}"; do
  [[ -n "${!key:-}" ]] || { echo "Lock key '$key' is empty." >&2; exit 22; }
done
for key in UV_SHA256 PYTHON_SHA256 POWERSHELL_SHA256 TAILSCALE_INSTALLER_SHA256 RUSTUP_INIT_SHA256 NODE_SHA256 HERDR_SHA256; do
  [[ "${!key}" =~ ^[0-9a-f]{64}$ ]] || { echo "Lock key '$key' is not a lowercase SHA-256 value." >&2; exit 22; }
done

path_is_under() {
  local child="$1"
  local parent="$2"
  [[ "$child" == "$parent" || "$child" == "$parent/"* ]]
}

validate_cargo_roots() {
  local expected_root="$HOME/.cargo"
  cargo_home="${CARGO_HOME:-$expected_root}"
  cargo_install_root="${CARGO_INSTALL_ROOT:-$cargo_home}"
  [[ "$cargo_home" == "$expected_root" ]] || {
    echo "CARGO_HOME must be the canonical cargo root '$expected_root', got '$cargo_home'." >&2
    return 1
  }
  [[ "$cargo_install_root" == "$expected_root" ]] || {
    echo "CARGO_INSTALL_ROOT must be the canonical cargo root '$expected_root', got '$cargo_install_root'." >&2
    return 1
  }
  export CARGO_HOME="$expected_root"
  export CARGO_INSTALL_ROOT="$expected_root"
}

trusted_git_command() {
  /usr/bin/env -i \
    HOME="$HOME" \
    PATH='/usr/sbin:/usr/bin:/sbin:/bin' \
    LC_ALL=C \
    TZ=UTC \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_SYSTEM=/dev/null \
    GIT_CONFIG_COUNT=0 \
    /usr/bin/git --no-replace-objects \
    -c core.attributesfile=/dev/null \
    -c core.excludesfile=/dev/null \
    -c core.hooksPath=/dev/null \
    -c core.filemode=true \
    "$@"
}

validate_rtk_source_checkout() {
  local source_path="${1:-}"
  local expected_url="${2:-}"
  local expected_ref="${3:-}"
  attestation_create_git_snapshot "$source_path" "$expected_url" "$expected_ref" || return 1
  rtk_snapshot_path="$attestation_snapshot_dir"
  rtk_snapshot_manifest="$attestation_snapshot_manifest"
  rtk_snapshot_commit="$attestation_snapshot_commit"
  rtk_snapshot_url="$attestation_snapshot_url"
  rtk_snapshot_manifest_sha256="$attestation_snapshot_manifest_sha256"
}

install_rtk_from_source() {
  local source_path="$1"
  local expected_url="$2"
  local expected_ref="$3"
  validate_rtk_source_checkout "$source_path" "$expected_url" "$expected_ref" || return 1
  install_rtk_snapshot
}

install_rtk_snapshot() {
  local cargo_real cargo_real_after cargo_hash_before cargo_hash_after cargo_identity_before cargo_identity_after
  local cargo_mode cargo_stage_dir cargo_stage cargo_stage_real cargo_stage_mode cargo_stage_hash
  local rustc_path rustc_real rustc_mode
  local cargo_target_dir cargo_status
  cargo_real="$(attestation_canonical_cargo "$HOME")" || {
    echo 'Canonical Cargo executable is unavailable under the managed Cargo root.' >&2
    return 1
  }
  cargo_identity_before="$(/usr/bin/stat -Lc '%d:%i' -- "$cargo_real" 2>/dev/null || true)"
  cargo_mode="$(/usr/bin/stat -c '%a' -- "$cargo_real" 2>/dev/null || true)"
  cargo_hash_before="$(/usr/bin/sha256sum -- "$cargo_real" | /usr/bin/gawk '{print $1}')"
  [[ "$cargo_identity_before" =~ ^[0-9]+:[0-9]+$ && "$cargo_mode" =~ ^[0-7]+$ && \
    $((8#$cargo_mode & 022)) == 0 && "$cargo_hash_before" =~ ^[0-9a-f]{64}$ ]] || {
    echo 'Canonical Cargo executable identity or mode is invalid.' >&2
    return 1
  }
  cargo_stage_dir="$(/usr/bin/mktemp -d /tmp/herdr-cargo-exec.XXXXXX)"
  bootstrap_register_cleanup "$cargo_stage_dir"
  cargo_stage="$cargo_stage_dir/cargo"
  /usr/bin/cp -p -- "$cargo_real" "$cargo_stage"
  /usr/bin/chmod "$cargo_mode" -- "$cargo_stage"
  cargo_stage_real="$(/usr/bin/realpath -e -- "$cargo_stage" 2>/dev/null || true)"
  cargo_stage_mode="$(/usr/bin/stat -c '%a' -- "$cargo_stage" 2>/dev/null || true)"
  cargo_stage_hash="$(/usr/bin/sha256sum -- "$cargo_stage" | /usr/bin/gawk '{print $1}')"
  [[ "$cargo_stage_real" == "$cargo_stage" && -f "$cargo_stage" && ! -L "$cargo_stage" && \
    "$cargo_stage_mode" == "$cargo_mode" && "$cargo_stage_hash" == "$cargo_hash_before" ]] || {
    echo 'Private Cargo staging identity does not match the validated executable.' >&2
    return 1
  }
  cargo_identity_after="$(/usr/bin/stat -Lc '%d:%i' -- "$cargo_real" 2>/dev/null || true)"
  cargo_hash_after="$(/usr/bin/sha256sum -- "$cargo_real" | /usr/bin/gawk '{print $1}')"
  [[ "$cargo_identity_after" == "$cargo_identity_before" && "$cargo_hash_after" == "$cargo_hash_before" ]] || {
    echo 'Cargo executable changed during private staging.' >&2
    return 1
  }
  rustc_path="$HOME/.cargo/bin/rustc"
  rustc_real="$(/usr/bin/realpath -e -- "$rustc_path" 2>/dev/null || true)"
  if [[ -n "$rustc_real" ]]; then
    rustc_mode="$(/usr/bin/stat -c '%a' -- "$rustc_real" 2>/dev/null || true)"
    [[ -f "$rustc_real" && ! -L "$rustc_real" && -x "$rustc_real" && \
      ( "$rustc_real" == "$HOME/.cargo/"* || "$rustc_real" == "$HOME/.rustup/"* ) && \
      "$rustc_mode" =~ ^[0-7]+$ && $((8#$rustc_mode & 022)) == 0 ]] || {
      echo 'Rustc executable is outside the approved managed toolchain identity.' >&2
      return 1
    }
  else
    rustc_real="$rustc_path"
  fi
  cargo_target_dir="$(/usr/bin/mktemp -d /tmp/herdr-cargo-target.XXXXXX)"
  bootstrap_register_cleanup "$cargo_target_dir"
  bootstrap_test_pause before-cargo-exec
  # Keep every compiler/tool lookup at the build seam canonical.  Cargo and
  # rustc are passed by exact absolute path; the validated private Cargo copy
  # is the executable used, so a user-controlled cargo-bin entry cannot win a
  # validation-to-use race.
  if /usr/bin/env -i \
    HOME="$HOME" \
    PATH='/usr/sbin:/usr/bin:/sbin:/bin' \
    LC_ALL=C \
    TZ=UTC \
    CARGO_HOME="$HOME/.cargo" \
    CARGO_INSTALL_ROOT="$HOME/.cargo" \
    CARGO_TARGET_DIR="$cargo_target_dir" \
    RUSTC="$rustc_real" \
    "$cargo_stage" install --path "$rtk_snapshot_path" --locked --force; then
    cargo_status=0
  else
    cargo_status=$?
  fi
  /usr/bin/rm -rf -- "$cargo_target_dir"
  (( cargo_status == 0 )) || return "$cargo_status"
  cargo_real_after="$(/usr/bin/realpath -e -- "$HOME/.cargo/bin/cargo" 2>/dev/null || true)"
  cargo_hash_after="$(/usr/bin/sha256sum -- "$cargo_real_after" | /usr/bin/gawk '{print $1}')"
  cargo_identity_after="$(/usr/bin/stat -Lc '%d:%i' -- "$cargo_real_after" 2>/dev/null || true)"
  [[ "$cargo_real_after" == "$cargo_real" && "$cargo_identity_after" == "$cargo_identity_before" && \
    "$cargo_hash_after" == "$cargo_hash_before" ]] || {
    echo 'Canonical Cargo executable changed across the build seam.' >&2
    return 1
  }
}

install_receipt_from_snapshots() {
  local payload_root payload_manifest expected_payload_sha expected_source_helper_sha
  local sudo_bin
  payload_root="$(/usr/bin/mktemp -d /tmp/herdr-receipt-payload.XXXXXX)"
  bootstrap_register_cleanup "$payload_root"
  /usr/bin/chmod 0700 -- "$payload_root"
  /usr/bin/mkdir -p -- "$payload_root/source" "$payload_root/rtk"
  /usr/bin/cp -a -- "$bootstrap_source_snapshot/." "$payload_root/source/"
  /usr/bin/cp -a -- "$rtk_snapshot_path/." "$payload_root/rtk/"
  payload_manifest="$payload_root/.payload-manifest"
  expected_source_helper_sha="$(attestation_snapshot_file_digest \
    "$bootstrap_source_snapshot/.source-attestation" scripts/ubuntu/source-attestation.sh)"
  attestation_build_payload_manifest "$payload_root" "$payload_manifest" || {
    /usr/bin/rm -rf -- "$payload_root"
    return 1
  }
  expected_payload_sha="$(attestation_hash_file "$payload_manifest")"
  sudo_bin="$(bootstrap_command_path sudo)"

  /usr/bin/tar -C "$payload_root" -cf - . | "$sudo_bin" -- /usr/bin/bash -c '
    set -euo pipefail
    expected_payload_sha="$1"
    expected_source_helper_sha="$2"
    managed_user_home="$3"
    stage="$(/usr/bin/mktemp -d /tmp/herdr-root-receipt-payload.XXXXXX)"
    cleanup_root_payload() { /usr/bin/rm -rf -- "$stage"; }
    trap cleanup_root_payload EXIT
    /usr/bin/tar --extract --file=- --directory="$stage" --no-same-owner --no-same-permissions
    /usr/bin/chown -R --no-dereference 0:0 -- "$stage"
    [[ -f "$stage/.payload-manifest" && ! -L "$stage/.payload-manifest" ]] || exit 24
    [[ "$(/usr/bin/sha256sum -- "$stage/.payload-manifest" | /usr/bin/gawk "{print \$1}")" == "$expected_payload_sha" ]] || exit 24
    [[ "$(/usr/bin/sha256sum -- "$stage/source/scripts/ubuntu/source-attestation.sh" | /usr/bin/gawk "{print \$1}")" == "$expected_source_helper_sha" ]] || exit 24
    # The helper exact committed bytes are checked before it is sourced.  It
    # then proves every other extracted file before the authority script is
    # loaded, so root never executes a mutable payload input.
    # shellcheck disable=SC1091
    source "$stage/source/scripts/ubuntu/source-attestation.sh"
    attestation_reject_git_environment
    attestation_verify_payload_manifest "$stage" "$stage/.payload-manifest" "$expected_payload_sha"
    exec /usr/bin/bash "$stage/source/scripts/ubuntu/receipt-authority.sh" \
      --install \
      --source-root "$stage/source" \
      --source-manifest "$stage/source/.source-attestation" \
      --rtk-source-root "$stage/rtk" \
      --rtk-source-manifest "$stage/rtk/.source-attestation" \
      --payload-root "$stage" \
      --payload-manifest "$stage/.payload-manifest" \
      --payload-manifest-sha256 "$expected_payload_sha" \
      --user-home "$managed_user_home"
  ' -- "$expected_payload_sha" "$expected_source_helper_sha" "$HOME"
  /usr/bin/rm -rf -- "$payload_root"
}

validate_user_home() {
  [[ -n "${HOME:-}" && "$HOME" == /* && "$HOME" != '/' && -d "$HOME" ]] || {
    echo 'HOME is not a safe absolute user directory.' >&2
    return 1
  }
  [[ ! -L "$HOME" ]] || {
    echo 'HOME itself must not be a symlink.' >&2
    return 1
  }
  home_real="$(/usr/bin/realpath -e -- "$HOME" 2>/dev/null || true)"
  [[ -n "$home_real" && -d "$home_real" ]] || {
    echo 'Could not resolve the real user home.' >&2
    return 1
  }
  [[ "$(/usr/bin/stat -c '%u' -- "$home_real" 2>/dev/null || true)" == "$(/usr/bin/id -u)" ]] || {
    echo 'The resolved user home is not owned by the current user.' >&2
    return 1
  }
}

validate_managed_path() {
  local path="$1"
  local normalized
  local relative
  local component
  local component_path
  local -a components

  [[ "$path" == "$HOME" || "$path" == "$HOME/"* ]] || {
    echo "Managed path is outside HOME: $path" >&2
    return 1
  }
  normalized="$(/usr/bin/realpath -m -- "$path" 2>/dev/null || true)"
  path_is_under "$normalized" "$home_real" || {
    echo "Managed path resolves outside the real user home: $path" >&2
    return 1
  }

  [[ "$path" == "$HOME" ]] && return 0
  relative="${path#"$HOME"/}"
  component_path="$HOME"
  IFS='/' read -r -a components <<< "$relative"
  for component in "${components[@]}"; do
    [[ -z "$component" || "$component" == '.' ]] && continue
    component_path="$component_path/$component"
    [[ ! -L "$component_path" ]] || {
      echo "Managed path contains a symlinked component: $component_path" >&2
      return 1
    }
  done
}

validate_managed_paths() {
  validate_user_home || return 1
  local path
  for path in "$@"; do
    validate_managed_path "$path" || return 1
  done
}

fence_components_safe() {
  local path="$1"
  local normalized
  local relative
  local component
  local component_path
  local -a components

  [[ "$path" == "$HOME" || "$path" == "$HOME/"* ]] || return 1
  normalized="$(/usr/bin/realpath -m -- "$path" 2>/dev/null || true)"
  path_is_under "$normalized" "$home_real" || return 1
  [[ "$path" == "$HOME" ]] && return 0
  relative="${path#"$HOME"/}"
  component_path="$HOME"
  IFS='/' read -r -a components <<< "$relative"
  for component in "${components[@]}"; do
    [[ -z "$component" || "$component" == '.' ]] && continue
    [[ "$component" != '..' && "$component" != *'/'* ]] || return 1
    component_path="$component_path/$component"
    [[ ! -L "$component_path" ]] || return 1
  done
}

close_fence_fd() {
  local fd="$1"
  [[ "$fd" =~ ^[0-9]+$ ]] || return 0
  eval "exec ${fd}<&-" 2>/dev/null || true
}

fence_open_directory() {
  local path="$1"
  local output_name="$2"
  local relative
  local component
  local current
  local child
  local -a components
  local opened_fd
  local next_fd

  validate_user_home || exit 24
  fence_components_safe "$path" || {
    echo "Unsafe fenced directory: $path" >&2
    exit 24
  }
  exec {opened_fd}<"$HOME" || { echo 'Could not open fenced HOME directory.' >&2; exit 24; }
  current="/proc/self/fd/$opened_fd"
  relative="${path#"$HOME"}"
  relative="${relative#/}"
  if [[ -n "$relative" ]]; then
    IFS='/' read -r -a components <<< "$relative"
    for component in "${components[@]}"; do
      [[ -n "$component" && "$component" != '.' && "$component" != '..' && "$component" != *'/'* ]] || {
        close_fence_fd "$opened_fd"
        echo "Unsafe fenced path component: $component" >&2
        exit 24
      }
      child="$current/$component"
      [[ ! -L "$child" ]] || {
        close_fence_fd "$opened_fd"
        echo "Fenced directory contains a symlink: $path" >&2
        exit 24
      }
      if [[ ! -e "$child" ]]; then
        /usr/bin/mkdir -- "$child" || {
          close_fence_fd "$opened_fd"
          echo "Could not create fenced directory: $path" >&2
          exit 24
        }
      fi
      [[ -d "$child" && ! -L "$child" ]] || {
        close_fence_fd "$opened_fd"
        echo "Fenced directory is not a real directory: $path" >&2
        exit 24
      }
      exec {next_fd}<"$child" || {
        close_fence_fd "$opened_fd"
        echo "Could not open fenced directory: $path" >&2
        exit 24
      }
      close_fence_fd "$opened_fd"
      opened_fd="$next_fd"
      current="/proc/self/fd/$opened_fd"
    done
  fi
  [[ -d "$current" ]] || {
    close_fence_fd "$opened_fd"
    echo "Fenced path is not a directory: $path" >&2
    exit 24
  }
  printf -v "$output_name" '%s' "$opened_fd"
}

fence_directory_matches() {
  local path="$1"
  local fd="$2"
  local fd_id
  local live_id
  [[ "$fd" =~ ^[0-9]+$ ]] || return 1
  [[ -d "/proc/self/fd/$fd" ]] || return 1
  [[ ! -L "$path" ]] || return 1
  fence_components_safe "$path" || return 1
  fd_id="$(/usr/bin/stat -Lc '%d:%i' -- "/proc/self/fd/$fd" 2>/dev/null || true)"
  live_id="$(/usr/bin/stat -Lc '%d:%i' -- "$path" 2>/dev/null || true)"
  [[ -n "$fd_id" && "$fd_id" == "$live_id" ]]
}

fence_require_directory() {
  local path="$1"
  local fd="$2"
  local label="${3:-managed directory}"
  fence_directory_matches "$path" "$fd" || {
    echo "Managed namespace drift detected for $label: $path" >&2
    exit 24
  }
}

fence_open_parent() {
  local path="$1"
  local fd_name="$2"
  local anchor_name="$3"
  local parent_name="$4"
  local expected_fd="${5:-}"
  local fence_open_parent_path="${path%/*}"
  local fence_open_parent_base="${path##*/}"
  local fence_open_parent_fd
  if [[ -n "$expected_fd" ]]; then
    fence_open_parent_fd="$expected_fd"
  else
    fence_open_directory "$fence_open_parent_path" fence_open_parent_fd
  fi
  printf -v "$fd_name" '%s' "$fence_open_parent_fd"
  printf -v "$anchor_name" '/proc/self/fd/%s/%s' "$fence_open_parent_fd" "$fence_open_parent_base"
  printf -v "$parent_name" '%s' "$fence_open_parent_path"
}

fence_require_parent() {
  fence_require_directory "$1" "$2" "${3:-managed parent}"
}

bootstrap_test_pause() {
  local phase="$1"
  local ready_file="${HERDR_BOOTSTRAP_TEST_READY_FILE:-${HERDR_PAYLOAD_TEST_READY_FILE:-}}"
  local continue_file="${HERDR_BOOTSTRAP_TEST_CONTINUE_FILE:-${HERDR_PAYLOAD_TEST_CONTINUE_FILE:-}}"
  [[ "${HERDR_BOOTSTRAP_TEST_PAUSE_PHASE:-}" == "$phase" ]] || return 0
  [[ -n "$ready_file" && -n "$continue_file" ]] || {
    echo "Test pause is missing synchronization files: $phase" >&2
    exit 24
  }
  : > "$ready_file"
  while [[ ! -e "$continue_file" ]]; do sleep 0.01; done
}

fence_replace_link() {
  local source="$1"
  local link_path="$2"
  local phase="$3"
  local expected_fd="${4:-}"
  local fd
  local anchor
  local parent
  local owns_fd=0
  if [[ -n "$expected_fd" ]]; then
    fence_open_parent "$link_path" fd anchor parent "$expected_fd"
  else
    fence_open_parent "$link_path" fd anchor parent
    owns_fd=1
  fi
  fence_require_parent "$parent" "$fd" "link parent for $link_path"
  bootstrap_test_pause "$phase"
  fence_require_parent "$parent" "$fd" "link parent for $link_path"
  [[ ! -e "$anchor" || -L "$anchor" ]] || {
    if (( owns_fd == 1 )); then close_fence_fd "$fd"; fi
    echo "Refusing to replace non-managed path: $link_path" >&2
    exit 24
  }
  ln -sfnT -- "$source" "$anchor"
  fence_require_parent "$parent" "$fd" "link parent for $link_path"
  if (( owns_fd == 1 )); then close_fence_fd "$fd"; fi
}

fence_replace_file() {
  local source="$1"
  local target_path="$2"
  local mode="$3"
  local phase="$4"
  local expected_fd="${5:-}"
  local fd
  local anchor
  local parent
  local owns_fd=0
  if [[ -n "$expected_fd" ]]; then
    fence_open_parent "$target_path" fd anchor parent "$expected_fd"
  else
    fence_open_parent "$target_path" fd anchor parent
    owns_fd=1
  fi
  fence_require_parent "$parent" "$fd" "file parent for $target_path"
  chmod "$mode" "$source"
  bootstrap_test_pause "$phase"
  fence_require_parent "$parent" "$fd" "file parent for $target_path"
  [[ ! -L "$anchor" ]] || {
    if (( owns_fd == 1 )); then close_fence_fd "$fd"; fi
    echo "Managed file path became a symlink: $target_path" >&2
    exit 24
  }
  mv -T -- "$source" "$anchor"
  fence_require_parent "$parent" "$fd" "file parent for $target_path"
  if (( owns_fd == 1 )); then close_fence_fd "$fd"; fi
}

fence_replace_python_launcher() {
  local source="$1"
  local target_path="$2"
  local phase="$3"
  local expected_fd="${4:-}"
  local managed_root="$5"
  local fd
  local anchor
  local parent
  local existing_real
  local owns_fd=0
  if [[ -n "$expected_fd" ]]; then
    fence_open_parent "$target_path" fd anchor parent "$expected_fd"
  else
    fence_open_parent "$target_path" fd anchor parent
    owns_fd=1
  fi
  fence_require_parent "$parent" "$fd" "Python launcher parent for $target_path"
  [[ -f "$source" && ! -L "$source" ]] || {
    if (( owns_fd == 1 )); then close_fence_fd "$fd"; fi
    echo "Python launcher source is not a regular file: $source" >&2
    exit 24
  }
  if [[ -L "$anchor" ]]; then
    existing_real="$(/usr/bin/realpath -e -- "$target_path" 2>/dev/null || true)"
    [[ "$existing_real" == "$managed_root"/python/*/bin/python3.13 ]] || {
      if (( owns_fd == 1 )); then close_fence_fd "$fd"; fi
      echo "Refusing to replace an unmanaged Python launcher symlink: $target_path" >&2
      exit 24
    }
    [[ -f "$existing_real" && ! -L "$existing_real" ]] || {
      if (( owns_fd == 1 )); then close_fence_fd "$fd"; fi
      echo "Managed Python launcher symlink does not target a regular runtime: $target_path" >&2
      exit 24
    }
    fence_components_safe "$existing_real" || {
      if (( owns_fd == 1 )); then close_fence_fd "$fd"; fi
      echo "Managed Python launcher symlink target has unsafe components: $target_path" >&2
      exit 24
    }
  elif [[ -e "$anchor" && ! -f "$anchor" ]]; then
    if (( owns_fd == 1 )); then close_fence_fd "$fd"; fi
    echo "Refusing to replace a non-file Python launcher: $target_path" >&2
    exit 24
  fi
  chmod 0755 "$source"
  bootstrap_test_pause "$phase"
  fence_require_parent "$parent" "$fd" "Python launcher parent for $target_path"
  mv -T -- "$source" "$anchor"
  fence_require_parent "$parent" "$fd" "Python launcher parent for $target_path"
  [[ -f "$anchor" && ! -L "$anchor" ]] || {
    if (( owns_fd == 1 )); then close_fence_fd "$fd"; fi
    echo "Python launcher publication did not produce a regular file: $target_path" >&2
    exit 24
  }
  if (( owns_fd == 1 )); then close_fence_fd "$fd"; fi
}

fence_remove_managed_link() {
  local source="$1"
  local target_path="$2"
  local phase="$3"
  local expected_fd="${4:-}"
  local fd
  local anchor
  local parent
  local expected_real
  local actual_real
  local quarantine_dir
  local quarantine_path
  local detached_real
  local owns_fd=0
  if [[ -n "$expected_fd" ]]; then
    fence_open_parent "$target_path" fd anchor parent "$expected_fd"
  else
    fence_open_parent "$target_path" fd anchor parent
    owns_fd=1
  fi
  fence_require_parent "$parent" "$fd" "managed alias parent for $target_path"
  if [[ -e "$anchor" || -L "$anchor" ]]; then
    [[ -L "$anchor" ]] || {
      if (( owns_fd == 1 )); then close_fence_fd "$fd"; fi
      echo "Refusing to replace a non-managed alias: $target_path" >&2
      exit 24
    }
    expected_real="$(/usr/bin/realpath -e -- "$source" 2>/dev/null || true)"
    actual_real="$(/usr/bin/realpath -e -- "$target_path" 2>/dev/null || true)"
    [[ -n "$expected_real" && "$actual_real" == "$expected_real" ]] || {
      if (( owns_fd == 1 )); then close_fence_fd "$fd"; fi
      echo "Refusing to remove an unmanaged alias: $target_path" >&2
      exit 24
    }
    quarantine_dir="$(/usr/bin/mktemp -d "$parent/.herdr-rtk-remove.XXXXXX")" || {
      if (( owns_fd == 1 )); then close_fence_fd "$fd"; fi
      echo "Could not create the managed alias quarantine: $target_path" >&2
      exit 24
    }
    bootstrap_register_cleanup "$quarantine_dir"
    /usr/bin/chmod 0700 -- "$quarantine_dir"
    quarantine_path="$quarantine_dir/${target_path##*/}"
    bootstrap_test_pause "$phase"
    fence_require_parent "$parent" "$fd" "managed alias parent for $target_path"
    # Detach the name with one atomic no-replace rename.  The object moved to
    # quarantine is then the object whose identity is checked; the target
    # pathname is never checked and later unlinked.  If a replacement won the
    # race, restore that exact replacement when the target name is still free,
    # otherwise leave it quarantined and fail closed without removing it.
    /usr/bin/mv -n -T -- "$anchor" "$quarantine_path" || {
      echo "Managed alias could not be atomically detached: $target_path" >&2
      exit 24
    }
    [[ ! -e "$anchor" && ! -L "$anchor" ]] || {
      echo "Managed alias detach did not produce the expected state: $target_path" >&2
      exit 24
    }
    if [[ ! -L "$quarantine_path" ]]; then
      # A raced regular-file replacement may have won the rename.  Restore
      # that exact object to the public name before failing closed; never
      # quarantine it away from the name an operator or subsequent run sees.
      if [[ ! -e "$anchor" && ! -L "$anchor" ]]; then
        /usr/bin/mv -n -T -- "$quarantine_path" "$anchor" || true
      fi
      if (( owns_fd == 1 )); then close_fence_fd "$fd"; fi
      echo "Managed alias replacement was not a symlink: $target_path" >&2
      exit 24
    fi
    detached_real="$(/usr/bin/realpath -e -- "$quarantine_path" 2>/dev/null || true)"
    if [[ "$detached_real" != "$expected_real" ]]; then
      if [[ ! -e "$anchor" && ! -L "$anchor" ]]; then
        /usr/bin/mv -n -T -- "$quarantine_path" "$anchor" || true
      fi
      if (( owns_fd == 1 )); then close_fence_fd "$fd"; fi
      echo "Managed alias replacement won the removal race: $target_path" >&2
      exit 24
    fi
    # Only the already-detached, identity-verified managed link is removed.
    # A replacement at the public alias path is never a target of this rm.
    /usr/bin/rm -f -- "$quarantine_path"
    /usr/bin/rmdir -- "$quarantine_dir" 2>/dev/null || true
  fi
  fence_require_parent "$parent" "$fd" "managed alias parent for $target_path"
  if (( owns_fd == 1 )); then close_fence_fd "$fd"; fi
}

validate_toolchain_lock() {
  for lock_hash_key in UV_SHA256 PYTHON_SHA256 POWERSHELL_SHA256 TAILSCALE_INSTALLER_SHA256 RUSTUP_INIT_SHA256 NODE_SHA256 HERDR_SHA256; do
    [[ "${!lock_hash_key:-}" =~ ^[0-9a-f]{64}$ ]] || {
      echo "Lock key '$lock_hash_key' is not a lowercase SHA-256 value." >&2
      return 1
    }
  done
  [[ "$UV_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo 'UV_VERSION is not a pinned semantic version.' >&2; return 1;
  }
  [[ "$UV_PLATFORM" == 'x86_64-unknown-linux-gnu' ]] || {
    echo 'UV_PLATFORM is not the supported Ubuntu x86-64 target.' >&2; return 1;
  }
  [[ "$UV_URL" == "https://github.com/astral-sh/uv/releases/download/$UV_VERSION/uv-$UV_PLATFORM.tar.gz" ]] || {
    echo 'UV_URL does not identify the pinned official uv artifact.' >&2; return 1;
  }
  [[ "$PYTHON_VERSION" =~ ^3\.13\.[0-9]+$ ]] || {
    echo 'PYTHON_VERSION is not a pinned Python 3.13 release.' >&2; return 1;
  }
  [[ "$PYTHON_RELEASE" =~ ^[0-9]{8}$ ]] || {
    echo 'PYTHON_RELEASE is not a pinned python-build-standalone release.' >&2; return 1;
  }
  [[ "$PYTHON_PLATFORM" == 'x86_64-unknown-linux-gnu' ]] || {
    echo 'PYTHON_PLATFORM is not the supported Ubuntu x86-64 target.' >&2; return 1;
  }
  expected_python_archive="cpython-$PYTHON_VERSION+$PYTHON_RELEASE-$PYTHON_PLATFORM-install_only_stripped.tar.gz"
  [[ "$PYTHON_ARCHIVE" == "$expected_python_archive" ]] || {
    echo 'PYTHON_ARCHIVE does not match the pinned Python release inputs.' >&2; return 1;
  }
  expected_python_url="https://github.com/astral-sh/python-build-standalone/releases/download/$PYTHON_RELEASE/${PYTHON_ARCHIVE//+/%2B}"
  [[ "$PYTHON_URL" == "$expected_python_url" ]] || {
    echo 'PYTHON_URL does not identify the pinned official CPython artifact.' >&2; return 1;
  }
  [[ "$TAILSCALE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo 'TAILSCALE_VERSION is not a pinned semantic version.' >&2; return 1;
  }
  [[ "$TAILSCALE_INSTALLER_URL" == 'https://tailscale.com/install.sh' ]] || {
    echo 'TAILSCALE_INSTALLER_URL is not the pinned official installer.' >&2
    return 1
  }
  return 0
}

validate_platform() {
  [[ "$(uname -s)" == 'Linux' && "$(uname -m)" == 'x86_64' && "$(getconf LONG_BIT)" == '64' ]] || {
    echo 'This bootstrap lock supports only 64-bit x86 Linux.' >&2
    return 1
  }
}

check_uv_version() {
  local executable="$1"
  local expected="uv $UV_VERSION ($UV_PLATFORM)"
  local actual
  actual="$("$executable" --version 2>&1)" || return 1
  [[ "$actual" == "$expected" ]]
}

check_python_version() {
  local executable="$1"
  local actual
  actual="$("$executable" --version 2>&1)" || return 1
  [[ "$actual" == "Python $PYTHON_VERSION" ]]
}

check_python_platform() {
  local executable="$1"
  local actual
  actual="$("$executable" -c 'import platform, sys; print(f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}|{platform.machine()}|{sys.platform}")')" || return 1
  [[ "$actual" == "$PYTHON_VERSION|x86_64|linux" ]]
}

write_py_compat() {
  local expected_fd="${1:-}"
  local wrapper="$bin_dir/py"
  local replacement
  local wrapper_fd
  local wrapper_anchor
  local wrapper_parent
  local owns_fd=0
  validate_managed_paths "$wrapper" || {
    echo "Unsafe managed py path: $wrapper" >&2
    exit 24
  }
  if [[ -n "$expected_fd" ]]; then
    fence_open_parent "$wrapper" wrapper_fd wrapper_anchor wrapper_parent "$expected_fd"
  else
    fence_open_parent "$wrapper" wrapper_fd wrapper_anchor wrapper_parent
    owns_fd=1
  fi
  fence_require_parent "$wrapper_parent" "$wrapper_fd" 'managed py parent'
  [[ ! -L "$wrapper_anchor" ]] || {
    if (( owns_fd == 1 )); then close_fence_fd "$wrapper_fd"; fi
    echo "Managed py path is a symlink: $wrapper" >&2
    exit 24
  }
  replacement="$(mktemp)"
  cat > "$replacement" <<'EOF'
#!/usr/bin/bash
set -euo pipefail

if [[ $# -lt 1 || "$1" != '-3.13' ]]; then
  echo 'This managed py command supports only the -3.13 selector.' >&2
  exit 2
fi
shift
wrapper_dir="$(cd -- "$(/usr/bin/dirname -- "${BASH_SOURCE[0]}")" && /usr/bin/pwd)"
exec "$wrapper_dir/python3.13" "$@"
EOF
  chmod 0755 "$replacement"
  bootstrap_test_pause before-py-publish
  fence_require_parent "$wrapper_parent" "$wrapper_fd" 'managed py parent'
  if ! cmp -s "$replacement" "$wrapper_anchor" 2>/dev/null; then
    mv -T -- "$replacement" "$wrapper_anchor"
    replacement=''
  fi
  fence_require_parent "$wrapper_parent" "$wrapper_fd" 'managed py parent'
  if (( owns_fd == 1 )); then close_fence_fd "$wrapper_fd"; fi
  [[ -z "$replacement" ]] || rm -f "$replacement"
}

download_verified() {
  local url="$1"
  local expected_sha="$2"
  local destination="$3"
  bootstrap_register_cleanup "$destination"
  /usr/bin/curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
    --retry 3 --connect-timeout 15 --output "$destination" "$url"
  printf '%s  %s\n' "$expected_sha" "$destination" | /usr/bin/sha256sum --check --status || {
    echo "SHA-256 verification failed for $url" >&2
    /usr/bin/rm -f -- "$destination"
    exit 23
  }
}

install_locked_tailscale() (
  local installed_tailscale
  local tailscale_temp_dir
  local installer
  local apt_get_shim
  local trusted_path='/usr/sbin:/usr/bin:/sbin:/bin'
  local tailscale_bin sudo_bin shell_bin apt_get_bin
  local resolved_apt_get
  local real_apt_get
  local installer_status

  validate_toolchain_lock || exit 22
  tailscale_bin="$(bootstrap_command_path tailscale)"
  sudo_bin="$(bootstrap_command_path sudo)"
  shell_bin='/usr/bin/dash'
  bootstrap_trust_assert_binary "$shell_bin"
  apt_get_bin="$(bootstrap_command_path apt-get)"
  installed_tailscale="$("$tailscale_bin" version 2>/dev/null | /usr/bin/head -n 1 || true)"
  [[ "$installed_tailscale" == "$TAILSCALE_VERSION" ]] && return 0

  tailscale_temp_dir="$(/usr/bin/mktemp -d /tmp/herdr-tailscale.XXXXXX)"
  bootstrap_register_cleanup "$tailscale_temp_dir"
  trap '/usr/bin/rm -rf -- "$tailscale_temp_dir"' EXIT
  installer="$tailscale_temp_dir/install.sh"
  apt_get_shim="$tailscale_temp_dir/apt-get"
  resolved_apt_get="$apt_get_bin"
  real_apt_get="$(/usr/bin/realpath -e -- "$resolved_apt_get" 2>/dev/null || true)"
  if [[ "${HERDR_BOOTSTRAP_TEST_MODE:-0}" == 1 ]]; then
    [[ "$real_apt_get" == "$apt_get_bin" && -x "$real_apt_get" ]] || {
      echo 'Could not resolve the test apt-get executable.' >&2
      exit 24
    }
  else
    [[ "$real_apt_get" == '/usr/bin/apt-get' && -x "$real_apt_get" ]] || {
      echo 'Could not resolve the system apt-get executable.' >&2
      exit 24
    }
  fi

  download_verified "$TAILSCALE_INSTALLER_URL" "$TAILSCALE_INSTALLER_SHA256" "$installer"
  cat > "$apt_get_shim" <<'EOF'
#!/usr/bin/bash
set -euo pipefail

real_apt_get="${HERDR_TAILSCALE_REAL_APT_GET:?}"
locked_version="${TAILSCALE_VERSION:?}"
args=("$@")
has_tailscale_package=0
for arg in "${args[@]}"; do
  case "$arg" in
    tailscale|tailscale=*) has_tailscale_package=1 ;;
  esac
done

if (( has_tailscale_package == 1 )); then
  if [[ "${#args[@]}" -eq 4 &&
        "${args[0]}" == 'install' &&
        "${args[1]}" == '-y' &&
        "${args[2]}" == "tailscale=$locked_version" &&
        "${args[3]}" == 'tailscale-archive-keyring' ]]; then
    exec "$real_apt_get" install --allow-downgrades -y "${args[2]}" "${args[3]}"
  fi
  echo 'Unexpected or unlocked Tailscale apt-get invocation.' >&2
  exit 24
fi

exec "$real_apt_get" "${args[@]}"
EOF
  /usr/bin/chmod 0755 -- "$apt_get_shim"

  if "$sudo_bin" /usr/bin/env \
    PATH="$tailscale_temp_dir:$trusted_path" \
    HERDR_TAILSCALE_REAL_APT_GET="$real_apt_get" \
    TAILSCALE_VERSION="$TAILSCALE_VERSION" \
    "$shell_bin" "$installer"; then
    installer_status=0
  else
    installer_status=$?
  fi
  (( installer_status == 0 )) || {
    echo "Tailscale installer failed with exit status $installer_status." >&2
    exit "$installer_status"
  }
  [[ "$("$tailscale_bin" version | /usr/bin/head -n 1)" == "$TAILSCALE_VERSION" ]] || {
    echo "Tailscale version does not match lock ($TAILSCALE_VERSION)." >&2
    exit 24
  }
)

install_python_toolchain() {
  local state_fd
  local bin_fd
  local local_dir_fd
  local uv_parent_fd
  local uv_version_parent_fd
  local python_parent_fd
  local uv_dir_fd
  local python_dir_fd
  local uv_parent_anchor
  local python_parent_anchor
  local uv_dir_anchor
  local python_dir_anchor
  local uv_dir_parent
  local python_dir_parent
  local bin_dir_anchor
  local local_dir_anchor
  local uv_runtime_real
  local python_runtime_real
  local python_launcher_stage=''
  local python_venv_stage=''
  validate_toolchain_lock || exit 22
  validate_platform || exit 20

  managed_root="$HOME/.local/lib/herdr-workstation"
  uv_parent="$managed_root/uv"
  python_parent="$managed_root/python"
  uv_dir="$uv_parent/$UV_VERSION/$UV_PLATFORM"
  python_dir="$python_parent/$PYTHON_VERSION-$PYTHON_RELEASE-$PYTHON_PLATFORM"
  validate_managed_paths \
    "$state_dir" "$bin_dir" "$managed_root" "$uv_parent" "$python_parent" \
    "$uv_dir" "$uv_dir/uv" "$python_dir" "$python_dir/bin" "$python_dir/bin/python3.13" \
    "$HOME/.local" "$HOME/.local/pyvenv.cfg" || {
      echo 'Managed Python toolchain paths are unsafe.' >&2
      exit 24
    }
  fence_open_directory "$state_dir" state_fd
  fence_open_directory "$bin_dir" bin_fd
  fence_open_directory "$HOME/.local" local_dir_fd
  fence_require_directory "$state_dir" "$state_fd" 'toolchain state directory'
  fence_require_directory "$bin_dir" "$bin_fd" 'toolchain bin directory'
  fence_require_directory "$HOME/.local" "$local_dir_fd" 'local directory'
  bin_dir_anchor="/proc/self/fd/$bin_fd"
  local_dir_anchor="/proc/self/fd/$local_dir_fd"
  bootstrap_test_pause before-toolchain-directory-mutations
  fence_open_directory "$uv_parent" uv_parent_fd
  uv_parent_anchor="/proc/self/fd/$uv_parent_fd"
  fence_open_directory "$uv_parent/$UV_VERSION" uv_version_parent_fd
  fence_open_directory "$python_parent" python_parent_fd
  python_parent_anchor="/proc/self/fd/$python_parent_fd"

  if [[ ! -x "$uv_dir/uv" ]] || ! check_uv_version "$uv_dir/uv"; then
    uv_archive="$(/usr/bin/mktemp --suffix=.tar.gz)"
    bootstrap_register_cleanup "$uv_archive"
    uv_stage="$(/usr/bin/mktemp -d /tmp/herdr-uv-stage.XXXXXX)"
    bootstrap_register_cleanup "$uv_stage"
    download_verified "$UV_URL" "$UV_SHA256" "$uv_archive"
    /usr/bin/tar -xzf "$uv_archive" -C "$uv_stage"
    mapfile -t uv_candidates < <(/usr/bin/find "$uv_stage" -type f -name uv -perm -u+x -print)
    if (( ${#uv_candidates[@]} != 1 )); then
      echo 'The pinned uv archive did not contain exactly one executable uv.' >&2
      exit 24
    fi
    check_uv_version "${uv_candidates[0]}" || {
      echo "uv artifact version does not match the lock ($UV_VERSION)." >&2
      exit 24
    }
    fence_require_directory "$uv_parent" "$uv_parent_fd" 'uv parent'
    uv_install_stage="$(/usr/bin/mktemp -d "$uv_parent_anchor/.install.XXXXXX")"
    bootstrap_register_cleanup "$uv_install_stage"
    /usr/bin/install -m 0755 -- "${uv_candidates[0]}" "$uv_install_stage/uv"
    fence_open_parent "$uv_dir" uv_dir_fd uv_dir_anchor uv_dir_parent "$uv_version_parent_fd"
    bootstrap_test_pause before-uv-publish
    fence_require_parent "$uv_dir_parent" "$uv_dir_fd" 'uv destination parent'
    [[ ! -L "$uv_dir_anchor" ]] || { echo 'Unsafe uv managed destination symlink.' >&2; exit 24; }
    if [[ -e "$uv_dir_anchor" ]]; then /usr/bin/rm -rf -- "$uv_dir_anchor"; fi
    /usr/bin/mv -T -- "$uv_install_stage" "$uv_dir_anchor"
    fence_require_parent "$uv_dir_parent" "$uv_dir_fd" 'uv destination parent'
    close_fence_fd "$uv_dir_fd"
    /usr/bin/rm -rf -- "$uv_stage"
    /usr/bin/rm -f -- "$uv_archive"
  fi

  if [[ ! -x "$python_dir/bin/python3.13" ]] || ! check_python_version "$python_dir/bin/python3.13" || ! check_python_platform "$python_dir/bin/python3.13"; then
    python_archive="$(/usr/bin/mktemp --suffix=.tar.gz)"
    bootstrap_register_cleanup "$python_archive"
    python_stage="$(/usr/bin/mktemp -d /tmp/herdr-python-stage.XXXXXX)"
    bootstrap_register_cleanup "$python_stage"
    download_verified "$PYTHON_URL" "$PYTHON_SHA256" "$python_archive"
    /usr/bin/tar -xzf "$python_archive" -C "$python_stage"
    mapfile -t python_candidates < <(/usr/bin/find "$python_stage" -type f -path '*/bin/python3.13' -perm -u+x -print)
    if (( ${#python_candidates[@]} != 1 )); then
      echo 'The pinned CPython archive did not contain exactly one executable python3.13.' >&2
      exit 24
    fi
    check_python_version "${python_candidates[0]}" && check_python_platform "${python_candidates[0]}" || {
      echo "CPython artifact does not match the lock ($PYTHON_VERSION, $PYTHON_PLATFORM)." >&2
      exit 24
    }
    python_source_root="$(cd "$(/usr/bin/dirname "${python_candidates[0]}")/.." && /usr/bin/pwd -P)"
    fence_require_directory "$python_parent" "$python_parent_fd" 'Python parent'
    python_install_stage="$(/usr/bin/mktemp -d "$python_parent_anchor/.install.XXXXXX")"
    bootstrap_register_cleanup "$python_install_stage"
    /usr/bin/cp -a -- "$python_source_root"/. "$python_install_stage"/
    check_python_version "$python_install_stage/bin/python3.13" && check_python_platform "$python_install_stage/bin/python3.13" || {
      echo 'Staged CPython runtime failed its exact version/platform check.' >&2
      exit 24
    }
    fence_open_parent "$python_dir" python_dir_fd python_dir_anchor python_dir_parent "$python_parent_fd"
    bootstrap_test_pause before-python-publish
    fence_require_parent "$python_dir_parent" "$python_dir_fd" 'Python destination parent'
    [[ ! -L "$python_dir_anchor" ]] || { echo 'Unsafe Python managed destination symlink.' >&2; exit 24; }
    if [[ -e "$python_dir_anchor" ]]; then /usr/bin/rm -rf -- "$python_dir_anchor"; fi
    /usr/bin/mv -T -- "$python_install_stage" "$python_dir_anchor"
    fence_require_parent "$python_dir_parent" "$python_dir_fd" 'Python destination parent'
    close_fence_fd "$python_dir_fd"
    /usr/bin/rm -rf -- "$python_stage"
    /usr/bin/rm -f -- "$python_archive"
  fi

  uv_runtime_real="$(/usr/bin/realpath -e -- "$uv_dir/uv" 2>/dev/null || true)"
  python_runtime_real="$(/usr/bin/realpath -e -- "$python_dir/bin/python3.13" 2>/dev/null || true)"
  path_is_under "$uv_runtime_real" "$home_real" || { echo 'uv runtime escaped the managed HOME.' >&2; exit 24; }
  path_is_under "$python_runtime_real" "$home_real" || { echo 'Python runtime escaped the managed HOME.' >&2; exit 24; }
  [[ -f "$python_runtime_real" && ! -L "$python_runtime_real" ]] || { echo 'Managed Python runtime is not a regular file.' >&2; exit 24; }
  fence_replace_link "$uv_runtime_real" "$bin_dir/uv" before-uv-link-publish "$bin_fd"
  python_launcher_stage="$(/usr/bin/mktemp "$bin_dir_anchor/.python3.13.XXXXXX")"
  bootstrap_register_cleanup "$python_launcher_stage"
  /usr/bin/install -m 0755 -- "$python_runtime_real" "$python_launcher_stage"
  fence_replace_python_launcher "$python_launcher_stage" "$bin_dir/python3.13" before-python-link-publish "$bin_fd" "$managed_root"
  python_launcher_stage=''
  python_venv_stage="$(/usr/bin/mktemp "$local_dir_anchor/.pyvenv.cfg.XXXXXX")"
  bootstrap_register_cleanup "$python_venv_stage"
  cat > "$python_venv_stage" <<EOF
home = $python_dir
include-system-site-packages = false
version = $PYTHON_VERSION
EOF
  fence_replace_file "$python_venv_stage" "$HOME/.local/pyvenv.cfg" 0644 before-python-venv-config-publish "$local_dir_fd"
  python_venv_stage=''
  write_py_compat "$bin_fd"
  check_uv_version "$bin_dir/uv" || { echo 'Managed uv failed its final version check.' >&2; exit 24; }
  check_python_version "$bin_dir/python3.13" && check_python_platform "$bin_dir/python3.13" || {
    echo 'Managed python3.13 failed its final version/platform check.' >&2
    exit 24
  }
  py_probe="$("$bin_dir/py" -3.13 -c 'import platform, sys; print(f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}|{platform.machine()}|{sys.platform}")')"
  [[ "$py_probe" == "$PYTHON_VERSION|x86_64|linux" ]] || {
    echo 'Managed py -3.13 did not select the pinned CPython runtime.' >&2
    exit 24
  }
  fence_require_directory "$state_dir" "$state_fd" 'toolchain state directory'
  fence_require_directory "$bin_dir" "$bin_fd" 'toolchain bin directory'
  close_fence_fd "$uv_version_parent_fd"
  close_fence_fd "$uv_parent_fd"
  close_fence_fd "$python_parent_fd"
  close_fence_fd "$local_dir_fd"
  close_fence_fd "$state_fd"
  close_fence_fd "$bin_fd"
}

converge_profile_hook() {
  local profile_file="$1"
  local chain_profile="${2:-false}"
  local marker='# BEGIN herdr-workstation PATH'
  local end_marker='# END herdr-workstation PATH'
  local replacement
  local profile_fd
  local profile_anchor
  local profile_parent
  local backup_temp=''
  local backup_name
  local backup_anchor
  validate_managed_paths "$profile_file" || {
    echo "Unsafe managed profile path: $profile_file" >&2
    exit 24
  }
  fence_open_parent "$profile_file" profile_fd profile_anchor profile_parent
  fence_require_parent "$profile_parent" "$profile_fd" "profile parent for $profile_file"
  [[ ! -L "$profile_anchor" ]] || {
    close_fence_fd "$profile_fd"
    echo "Managed profile path is a symlink: $profile_file" >&2
    exit 24
  }
  replacement="$(mktemp)"
  if [[ ! -e "$profile_anchor" ]]; then : > "$profile_anchor"; fi
  fence_require_parent "$profile_parent" "$profile_fd" "profile parent for $profile_file"
  mapfile -t begin_lines < <(grep -nFx "$marker" "$profile_anchor" | cut -d: -f1)
  mapfile -t end_lines < <(grep -nFx "$end_marker" "$profile_anchor" | cut -d: -f1)
  if (( ${#begin_lines[@]} == 0 && ${#end_lines[@]} == 0 )); then
    cp "$profile_anchor" "$replacement"
  elif (( ${#begin_lines[@]} == 1 && ${#end_lines[@]} == 1 && begin_lines[0] < end_lines[0] )); then
    begin="${begin_lines[0]}"
    end="${end_lines[0]}"
    remove_start="$begin"
    if (( begin > 1 )) && [[ -z "$(sed -n "$((begin - 1))p" "$profile_anchor")" ]]; then
      remove_start=$((begin - 1))
    fi
    if (( remove_start > 1 )); then head -n "$((remove_start - 1))" "$profile_anchor" > "$replacement"; fi
    tail -n "+$((end + 1))" "$profile_anchor" >> "$replacement"
  else
    echo "Managed PATH markers in $profile_file are missing, duplicated, or out of order." >&2
    exit 24
  fi
  if [[ -s "$replacement" ]]; then
    if [[ "$(tail -c 1 "$replacement" | wc -l)" -eq 0 ]]; then printf '\n' >> "$replacement"; fi
    printf '\n' >> "$replacement"
  fi
  {
    printf '%s\n' "$marker"
    if [[ "$chain_profile" == true ]]; then
      printf '%s\n' 'if [[ "${HERDR_PROFILE_SOURCED_PID:-}" != "$$" && "${HERDR_PROFILE_CHAIN_ACTIVE:-0}" != 1 ]]; then'
      printf '%s\n' '  export HERDR_PROFILE_CHAIN_ACTIVE=1'
      printf '%s\n' '  [[ -f "$HOME/.profile" ]] && . "$HOME/.profile"'
      printf '%s\n' '  unset HERDR_PROFILE_CHAIN_ACTIVE'
      printf '%s\n' 'fi'
    else
      printf '%s\n' 'export HERDR_PROFILE_SOURCED_PID="$$"'
      printf '. "$HOME/.config/herdr-workstation/profile.sh"\n'
    fi
    printf '%s\n' "$end_marker"
  } >> "$replacement"
  if ! cmp -s "$profile_anchor" "$replacement"; then
    fence_require_parent "$profile_parent" "$profile_fd" "profile parent for $profile_file"
    backup_name="$(basename "$profile_file").$(date +%Y%m%d-%H%M%S)-$$.bak"
    backup_temp="$(mktemp "/proc/self/fd/$profile_fd/.herdr-profile-backup.XXXXXX")"
    cp "$profile_anchor" "$backup_temp"
    backup_anchor="/proc/self/fd/$profile_fd/$backup_name"
    mv -T -- "$backup_temp" "$backup_anchor"
    backup_temp=''
    chmod 0644 "$replacement"
    bootstrap_test_pause before-profile-publish
    fence_require_parent "$profile_parent" "$profile_fd" "profile parent for $profile_file"
    [[ ! -L "$profile_anchor" ]] || {
      close_fence_fd "$profile_fd"
      rm -f "$replacement"
      echo "Managed profile path became a symlink: $profile_file" >&2
      exit 24
    }
    mv -T -- "$replacement" "$profile_anchor"
    replacement=''
    fence_require_parent "$profile_parent" "$profile_fd" "profile parent for $profile_file"
  fi
  close_fence_fd "$profile_fd"
  [[ -z "$backup_temp" ]] || rm -f "$backup_temp"
  [[ -z "$replacement" ]] || rm -f "$replacement"
}

install_base() {
  local state_fd
  local bin_fd
  local state_anchor
  local sudo_bin apt_get_bin ps_bin pwsh_bin systemctl_bin
  sudo_bin="$(bootstrap_command_path sudo)"
  apt_get_bin="$(bootstrap_command_path apt-get)"
  ps_bin="$(bootstrap_command_path ps)"
  pwsh_bin="$(bootstrap_command_path pwsh)"
  systemctl_bin="$(bootstrap_command_path systemctl)"
  validate_toolchain_lock || exit 22
  validate_managed_paths "$state_dir" "$state_dir/base-complete" "$bin_dir" || {
    echo 'Managed bootstrap paths are unsafe.' >&2
    exit 24
  }
  fence_open_directory "$state_dir" state_fd
  fence_open_directory "$bin_dir" bin_fd
  state_anchor="/proc/self/fd/$state_fd"
  fence_require_directory "$state_dir" "$state_fd" 'base state directory'
  fence_require_directory "$bin_dir" "$bin_fd" 'base bin directory'
  bootstrap_test_pause before-base-directory-mutations
  "$sudo_bin" "$apt_get_bin" update
  "$sudo_bin" DEBIAN_FRONTEND=noninteractive "$apt_get_bin" install -y \
    apt-transport-https build-essential ca-certificates cifs-utils curl git git-lfs gh gnupg jq mosh \
    openssh-client openssh-server pkg-config ripgrep rsync unzip zip
  PATH='/usr/sbin:/usr/bin:/sbin:/bin' /usr/bin/git lfs install

  if [[ "$("$ps_bin" -p 1 -o comm=)" != "systemd" ]]; then
    echo 'PID 1 is not systemd. This bootstrap expects a normal Ubuntu VM boot.' >&2
    exit 21
  fi

  installed_pwsh="$("$pwsh_bin" -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>/dev/null || true)"
  if [[ "$installed_pwsh" != "$POWERSHELL_VERSION" ]]; then
    package="$(/usr/bin/mktemp --suffix=.deb)"
    bootstrap_register_cleanup "$package"
    download_verified "$POWERSHELL_URL" "$POWERSHELL_SHA256" "$package"
    "$sudo_bin" DEBIAN_FRONTEND=noninteractive "$apt_get_bin" install -y "$package"
    /usr/bin/rm -f -- "$package"
  fi
  [[ "$("$pwsh_bin" -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')" == "$POWERSHELL_VERSION" ]] || {
    echo 'PowerShell version does not match lock.' >&2; exit 24;
  }

  "$sudo_bin" "$systemctl_bin" enable --now ssh
  install_locked_tailscale
  "$sudo_bin" "$systemctl_bin" enable --now tailscaled
  fence_require_directory "$state_dir" "$state_fd" 'base state directory'
  : > "$state_anchor/base-complete"
  fence_require_directory "$state_dir" "$state_fd" 'base state directory'
  close_fence_fd "$state_fd"
  close_fence_fd "$bin_fd"
}

install_tools() {
  local state_fd
  local bin_fd
  local state_anchor
  local src_fd
  local src_anchor
  local profile_dir_fd
  local profile_dir_anchor
  local node_fd
  local node_anchor
  local code_fd
  local manifest_tmp
  local ps_bin
  ps_bin="$(bootstrap_command_path ps)"
  profile_dir="$HOME/.config/herdr-workstation"
  node_dir="$HOME/.local/lib/node-v${NODE_VERSION}-linux-x64"
  validate_cargo_roots || exit 24
  validate_managed_paths \
    "$state_dir" "$state_dir/base-complete" "$state_dir/toolchain-manifest.txt" \
    "$bin_dir" "$profile_dir" "$profile_dir/profile.sh" "$node_dir" "$node_dir/bin" "$HOME/src" \
    "$HOME/.cargo" "$HOME/.cargo/bin" "$HOME/.cargo/bin/rtk" \
    "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.bash_login" || {
      echo 'Managed bootstrap paths are unsafe.' >&2
      exit 24
    }
  fence_open_directory "$state_dir" state_fd
  fence_open_directory "$bin_dir" bin_fd
  fence_open_directory "$profile_dir" profile_dir_fd
  fence_open_directory "$HOME/src" src_fd
  fence_open_directory "$node_dir" node_fd
  fence_open_directory "$HOME/code" code_fd
  state_anchor="/proc/self/fd/$state_fd"
  src_anchor="/proc/self/fd/$src_fd"
  profile_dir_anchor="/proc/self/fd/$profile_dir_fd"
  node_anchor="/proc/self/fd/$node_fd"
  fence_require_directory "$state_dir" "$state_fd" 'tools state directory'
  fence_require_directory "$bin_dir" "$bin_fd" 'tools bin directory'
  fence_require_directory "$profile_dir" "$profile_dir_fd" 'profile directory'
  fence_require_directory "$HOME/src" "$src_fd" 'source directory'
  fence_require_directory "$node_dir" "$node_fd" 'Node directory'
  bootstrap_test_pause before-tools-directory-mutations
  if [[ "$("$ps_bin" -p 1 -o comm=)" != "systemd" ]]; then
    echo 'systemd is required before the tools phase.' >&2
    exit 21
  fi

  rustup_path="$HOME/.cargo/bin/rustup"
  installed_rustup=''
  if [[ -x "$rustup_path" ]]; then
    installed_rustup="$("$rustup_path" --version 2>/dev/null | /usr/bin/gawk 'NR == 1 { print $1 " " $2 }' || true)"
  fi
  if [[ "$installed_rustup" != "rustup $RUSTUP_VERSION" ]]; then
    rustup_temp_dir="$(/usr/bin/mktemp -d /tmp/herdr-rustup.XXXXXX)"
    bootstrap_register_cleanup "$rustup_temp_dir"
    # rustup-init dispatches by argv[0], so its executable basename must remain exact.
    rustup_init="$rustup_temp_dir/rustup-init"
    download_verified "$RUSTUP_INIT_URL" "$RUSTUP_INIT_SHA256" "$rustup_init"
    /usr/bin/chmod 0700 -- "$rustup_init"
    "$rustup_init" -y --no-modify-path --profile minimal --default-toolchain "$RUST_TOOLCHAIN"
    /usr/bin/rm -rf -- "$rustup_temp_dir"
  fi
  if [[ -f "$HOME/.cargo/env" ]]; then
    # shellcheck disable=SC1091
    source "$HOME/.cargo/env"
  fi
  validate_cargo_roots || exit 24
  [[ -x "$rustup_path" ]] && attestation_canonical_cargo "$HOME" >/dev/null || {
    echo 'The locked rustup is present but the canonical ~/.cargo toolchain identities are not both available.' >&2
    exit 24
  }
  "$rustup_path" set auto-self-update disable
  [[ "$("$rustup_path" --version | /usr/bin/gawk 'NR == 1 { print $1 " " $2 }')" == "rustup $RUSTUP_VERSION" ]] || {
    echo "rustup version does not match lock after reinstall ($RUSTUP_VERSION)." >&2; exit 24;
  }
  "$rustup_path" toolchain install "$RUST_TOOLCHAIN" --profile minimal
  "$rustup_path" default "$RUST_TOOLCHAIN"
  [[ "$("$rustup_path" --version | /usr/bin/gawk 'NR == 1 { print $1 " " $2 }')" == "rustup $RUSTUP_VERSION" ]] || {
    echo "rustup version changed after toolchain installation ($RUSTUP_VERSION)." >&2; exit 24;
  }

  fence_require_directory "$HOME/src" "$src_fd" 'source directory'
  [[ ! -L "$src_anchor/rtk" ]] || {
    echo 'RTK source checkout path must not be a symlink.' >&2
    exit 24
  }
  if [[ ! -d "$src_anchor/rtk/.git" ]]; then
    trusted_git_command clone --no-checkout --no-tags -- "$RTK_REPO_URL" "$HOME/src/rtk"
  else
    validate_rtk_source_checkout "$HOME/src/rtk" "$RTK_REPO_URL" "$RTK_REF" || exit 24
  fi
  fence_require_directory "$HOME/src" "$src_fd" 'source directory'
  trusted_git_command -C "$HOME/src/rtk" fetch --force --no-tags "$RTK_REPO_URL" "$RTK_REF"
  fence_require_directory "$HOME/src" "$src_fd" 'source directory'
  attestation_create_git_snapshot "$HOME/src/rtk" "$RTK_REPO_URL" "$RTK_REF" false || {
    echo 'RTK locked commit could not be materialized without a worktree checkout.' >&2
    exit 24
  }
  rtk_snapshot_path="$attestation_snapshot_dir"
  rtk_snapshot_manifest="$attestation_snapshot_manifest"
  rtk_snapshot_commit="$attestation_snapshot_commit"
  rtk_snapshot_url="$attestation_snapshot_url"
  rtk_snapshot_manifest_sha256="$attestation_snapshot_manifest_sha256"
  install_rtk_snapshot || exit 24
  for executable in rustup cargo rustc; do
    executable_path="$HOME/.cargo/bin/$executable"
    [[ -x "$executable_path" ]] || {
      echo "Canonical Cargo toolchain executable is missing: $executable_path" >&2
      exit 24
    }
    fence_replace_link "$executable_path" "$bin_dir/$executable" "before-$executable-link-publish" "$bin_fd"
  done
  [[ -x "$cargo_install_root/bin/rtk" ]] || {
    echo "cargo installed RTK outside the expected '$cargo_install_root/bin' directory. Set CARGO_INSTALL_ROOT explicitly and retry." >&2
    exit 24
  }
  [[ -f "$cargo_install_root/bin/rtk" && ! -L "$cargo_install_root/bin/rtk" ]] || {
    echo 'Canonical cargo RTK is not a regular executable.' >&2
    exit 24
  }
  fence_remove_managed_link "$cargo_install_root/bin/rtk" "$bin_dir/rtk" before-rtk-alias-removal "$bin_fd"

  profile_script_tmp="$(mktemp)"
  {
    printf '%s\n' '# Managed by herdr-workstation-bootstrap.'
    printf '%s\n' 'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac'
    printf '%s\n' 'case ":$PATH:" in *":$HOME/.cargo/bin:"*) ;; *) PATH="$HOME/.cargo/bin:$PATH" ;; esac'
    printf '%s\n' 'export PATH'
  } > "$profile_script_tmp"
  fence_replace_file "$profile_script_tmp" "$profile_dir/profile.sh" 0644 before-profile-script-publish "$profile_dir_fd"
  profile_script_tmp=''
  converge_profile_hook "$HOME/.profile"
  if [[ -e "$HOME/.bash_profile" ]]; then
    converge_profile_hook "$HOME/.bash_profile" true
  fi
  if [[ -e "$HOME/.bash_login" ]]; then
    converge_profile_hook "$HOME/.bash_login" true
  fi

  install_python_toolchain

  fence_require_directory "$node_dir" "$node_fd" 'Node directory'
  if [[ ! -x "$node_anchor/bin/node" ]]; then
    archive="$(mktemp --suffix=.tar.gz)"
    download_verified "$NODE_URL" "$NODE_SHA256" "$archive"
    bootstrap_test_pause before-node-extract
    fence_require_directory "$node_dir" "$node_fd" 'Node directory'
    tar -xzf "$archive" -C "$node_anchor" --strip-components=1
    fence_require_directory "$node_dir" "$node_fd" 'Node directory'
    rm -f "$archive"
  fi
  for executable in node npm npx corepack; do
    executable_real="$(realpath -e -- "$node_anchor/bin/$executable" 2>/dev/null || true)"
    path_is_under "$executable_real" "$home_real" || { echo "Node executable escaped HOME: $executable" >&2; exit 24; }
    fence_replace_link "$executable_real" "$bin_dir/$executable" "before-$executable-link-publish" "$bin_fd"
  done
  # Keep the process PATH hermetic.  User-local tools are invoked below by
  # their validated absolute paths; no user-writable directory is prepended
  # globally.
  export PATH="$bootstrap_trusted_path"
  hash -r
  [[ "$("$node_anchor/bin/node" --version)" == "v$NODE_VERSION" ]] || { echo 'Node version does not match lock.' >&2; exit 24; }

  "$node_anchor/bin/npm" install --global --save-exact --prefix "$node_anchor" \
    "@openai/codex@$CODEX_VERSION" \
    "@anthropic-ai/claude-code@$CLAUDE_VERSION" \
    "bun@$BUN_VERSION"
  for package_dir in '@openai/codex' '@anthropic-ai/claude-code' bun; do
    [[ -d "$node_anchor/lib/node_modules/$package_dir" ]] || {
      echo "npm did not install '$package_dir' under the pinned Node prefix '$node_dir'." >&2
      exit 24
    }
  done
  for executable in codex claude bun bunx; do
    executable_real="$(realpath -e -- "$node_anchor/bin/$executable" 2>/dev/null || true)"
    path_is_under "$executable_real" "$home_real" || { echo "Node executable escaped HOME: $executable" >&2; exit 24; }
    fence_replace_link "$executable_real" "$bin_dir/$executable" "before-$executable-link-publish" "$bin_fd"
  done

  herdr_temp="$(mktemp)"
  download_verified "$HERDR_URL" "$HERDR_SHA256" "$herdr_temp"
  fence_replace_file "$herdr_temp" "$bin_dir/herdr" 0755 before-herdr-publish "$bin_fd"
  herdr_temp=''

  [[ "$("$node_anchor/bin/codex" --version | /usr/bin/gawk '{ print $NF }')" == "$CODEX_VERSION" ]] || { echo 'Codex version does not match lock.' >&2; exit 24; }
  [[ "$("$node_anchor/bin/claude" --version | /usr/bin/gawk '{ print $1 }')" == "$CLAUDE_VERSION" ]] || { echo 'Claude version does not match lock.' >&2; exit 24; }
  [[ "$("$node_anchor/bin/bun" --version)" == "$BUN_VERSION" ]] || { echo 'Bun version does not match lock.' >&2; exit 24; }
  [[ "$("$bin_dir/herdr" --version | /usr/bin/gawk '{ print $NF }')" == "$HERDR_VERSION" ]] || { echo 'Herdr version does not match lock.' >&2; exit 24; }

  install_receipt_from_snapshots

  manifest="$state_dir/toolchain-manifest.txt"
  manifest_tmp="$(mktemp "$state_anchor/.toolchain-manifest.XXXXXX")"
  {
    printf 'receipt_format=%s\n' 'issue-961-toolchain-v2'
    printf 'lock_sha256=%s\n' "$(/usr/bin/sha256sum "$lock_file" | /usr/bin/gawk '{print $1}')"
    printf 'host_platform=%s\n' 'linux'
    printf 'host_architecture=%s\n' "$(/usr/bin/uname -m)"
    printf 'uv_path=%s\n' "$bin_dir/uv"
    printf 'python3.13_path=%s\n' "$bin_dir/python3.13"
    printf 'python3.13_kind=%s\n' 'regular-file'
    printf 'python3.13_sha256=%s\n' "$(/usr/bin/sha256sum "$bin_dir/python3.13" | /usr/bin/gawk '{print $1}')"
    printf 'python3.13_pyvenv_cfg=%s\n' "$HOME/.local/pyvenv.cfg"
    printf 'py_path=%s\n' "$bin_dir/py"
    printf 'uv_version=%s\n' "$("$bin_dir/uv" --version)"
    printf 'uv_url=%s\n' "$UV_URL"
    printf 'uv_sha256=%s\n' "$UV_SHA256"
    printf 'python3.13_version=%s\n' "$("$bin_dir/python3.13" --version 2>&1)"
    printf 'py_3.13_version=%s\n' "$("$bin_dir/py" -3.13 --version 2>&1)"
    printf 'py_3.13_probe=%s\n' "$("$bin_dir/py" -3.13 -c 'import platform, sys; print(f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}|{platform.machine()}|{sys.platform}")')"
    printf 'uv_platform=%s\n' "$UV_PLATFORM"
    printf 'python_version=%s\n' "$PYTHON_VERSION"
    printf 'python_platform=%s\n' "$PYTHON_PLATFORM"
    printf 'python_release=%s\n' "$PYTHON_RELEASE"
    printf 'python_archive=%s\n' "$PYTHON_ARCHIVE"
    printf 'python_url=%s\n' "$PYTHON_URL"
    printf 'python_sha256=%s\n' "$PYTHON_SHA256"
    printf 'tailscale=%s\n' "$("$(bootstrap_command_path tailscale)" version | /usr/bin/head -n 1)"
    printf 'rustup=%s\n' "$("$HOME/.cargo/bin/rustup" --version | /usr/bin/head -n 1)"
    printf 'rustc=%s\n' "$("$HOME/.cargo/bin/rustc" --version)"
    printf 'node=%s\n' "$("$node_anchor/bin/node" --version)"
    printf 'npm=%s\n' "$("$node_anchor/bin/npm" --version)"
    printf 'codex=%s\n' "$("$node_anchor/bin/codex" --version)"
    printf 'claude=%s\n' "$("$node_anchor/bin/claude" --version)"
    printf 'bun=%s\n' "$("$node_anchor/bin/bun" --version)"
    printf 'herdr=%s\n' "$("$bin_dir/herdr" --version)"
    printf 'powershell=%s\n' "$("$(bootstrap_command_path pwsh)" -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')"
    printf 'receipt_authority_path=%s\n' '/etc/stmodel/issue-961/receipt-authority.json'
    printf 'receipt_authority_sha256=%s\n' "$(/usr/bin/sha256sum /etc/stmodel/issue-961/receipt-authority.json | /usr/bin/gawk '{print $1}')"
    /usr/bin/dpkg-query -W -f='apt:${binary:Package}=${Version}\n' \
      cifs-utils curl git git-lfs gh jq mosh openssh-client openssh-server ripgrep rsync
  } > "$manifest_tmp"
  fence_require_directory "$state_dir" "$state_fd" 'tools state directory'
  mv -T -- "$manifest_tmp" "$state_anchor/toolchain-manifest.txt"
  manifest_tmp=''
  fence_require_directory "$state_dir" "$state_fd" 'tools state directory'

  fence_require_directory "$HOME/code" "$code_fd" 'code directory'
  fence_require_directory "$state_dir" "$state_fd" 'tools state directory'
  : > "$state_anchor/tools-complete"
  fence_require_directory "$state_dir" "$state_fd" 'tools state directory'
  close_fence_fd "$state_fd"
  close_fence_fd "$bin_fd"
  close_fence_fd "$profile_dir_fd"
  close_fence_fd "$src_fd"
  close_fence_fd "$node_fd"
  close_fence_fd "$code_fd"
  echo "Tool installation complete. Resolved manifest: $manifest"
  echo "The tools are available immediately through $bin_dir. The managed .profile hook, plus any pre-existing .bash_profile or .bash_login chain, makes them available in new Bash login shells."
  echo 'Authentication, Tailscale login, SMB credentials, and Herdr integration validation remain manual.'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "$phase" in
    base) install_base ;;
    validate-lock) validate_toolchain_lock; echo 'Ubuntu toolchain lock validation passed.' ;;
    tools) install_tools ;;
    all) install_base; install_tools ;;
    *) echo "Unsupported phase: $phase" >&2; exit 2 ;;
  esac
fi
