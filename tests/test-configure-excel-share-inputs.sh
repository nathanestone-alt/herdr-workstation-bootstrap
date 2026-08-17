#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

fake_bin="$test_root/bin"
sudo_marker="$test_root/sudo-called"
sudo_log="$test_root/sudo.log"
mkdir -p "$fake_bin"
export HERDR_TEST_SUDO_MARKER="$sudo_marker"
export HERDR_TEST_SUDO_LOG="$sudo_log"
cat > "$fake_bin/sudo" <<'EOF'
#!/usr/bin/env bash
touch "$HERDR_TEST_SUDO_MARKER"
printf '%s\n' "$*" >> "$HERDR_TEST_SUDO_LOG"
case "$1" in
  test) exit 0 ;;
  stat) printf '%s\n' '755:root:root'; exit 0 ;;
  *) exit 99 ;;
esac
EOF
cat > "$fake_bin/mount.cifs" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$fake_bin/sudo" "$fake_bin/mount.cifs"
export PATH="$fake_bin:/usr/bin:/bin"

existing_path="$test_root/existing path"
mkdir -p "$existing_path"
chmod 0755 "$existing_path"

expect_rejected() {
  local label="$1"
  local expected="$2"
  shift 2
  local output="$test_root/$label.out"

  rm -f "$sudo_marker"
  set +e
  "$repo_root/scripts/ubuntu/configure-excel-share.sh" "$@" >"$output" 2>&1
  local status=$?
  set -e

  [[ $status -eq 2 ]] || {
    echo "$label: expected exit 2, got $status" >&2
    cat "$output" >&2
    exit 1
  }
  grep -Fq "$expected" "$output" || {
    echo "$label: expected diagnostic was not emitted" >&2
    cat "$output" >&2
    exit 1
  }
  [[ ! -e "$sudo_marker" ]] || {
    echo "$label: validation invoked sudo before rejecting input" >&2
    exit 1
  }
}

expect_rejected root-mount "protected system path" --mount-point /
expect_rejected home-mount "protected system path" --mount-point /home
expect_rejected srv-root "protected system path" --mount-point /srv
expect_rejected opt-mount "direct /srv/herdr-* child" --mount-point /opt
expect_rejected nested-system-mount "direct /srv/herdr-* child" --mount-point /usr/local
expect_rejected spaced-mount "unsupported characters or path components" --mount-point "$existing_path"
[[ "$(stat -c '%a' "$existing_path")" == 755 ]] || {
  echo 'Invalid mount-point validation changed an existing directory mode.' >&2
  exit 1
}
expect_rejected bad-host "Windows host contains unsupported characters" --host 'bad host'
expect_rejected bad-share "SMB share name contains unsupported characters" --share 'bad#share'
expect_rejected bad-user "Windows user contains unsupported characters" --user $'bad\nuser'

rm -f "$sudo_marker" "$sudo_log"
existing_output="$test_root/existing-safe-name.out"
set +e
"$repo_root/scripts/ubuntu/configure-excel-share.sh" --mount-point /srv/herdr-existing >"$existing_output" 2>&1
existing_status=$?
set -e
[[ $existing_status -eq 22 ]] || {
  echo "existing-safe-name: expected exit 22, got $existing_status" >&2
  cat "$existing_output" >&2
  exit 1
}
grep -Fq 'Refusing to change it' "$existing_output" || {
  echo 'existing-safe-name: expected fail-closed ownership/mode diagnostic.' >&2
  cat "$existing_output" >&2
  exit 1
}
if grep -Fq 'install -d' "$sudo_log"; then
  echo 'Existing mount-point validation attempted a directory mode change.' >&2
  exit 1
fi

echo 'configure-excel-share input validation regression test passed.'
