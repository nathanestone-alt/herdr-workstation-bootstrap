#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

# The bootstrap source is itself attested before its functions are exposed.
# Run this function-only suite from a disposable clean fixture so it can be
# invoked from a mutable developer worktree as well as from CI.
source_fixture="$test_root/source"
cp -a -- "$repo_root/." "$source_fixture/"
/usr/bin/rm -rf -- "$source_fixture/.agents" "$source_fixture/.codex"
rm -rf -- "$source_fixture/.git"
git -C "$source_fixture" init -q
git -C "$source_fixture" config user.email fixture@example.invalid
git -C "$source_fixture" config user.name fixture
git -C "$source_fixture" add -f .
git -C "$source_fixture" commit -qm 'clean bootstrap fencing fixture'

# An entrypoint must not source a dirty live helper, even when that helper
# contains top-level code and a forged attestation function.
dirty_bootstrap_root="$test_root/dirty-bootstrap"
cp -a -- "$source_fixture" "$dirty_bootstrap_root"
dirty_bootstrap_marker="$test_root/dirty-bootstrap-top-level"
dirty_bootstrap_function_marker="$test_root/dirty-bootstrap-function"
dirty_bootstrap_entrypoint_marker="$test_root/dirty-bootstrap-entrypoint"
cat >> "$dirty_bootstrap_root/scripts/ubuntu/source-attestation.sh" <<EOF
: > '$dirty_bootstrap_marker'
attestation_create_git_snapshot() { : > '$dirty_bootstrap_function_marker'; return 0; }
EOF
cat >> "$dirty_bootstrap_root/scripts/ubuntu/bootstrap.sh" <<EOF
: > '$dirty_bootstrap_entrypoint_marker'
EOF

bash_env_marker="$test_root/bash-env-reached"
bash_env_file="$test_root/bash-env"
cat > "$bash_env_file" <<EOF
: > '$bash_env_marker'
EOF
chmod 0755 "$bash_env_file"

# Every prelude command is deliberately shadowed by a marker binary.  The
# entrypoints must bind to absolute system tools before any PATH lookup.
hostile_path_bin="$test_root/hostile-path-bin"
mkdir -p "$hostile_path_bin"
for hostile_command in env git realpath dirname find mktemp chmod stat sha256sum gawk cp rm mkdir head; do
  cat > "$hostile_path_bin/$hostile_command" <<EOF
#!/usr/bin/bash
: > '$test_root/path-$hostile_command-reached'
exit 99
EOF
  chmod 0755 "$hostile_path_bin/$hostile_command"
done

set +e
env -i HOME="$test_root/home" PATH="$hostile_path_bin:/usr/bin:/bin" BASH_ENV="$bash_env_file" \
  "$dirty_bootstrap_root/scripts/ubuntu/bootstrap.sh" --phase validate-lock \
  > "$test_root/dirty-bootstrap-output" 2>&1
dirty_bootstrap_status=$?
set -e
(( dirty_bootstrap_status != 0 )) || { echo 'Dirty live bootstrap helper was accepted.' >&2; exit 1; }
[[ ! -e "$dirty_bootstrap_marker" && ! -e "$dirty_bootstrap_function_marker" && \
   ! -e "$dirty_bootstrap_entrypoint_marker" && ! -e "$bash_env_marker" ]] || {
  echo 'Dirty bootstrap helper code executed before attestation.' >&2
  exit 1
}

if ! env -i HOME="$test_root/home" PATH="$hostile_path_bin:/usr/bin:/bin" BASH_ENV="$bash_env_file" \
  "$source_fixture/scripts/ubuntu/bootstrap.sh" --phase validate-lock \
  > "$test_root/hostile-bootstrap-output" 2>&1; then
  cat "$test_root/hostile-bootstrap-output" >&2
  exit 1
fi
for hostile_command in env git realpath dirname find mktemp chmod stat sha256sum gawk cp rm mkdir head; do
  [[ ! -e "$test_root/path-$hostile_command-reached" ]] || {
    echo "Bootstrap resolved hostile PATH command: $hostile_command" >&2
    exit 1
  }
done

bootstrap_script="$source_fixture/scripts/ubuntu/bootstrap.sh"
attestation_helper="$source_fixture/scripts/ubuntu/source-attestation.sh"
repo_root="$source_fixture"
export HOME="$test_root/home"
mkdir -p "$HOME/.local/bin" "$HOME/.local/lib/herdr-workstation" "$HOME/.config/herdr-workstation" "$HOME/.cargo/bin"

# Source only: the real base/tools phases must not run in this regression.
# shellcheck disable=SC1091
source "$bootstrap_script"

# Re-sourcing the helper must not reset the cleanup registry. This mirrors the
# bootstrap/receipt helper reload path and makes failure cleanup observable.
cleanup_registry_probe="$(mktemp -d)"
attestation_register_temporary_path "$cleanup_registry_probe"
source "$attestation_helper"
[[ "${attestation_temporary_paths[*]}" == *"$cleanup_registry_probe"* ]] || {
  echo 'Helper re-source discarded the cleanup registry.' >&2
  exit 1
}
attestation_cleanup_temporary_paths
[[ ! -e "$cleanup_registry_probe" ]] || {
  echo 'Cleanup registry did not remove the re-source probe.' >&2
  exit 1
}

# Cargo roots are validated before any Cargo operation can run.
mkdir -p "$HOME/.cargo"
CARGO_HOME="$HOME/noncanonical-cargo"
if validate_cargo_roots; then
  echo 'Noncanonical CARGO_HOME was accepted.' >&2
  exit 1
fi
unset CARGO_HOME
CARGO_INSTALL_ROOT="$HOME/noncanonical-cargo"
if validate_cargo_roots; then
  echo 'Noncanonical CARGO_INSTALL_ROOT was accepted.' >&2
  exit 1
fi
unset CARGO_INSTALL_ROOT
validate_cargo_roots

# RTK source provenance rejects dirty, staged and untracked source before build.
rtk_source="$test_root/rtk-source"
mkdir -p "$rtk_source"
git -C "$rtk_source" init -q
git -C "$rtk_source" config user.email fixture@example.invalid
git -C "$rtk_source" config user.name fixture
printf 'locked source\n' > "$rtk_source/README"
chmod 0644 "$rtk_source/README"
git -C "$rtk_source" add README
git -C "$rtk_source" commit -qm 'fixture source'
rtk_source_commit="$(git -C "$rtk_source" rev-parse HEAD)"
git -C "$rtk_source" remote add origin https://example.invalid/rtk.git
validate_rtk_source_checkout "$rtk_source" https://example.invalid/rtk.git "$rtk_source_commit"

# Linked worktrees are accepted only when the checkout pointer, reciprocal
# worktree record, exact ../.. common-directory relationship, and local object
# storage all agree on the same source. Each substitution below is rejected
# before any snapshot bytes reach Cargo.
linked_main="$test_root/linked-main"
linked_checkout="$test_root/linked-checkout"
mkdir -p "$linked_main"
git -C "$linked_main" init -q
git -C "$linked_main" config user.email fixture@example.invalid
git -C "$linked_main" config user.name fixture
printf 'linked source\n' > "$linked_main/README"
git -C "$linked_main" add README
git -C "$linked_main" commit -qm 'linked source fixture'
git -C "$linked_main" remote add origin https://example.invalid/rtk.git
git -C "$linked_main" worktree add -q --detach "$linked_checkout" HEAD
linked_commit="$(git -C "$linked_checkout" rev-parse HEAD)"
validate_rtk_source_checkout "$linked_checkout" https://example.invalid/rtk.git "$linked_commit"
linked_git_pointer_before="$(< "$linked_checkout/.git")"
linked_git_dir="$(git -C "$linked_checkout" rev-parse --absolute-git-dir)"
linked_common_dir="$(git -C "$linked_checkout" rev-parse --git-common-dir)"
linked_common_dir="$(realpath -e -- "$linked_common_dir")"
linked_record="$linked_git_dir/gitdir"
linked_record_before="$(< "$linked_record")"
linked_commondir_before="$(< "$linked_git_dir/commondir")"
printf 'gitdir: %s\n' "$linked_main/.git" > "$linked_checkout/.git"
expect_linked_failure() {
  local label="$1"
  if attestation_create_git_snapshot "$linked_checkout" https://example.invalid/rtk.git "$linked_commit"; then
    echo "$label was accepted." >&2
    exit 1
  fi
}
expect_linked_failure 'Substituted linked-worktree checkout pointer'
printf '%s\n' "$linked_git_pointer_before" > "$linked_checkout/.git"
printf '%s\n' "$linked_main/.git" > "$linked_record"
expect_linked_failure 'Substituted linked-worktree reciprocal record'
printf '%s\n' "$linked_record_before" > "$linked_record"
printf '../' > "$linked_git_dir/commondir"
expect_linked_failure 'Substituted linked-worktree commondir'
printf '%s\n' "$linked_commondir_before" > "$linked_git_dir/commondir"
mkdir -p "$linked_common_dir/worktrees/substitution"
printf '%s\n' "$linked_checkout/.git" > "$linked_common_dir/worktrees/substitution/gitdir"
expect_linked_failure 'Duplicate linked-worktree source owner'
rm -rf -- "$linked_common_dir/worktrees/substitution"
mv "$linked_common_dir/objects" "$linked_common_dir/objects-real"
ln -s objects-real "$linked_common_dir/objects"
expect_linked_failure 'Substituted linked-worktree object storage'
rm -- "$linked_common_dir/objects"
mv "$linked_common_dir/objects-real" "$linked_common_dir/objects"

# Git configuration, environment, and PATH are all hostile inputs to the
# attestation seam. They must fail closed before any filter or forged Git is
# reached.
filter_marker="$test_root/filter-marker"
git -C "$rtk_source" config filter.attacker.clean "printf FILTER-RAN > '$filter_marker'"
printf '*.txt filter=attacker\n' > "$rtk_source/.gitattributes"
if attestation_create_git_snapshot "$rtk_source" https://example.invalid/rtk.git "$rtk_source_commit"; then
  echo 'Repository-local clean filter configuration was accepted.' >&2
  exit 1
fi
[[ ! -e "$filter_marker" ]] || { echo 'Repository-local clean filter executed.' >&2; exit 1; }
git -C "$rtk_source" config --unset-all filter.attacker.clean
rm -- "$rtk_source/.gitattributes"

if (export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.filemode GIT_CONFIG_VALUE_0=false; \
  attestation_create_git_snapshot "$rtk_source" https://example.invalid/rtk.git "$rtk_source_commit"); then
  echo 'GIT_CONFIG_COUNT override was accepted.' >&2
  exit 1
fi
if (export GIT_COMMON_DIR="$test_root/external-common"; \
  attestation_create_git_snapshot "$rtk_source" https://example.invalid/rtk.git "$rtk_source_commit"); then
  echo 'GIT_COMMON_DIR override was accepted.' >&2
  exit 1
fi

# No temporary index is created by the attestor.  A pathname that would point
# at the caller index is rejected as an environment override, and the caller
# index remains byte-for-byte and flag-for-flag unchanged.
caller_index_sha_before="$(sha256sum "$rtk_source/.git/index" | awk '{print $1}')"
caller_index_flags_before="$(git -C "$rtk_source" ls-files -v)"
temporary_index="$test_root/replaced-index"
ln -s "$rtk_source/.git/index" "$temporary_index"
if (export GIT_INDEX_FILE="$temporary_index"; \
  attestation_create_git_snapshot "$rtk_source" https://example.invalid/rtk.git "$rtk_source_commit"); then
  echo 'Temporary-index symlink replacement was accepted.' >&2
  exit 1
fi
caller_index_sha_after="$(sha256sum "$rtk_source/.git/index" | awk '{print $1}')"
caller_index_flags_after="$(git -C "$rtk_source" ls-files -v)"
[[ "$caller_index_sha_after" == "$caller_index_sha_before" && \
   "$caller_index_flags_after" == "$caller_index_flags_before" ]] || {
  echo 'Temporary-index probe changed the caller index.' >&2
  exit 1
}

fake_git_bin="$test_root/fake-git-bin"
mkdir -p "$fake_git_bin"
cat > "$fake_git_bin/git" <<EOF
#!/usr/bin/env bash
: > "$test_root/path-git-reached"
exit 99
EOF
chmod 0755 "$fake_git_bin/git"
PATH="$fake_git_bin:/usr/bin:/bin" /usr/bin/bash -c \
  'source "$1"; attestation_create_git_snapshot "$2" https://example.invalid/rtk.git "$3"' \
  _ "$attestation_helper" "$rtk_source" "$rtk_source_commit"
[[ ! -e "$test_root/path-git-reached" ]] || { echo 'PATH-resolved Git was used during attestation.' >&2; exit 1; }

git -C "$rtk_source" config core.filemode false
chmod 0755 "$rtk_source/README"
if attestation_create_git_snapshot "$rtk_source" https://example.invalid/rtk.git "$rtk_source_commit"; then
  echo 'Executable-mode tamper hidden by core.filemode=false.' >&2
  exit 1
fi
chmod 0644 "$rtk_source/README"
git -C "$rtk_source" config --unset core.filemode

cargo_install_marker="$test_root/cargo-install-reached"
cat > "$HOME/.cargo/bin/cargo" <<EOF
#!/usr/bin/env bash
: > "$cargo_install_marker"
EOF
chmod 0755 "$HOME/.cargo/bin/cargo"
cat > "$HOME/.cargo/bin/rustc" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 0755 "$HOME/.cargo/bin/rustc"
install_rtk_from_source "$rtk_source" https://example.invalid/rtk.git "$rtk_source_commit"
[[ -f "$cargo_install_marker" ]] || { echo 'Clean RTK source did not reach the Cargo seam.' >&2; exit 1; }

# Cargo receives only the immutable committed-blob snapshot. The fake Cargo
# mutates the live checkout at invocation; the observed source must remain the
# locked bytes and the install must still complete.
cargo_snapshot_observed="$test_root/cargo-snapshot-observed"
path_cargo_marker="$test_root/path-cargo-reached"
cat > "$HOME/.cargo/bin/cargo" <<EOF
#!/usr/bin/env bash
set -euo pipefail
snapshot_path=''
while [[ \$# -gt 0 ]]; do
  if [[ \$1 == --path ]]; then snapshot_path=\$2; shift 2; else shift; fi
done
cat "\$snapshot_path/README" > "$cargo_snapshot_observed"
printf 'validation-to-cargo race\n' > "$rtk_source/README"
: > "$cargo_install_marker"
EOF
chmod 0755 "$HOME/.cargo/bin/cargo"
PATH="$fake_git_bin:$HOME/.local/fake-cargo:/usr/bin:/bin" install_rtk_from_source "$rtk_source" https://example.invalid/rtk.git "$rtk_source_commit"
[[ "$(< "$cargo_snapshot_observed")" == 'locked source' ]] || {
  echo 'Cargo consumed the live checkout instead of the committed snapshot.' >&2
  exit 1
}
[[ "$(< "$rtk_source/README")" == 'validation-to-cargo race' ]] || exit 1
printf 'locked source\n' > "$rtk_source/README"
chmod 0644 "$rtk_source/README"
mkdir -p "$HOME/.local/fake-cargo"
cat > "$HOME/.local/fake-cargo/cargo" <<EOF
#!/usr/bin/env bash
: > "$path_cargo_marker"
exit 99
EOF
chmod 0755 "$HOME/.local/fake-cargo/cargo"
if PATH="$fake_git_bin:$HOME/.local/fake-cargo:/usr/bin:/bin" install_rtk_from_source "$rtk_source" https://example.invalid/rtk.git "$rtk_source_commit"; then
  :
fi
[[ ! -e "$path_cargo_marker" ]] || { echo 'PATH-resolved Cargo was used.' >&2; exit 1; }
printf 'locked source\n' > "$rtk_source/README"
chmod 0644 "$rtk_source/README"

# Deterministic Cargo replacement race: replace the user-writable Cargo path
# while the function is paused after validation and private staging.  The
# staged inode must execute, while the replacement remains unexecuted and the
# post-use identity check fails closed.
cargo_race_safe="$test_root/cargo-race-safe"
cargo_race_hostile="$test_root/cargo-race-hostile"
cargo_race_safe_marker="$test_root/cargo-race-safe-executed"
cargo_race_hostile_marker="$test_root/cargo-race-hostile-executed"
rustc_race_safe="$test_root/rustc-race-safe"
rustc_race_hostile="$test_root/rustc-race-hostile"
rustc_race_safe_marker="$test_root/rustc-race-safe-executed"
rustc_race_hostile_marker="$test_root/rustc-race-hostile-executed"
stage_race_hostile_marker="$test_root/cargo-stage-race-hostile-executed"
cat > "$cargo_race_safe" <<EOF
#!/usr/bin/bash
: > '$cargo_race_safe_marker'
\${RUSTC:?} --version
EOF
cat > "$cargo_race_hostile" <<EOF
#!/usr/bin/bash
: > '$cargo_race_hostile_marker'
EOF
cat > "$rustc_race_safe" <<EOF
#!/usr/bin/bash
: > '$rustc_race_safe_marker'
EOF
cat > "$rustc_race_hostile" <<EOF
#!/usr/bin/bash
: > '$rustc_race_hostile_marker'
EOF
chmod 0755 "$cargo_race_safe" "$cargo_race_hostile" "$rustc_race_safe" "$rustc_race_hostile"
cp -- "$cargo_race_safe" "$HOME/.cargo/bin/cargo"
cp -- "$rustc_race_safe" "$HOME/.cargo/bin/rustc"
run_cargo_race_probe() {
  local label="$1"
  local replacement="$2"
  local cargo_race_ready="$test_root/cargo-race-$label-ready"
  local cargo_race_continue="$test_root/cargo-race-$label-continue"
  local cargo_race_output="$test_root/cargo-race-$label-output"
  local cargo_race_pid cargo_race_status cargo_stage_dir previous_stage_dir already_present
  local -a cargo_stage_dirs_before=()
  rm -f -- "$cargo_race_safe_marker" "$rustc_race_safe_marker" \
    "$cargo_race_hostile_marker" "$rustc_race_hostile_marker" "$stage_race_hostile_marker"
  mapfile -t cargo_stage_dirs_before < <(find /tmp -maxdepth 1 -type d -name 'herdr-cargo-exec.*' -print)
  (
    HERDR_BOOTSTRAP_TEST_PAUSE_PHASE=before-cargo-exec \
    HERDR_BOOTSTRAP_TEST_READY_FILE="$cargo_race_ready" \
    HERDR_BOOTSTRAP_TEST_CONTINUE_FILE="$cargo_race_continue" \
    install_rtk_from_source "$rtk_source" https://example.invalid/rtk.git "$rtk_source_commit"
  ) > "$cargo_race_output" 2>&1 &
  cargo_race_pid=$!
  while [[ ! -e "$cargo_race_ready" ]]; do sleep 0.01; done
  case "$replacement" in
    cargo)
      rm -- "$HOME/.cargo/bin/cargo"
      ln -s "$cargo_race_hostile" "$HOME/.cargo/bin/cargo"
      ;;
    rustc)
      rm -- "$HOME/.cargo/bin/rustc"
      ln -s "$rustc_race_hostile" "$HOME/.cargo/bin/rustc"
      ;;
    stage)
      for cargo_stage_dir in /tmp/herdr-cargo-exec.*; do
        [[ -d "$cargo_stage_dir" ]] || continue
        already_present=0
        for previous_stage_dir in "${cargo_stage_dirs_before[@]}"; do
          [[ "$cargo_stage_dir" == "$previous_stage_dir" ]] && already_present=1
        done
        if (( already_present == 0 )); then
          rm -- "$cargo_stage_dir/cargo"
          cat > "$cargo_stage_dir/cargo" <<EOF
#!/usr/bin/bash
: > '$stage_race_hostile_marker'
EOF
          chmod 0755 "$cargo_stage_dir/cargo"
        fi
      done
      ;;
    *)
      echo "Unknown Cargo race replacement: $replacement" >&2
      exit 1
      ;;
  esac
  : > "$cargo_race_continue"
  set +e
  wait "$cargo_race_pid"
  cargo_race_status=$?
  set -e
  (( cargo_race_status != 0 )) || { echo "$label Cargo replacement race was accepted." >&2; exit 1; }
  [[ ! -e "$cargo_race_hostile_marker" && ! -e "$rustc_race_hostile_marker" && \
     ! -e "$stage_race_hostile_marker" ]] || {
    echo "Cargo, staged Cargo, or rustc replacement race executed an attacker path ($label)." >&2
    exit 1
  }
  if [[ "$replacement" == cargo ]]; then
    [[ -e "$cargo_race_safe_marker" && -e "$rustc_race_safe_marker" ]] || {
      echo 'Stable Cargo or rustc descriptors did not execute their validated material.' >&2
      exit 1
    }
  fi
  rm -f -- "$HOME/.cargo/bin/cargo" "$HOME/.cargo/bin/rustc"
  cp -- "$cargo_race_safe" "$HOME/.cargo/bin/cargo"
  cp -- "$rustc_race_safe" "$HOME/.cargo/bin/rustc"
}

run_cargo_race_probe cargo cargo
run_cargo_race_probe rustc rustc
run_cargo_race_probe stage stage

expect_rtk_install_rejected() {
  local label="$1"
  rm -f -- "$cargo_install_marker"
  if install_rtk_from_source "$rtk_source" https://example.invalid/rtk.git "$rtk_source_commit" >/dev/null 2>&1; then
    echo "$label was accepted before the Cargo seam." >&2
    exit 1
  fi
  [[ ! -e "$cargo_install_marker" ]] || {
    echo "$label reached the Cargo seam." >&2
    exit 1
  }
}

printf 'dirty\n' >> "$rtk_source/README"
expect_rtk_install_rejected 'Dirty RTK source'
git -C "$rtk_source" checkout -- README
printf 'staged\n' >> "$rtk_source/README"
git -C "$rtk_source" add README
expect_rtk_install_rejected 'Staged RTK source'
git -C "$rtk_source" reset -q HEAD -- README
git -C "$rtk_source" checkout -- README
printf 'untracked\n' > "$rtk_source/untracked"
expect_rtk_install_rejected 'Untracked RTK source'
rm -- "$rtk_source/untracked"

printf 'ignored-input\n' >> "$rtk_source/.git/info/exclude"
printf 'ignored build input\n' > "$rtk_source/ignored-input"
[[ -z "$(git -C "$rtk_source" status --porcelain --untracked-files=all)" ]] || {
  echo 'Ignored RTK fixture is not hidden from ordinary status.' >&2
  exit 1
}
expect_rtk_install_rejected 'Ignored untracked RTK source'
rm -- "$rtk_source/ignored-input"

git -C "$rtk_source" update-index --assume-unchanged README
assume_flag_before="$(git -C "$rtk_source" ls-files -v -- README)"
printf 'assume-unchanged attacker\n' > "$rtk_source/README"
expect_rtk_install_rejected 'Assume-unchanged RTK source'
assume_flag_after="$(git -C "$rtk_source" ls-files -v -- README)"
[[ "$assume_flag_after" == "$assume_flag_before" ]] || {
  echo 'RTK assume-unchanged index flag was mutated.' >&2
  exit 1
}
git -C "$rtk_source" update-index --no-assume-unchanged README
git -C "$rtk_source" checkout -- README

git -C "$rtk_source" update-index --skip-worktree README
skip_flag_before="$(git -C "$rtk_source" ls-files -v -- README)"
printf 'skip-worktree attacker\n' > "$rtk_source/README"
expect_rtk_install_rejected 'Skip-worktree RTK source'
skip_flag_after="$(git -C "$rtk_source" ls-files -v -- README)"
[[ "$skip_flag_after" == "$skip_flag_before" ]] || {
  echo 'RTK skip-worktree index flag was mutated.' >&2
  exit 1
}
git -C "$rtk_source" update-index --no-skip-worktree README
git -C "$rtk_source" checkout -- README

# Unsupported checkout layouts are rejected before the Cargo seam.  These
# fixtures cover filesystem-only inputs as well as Git metadata/layout modes
# that ordinary status or ignore-aware predicates can miss.
mkdir "$rtk_source/empty-directory"
expect_rtk_install_rejected 'Empty directory in RTK source'
rmdir "$rtk_source/empty-directory"

ln -s README "$rtk_source/symlink-input"
expect_rtk_install_rejected 'Symlink in RTK source'
rm -- "$rtk_source/symlink-input"

mkfifo "$rtk_source/fifo-input"
expect_rtk_install_rejected 'FIFO in RTK source'
rm -- "$rtk_source/fifo-input"

mkdir "$rtk_source/nested-repository"
git -C "$rtk_source/nested-repository" init -q
expect_rtk_install_rejected 'Nested repository in RTK source'
rm -rf -- "$rtk_source/nested-repository"

git -C "$rtk_source" config core.sparseCheckout true
expect_rtk_install_rejected 'Sparse checkout metadata'
git -C "$rtk_source" config --unset core.sparseCheckout
git -C "$rtk_source" config index.sparse true
expect_rtk_install_rejected 'Sparse index metadata'
git -C "$rtk_source" config --unset index.sparse

: > "$rtk_source/.git/shallow"
expect_rtk_install_rejected 'Shallow repository metadata'
rm -- "$rtk_source/.git/shallow"

printf '%s\n' "$test_root/external-objects" > "$rtk_source/.git/objects/info/alternates"
expect_rtk_install_rejected 'External Git alternates'
rm -- "$rtk_source/.git/objects/info/alternates"

git -C "$rtk_source" config remote.origin.promisor true
expect_rtk_install_rejected 'Partial clone promisor configuration'
git -C "$rtk_source" config --unset remote.origin.promisor
git -C "$rtk_source" config extensions.partialClone origin
expect_rtk_install_rejected 'Partial clone extension'
git -C "$rtk_source" config --unset extensions.partialClone

# A committed submodule is rejected from the tree before any worktree or
# Cargo operation can observe it.
submodule_child="$test_root/submodule-child"
submodule_source="$test_root/submodule-source"
mkdir -p "$submodule_child" "$submodule_source"
git -C "$submodule_child" init -q
git -C "$submodule_child" config user.email fixture@example.invalid
git -C "$submodule_child" config user.name fixture
printf 'submodule\n' > "$submodule_child/README"
git -C "$submodule_child" add README
git -C "$submodule_child" commit -qm 'submodule fixture'
git -C "$submodule_source" init -q
git -C "$submodule_source" config user.email fixture@example.invalid
git -C "$submodule_source" config user.name fixture
printf 'parent\n' > "$submodule_source/README"
git -C "$submodule_source" add README
git -C "$submodule_source" commit -qm 'submodule parent fixture'
git -C "$submodule_source" remote add origin https://example.invalid/rtk.git
git -C "$submodule_source" -c protocol.file.allow=always submodule add -q "$submodule_child" nested-submodule
git -C "$submodule_source" commit -qm 'add submodule fixture'
submodule_commit="$(git -C "$submodule_source" rev-parse HEAD)"
rm -f -- "$cargo_install_marker"
if install_rtk_from_source "$submodule_source" https://example.invalid/rtk.git "$submodule_commit"; then
  echo 'Committed submodule was accepted.' >&2
  exit 1
fi
[[ ! -e "$cargo_install_marker" ]] || { echo 'Submodule fixture reached the Cargo seam.' >&2; exit 1; }

# An unmerged index must be rejected even when HEAD and the expected commit
# are otherwise correct.
conflict_source="$test_root/unmerged-source"
mkdir -p "$conflict_source"
git -C "$conflict_source" init -q
git -C "$conflict_source" config user.email fixture@example.invalid
git -C "$conflict_source" config user.name fixture
printf 'base\n' > "$conflict_source/README"
git -C "$conflict_source" add README
git -C "$conflict_source" commit -qm 'unmerged base fixture'
git -C "$conflict_source" remote add origin https://example.invalid/rtk.git
conflict_base="$(git -C "$conflict_source" rev-parse HEAD)"
git -C "$conflict_source" checkout -qb conflict-left
printf 'left\n' > "$conflict_source/README"
git -C "$conflict_source" commit -qam 'left conflict fixture'
git -C "$conflict_source" checkout -qb conflict-right "$conflict_base"
printf 'right\n' > "$conflict_source/README"
git -C "$conflict_source" commit -qam 'right conflict fixture'
conflict_commit="$(git -C "$conflict_source" rev-parse HEAD)"
set +e
git -C "$conflict_source" merge conflict-left >/dev/null 2>&1
merge_status=$?
set -e
(( merge_status != 0 )) || { echo 'Unmerged fixture did not produce a conflict.' >&2; exit 1; }
rm -f -- "$cargo_install_marker"
if install_rtk_from_source "$conflict_source" https://example.invalid/rtk.git "$conflict_commit"; then
  echo 'Unmerged index was accepted.' >&2
  exit 1
fi
[[ ! -e "$cargo_install_marker" ]] || { echo 'Unmerged fixture reached the Cargo seam.' >&2; exit 1; }
git -C "$conflict_source" merge --abort

# A tree that names an unavailable blob is rejected before the builder can
# consume a partially available object database.
missing_source="$test_root/missing-object-source"
mkdir -p "$missing_source"
git -C "$missing_source" init -q
git -C "$missing_source" config user.email fixture@example.invalid
git -C "$missing_source" config user.name fixture
printf 'missing object\n' > "$missing_source/README"
git -C "$missing_source" add README
git -C "$missing_source" commit -qm 'missing object fixture'
git -C "$missing_source" remote add origin https://example.invalid/rtk.git
missing_commit="$(git -C "$missing_source" rev-parse HEAD)"
missing_oid="$(git -C "$missing_source" rev-parse "$missing_commit:README")"
missing_object="$missing_source/.git/objects/${missing_oid:0:2}/${missing_oid:2}"
[[ -f "$missing_object" ]] || { echo 'Missing-object fixture was not loose.' >&2; exit 1; }
rm -- "$missing_object"
rm -f -- "$cargo_install_marker"
if install_rtk_from_source "$missing_source" https://example.invalid/rtk.git "$missing_commit"; then
  echo 'Missing Git object was accepted.' >&2
  exit 1
fi
[[ ! -e "$cargo_install_marker" ]] || { echo 'Missing-object fixture reached the Cargo seam.' >&2; exit 1; }

# These callers intentionally use the generic fd/anchor/parent names that
# collided with fence_open_parent's dynamic-scope locals on the starting
# candidate.
generic_link_source="$test_root/generic-link-source"
printf 'generic link source\n' > "$generic_link_source"
fence_replace_link "$generic_link_source" "$HOME/.local/bin/generic-link" before-generic-link
[[ -L "$HOME/.local/bin/generic-link" ]] || { echo 'Generic fenced link was not published.' >&2; exit 1; }
[[ "$(readlink "$HOME/.local/bin/generic-link")" == "$generic_link_source" ]] || {
  echo 'Generic fenced link target changed.' >&2
  exit 1
}

# The managed RTK alias is revalidated after the synchronization pause and
# must not remove a replacement symlink from the same parent.
canonical_rtk="$HOME/.cargo/bin/rtk"
printf 'canonical rtk\n' > "$canonical_rtk"
chmod 0755 "$canonical_rtk"
ln -s "$canonical_rtk" "$HOME/.local/bin/rtk"
race_ready="$test_root/rtk-race-ready"
race_continue="$test_root/rtk-race-continue"
race_other="$test_root/other-rtk"
printf 'replacement rtk\n' > "$race_other"
chmod 0755 "$race_other"
(
  HERDR_BOOTSTRAP_TEST_PAUSE_PHASE=before-rtk-alias-removal \
  HERDR_BOOTSTRAP_TEST_READY_FILE="$race_ready" \
  HERDR_BOOTSTRAP_TEST_CONTINUE_FILE="$race_continue" \
  fence_remove_managed_link "$canonical_rtk" "$HOME/.local/bin/rtk" before-rtk-alias-removal
) > "$test_root/rtk-race-output" 2>&1 &
race_pid=$!
while [[ ! -e "$race_ready" ]]; do sleep 0.01; done
rm -- "$HOME/.local/bin/rtk"
ln -s "$race_other" "$HOME/.local/bin/rtk"
: > "$race_continue"
if wait "$race_pid"; then
  echo 'RTK alias replacement race was accepted.' >&2
  exit 1
fi
[[ -L "$HOME/.local/bin/rtk" && "$(readlink "$HOME/.local/bin/rtk")" == "$race_other" ]] || {
  echo 'RTK alias replacement race changed the replacement path.' >&2
  exit 1
}

# The same detach race with a non-symlink replacement must preserve the
# replacement at the public name while failing closed.
rm -- "$HOME/.local/bin/rtk"
ln -s "$canonical_rtk" "$HOME/.local/bin/rtk"
regular_race_ready="$test_root/rtk-regular-race-ready"
regular_race_continue="$test_root/rtk-regular-race-continue"
regular_race_content='raced regular RTK replacement'
(
  HERDR_BOOTSTRAP_TEST_PAUSE_PHASE=before-rtk-regular-alias-removal \
  HERDR_BOOTSTRAP_TEST_READY_FILE="$regular_race_ready" \
  HERDR_BOOTSTRAP_TEST_CONTINUE_FILE="$regular_race_continue" \
  fence_remove_managed_link "$canonical_rtk" "$HOME/.local/bin/rtk" before-rtk-regular-alias-removal
) > "$test_root/rtk-regular-race-output" 2>&1 &
regular_race_pid=$!
while [[ ! -e "$regular_race_ready" ]]; do sleep 0.01; done
rm -- "$HOME/.local/bin/rtk"
printf '%s\n' "$regular_race_content" > "$HOME/.local/bin/rtk"
chmod 0644 "$HOME/.local/bin/rtk"
: > "$regular_race_continue"
set +e
wait "$regular_race_pid"
regular_race_status=$?
set -e
(( regular_race_status != 0 )) || { echo 'RTK regular replacement race was accepted.' >&2; exit 1; }
[[ -f "$HOME/.local/bin/rtk" && ! -L "$HOME/.local/bin/rtk" && \
   "$(< "$HOME/.local/bin/rtk")" == "$regular_race_content" ]] || {
  echo 'RTK regular replacement was not preserved at the public name.' >&2
  exit 1
}

generic_file_source="$test_root/generic-file-source"
printf 'generic file content\n' > "$generic_file_source"
fence_replace_file "$generic_file_source" "$HOME/.local/bin/generic-file" 0644 before-generic-file
[[ "$(< "$HOME/.local/bin/generic-file")" == 'generic file content' ]] || {
  echo 'Generic fenced file content changed.' >&2
  exit 1
}
[[ "$(stat -c '%a' "$HOME/.local/bin/generic-file")" == 644 ]] || {
  echo 'Generic fenced file mode changed.' >&2
  exit 1
}

# Exercise the managed toolchain's expected-fd Python migration and exact
# python3.13/py compatibility seam without downloads or a real HOME.
managed_python="$HOME/.local/lib/herdr-workstation/python/test/bin/python3.13"
mkdir -p "$(dirname "$managed_python")"
cat > "$managed_python" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == '--version' ]]; then
  printf 'Python 3.13.15\n'
  exit 0
fi
printf '%s\n' "$@" > "$HOME/forwarded-args"
exit "${PYTHON_STUB_EXIT:-0}"
EOF
chmod 0755 "$managed_python"
ln -s "$managed_python" "$HOME/.local/bin/python3.13"
python_launcher_stage="$(mktemp "$HOME/.local/bin/.python3.13.XXXXXX")"
cp "$managed_python" "$python_launcher_stage"
managed_bin_fd=''
fence_open_directory "$HOME/.local/bin" managed_bin_fd
fence_replace_python_launcher "$python_launcher_stage" "$HOME/.local/bin/python3.13" before-python-link-publish "$managed_bin_fd" "$HOME/.local/lib/herdr-workstation"
fence_require_directory "$HOME/.local/bin" "$managed_bin_fd" 'test managed bin'
close_fence_fd "$managed_bin_fd"
[[ -f "$HOME/.local/bin/python3.13" && ! -L "$HOME/.local/bin/python3.13" ]] || {
  echo 'Managed python3.13 launcher was not migrated to a regular file.' >&2
  exit 1
}

write_py_compat
wrapper_hash_before="$(sha256sum "$HOME/.local/bin/py" | awk '{print $1}')"
write_py_compat
wrapper_hash_after="$(sha256sum "$HOME/.local/bin/py" | awk '{print $1}')"
[[ "$wrapper_hash_before" == "$wrapper_hash_after" ]] || {
  echo 'Managed py wrapper convergence is not byte-idempotent.' >&2
  exit 1
}
grep -Fq 'exec "$wrapper_dir/python3.13" "$@"' "$HOME/.local/bin/py" || {
  echo 'Managed py wrapper did not publish the expected interpreter seam.' >&2
  exit 1
}
"$HOME/.local/bin/py" -3.13 -c 'print("argument with spaces")' 'value with spaces'
mapfile -t forwarded < "$HOME/forwarded-args"
[[ "${forwarded[0]}" == '-c' && "${forwarded[1]}" == 'print("argument with spaces")' && "${forwarded[2]}" == 'value with spaces' ]] || {
  echo 'Managed py wrapper changed forwarded arguments.' >&2
  exit 1
}

# The profile caller uses distinct output names and must remain covered while
# the generic callers exercise the dynamic-scope collision boundary.
printf 'export HERDR_PROFILE_TEST=1\n' > "$HOME/.profile"
converge_profile_hook "$HOME/.profile"
grep -Fxq '# BEGIN herdr-workstation PATH' "$HOME/.profile" || {
  echo 'Managed profile hook was not published.' >&2
  exit 1
}

echo 'bootstrap fencing, managed link, py wrapper and profile seam tests passed.'
