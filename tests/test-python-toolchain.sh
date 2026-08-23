#!/usr/bin/env bash
set -euo pipefail
umask 022

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

# The bootstrap source is now an attested committed snapshot.  Keep this
# function-only regression runnable from a mutable developer checkout by
# testing the exact current files in a disposable clean Git fixture.
source_fixture="$test_root/source"
fixture_root="$test_root/fixture"
fixture_home="$fixture_root/home"
transport="$fixture_root/transport.git"
mkdir -p "$fixture_root" "$fixture_home"
cp -a -- "$repo_root/." "$source_fixture/"
chmod 0755 "$source_fixture"
/usr/bin/rm -rf -- "$source_fixture/.agents" "$source_fixture/.codex"
rm -rf -- "$source_fixture/.git"
dispatch_sentinel='if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then'
/usr/bin/awk -v sentinel="$dispatch_sentinel" '
  $0 == sentinel { exit }
  { print }
' "$source_fixture/scripts/ubuntu/bootstrap.sh" > "$source_fixture/scripts/ubuntu/bootstrap.sh.tmp"
mv -T "$source_fixture/scripts/ubuntu/bootstrap.sh.tmp" "$source_fixture/scripts/ubuntu/bootstrap.sh"
cat >> "$source_fixture/scripts/ubuntu/bootstrap.sh" <<'EOF'
fixture_set_home() {
  HOME="$1"
  state_dir="$HOME/.local/state/herdr-workstation-bootstrap"
  bin_dir="$HOME/.local/bin"
}
fixture_python_main() {
  local fixture_base_home="$HOME"
  case "$phase" in
    validate-lock)
      validate_toolchain_lock
      ;;
    malformed-uv)
      UV_SHA256=not-a-sha256
      validate_toolchain_lock
      ;;
    malformed-python)
      PYTHON_VERSION=3.12.0
      validate_toolchain_lock
      ;;
    malformed-tailscale)
      TAILSCALE_VERSION=not-a-semantic-version
      validate_toolchain_lock
      ;;
    wrong-python)
      check_python_version "$fixture_base_home/wrong-python"
      ;;
    write-py)
      write_py_compat
      ;;
    install-python-local)
      fixture_set_home "$fixture_base_home/bootstrap-home-local"
      install_python_toolchain
      ;;
    install-python-lib)
      fixture_set_home "$fixture_base_home/bootstrap-home-lib"
      install_python_toolchain
      ;;
    install-python-bin)
      fixture_set_home "$fixture_base_home/bootstrap-home-bin"
      install_python_toolchain
      ;;
    install-python-state)
      fixture_set_home "$fixture_base_home/bootstrap-home-state"
      install_python_toolchain
      ;;
    install-tools-profile)
      fixture_set_home "$fixture_base_home/bootstrap-home-profile"
      install_tools
      ;;
    write-py-race)
      fixture_set_home "$fixture_base_home/bootstrap-home-mutation-swap"
      HERDR_BOOTSTRAP_TEST_PAUSE_PHASE=before-py-publish
      HERDR_BOOTSTRAP_TEST_READY_FILE="$fixture_base_home/bootstrap-mutation-swap.ready"
      HERDR_BOOTSTRAP_TEST_CONTINUE_FILE="$fixture_base_home/bootstrap-mutation-swap.continue"
      export HERDR_BOOTSTRAP_TEST_PAUSE_PHASE HERDR_BOOTSTRAP_TEST_READY_FILE HERDR_BOOTSTRAP_TEST_CONTINUE_FILE
      write_py_compat
      ;;
    *)
      echo "Unsupported Python fixture phase: $phase" >&2
      exit 2
      ;;
  esac
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  fixture_python_main
fi
EOF
chmod 0755 "$source_fixture/scripts/ubuntu/bootstrap.sh"
git -C "$source_fixture" init -q
git -C "$source_fixture" config user.email fixture@example.invalid
git -C "$source_fixture" config user.name fixture
git -C "$source_fixture" add -f .
git -C "$source_fixture" commit -qm 'clean Python toolchain fixture'
git clone -q --bare "$source_fixture" "$transport"
chmod 0700 "$transport"
/usr/bin/bash "$repo_root/scripts/ubuntu/install-trusted-launcher.sh" \
  --origin https://github.com/nathanestone-alt/herdr-workstation-bootstrap.git \
  --commit "$(git -C "$source_fixture" rev-parse --verify HEAD^{commit})" \
  --fixture-root "$fixture_root" --fixture-transport "$transport" --fixture-home "$fixture_home" \
  > "$test_root/launcher-install.out"
launcher="$fixture_root/usr/local/libexec/herdr-workstation-bootstrap"
export HOME="$fixture_home"
mkdir -p "$HOME/.local/bin"

run_fixture_phase() {
  local phase_name="$1"
  /usr/bin/env -i HOME="$HOME" PATH=/usr/sbin:/usr/bin:/sbin:/bin \
    BASH_ENV= ENV= LC_ALL=C TZ=UTC \
    "$launcher" --entrypoint bootstrap -- --phase "$phase_name"
}

expect_fixture_failure() {
  local phase_name="$1" output="$test_root/phase-$1.out"
  set +e
  run_fixture_phase "$phase_name" > "$output" 2>&1
  local status=$?
  set -e
  [[ "$status" -ne 0 ]] || { echo "$phase_name unexpectedly passed." >&2; exit 1; }
}

run_fixture_phase validate-lock
expect_fixture_failure malformed-uv
expect_fixture_failure malformed-python
expect_fixture_failure malformed-tailscale

wrong_python="$test_root/wrong-python"
printf '#!/usr/bin/env bash\nprintf "Python 3.12.3\\n"\n' > "$wrong_python"
chmod 0755 "$wrong_python"
cp -- "$wrong_python" "$HOME/wrong-python"
expect_fixture_failure wrong-python

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

run_fixture_phase write-py
wrapper_hash_before="$(sha256sum "$HOME/.local/bin/py" | awk '{print $1}')"
run_fixture_phase write-py
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
  local fixture_phase="install-python-$case_name"
  [[ "$phase" == install-tools ]] && fixture_phase=install-tools-profile
  set +e
  run_fixture_phase "$fixture_phase" > "$output" 2>&1
  local status=$?
  set -e
  [[ "$status" -ne 0 ]] || { echo "$case_name unexpectedly passed." >&2; exit 1; }
  grep -Fq 'Managed path' "$output" || { sed -n '1,80p' "$output" >&2; exit 1; }
}

make_bootstrap_safety_home() {
  local case_name="$1"
  local home="$fixture_home/bootstrap-home-$case_name"
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
bootstrap_swap_outside="$fixture_root/bootstrap-outside-mutation-swap"
mkdir -p "$bootstrap_swap_outside"
printf 'outside sentinel\n' > "$bootstrap_swap_outside/sentinel.txt"
bootstrap_swap_ready="$fixture_home/bootstrap-mutation-swap.ready"
bootstrap_swap_continue="$fixture_home/bootstrap-mutation-swap.continue"
bootstrap_swap_output="$test_root/bootstrap-mutation-swap.out"
run_fixture_phase write-py-race > "$bootstrap_swap_output" 2>&1 &
bootstrap_swap_pid=$!
for attempt in $(seq 1 1000); do
  [[ -e "$bootstrap_swap_ready" ]] && break
  sleep 0.01
done
[[ -e "$bootstrap_swap_ready" ]] || {
  cat "$bootstrap_swap_output" >&2 || true
  kill "$bootstrap_swap_pid" 2>/dev/null || true
  exit 1
}
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
