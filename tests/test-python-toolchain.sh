#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
export HOME="$test_root/home"
mkdir -p "$HOME/.local/bin"

# Source only: none of the download, apt, rust, Node or runtime convergence
# phases may run in this test.
# shellcheck disable=SC1091
source "$repo_root/scripts/ubuntu/bootstrap.sh"
validate_toolchain_lock

saved_uv_sha="$UV_SHA256"
UV_SHA256=not-a-sha256
if validate_toolchain_lock; then
  echo 'Lock validation accepted a malformed uv checksum.' >&2
  exit 1
fi
UV_SHA256="$saved_uv_sha"

saved_python_version="$PYTHON_VERSION"
PYTHON_VERSION=3.12.0
if validate_toolchain_lock; then
  echo 'Lock validation accepted a non-3.13 Python version.' >&2
  exit 1
fi
PYTHON_VERSION="$saved_python_version"
validate_toolchain_lock

wrong_python="$test_root/wrong-python"
printf '#!/usr/bin/env bash\nprintf "Python 3.12.3\\n"\n' > "$wrong_python"
chmod 0755 "$wrong_python"
if check_python_version "$wrong_python"; then
  echo 'Version mismatch seam accepted the wrong Python version.' >&2
  exit 1
fi

cat > "$HOME/.local/bin/python3.13" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == '--version' ]]; then
  echo 'Python 3.13.15'
  exit 0
fi
printf '%s\n' "$@" > "$HOME/forwarded-args"
exit "${PYTHON_STUB_EXIT:-0}"
EOF
chmod 0755 "$HOME/.local/bin/python3.13"

write_py_compat
wrapper_hash_before="$(sha256sum "$HOME/.local/bin/py" | awk '{print $1}')"
write_py_compat
wrapper_hash_after="$(sha256sum "$HOME/.local/bin/py" | awk '{print $1}')"
[[ "$wrapper_hash_before" == "$wrapper_hash_after" ]] || {
  echo 'Managed py wrapper convergence is not idempotent.' >&2
  exit 1
}

set +e
"$HOME/.local/bin/py" --list >/dev/null 2>&1
unsupported_status=$?
set -e
[[ "$unsupported_status" -eq 2 ]] || {
  echo "Unsupported py selector returned $unsupported_status instead of 2." >&2
  exit 1
}

"$HOME/.local/bin/py" -3.13 -c 'print("argument with spaces")' 'value with spaces'
mapfile -t forwarded < "$HOME/forwarded-args"
[[ "${forwarded[0]}" == '-c' ]] || { echo 'py did not forward -c.' >&2; exit 1; }
[[ "${forwarded[1]}" == 'print("argument with spaces")' ]] || { echo 'py changed the -c argument.' >&2; exit 1; }
[[ "${forwarded[2]}" == 'value with spaces' ]] || { echo 'py changed a positional argument.' >&2; exit 1; }

set +e
PYTHON_STUB_EXIT=17 "$HOME/.local/bin/py" -3.13 -m example_module
propagated_status=$?
set -e
[[ "$propagated_status" -eq 17 ]] || {
  echo "py did not preserve the interpreter exit code: $propagated_status" >&2
  exit 1
}

echo 'Python 3.13 lock, selector and convergence seam tests passed.'
