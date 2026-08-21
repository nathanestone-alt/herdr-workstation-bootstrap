#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
export HOME="$test_root/home"
mkdir -p "$HOME/.local/bin" "$HOME/.local/lib/herdr-workstation" "$HOME/.config/herdr-workstation"

# Source only: the real base/tools phases must not run in this regression.
# shellcheck disable=SC1091
source "$repo_root/scripts/ubuntu/bootstrap.sh"

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
