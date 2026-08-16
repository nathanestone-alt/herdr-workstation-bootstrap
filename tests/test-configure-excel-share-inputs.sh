#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

fake_bin="$test_root/bin"
sudo_marker="$test_root/sudo-called"
mkdir -p "$fake_bin"
cat > "$fake_bin/sudo" <<EOF
#!/usr/bin/env bash
touch '$sudo_marker'
exit 99
EOF
chmod +x "$fake_bin/sudo"
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
expect_rejected spaced-mount "unsupported characters or path components" --mount-point "$existing_path"
[[ "$(stat -c '%a' "$existing_path")" == 755 ]] || {
  echo 'Invalid mount-point validation changed an existing directory mode.' >&2
  exit 1
}
expect_rejected bad-host "Windows host contains unsupported characters" --host 'bad host'
expect_rejected bad-share "SMB share name contains unsupported characters" --share 'bad#share'
expect_rejected bad-user "Windows user contains unsupported characters" --user $'bad\nuser'

echo 'configure-excel-share input validation regression test passed.'
