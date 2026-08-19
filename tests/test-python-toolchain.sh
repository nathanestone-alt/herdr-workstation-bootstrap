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

saved_tailscale_version="$TAILSCALE_VERSION"
TAILSCALE_VERSION=not-a-semantic-version
if validate_toolchain_lock; then
  echo 'Lock validation accepted a malformed Tailscale version.' >&2
  exit 1
fi
TAILSCALE_VERSION="$saved_tailscale_version"
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

expect_bootstrap_path_blocked() {
  local case_name="$1"
  local home="$2"
  local phase="${3:-install-python}"
  local output="$test_root/bootstrap-$case_name.out"
  set +e
  HOME="$home" bash -c 'bootstrap_script="$1"; requested_phase="$2"; set --; source "$bootstrap_script"; if [[ "$requested_phase" == install-tools ]]; then install_tools; else install_python_toolchain; fi' \
    _ "$repo_root/scripts/ubuntu/bootstrap.sh" "$phase" > "$output" 2>&1
  local status=$?
  set -e
  [[ "$status" -ne 0 ]] || { echo "$case_name unexpectedly passed." >&2; exit 1; }
  grep -Fq 'Managed path' "$output" || { sed -n '1,80p' "$output" >&2; exit 1; }
}

make_bootstrap_safety_home() {
  local case_name="$1"
  local home="$test_root/bootstrap-home-$case_name"
  rm -rf "$home"
  mkdir -p "$home"
  printf '%s' "$home"
}

bootstrap_local_home="$(make_bootstrap_safety_home local)"
bootstrap_local_outside="$test_root/bootstrap-outside-local"
mkdir -p "$bootstrap_local_outside"
printf 'local sentinel\n' > "$bootstrap_local_outside/sentinel.txt"
ln -s "$bootstrap_local_outside" "$bootstrap_local_home/.local"
expect_bootstrap_path_blocked local "$bootstrap_local_home"
[[ "$(< "$bootstrap_local_outside/sentinel.txt")" == 'local sentinel' ]] || exit 1

bootstrap_lib_home="$(make_bootstrap_safety_home lib)"
bootstrap_lib_outside="$test_root/bootstrap-outside-lib"
mkdir -p "$bootstrap_lib_home/.local/lib" "$bootstrap_lib_home/.local/bin" "$bootstrap_lib_home/.local/state" "$bootstrap_lib_outside"
printf 'lib sentinel\n' > "$bootstrap_lib_outside/sentinel.txt"
ln -s "$bootstrap_lib_outside" "$bootstrap_lib_home/.local/lib/herdr-workstation"
expect_bootstrap_path_blocked lib "$bootstrap_lib_home"
[[ "$(< "$bootstrap_lib_outside/sentinel.txt")" == 'lib sentinel' ]] || exit 1

bootstrap_bin_home="$(make_bootstrap_safety_home bin)"
bootstrap_bin_outside="$test_root/bootstrap-outside-bin"
mkdir -p "$bootstrap_bin_home/.local/state" "$bootstrap_bin_outside"
printf 'bin sentinel\n' > "$bootstrap_bin_outside/sentinel.txt"
ln -s "$bootstrap_bin_outside" "$bootstrap_bin_home/.local/bin"
expect_bootstrap_path_blocked bin "$bootstrap_bin_home"
[[ "$(< "$bootstrap_bin_outside/sentinel.txt")" == 'bin sentinel' ]] || exit 1

bootstrap_state_home="$(make_bootstrap_safety_home state)"
bootstrap_state_outside="$test_root/bootstrap-outside-state"
mkdir -p "$bootstrap_state_home/.local/bin" "$bootstrap_state_outside"
printf 'state sentinel\n' > "$bootstrap_state_outside/sentinel.txt"
ln -s "$bootstrap_state_outside" "$bootstrap_state_home/.local/state"
expect_bootstrap_path_blocked state "$bootstrap_state_home"
[[ "$(< "$bootstrap_state_outside/sentinel.txt")" == 'state sentinel' ]] || exit 1

bootstrap_profile_home="$(make_bootstrap_safety_home profile)"
bootstrap_profile_outside="$test_root/bootstrap-outside-profile"
mkdir -p "$bootstrap_profile_home/.local/bin" "$bootstrap_profile_home/.local/state" "$bootstrap_profile_outside"
printf 'profile sentinel\n' > "$bootstrap_profile_outside/sentinel.txt"
ln -s "$bootstrap_profile_outside" "$bootstrap_profile_home/.config"
expect_bootstrap_path_blocked profile "$bootstrap_profile_home" install-tools
[[ "$(< "$bootstrap_profile_outside/sentinel.txt")" == 'profile sentinel' ]] || exit 1

# A destination parent replacement after the bootstrap writer captures its
# directory fd must fail closed and leave the original managed file intact.
bootstrap_swap_home="$(make_bootstrap_safety_home mutation-swap)"
mkdir -p "$bootstrap_swap_home/.local/bin"
printf 'original py wrapper\n' > "$bootstrap_swap_home/.local/bin/py"
bootstrap_swap_outside="$test_root/bootstrap-outside-mutation-swap"
mkdir -p "$bootstrap_swap_outside"
printf 'outside sentinel\n' > "$bootstrap_swap_outside/sentinel.txt"
bootstrap_swap_ready="$test_root/bootstrap-mutation-swap.ready"
bootstrap_swap_continue="$test_root/bootstrap-mutation-swap.continue"
bootstrap_swap_output="$test_root/bootstrap-mutation-swap.out"
HERDR_BOOTSTRAP_TEST_PAUSE_PHASE=before-py-publish \
HERDR_BOOTSTRAP_TEST_READY_FILE="$bootstrap_swap_ready" \
HERDR_BOOTSTRAP_TEST_CONTINUE_FILE="$bootstrap_swap_continue" \
HOME="$bootstrap_swap_home" bash -c \
  'bootstrap_script="$1"; set --; source "$bootstrap_script"; write_py_compat' _ "$repo_root/scripts/ubuntu/bootstrap.sh" > "$bootstrap_swap_output" 2>&1 &
bootstrap_swap_pid=$!
for attempt in $(seq 1 200); do
  [[ -e "$bootstrap_swap_ready" ]] && break
  sleep 0.01
done
[[ -e "$bootstrap_swap_ready" ]] || { kill "$bootstrap_swap_pid" 2>/dev/null || true; exit 1; }
mv "$bootstrap_swap_home/.local" "$bootstrap_swap_home/.local-original"
ln -s "$bootstrap_swap_outside" "$bootstrap_swap_home/.local"
: > "$bootstrap_swap_continue"
set +e
wait "$bootstrap_swap_pid"
bootstrap_swap_status=$?
set -e
[[ "$bootstrap_swap_status" -ne 0 ]] || { cat "$bootstrap_swap_output" >&2; exit 1; }
[[ "$(< "$bootstrap_swap_outside/sentinel.txt")" == 'outside sentinel' ]] || exit 1
[[ "$(< "$bootstrap_swap_home/.local-original/bin/py")" == 'original py wrapper' ]] || exit 1
[[ ! -e "$bootstrap_swap_outside/bin/py" ]] || { echo 'Bootstrap wrote outside HOME.' >&2; exit 1; }
rm "$bootstrap_swap_home/.local"
mv "$bootstrap_swap_home/.local-original" "$bootstrap_swap_home/.local"

echo 'Python 3.13 lock, selector and convergence seam tests passed.'
