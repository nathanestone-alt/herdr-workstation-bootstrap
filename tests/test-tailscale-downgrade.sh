#!/usr/bin/env bash
set -euo pipefail
umask 022

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
canonical_origin='https://github.com/nathanestone-alt/herdr-workstation-bootstrap.git'

prepare_fixture() {
  local case_root="$1" case_mode="$2"
  local source_root="$case_root/source"
  local fixture_root="$case_root/fixture"
  local fixture_home="$fixture_root/home"
  local transport="$fixture_root/transport.git"
  local fake_bin="$case_root/bin"
  local trusted_bin="$case_root/trusted-bin"
  local trusted_apt="$trusted_bin/apt-get"
  mkdir -p "$source_root/scripts/ubuntu" "$source_root/config" "$fixture_home" "$fake_bin" "$trusted_bin"
  cp "$repo_root/scripts/ubuntu/bootstrap.sh" "$source_root/scripts/ubuntu/bootstrap.sh"
  cp "$repo_root/scripts/ubuntu/rtk-release.sh" "$source_root/scripts/ubuntu/rtk-release.sh"
  cp "$repo_root/scripts/ubuntu/source-attestation.sh" "$source_root/scripts/ubuntu/source-attestation.sh"
  cp "$repo_root/scripts/ubuntu/launcher-capability.sh" "$source_root/scripts/ubuntu/launcher-capability.sh"
  cp "$repo_root/scripts/ubuntu/trusted-launcher.sh" "$source_root/scripts/ubuntu/trusted-launcher.sh"
  cp "$repo_root/config/ubuntu-toolchain.lock" "$source_root/config/ubuntu-toolchain.lock"
  chmod 0755 "$source_root" "$source_root/scripts/ubuntu/"*.sh
  chmod 0644 "$source_root/config/ubuntu-toolchain.lock"

  cat > "$fake_bin/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while [[ $# -gt 0 && "$1" == *=* && "$1" != -* ]]; do
  export "$1"
  shift
done
if [[ "$1" == /usr/bin/bash && "__CASE_MODE__" == installer-replacement ]]; then
  printf '%s\n' 'tampered installer' > "$4"
fi
exec "$@"
EOF
  cat > "$fake_bin/apt-get" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case_root='__CASE_ROOT__'
case_mode='__CASE_MODE__'
expected_version='1.102.2'
apt_self="$(/usr/bin/realpath -e -- "$0" 2>/dev/null || printf '%s' "$0")"
apt_log="$case_root/apt.log"
[[ "$apt_self" == "$case_root/trusted-bin/apt-get" ]] && apt_log="$case_root/trusted-apt.log"
printf 'apt-get' >> "$apt_log"
for arg in "$@"; do printf ' %q' "$arg" >> "$apt_log"; done
printf '\n' >> "$apt_log"
has_tailscale=0
has_allow_downgrades=0
for arg in "$@"; do
  case "$arg" in
    tailscale|tailscale=*) has_tailscale=1 ;;
    --allow-downgrades) has_allow_downgrades=1 ;;
  esac
done
if (( has_tailscale == 1 )); then
  (( has_allow_downgrades == 1 )) || exit 100
  [[ "$case_mode" != install-failure ]] || exit 71
  if [[ "$case_mode" != post-mismatch ]]; then
    printf '%s\n' "$expected_version" > "$case_root/tailscale.version"
  fi
fi
EOF
  cp "$fake_bin/apt-get" "$trusted_apt"
  chmod 0755 "$trusted_apt"
  cat > "$fake_bin/tailscale" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == version ]]; then cat '__CASE_ROOT__/tailscale.version'; fi
EOF
  cat > "$fake_bin/ps" <<'EOF'
#!/usr/bin/env bash
printf 'systemd\n'
EOF
  cat > "$fake_bin/pwsh" <<'EOF'
#!/usr/bin/env bash
printf '7.6.5\n'
EOF
  cat > "$fake_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod 0755 "$fake_bin"/*
  /usr/bin/sed -i \
    -e "s|__CASE_ROOT__|$case_root|g" \
    -e "s|__CASE_MODE__|$case_mode|g" \
    "$fake_bin/apt-get" "$trusted_apt" "$fake_bin/tailscale" "$fake_bin/sudo"

  # This fixture invokes the production bootstrap through the installed
  # launcher. Only the apt pathname is redirected inside the disposable
  # fixture; the production source is asserted below to bind /usr/bin/apt-get.
  /usr/bin/sed -i \
    -e "s|apt_get_path=/usr/bin/apt-get|apt_get_path=$trusted_apt|g" \
    -e "s|== /usr/bin/apt-get|== $trusted_apt|g" \
    -e "s|== 0:0:\\*|== $(/usr/bin/id -u):$(/usr/bin/id -g):*|g" \
    "$source_root/scripts/ubuntu/bootstrap.sh"
  /usr/bin/head -n -9 "$source_root/scripts/ubuntu/bootstrap.sh" > "$source_root/scripts/ubuntu/bootstrap.sh.tmp"
  /usr/bin/mv -T "$source_root/scripts/ubuntu/bootstrap.sh.tmp" "$source_root/scripts/ubuntu/bootstrap.sh"
  cat >> "$source_root/scripts/ubuntu/bootstrap.sh" <<EOF
fixture_tailscale_main() {
  TAILSCALE_INSTALLER_SHA256='__INSTALLER_SHA256__'
  bootstrap_command_path() {
    case "\$1" in
      sudo|ps|pwsh|systemctl|tailscale) printf '%s/bin/%s\\n' '$case_root' "\$1" ;;
      apt-get) printf '%s\\n' '$trusted_apt' ;;
      *) return 1 ;;
    esac
  }
  bootstrap_exec_system() {
    /usr/bin/env -i HOME='$fixture_home' PATH='$case_root/bin:/usr/bin:/bin' \
      CASE_ROOT='$case_root' CASE_MODE='$case_mode' \
      EXPECTED_TAILSCALE_VERSION='1.102.2' "\$@"
  }
  bootstrap_validate_tailscale_apt_identity() {
    [[ "\$1" == '$trusted_apt' ]]
  }
  bootstrap_download_transport() {
    cp '$case_root/installer.sh' "\$2"
  }
  install_base
}
case "\$phase" in
  fixture-tailscale) fixture_tailscale_main ;;
  *) echo "unsupported fixture phase: \$phase" >&2; exit 2 ;;
esac
EOF
  chmod 0755 "$source_root/scripts/ubuntu/bootstrap.sh"

  /usr/bin/git -C "$source_root" init -q
  /usr/bin/git -C "$source_root" config user.email fixture@example.invalid
  /usr/bin/git -C "$source_root" config user.name fixture
  /usr/bin/git -C "$source_root" remote add origin "$canonical_origin"
  /usr/bin/git -C "$source_root" add .
  /usr/bin/git -C "$source_root" commit -qm 'tailscale launcher fixture'
  printf '%s\n' '1.103.0' > "$case_root/tailscale.version"
  cat > "$case_root/installer.sh" <<'EOF'
#!/usr/bin/env sh
set -eu
version="${TAILSCALE_VERSION:?}"
if [ "__CASE_MODE__" = arbitrary-installer ]; then version=9.99.9; fi
apt-get install -y "tailscale=$version" tailscale-archive-keyring
EOF
  /usr/bin/sed -i "s|__CASE_MODE__|$case_mode|g" "$case_root/installer.sh"
  chmod 0755 "$case_root/installer.sh"
  installer_sha256="$(/usr/bin/sha256sum "$case_root/installer.sh" | /usr/bin/gawk '{print $1}')"
  /usr/bin/sed -i "s|__INSTALLER_SHA256__|$installer_sha256|g" "$source_root/scripts/ubuntu/bootstrap.sh"
  /usr/bin/git -C "$source_root" add scripts/ubuntu/bootstrap.sh
  /usr/bin/git -C "$source_root" commit -qm 'bind fixture installer hash'
  fixture_commit="$(/usr/bin/git -C "$source_root" rev-parse --verify HEAD^{commit})"
  /usr/bin/git clone -q --bare "$source_root" "$transport"
  chmod 0700 "$transport"
  /usr/bin/bash "$repo_root/scripts/ubuntu/install-trusted-launcher.sh" \
    --origin "$canonical_origin" --commit "$fixture_commit" \
    --fixture-root "$fixture_root" --fixture-transport "$transport" --fixture-home "$fixture_home" \
    > "$case_root/launcher-install.out"
  launcher="$fixture_root/usr/local/libexec/herdr-workstation-bootstrap"
}

run_case() {
  local case_name="$1" case_mode="$2" initial_version="$3" expected_status="$4" expect_marker="$5"
  local case_root="$test_root/$case_name"
  local fixture_root="$case_root/fixture"
  local fixture_home="$fixture_root/home"
  mkdir -p "$case_root"
  prepare_fixture "$case_root" "$case_mode"
  printf '%s\n' "$initial_version" > "$case_root/tailscale.version"
  set +e
  /usr/bin/env -i HOME="$fixture_home" PATH="$case_root/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    BASH_ENV= ENV= LC_ALL=C TZ=UTC CASE_ROOT="$case_root" CASE_MODE="$case_mode" \
    EXPECTED_TAILSCALE_VERSION='1.102.2' \
    "$case_root/fixture/usr/local/libexec/herdr-workstation-bootstrap" \
    --entrypoint bootstrap -- --phase fixture-tailscale > "$case_root/output.log" 2>&1
  status=$?
  set -e
  [[ "$status" == "$expected_status" ]] || {
    cat "$case_root/output.log" >&2
    echo "$case_name returned $status, expected $expected_status." >&2
    exit 1
  }
  if [[ "$expect_marker" == yes ]]; then
    [[ -f "$case_root/tailscale.version" && "$(< "$case_root/tailscale.version")" == 1.102.2 ]] || {
      cat "$case_root/output.log" >&2
      echo "$case_name did not publish the locked Tailscale version." >&2
      exit 1
    }
  else
    [[ "$(< "$case_root/tailscale.version")" == "$initial_version" ]] ||
      { echo "$case_name changed Tailscale after failure." >&2; exit 1; }
  fi
  if [[ "$expect_marker" == yes ]]; then
    grep -Fq -- '--allow-downgrades' "$case_root/trusted-apt.log" ||
      { echo "$case_name did not use the descriptor-bound downgrade seam." >&2; exit 1; }
  elif [[ -f "$case_root/trusted-apt.log" ]] && grep -Fq -- '--allow-downgrades' "$case_root/trusted-apt.log"; then
    echo "$case_name unexpectedly used the downgrade option." >&2
    exit 1
  fi
  printf '%s status=%s marker=%s\n' "$case_name" "$status" "$expect_marker"
}

run_case candidate-downgrade exact 1.103.0 0 yes
run_case candidate-exact exact 1.102.2 0 no
run_case candidate-arbitrary-installer arbitrary-installer 1.103.0 24 no
run_case candidate-installer-replacement installer-replacement 1.103.0 24 no

production_bootstrap="$repo_root/scripts/ubuntu/bootstrap.sh"
/usr/bin/grep -Fq 'apt_get_path=/usr/bin/apt-get' "$production_bootstrap"
/usr/bin/grep -Fq 'exec 8<"$apt_get_path"' "$production_bootstrap"
/usr/bin/grep -Fq 'apt_fd_path=/proc/self/fd/8' "$production_bootstrap"
! /usr/bin/grep -Fq 'HERDR_TAILSCALE_REAL_APT_GET' "$production_bootstrap" ||
  { echo 'Production Tailscale path still trusts a caller apt marker.' >&2; exit 1; }

echo 'Tailscale launcher downgrade, exact-version, installer-integrity, and apt-descriptor tests passed.'
