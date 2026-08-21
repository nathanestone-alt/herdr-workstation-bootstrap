#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

fixture_root="$test_root/fixture"
fixture_home="$fixture_root/home"
authority_path="$fixture_root/etc/stmodel/issue-961/receipt-authority.json"
receipt_path="$fixture_root/etc/stmodel/issue-961/receipt.json"
mkdir -p \
  "$fixture_root/bin" \
  "$fixture_home/.local/bin" \
  "$fixture_home/.local/lib/node-v24.19.0-linux-x64/bin" \
  "$fixture_home/.cargo/bin"

make_tool() {
  local path="$1"
  local output="$2"
  cat > "$path" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == '--version' ]]; then
  printf '%s\n' '$output'
else
  exit 2
fi
EOF
  chmod 0755 "$path"
}

make_tool "$fixture_root/bin/bash" 'GNU bash, version 5.2.21(1)-release (x86_64-pc-linux-gnu)'
make_tool "$fixture_root/bin/git" 'git version 2.43.0'
make_tool "$fixture_root/bin/gh" 'gh version 2.45.0 (fixture)'
make_tool "$fixture_root/bin/pwsh" 'PowerShell 7.6.5'
make_tool "$fixture_home/.local/lib/node-v24.19.0-linux-x64/bin/node" 'v24.19.0'
make_tool "$fixture_home/.cargo/bin/rtk" 'rtk 0.42.4'

cat > "$fixture_home/.local/bin/python3.13" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == '--version' ]]; then
  printf 'Python 3.13.15\n'
else
  printf '%s\n' '{"version":"3.13.15","version_info":[3,13,15,"final",0],"implementation":"CPython"}'
fi
EOF
chmod 0755 "$fixture_home/.local/bin/python3.13"

run_authority() {
  bash "$repo_root/scripts/ubuntu/receipt-authority.sh" "$@" \
    --source-root "$repo_root" \
    --user-home "$fixture_home" \
    --authority-path "$authority_path" \
    --receipt-path "$receipt_path" \
    --fixture-root "$fixture_root"
}

expect_failure() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "$label unexpectedly passed." >&2
    exit 1
  fi
}

run_authority --install
run_authority --check
[[ -f "$authority_path" && ! -L "$authority_path" ]] || exit 1
[[ -f "$receipt_path" && ! -L "$receipt_path" ]] || exit 1
[[ "$(jq -r '.authority_id' "$authority_path")" == '#961-installation-authority-v1' ]] || exit 1
[[ "$(jq -r '.role_identities.rtk.executable' "$receipt_path")" == "$fixture_home/.cargo/bin/rtk" ]] || exit 1
[[ "$(jq -r '.python313.executable' "$receipt_path")" == "$fixture_home/.local/bin/python3.13" ]] || exit 1

cp "$authority_path" "$test_root/authority.good"
cp "$receipt_path" "$test_root/receipt.good"
jq '.receipt_sha256 = ("0" * 64)' "$authority_path" > "$test_root/authority.tampered"
mv -- "$test_root/authority.tampered" "$authority_path"
expect_failure 'tampered authority hash' run_authority --check
cp "$test_root/authority.good" "$authority_path"

cp "$fixture_home/.cargo/bin/rtk" "$test_root/rtk.good"
printf 'tampered\n' >> "$fixture_home/.cargo/bin/rtk"
expect_failure 'tampered RTK executable' run_authority --check
cp "$test_root/rtk.good" "$fixture_home/.cargo/bin/rtk"

cp "$fixture_home/.cargo/bin/rtk" "$fixture_root/bin/rtk"
expect_failure 'duplicate RTK executable' run_authority --check
rm -- "$fixture_root/bin/rtk"

jq '.python313.sha256 = ("0" * 64)' "$receipt_path" > "$test_root/receipt.tampered"
mv -- "$test_root/receipt.tampered" "$receipt_path"
expect_failure 'tampered Python receipt' run_authority --check
cp "$test_root/receipt.good" "$receipt_path"

mv -- "$authority_path" "$test_root/authority.real"
ln -s "$test_root/authority.real" "$authority_path"
expect_failure 'symlinked authority' run_authority --check
rm -- "$authority_path"
mv -- "$test_root/authority.real" "$authority_path"

run_authority --check
echo 'receipt authority install, reconciliation and fail-closed tamper tests passed.'
