#!/usr/bin/env bash
set -euo pipefail
umask 022

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$(id -u)" != 0 ]]; then
  echo "SKIP: bootstrap privilege-model regression requires root (uid=$(id -u))."
  exit 0
fi

powershell_version="$(/usr/bin/gawk -F= '$1 == "POWERSHELL_VERSION" { print $2; exit }' "$repo_root/config/ubuntu-toolchain.lock")"
tailscale_version="$(/usr/bin/gawk -F= '$1 == "TAILSCALE_VERSION" { print $2; exit }' "$repo_root/config/ubuntu-toolchain.lock")"
[[ "$powershell_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$tailscale_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo 'Could not resolve pinned fixture versions.' >&2
  exit 1
}

runtime_uid="$(id -u nobody 2>/dev/null || true)"
runtime_gid="$(id -g nobody 2>/dev/null || true)"
if [[ ! "$runtime_uid" =~ ^[1-9][0-9]*$ || ! "$runtime_gid" =~ ^[0-9]+$ ]]; then
  echo 'SKIP: bootstrap privilege-model regression requires the nobody account.'
  exit 0
fi

test_root="$(mktemp -d)"
runtime_surface="$(mktemp -d)"
trap 'rm -rf -- "$test_root" "$runtime_surface"' EXIT
case_root="$test_root/case"
source_root="$case_root/source"
fixture_root="$case_root/fixture"
fixture_home="$fixture_root/home"
transport="$fixture_root/transport.git"
mkdir -p "$source_root/scripts/ubuntu" "$source_root/config" "$fixture_home" "$case_root/bin"
chmod 0711 "$test_root" "$case_root"
chown "$runtime_uid:$runtime_gid" "$fixture_home"
chown "$runtime_uid:$runtime_gid" "$runtime_surface"

cp "$repo_root/scripts/ubuntu/bootstrap.sh" "$source_root/scripts/ubuntu/bootstrap.sh"
cp "$repo_root/scripts/ubuntu/launcher-capability.sh" "$source_root/scripts/ubuntu/launcher-capability.sh"
cp "$repo_root/scripts/ubuntu/trusted-launcher.sh" "$source_root/scripts/ubuntu/trusted-launcher.sh"
cp "$repo_root/scripts/ubuntu/source-attestation.sh" "$source_root/scripts/ubuntu/source-attestation.sh"
cp "$repo_root/scripts/ubuntu/rtk-release.sh" "$source_root/scripts/ubuntu/rtk-release.sh"
cp "$repo_root/config/ubuntu-toolchain.lock" "$source_root/config/ubuntu-toolchain.lock"
chmod 0755 "$source_root" "$source_root/scripts/ubuntu/"*.sh
chmod 0644 "$source_root/config/ubuntu-toolchain.lock"

cat > "$case_root/bin/sudo" <<'EOF'
#!/usr/bin/bash
set -euo pipefail
marker_root="${CASE_ROOT:?CASE_ROOT is required}"
no_new_privs="$(/usr/bin/awk '/^NoNewPrivs:/ { print $2; found++ } END { exit(found == 1 ? 0 : 1) }' /proc/self/status)"
if [[ "$no_new_privs" == 1 ]]; then
  : > "$marker_root/sudo-no-new-privs-failure"
  echo 'sudo: The "no new privileges" flag is set, which prevents sudo from running as root.' >&2
  exit 1
fi
: > "$marker_root/sudo-invoked"
exec "$@"
EOF
cat > "$case_root/bin/apt-get" <<EOF
#!/usr/bin/bash
set -euo pipefail
printf '%s\n' "\$*" >> "$case_root/apt.log"
EOF
cat > "$case_root/bin/ps" <<'EOF'
#!/usr/bin/bash
printf '%s\n' systemd
EOF
cat > "$case_root/bin/pwsh" <<EOF
#!/usr/bin/bash
printf '%s\n' '$powershell_version'
EOF
cat > "$case_root/bin/systemctl" <<EOF
#!/usr/bin/bash
set -euo pipefail
printf '%s\n' "\$*" >> "$case_root/systemctl.log"
EOF
cat > "$case_root/bin/tailscale" <<EOF
#!/usr/bin/bash
set -euo pipefail
if [[ "\$1" == version ]]; then
  printf '%s\n' '$tailscale_version'
fi
EOF
chmod 0755 "$case_root/bin/"*

/usr/bin/awk '
  /^if \[\[ .*BASH_SOURCE.*\]\]; then$/ { exit }
  { print }
' "$source_root/scripts/ubuntu/bootstrap.sh" > "$source_root/scripts/ubuntu/bootstrap.sh.tmp"
/usr/bin/mv -T "$source_root/scripts/ubuntu/bootstrap.sh.tmp" "$source_root/scripts/ubuntu/bootstrap.sh"
cat >> "$source_root/scripts/ubuntu/bootstrap.sh" <<EOF
bootstrap_command_path() {
  case "\$1" in
    sudo|apt-get|ps|pwsh|systemctl|tailscale) printf '%s/bin/%s\n' '$case_root' "\$1" ;;
    *) echo "unexpected command seam: \$1" >&2; return 24 ;;
  esac
}
bootstrap_exec_system() {
  /usr/bin/env -i HOME='$fixture_home' PATH='$case_root/bin:/usr/sbin:/usr/bin:/sbin:/bin' \\
    CASE_ROOT='$case_root' "\$@"
}
fixture_base_user() {
  printf '%s\n' "\$(/usr/bin/id -u)" > "\$HOME/base-user-uid"
  /usr/bin/awk '/^NoNewPrivs:/ { print \$2; found++ } END { exit(found == 1 ? 0 : 1) }' \\
    /proc/self/status > "\$HOME/base-user-no-new-privs"
  install_base_user
}
fixture_runtime_child() {
  local runtime_child_phase="\$1"
  printf '%s\n' "\$(/usr/bin/id -u)" > "\$HOME/\$runtime_child_phase-uid"
  /usr/bin/awk '/^NoNewPrivs:/ { print \$2; found++ } END { exit(found == 1 ? 0 : 1) }' \
    /proc/self/status > "\$HOME/\$runtime_child_phase-no-new-privs"
}
fixture_runtime_children() {
  bootstrap_run_as_runtime_phase runtime-child-1
  bootstrap_run_as_runtime_phase runtime-child-2
  bootstrap_run_as_runtime_phase runtime-child-3
}
case "\$phase" in
  base) install_base ;;
  base-user) fixture_base_user ;;
  runtime-child-regression) fixture_runtime_children ;;
  runtime-child-1|runtime-child-2|runtime-child-3) fixture_runtime_child "\$phase" ;;
  *) echo "unsupported privilege fixture phase: \$phase" >&2; exit 2 ;;
esac
EOF
chmod 0755 "$source_root/scripts/ubuntu/bootstrap.sh"

/usr/bin/git -C "$source_root" init -q
/usr/bin/git -C "$source_root" config user.email fixture@example.invalid
/usr/bin/git -C "$source_root" config user.name fixture
/usr/bin/git -C "$source_root" remote add origin https://github.com/nathanestone-alt/herdr-workstation-bootstrap.git
/usr/bin/git -C "$source_root" add .
/usr/bin/git -C "$source_root" commit -qm 'bootstrap privilege model fixture'
fixture_commit="$(/usr/bin/git -C "$source_root" rev-parse --verify HEAD^{commit})"
/usr/bin/git clone -q --bare "$source_root" "$transport"
chmod 0700 "$transport"

old_output="$case_root/old-setpriv-sudo.out"
set +e
/usr/bin/env CASE_ROOT="$runtime_surface" /usr/bin/setpriv \
  --reuid="$runtime_uid" --regid="$runtime_gid" --clear-groups --no-new-privs \
  "$case_root/bin/sudo" /usr/bin/true > "$old_output" 2>&1
old_status=$?
set -e
(( old_status != 0 )) || { cat "$old_output" >&2; echo 'setpriv/sudo failure probe unexpectedly passed.' >&2; exit 1; }
grep -Fqx 'sudo: The "no new privileges" flag is set, which prevents sudo from running as root.' "$old_output" ||
  { cat "$old_output" >&2; echo 'setpriv/sudo failure probe did not reproduce the exact diagnostic.' >&2; exit 1; }
rm -f "$runtime_surface/sudo-no-new-privs-failure"

if [[ -x /usr/bin/sudo && "$(stat -c '%u:%a' /usr/bin/sudo 2>/dev/null || true)" == 0:4755 ]]; then
  actual_output="$case_root/actual-setpriv-sudo.out"
  set +e
  /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C /usr/bin/setpriv --reuid="$runtime_uid" --regid="$runtime_gid" --clear-groups --no-new-privs /usr/bin/sudo -n /usr/bin/true > "$actual_output" 2>&1
  actual_status=$?
  set -e
  (( actual_status != 0 )) || { cat "$actual_output" >&2; echo 'real setpriv/sudo failure probe unexpectedly passed.' >&2; exit 1; }
  grep -Fq 'no new privileges' "$actual_output" || {
    cat "$actual_output" >&2
    echo 'real setpriv/sudo failure probe did not report the expected privilege contradiction.' >&2
    exit 1
  }
else
  echo 'SKIP: real /usr/bin/sudo setuid probe (sudo is not root-owned setuid).'
fi

/usr/bin/bash "$repo_root/scripts/ubuntu/install-trusted-launcher.sh" \
  --origin https://github.com/nathanestone-alt/herdr-workstation-bootstrap.git \
  --commit "$fixture_commit" \
  --fixture-root "$fixture_root" --fixture-transport "$transport" --fixture-home "$fixture_home" \
  --fixture-runtime-uid "$runtime_uid" --fixture-runtime-gid "$runtime_gid" \
  > "$case_root/launcher-install.out"
launcher="$fixture_root/usr/local/libexec/herdr-workstation-bootstrap"
set +e
/usr/bin/env -i HOME="$fixture_home" PATH=/usr/sbin:/usr/bin:/sbin:/bin \
  BASH_ENV= ENV= LC_ALL=C TZ=UTC \
  "$launcher" --entrypoint bootstrap -- --phase base > "$case_root/base.out" 2>&1
base_status=$?
set -e
(( base_status == 0 )) || {
  cat "$case_root/base.out" >&2
  if grep -Fq 'herdr launcher capability: policy grammar is not exact' "$case_root/base.out"; then
    echo 'Runtime-child capability regression reproduced the consumed policy descriptor failure.' >&2
  fi
  exit 1
}

[[ -s "$case_root/apt.log" ]] || { cat "$case_root/base.out" >&2; echo 'Base phase did not execute its privileged apt seam.' >&2; exit 1; }
[[ -s "$case_root/systemctl.log" ]] || { cat "$case_root/base.out" >&2; echo 'Base phase did not execute its privileged systemctl seam.' >&2; exit 1; }
[[ ! -e "$case_root/sudo-invoked" && ! -e "$case_root/sudo-no-new-privs-failure" ]] ||
  { cat "$case_root/base.out" >&2; echo 'Corrected root base phase still invoked sudo.' >&2; exit 1; }
[[ "$(< "$fixture_home/base-user-uid")" == "$runtime_uid" ]] ||
  { cat "$case_root/base.out" >&2; echo 'Base user stage did not run as the selected runtime user.' >&2; exit 1; }
[[ "$(< "$fixture_home/base-user-no-new-privs")" == 1 ]] ||
  { cat "$case_root/base.out" >&2; echo 'Base user stage did not retain no_new_privs.' >&2; exit 1; }
[[ "$(stat -c '%u:%g' "$fixture_home/.local/state/herdr-workstation-bootstrap/base-complete")" == "$runtime_uid:$runtime_gid" ]] ||
  { cat "$case_root/base.out" >&2; echo 'Base completion marker is not runtime-user owned.' >&2; exit 1; }
[[ "$(stat -c '%u:%g' "$fixture_home/.local/bin")" == "$runtime_uid:$runtime_gid" ]] ||
  { cat "$case_root/base.out" >&2; echo 'Base managed bin directory is not runtime-user owned.' >&2; exit 1; }
runtime_output="$case_root/runtime-children.out"
set +e
/usr/bin/env -i HOME="$fixture_home" PATH=/usr/sbin:/usr/bin:/sbin:/bin \
  BASH_ENV= ENV= LC_ALL=C TZ=UTC \
  "$launcher" --entrypoint bootstrap -- --phase runtime-child-regression > "$runtime_output" 2>&1
runtime_status=$?
set -e
(( runtime_status == 0 )) || {
  cat "$runtime_output" >&2
  if grep -Fq 'herdr launcher capability: policy grammar is not exact' "$runtime_output"; then
    echo 'Runtime-child capability regression reproduced the consumed policy descriptor failure.' >&2
  fi
  exit 1
}
for runtime_child_phase in runtime-child-1 runtime-child-2 runtime-child-3; do
  [[ "$(< "$fixture_home/$runtime_child_phase-uid")" == "$runtime_uid" ]] || {
    cat "$runtime_output" >&2
    echo "Runtime child '$runtime_child_phase' did not run as the selected runtime user." >&2
    exit 1
  }
  [[ "$(< "$fixture_home/$runtime_child_phase-no-new-privs")" == 1 ]] || {
    cat "$runtime_output" >&2
    echo "Runtime child '$runtime_child_phase' did not retain no_new_privs." >&2
    exit 1
  }
done
echo 'Parent-to-runtime-child capability descriptors and no-new-privs regression passed.'

echo 'Bootstrap privilege-model regression reproduced setpriv/sudo failure and passed the corrected root/runtime split.'
