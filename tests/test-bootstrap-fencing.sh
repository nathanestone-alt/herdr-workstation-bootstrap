#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
export HOME="$test_root/home"
mkdir -p "$HOME/.local/bin" "$HOME/.local/lib/herdr-workstation" "$HOME/.config/herdr-workstation" "$HOME/.cargo/bin"

# Source only: the real base/tools phases must not run in this regression.
# shellcheck disable=SC1091
source "$repo_root/scripts/ubuntu/bootstrap.sh"

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
git -C "$rtk_source" add README
git -C "$rtk_source" commit -qm 'fixture source'
rtk_source_commit="$(git -C "$rtk_source" rev-parse HEAD)"
git -C "$rtk_source" remote add origin https://example.invalid/rtk.git
validate_rtk_source_checkout "$rtk_source" https://example.invalid/rtk.git "$rtk_source_commit"

cargo_install_marker="$test_root/cargo-install-reached"
cargo() {
  : > "$cargo_install_marker"
}
install_rtk_from_source "$rtk_source" https://example.invalid/rtk.git "$rtk_source_commit"
[[ -f "$cargo_install_marker" ]] || { echo 'Clean RTK source did not reach the Cargo seam.' >&2; exit 1; }

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
