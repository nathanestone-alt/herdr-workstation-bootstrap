#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

# The authority deliberately validates the same source/RTK relationships as
# production. Build a small clean source checkout and a clean locked RTK
# checkout rather than weakening those predicates for fixture mode.
source "$repo_root/config/ubuntu-toolchain.lock"
fixture_root="$test_root/fixture"
fixture_home="$fixture_root/home"
authority_path="$fixture_root/etc/stmodel/issue-961/receipt-authority.json"
receipt_path="$fixture_root/etc/stmodel/issue-961/receipt.json"
source_root="$test_root/source"
rtk_source_root="$fixture_home/src/rtk"
runtime_root="$fixture_home/.local/lib/herdr-workstation/python/$PYTHON_VERSION-$PYTHON_RELEASE-$PYTHON_PLATFORM"
stdlib_root="$runtime_root/lib/python3.13"

mkdir -p \
  "$fixture_root/bin" \
  "$fixture_home/.local/bin" \
  "$fixture_home/.local/lib/node-v$NODE_VERSION-linux-x64/bin" \
  "$fixture_home/.cargo/bin" \
  "$stdlib_root" \
  "$runtime_root/bin" \
  "$rtk_source_root"

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
make_tool "$fixture_home/.local/lib/node-v$NODE_VERSION-linux-x64/bin/node" "v$NODE_VERSION"
make_tool "$fixture_home/.cargo/bin/rtk" 'rtk 0.42.4'

export FIXTURE_HOME="$fixture_home"
export FIXTURE_RUNTIME_ROOT="$runtime_root"
cat > "$fixture_home/.local/bin/python3.13" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == '--version' ]]; then
  printf 'Python 3.13.15\n'
elif [[ "${1:-}" == '-c' ]]; then
  printf '{"version":"3.13.15","version_info":[3,13,15,"final",0],"implementation":"CPython","executable":"%s","prefix":"%s/.local","base_prefix":"%s","stdlib":"%s/lib/python3.13"}\n' \
    "$0" "$FIXTURE_HOME" "$FIXTURE_RUNTIME_ROOT" "$FIXTURE_RUNTIME_ROOT"
else
  exit 2
fi
EOF
chmod 0755 "$fixture_home/.local/bin/python3.13"
printf 'runtime executable\n' > "$runtime_root/bin/python3.13"
printf 'stdlib fixture\n' > "$stdlib_root/fixture.py"
ln -s fixture.py "$stdlib_root/fixture-link.py"
cat > "$fixture_home/.local/pyvenv.cfg" <<EOF
home = $runtime_root
include-system-site-packages = false
version = $PYTHON_VERSION
EOF

git -C "$rtk_source_root" init -q
git -C "$rtk_source_root" config user.email fixture@example.invalid
git -C "$rtk_source_root" config user.name fixture
printf 'locked RTK source\n' > "$rtk_source_root/README"
git -C "$rtk_source_root" add README
git -C "$rtk_source_root" commit -qm 'fixture RTK source'
rtk_commit="$(git -C "$rtk_source_root" rev-parse HEAD)"
git -C "$rtk_source_root" remote add origin "$RTK_REPO_URL"

mkdir -p "$source_root/config" "$source_root/scripts/ubuntu"
cp "$repo_root/scripts/ubuntu/receipt-authority.sh" "$source_root/scripts/ubuntu/receipt-authority.sh"
cp "$repo_root/config/receipt-authority-role-allowlist.txt" "$source_root/config/receipt-authority-role-allowlist.txt"
cp "$repo_root/config/payload-manifest.sha256" "$source_root/config/payload-manifest.sha256"
cp "$repo_root/config/ubuntu-toolchain.lock" "$source_root/config/ubuntu-toolchain.lock"
sed -i "s/^RTK_REF=.*/RTK_REF=$rtk_commit/" "$source_root/config/ubuntu-toolchain.lock"
git -C "$source_root" init -q
git -C "$source_root" config user.email fixture@example.invalid
git -C "$source_root" config user.name fixture
git -C "$source_root" add .
git -C "$source_root" commit -qm 'fixture bootstrap source'

run_authority() {
  bash "$repo_root/scripts/ubuntu/receipt-authority.sh" "$@" \
    --source-root "$source_root" \
    --user-home "$fixture_home" \
    --authority-path "$authority_path" \
    --receipt-path "$receipt_path" \
    --rtk-source-root "$rtk_source_root" \
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
[[ "$(jq -r '.rtk_source.locked_ref' "$receipt_path")" == "$rtk_commit" ]] || exit 1
[[ "$(jq -r '.rtk_source.clean' "$receipt_path")" == true ]] || exit 1
[[ "$(jq -r '.python313.venv.home' "$receipt_path")" == "$runtime_root" ]] || exit 1
[[ "$(jq -r '.python313.runtime.base_prefix' "$receipt_path")" == "$runtime_root" ]] || exit 1
[[ "$(jq -r '.python313.runtime.stdlib' "$receipt_path")" == "$stdlib_root" ]] || exit 1

cp "$authority_path" "$test_root/authority.good"
cp "$receipt_path" "$test_root/receipt.good"

jq '.receipt_sha256 = ("0" * 64)' "$authority_path" > "$test_root/authority.tampered"
mv -- "$test_root/authority.tampered" "$authority_path"
expect_failure 'tampered authority hash' run_authority --check
cp "$test_root/authority.good" "$authority_path"
chmod 0644 "$authority_path"

cp "$fixture_home/.cargo/bin/rtk" "$test_root/rtk.good"
printf 'tampered\n' >> "$fixture_home/.cargo/bin/rtk"
expect_failure 'tampered RTK executable' run_authority --check
cp "$test_root/rtk.good" "$fixture_home/.cargo/bin/rtk"

printf 'tampered\n' >> "$rtk_source_root/README"
expect_failure 'dirty RTK source checkout' run_authority --check
git -C "$rtk_source_root" checkout -- README
printf 'staged tamper\n' >> "$rtk_source_root/README"
git -C "$rtk_source_root" add README
expect_failure 'staged RTK source checkout' run_authority --check
git -C "$rtk_source_root" reset -q HEAD -- README
git -C "$rtk_source_root" checkout -- README
printf 'untracked tamper\n' > "$rtk_source_root/untracked"
expect_failure 'untracked RTK source checkout' run_authority --check
rm -- "$rtk_source_root/untracked"

printf 'ignored-input\n' >> "$rtk_source_root/.git/info/exclude"
printf 'ignored RTK build input\n' > "$rtk_source_root/ignored-input"
[[ -z "$(git -C "$rtk_source_root" status --porcelain --untracked-files=all)" ]] || {
  echo 'Ignored RTK fixture is not hidden from ordinary status.' >&2
  exit 1
}
expect_failure 'ignored untracked RTK source checkout' run_authority --check
rm -- "$rtk_source_root/ignored-input"

git -C "$rtk_source_root" update-index --assume-unchanged README
assume_flag_before="$(git -C "$rtk_source_root" ls-files -v -- README)"
printf 'assume-unchanged tamper\n' > "$rtk_source_root/README"
expect_failure 'assume-unchanged RTK source checkout' run_authority --check
assume_flag_after="$(git -C "$rtk_source_root" ls-files -v -- README)"
[[ "$assume_flag_after" == "$assume_flag_before" ]] || {
  echo 'RTK assume-unchanged index flag was mutated.' >&2
  exit 1
}
git -C "$rtk_source_root" update-index --no-assume-unchanged README
git -C "$rtk_source_root" checkout -- README

git -C "$rtk_source_root" update-index --skip-worktree README
skip_flag_before="$(git -C "$rtk_source_root" ls-files -v -- README)"
printf 'skip-worktree tamper\n' > "$rtk_source_root/README"
expect_failure 'skip-worktree RTK source checkout' run_authority --check
skip_flag_after="$(git -C "$rtk_source_root" ls-files -v -- README)"
[[ "$skip_flag_after" == "$skip_flag_before" ]] || {
  echo 'RTK skip-worktree index flag was mutated.' >&2
  exit 1
}
git -C "$rtk_source_root" update-index --no-skip-worktree README
git -C "$rtk_source_root" checkout -- README
run_authority --check
[[ "$(jq -r '.clean' "$receipt_path")" == true ]] || exit 1

git -C "$rtk_source_root" remote set-url origin https://example.invalid/rtk.git
expect_failure 'RTK source URL mismatch' run_authority --check
git -C "$rtk_source_root" remote set-url origin "$RTK_REPO_URL"

jq '.python313.sha256 = ("0" * 64)' "$receipt_path" > "$test_root/receipt.tampered"
mv -- "$test_root/receipt.tampered" "$receipt_path"
expect_failure 'tampered Python receipt' run_authority --check
cp "$test_root/receipt.good" "$receipt_path"

printf 'tampered\n' >> "$fixture_home/.local/pyvenv.cfg"
expect_failure 'tampered pyvenv.cfg' run_authority --check
cat > "$fixture_home/.local/pyvenv.cfg" <<EOF
home = $runtime_root
include-system-site-packages = false
version = $PYTHON_VERSION
EOF

printf 'tampered\n' >> "$stdlib_root/fixture.py"
expect_failure 'tampered Python runtime' run_authority --check
printf 'stdlib fixture\n' > "$stdlib_root/fixture.py"

chmod 0666 "$receipt_path"
expect_failure 'writable receipt body' run_authority --check
chmod 0644 "$receipt_path"

cp "$fixture_home/.cargo/bin/rtk" "$fixture_root/bin/rtk"
expect_failure 'duplicate RTK executable' run_authority --check
rm -- "$fixture_root/bin/rtk"

mv -- "$authority_path" "$test_root/authority.real"
ln -s "$test_root/authority.real" "$authority_path"
expect_failure 'symlinked authority' run_authority --check
rm -- "$authority_path"
mv -- "$test_root/authority.real" "$authority_path"

printf '# source-root mismatch\n' >> "$source_root/scripts/ubuntu/receipt-authority.sh"
git -C "$source_root" add scripts/ubuntu/receipt-authority.sh
git -C "$source_root" commit -qm 'fixture source script mismatch'
expect_failure 'source-root script mismatch' run_authority --check

echo 'receipt authority install, reconciliation, provenance and fail-closed tamper tests passed.'
