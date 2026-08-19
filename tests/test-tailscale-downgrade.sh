#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
starting_commit='589b0c3c9879d9cb98b43952f02b6b5f01f73230'

git show "$starting_commit:scripts/ubuntu/bootstrap.sh" > "$test_root/starting-bootstrap.sh"

prepare_fixture_repo() {
  local fixture_repo="$1"
  local bootstrap_source="$2"
  mkdir -p "$fixture_repo/scripts/ubuntu" "$fixture_repo/config"
  cp "$bootstrap_source" "$fixture_repo/scripts/ubuntu/bootstrap.sh"
  cp "$repo_root/config/ubuntu-toolchain.lock" "$fixture_repo/config/ubuntu-toolchain.lock"
  chmod 0755 "$fixture_repo/scripts/ubuntu/bootstrap.sh"
}

write_fixture_commands() {
  local case_root="$1"
  local fake_bin="$case_root/bin"
  mkdir -p "$fake_bin"

  cat > "$fake_bin/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while [[ $# -gt 0 && "$1" == *=* && "$1" != -* ]]; do
  export "$1"
  shift
done
exec "$@"
EOF

  cat > "$fake_bin/apt-get" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case_root="${CASE_ROOT:?}"
printf 'apt-get' >> "$case_root/apt.log"
for arg in "$@"; do printf ' %q' "$arg" >> "$case_root/apt.log"; done
printf '\n' >> "$case_root/apt.log"

has_tailscale=0
has_allow_downgrades=0
for arg in "$@"; do
  case "$arg" in
    tailscale|tailscale=*) has_tailscale=1 ;;
    --allow-downgrades) has_allow_downgrades=1 ;;
  esac
done
if (( has_tailscale == 1 )); then
  if (( has_allow_downgrades == 0 )); then
    printf 'The following packages will be DOWNGRADED:\n  tailscale\nE: Packages were downgraded and -y was used without --allow-downgrades.\n' >&2
    exit 100
  fi
  if [[ "${CASE_MODE:-}" == install-failure ]]; then
    printf 'simulated package installation failure\n' >&2
    exit 71
  fi
  if [[ "${CASE_MODE:-}" != post-mismatch ]]; then
    printf '%s\n' "${EXPECTED_TAILSCALE_VERSION:?}" > "$case_root/tailscale.version"
  fi
fi
EOF

  cat > "$fake_bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'git %q' "$1" >> "${CASE_ROOT:?}/command.log"
for arg in "${@:2}"; do printf ' %q' "$arg" >> "$CASE_ROOT/command.log"; done
printf '\n' >> "$CASE_ROOT/command.log"
exit 0
EOF

  cat > "$fake_bin/ps" <<'EOF'
#!/usr/bin/env bash
printf 'systemd\n'
EOF

  cat > "$fake_bin/pwsh" <<'EOF'
#!/usr/bin/env bash
printf '7.6.4\n'
EOF

  cat > "$fake_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'systemctl' >> "${CASE_ROOT:?}/command.log"
for arg in "$@"; do printf ' %q' "$arg" >> "$CASE_ROOT/command.log"; done
printf '\n' >> "$CASE_ROOT/command.log"
EOF

  cat > "$fake_bin/tailscale" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == version ]]; then
  cat "${CASE_ROOT:?}/tailscale.version"
  exit 0
fi
exit 0
EOF

  cat > "$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'curl unexpectedly invoked\n' >> "${CASE_ROOT:?}/forbidden.log"
exit 99
EOF

  chmod 0755 "$fake_bin"/*
}

run_case() {
  local case_name="$1"
  local bootstrap_source="$2"
  local case_mode="$3"
  local initial_version="$4"
  local expected_status="$5"
  local expect_marker="$6"
  local expect_allow_downgrades="$7"
  local case_root="$test_root/$case_name"
  local fixture_repo="$case_root/repo"
  local home="$case_root/home"
  local output="$case_root/output.log"
  local status

  mkdir -p "$case_root" "$home"
  prepare_fixture_repo "$fixture_repo" "$bootstrap_source"
  write_fixture_commands "$case_root"
  printf '%s\n' "$initial_version" > "$case_root/tailscale.version"
  printf '#!/bin/sh\nset -eu\nversion="${TAILSCALE_VERSION}"\nif [ "${CASE_MODE:-}" = arbitrary-installer ]; then version=9.99.9; fi\napt-get install -y "tailscale=$version" tailscale-archive-keyring\n' > "$case_root/installer.sh"
  chmod 0755 "$case_root/installer.sh"

  set +e
  CASE_ROOT="$case_root" \
  CASE_MODE="$case_mode" \
  EXPECTED_TAILSCALE_VERSION='1.88.4' \
  HOME="$home" \
  PATH="$case_root/bin:/usr/bin:/bin" \
  bash -c '
    set -euo pipefail
    bootstrap_script="$1"
    set --
    source "$bootstrap_script"
    if [[ "${CASE_MODE:-}" == invalid-lock ]]; then
      TAILSCALE_VERSION=not-a-semantic-version
    fi
    download_verified() {
      printf "download_verified %s\\n" "$1" >> "${CASE_ROOT:?}/command.log"
      if [[ "${CASE_MODE:-}" == checksum-failure ]]; then
        printf "simulated checksum failure\\n" >&2
        return 23
      fi
      cp "${CASE_ROOT:?}/installer.sh" "$3"
    }
    install_base
  ' _ "$fixture_repo/scripts/ubuntu/bootstrap.sh" > "$output" 2>&1
  status=$?
  set -e

  [[ "$status" -eq "$expected_status" ]] || {
    sed -n '1,160p' "$output" >&2
    echo "$case_name returned $status, expected $expected_status." >&2
    exit 1
  }
  if [[ "$expect_marker" == yes ]]; then
    [[ -f "$home/.local/state/herdr-workstation-bootstrap/base-complete" ]] || {
      echo "$case_name did not publish base-complete." >&2
      exit 1
    }
  else
    [[ ! -e "$home/.local/state/herdr-workstation-bootstrap/base-complete" ]] || {
      echo "$case_name published base-complete after failure." >&2
      exit 1
    }
  fi
  if [[ "$expect_allow_downgrades" == yes ]]; then
    [[ -f "$case_root/apt.log" ]] || {
      echo "$case_name did not invoke the package seam." >&2
      exit 1
    }
    grep -Fq -- '--allow-downgrades' "$case_root/apt.log" || {
      echo "$case_name did not use the bounded apt downgrade option." >&2
      exit 1
      }
  else
    if [[ -f "$case_root/apt.log" ]] && grep -Fq -- '--allow-downgrades' "$case_root/apt.log"; then
      echo "$case_name unexpectedly used the downgrade option." >&2
      exit 1
    fi
  fi
  [[ ! -s "$case_root/forbidden.log" ]] || {
    cat "$case_root/forbidden.log" >&2
    echo "$case_name invoked a forbidden network seam." >&2
    exit 1
  }
  printf '%s status=%s marker=%s allow_downgrades=%s\n' \
    "$case_name" "$status" "$expect_marker" "$expect_allow_downgrades"
}

run_case parent-downgrade "$test_root/starting-bootstrap.sh" exact 1.102.2 100 no no
run_case candidate-downgrade "$repo_root/scripts/ubuntu/bootstrap.sh" exact 1.102.2 0 yes yes
run_case candidate-upgrade "$repo_root/scripts/ubuntu/bootstrap.sh" exact 1.80.0 0 yes yes
run_case candidate-exact "$repo_root/scripts/ubuntu/bootstrap.sh" exact 1.88.4 0 yes no
run_case candidate-arbitrary-installer "$repo_root/scripts/ubuntu/bootstrap.sh" arbitrary-installer 1.102.2 24 no no
run_case candidate-invalid-lock "$repo_root/scripts/ubuntu/bootstrap.sh" invalid-lock 1.102.2 22 no no
run_case candidate-checksum-failure "$repo_root/scripts/ubuntu/bootstrap.sh" checksum-failure 1.102.2 23 no no
run_case candidate-install-failure "$repo_root/scripts/ubuntu/bootstrap.sh" install-failure 1.102.2 71 no yes
run_case candidate-post-mismatch "$repo_root/scripts/ubuntu/bootstrap.sh" post-mismatch 1.102.2 24 no yes

exact_case="$test_root/candidate-exact"
if [[ -f "$exact_case/apt.log" ]] && grep -Fq 'tailscale=' "$exact_case/apt.log"; then
  echo 'Already-exact Tailscale unexpectedly installed a package.' >&2
  exit 1
fi
if [[ -f "$exact_case/command.log" ]] && grep -Fq 'download_verified' "$exact_case/command.log"; then
  echo 'Already-exact Tailscale unexpectedly downloaded or installed a package.' >&2
  exit 1
fi

echo 'Tailscale locked-version downgrade regression tests passed.'
