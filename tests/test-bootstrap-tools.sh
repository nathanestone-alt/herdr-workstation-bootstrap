#!/usr/bin/env bash
set -euo pipefail
umask 022

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

# This fixture executes the real tools phase through the installed trusted
# launcher. Downloads and the receipt handoff are test transports; all
# publication, version checks, manifest generation, and receipt verification
# remain the production functions.
# shellcheck disable=SC1091
source "$repo_root/config/ubuntu-toolchain.lock"
official_rtk_version="$RTK_VERSION"
official_rtk_url="$RTK_URL"
official_rtk_sha256="$RTK_SHA256"

assert_fixture_rewrite() {
  local fixture_file="$1"
  local expected_text="$2"
  local label="$3"
  /usr/bin/grep -Fq -- "$expected_text" "$fixture_file" || {
    echo "Fixture rewrite did not apply: $label" >&2
    exit 1
  }
}

root_tools_mode=0
root_tools_uid=''
root_tools_gid=''
if [[ "$(/usr/bin/id -u)" == 0 ]]; then
  root_tools_uid="$(/usr/bin/id -u nobody 2>/dev/null || true)"
  root_tools_gid="$(/usr/bin/id -g nobody 2>/dev/null || true)"
  if [[ "$root_tools_uid" =~ ^[1-9][0-9]*$ && "$root_tools_gid" =~ ^[0-9]+$ ]]; then
    root_tools_mode=1
  else
    echo 'SKIP: root trusted-launcher tools handoff fixture (nobody account unavailable).' >&2
  fi
else
  echo 'SKIP: root trusted-launcher tools handoff fixture (not running as root).' >&2
fi

source_fixture="$test_root/source"
fixture_root="$test_root/fixture"
fixture_home="$fixture_root/home"
transport="$fixture_root/transport.git"
mkdir -p -- "$fixture_root" "$fixture_home"
fixture_ambient_node_dir="$fixture_root/ambient-node"
wrong_node_version='22.0.0'
mkdir -p -- "$fixture_ambient_node_dir/bin"
cat > "$fixture_ambient_node_dir/bin/node" <<EOF
#!/usr/bin/bash
set -euo pipefail
if [[ "\${1:-}" == '--version' ]]; then
  printf 'v%s\n' '$wrong_node_version'
else
  echo 'Ambient wrong-version Node shim was executed.' >&2
  exit 24
fi
EOF
chmod 0755 "$fixture_ambient_node_dir/bin/node"
cp -a -- "$repo_root/." "$source_fixture/"
/usr/bin/rm -rf -- "$source_fixture/.agents" "$source_fixture/.codex" "$source_fixture/.git"
/usr/bin/awk -v ambient_node_bin="$fixture_ambient_node_dir/bin" '
  $0 ~ /^readonly bootstrap_trusted_path=/ {
    printf "readonly bootstrap_trusted_path=\"%s:/usr/sbin:/usr/bin:/sbin:/bin\"\n", ambient_node_bin
    found++
    next
  }
  { print }
  END { exit(found == 1 ? 0 : 1) }
' "$source_fixture/scripts/ubuntu/bootstrap.sh" > "$source_fixture/scripts/ubuntu/bootstrap.sh.tmp"
mv -T -- "$source_fixture/scripts/ubuntu/bootstrap.sh.tmp" "$source_fixture/scripts/ubuntu/bootstrap.sh"
dispatch_sentinel='if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then'
dispatch_counts="$(/usr/bin/awk -v sentinel="$dispatch_sentinel" '
  index($0, "if [[ \"${BASH_SOURCE[0]}\"") == 1 {
    candidates++
    if ($0 == sentinel) exact++
  }
  END { printf "%d %d\n", candidates + 0, exact + 0 }
' "$source_fixture/scripts/ubuntu/bootstrap.sh")"
read -r dispatch_candidate_count dispatch_sentinel_count <<< "$dispatch_counts"
[[ "$dispatch_candidate_count" == 1 && "$dispatch_sentinel_count" == 1 ]] || {
  echo 'Bootstrap tools fixture dispatch sentinel is missing or malformed.' >&2
  exit 1
}
/usr/bin/awk -v sentinel="$dispatch_sentinel" '
  $0 == sentinel { found++; exit }
  { print }
  END { exit(found == 1 ? 0 : 1) }
' "$source_fixture/scripts/ubuntu/bootstrap.sh" > "$source_fixture/scripts/ubuntu/bootstrap.sh.tmp"
mv -T -- "$source_fixture/scripts/ubuntu/bootstrap.sh.tmp" "$source_fixture/scripts/ubuntu/bootstrap.sh"
if [[ "$root_tools_mode" == 1 ]]; then
  # Keep the root regression isolated from live /etc and /usr/local. The
  # fixture-root rewrite intentionally does not exercise production's complete
  # /etc-to-/ ancestry; this is an accepted fixture relaxation, while the
  # actual production root handoff remains covered by the root invocation.
  /usr/bin/sed -i \
    -e "s|/etc/herdr-workstation/bootstrap-policy.conf|$fixture_root/etc/herdr-workstation/bootstrap-policy.conf|g" \
    -e "s|for policy_component in /etc /etc/herdr-workstation; do|for policy_component in \"$fixture_root/etc\" \"$fixture_root/etc/herdr-workstation\"; do|g" \
    -e "s|/usr/local/libexec/herdr-workstation-bootstrap|$fixture_root/usr/local/libexec/herdr-workstation-bootstrap|g" \
    "$source_fixture/scripts/ubuntu/bootstrap.sh"
  assert_fixture_rewrite "$source_fixture/scripts/ubuntu/bootstrap.sh" \
    "$fixture_root/etc/herdr-workstation/bootstrap-policy.conf" \
    'bootstrap policy path'
  assert_fixture_rewrite "$source_fixture/scripts/ubuntu/bootstrap.sh" \
    "for policy_component in \"$fixture_root/etc\" \"$fixture_root/etc/herdr-workstation\"; do" \
    'bootstrap policy component ancestry'
  assert_fixture_rewrite "$source_fixture/scripts/ubuntu/bootstrap.sh" \
    "$fixture_root/usr/local/libexec/herdr-workstation-bootstrap" \
    'trusted launcher path'
fi

assert_payload_delivery() {
  local payload_source="$1"
  local functions_file="$test_root/receipt-payload-functions.sh"
  local expected_payload="$test_root/receipt-payload.expected"
  local harness="$test_root/receipt-payload-harness.sh"
  local captured_payload="$test_root/receipt-payload.captured"
  /usr/bin/awk \
    -v start='bootstrap_receipt_root_payload() {' \
    -v end='# END bootstrap_receipt_root_payload' '
      $0 == start { capture=1 }
      capture { print }
      capture && $0 == end { closed=1; exit }
      END { exit(capture && closed ? 0 : 1) }
    ' "$payload_source" > "$functions_file" || {
      echo 'Receipt payload producer function was not found.' >&2
      exit 1
    }
  /usr/bin/awk \
    -v start='bootstrap_exec_privileged_payload() {' \
    -v end='# END bootstrap_exec_privileged_payload' '
      $0 == start { capture=1 }
      capture { print }
      capture && $0 == end { closed=1; exit }
      END { exit(capture && closed ? 0 : 1) }
    ' "$payload_source" >> "$functions_file" || {
      echo 'Privileged payload delivery function was not found.' >&2
      exit 1
    }
  /usr/bin/awk \
    -v start="  /usr/bin/cat <<'HERDR_RECEIPT_ROOT_PAYLOAD'" \
    -v end='HERDR_RECEIPT_ROOT_PAYLOAD' '
      $0 == start { capture=1; next }
      capture && $0 == end { closed=1; exit }
      capture { print }
      END { exit(capture && closed ? 0 : 1) }
    ' "$payload_source" > "$expected_payload" || {
      echo 'Receipt payload heredoc body was not found.' >&2
      exit 1
    }
  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
    /usr/bin/cat "$functions_file"
    /usr/bin/cat <<'EOF'
capture_path="$1"
expected_path="$2"
bootstrap_bash_bin=/usr/bin/bash
bootstrap_exec_privileged() {
  [[ "$1" == fixture-sudo && "$2" == /usr/bin/bash && "$3" == -c &&
    "$5" == -- && "$6" == payload-arg-1 && "$7" == payload-arg-2 ]] || {
    echo 'Privileged payload wrapper altered argv shape.' >&2
    exit 1
  }
  printf '%s' "$4" > "$capture_path"
}
payload="$(bootstrap_receipt_root_payload)"
payload+=$'\n'
bootstrap_exec_privileged_payload fixture-sudo "$payload" payload-arg-1 payload-arg-2
cmp -s "$capture_path" "$expected_path" || {
  echo 'Privileged shell payload is not byte-identical to the heredoc source.' >&2
  exit 1
}
EOF
  } > "$harness"
  /usr/bin/chmod 0755 "$harness"
  /usr/bin/bash "$harness" "$captured_payload" "$expected_payload"
  for required_fragment in \
    'found++ } } END' \
    "while IFS= read -r -d '' full; do" \
    'if [[ -L "$full" ]]; then' \
    'actual_mode=' \
    'actual_digest=' \
    'done < <(/usr/bin/find -P "$root" -mindepth 1 -print0)' \
    'for path in "${!payload_sha[@]}"; do'; do
    /usr/bin/grep -Fq -- "$required_fragment" "$expected_payload" || {
      echo "Receipt payload is missing required verifier fragment: $required_fragment" >&2
      exit 1
    }
  done
}

assert_payload_delivery "$source_fixture/scripts/ubuntu/bootstrap.sh"

cat >> "$source_fixture/scripts/ubuntu/bootstrap.sh" <<'EOF'
fixture_tools_root="${HOME%/home}"
fixture_tools_home="$HOME"
fixture_tools_receipt_dir="$fixture_tools_root/etc/stmodel/issue-961"
fixture_tools_authority="$fixture_tools_receipt_dir/receipt-authority.json"
fixture_tools_receipt="$fixture_tools_receipt_dir/receipt.json"
fixture_tools_launcher="$fixture_tools_root/usr/local/libexec/herdr-workstation-bootstrap"
fixture_tools_rtk_archive="$fixture_tools_root/rtk-official-fixture.tar.gz"
fixture_tools_handoff_marker="$fixture_tools_root/receipt-handoff.complete"

bootstrap_command_path() {
  case "$1" in
    ps|pwsh|tailscale) printf '%s/bin/%s\n' "$fixture_tools_root" "$1" ;;
    *) echo "Unexpected production command lookup in tools fixture: $1" >&2; return 24 ;;
  esac
}

bootstrap_receipt_authority_path() {
  printf '%s\n' "$fixture_tools_authority"
}

bootstrap_query_apt_manifest() {
  printf '%s\n' 'apt:fixture=tools-phase'
}

download_verified() {
  local url="$1"
  local _expected_sha="$2"
  local destination="$3"
  case "$url" in
    "$RTK_URL") /usr/bin/cp -- "$fixture_tools_rtk_archive" "$destination" ;;
    "$HERDR_URL") /usr/bin/cp -- "$fixture_tools_root/herdr-fixture" "$destination" ;;
    *) echo "Unexpected fixture download URL: $url" >&2; return 24 ;;
  esac
}

if [[ "$bootstrap_root_mode" != 1 ]]; then
  install_receipt_from_snapshots() {
    local handoff_home="$HOME"
    local handoff_uid handoff_gid
    # Root keeps the tools in the fixture HOME, then hands that same tree to a
    # non-root fixture owner. This exercises the production authority's
    # non-root managed-home contract without changing a live account.
    if [[ "$(/usr/bin/id -u)" == 0 ]]; then
      handoff_uid="$(/usr/bin/id -u nobody 2>/dev/null || true)"
      handoff_gid="$(/usr/bin/id -g nobody 2>/dev/null || true)"
      [[ "$handoff_uid" =~ ^[0-9]+$ && "$handoff_uid" != 0 && "$handoff_gid" =~ ^[0-9]+$ ]] || {
        echo 'Tools fixture requires a non-root nobody account for the receipt handoff.' >&2
        return 24
      }
      /usr/bin/chown -R --no-dereference "$handoff_uid:$handoff_gid" "$handoff_home"
    fi
    /usr/bin/mkdir -p -- "$fixture_tools_receipt_dir"
    /usr/bin/env -i HOME="$HOME" PATH=/usr/sbin:/usr/bin:/sbin:/bin BASH_ENV= ENV= \
      "$fixture_tools_launcher" --entrypoint receipt-authority -- --install \
      --source-root "$bootstrap_repo_root" \
      --user-home "$handoff_home" \
      --authority-path "$fixture_tools_authority" \
      --receipt-path "$fixture_tools_receipt" \
      --fixture-root "$fixture_tools_root"
    printf '%s\n' "$handoff_home" > "$fixture_tools_handoff_marker"
  }
fi

fixture_tools_main() {
  local fixture_rtk_sha256
  # A second root invocation restores the fixture HOME owner after the
  # receipt handoff, while preserving every public file and symlink name.
  if [[ "$(/usr/bin/id -u)" == 0 ]]; then
    /usr/bin/chown -R --no-dereference 0:0 "$HOME"
  fi
  fixture_rtk_sha256="$(/usr/bin/sha256sum -- "$fixture_tools_rtk_archive" | /usr/bin/gawk '{print $1}')"
  RTK_SHA256="$fixture_rtk_sha256"
  export RTK_SHA256
  case "$phase" in
    tools) install_tools ;;
    *) echo "Unsupported tools fixture phase: $phase" >&2; return 2 ;;
  esac
  if [[ "$phase" == tools ]]; then
    printf '%s\n' "$fixture_tools_home" > "$fixture_tools_handoff_marker"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  fixture_tools_main
fi
EOF
if [[ "$root_tools_mode" == 1 ]]; then
  /usr/bin/sed -i \
    -e "s|authority_path='/etc/stmodel/issue-961/receipt-authority.json'|authority_path='$fixture_root/etc/stmodel/issue-961/receipt-authority.json'|" \
    -e "s|receipt_path='/etc/stmodel/issue-961/receipt.json'|receipt_path='$fixture_root/etc/stmodel/issue-961/receipt.json'|" \
    "$source_fixture/scripts/ubuntu/receipt-authority.sh"
  assert_fixture_rewrite "$source_fixture/scripts/ubuntu/receipt-authority.sh" \
    "authority_path='$fixture_root/etc/stmodel/issue-961/receipt-authority.json'" \
    'receipt authority path'
  assert_fixture_rewrite "$source_fixture/scripts/ubuntu/receipt-authority.sh" \
    "receipt_path='$fixture_root/etc/stmodel/issue-961/receipt.json'" \
    'receipt path'
fi
chmod 0755 "$source_fixture/scripts/ubuntu/bootstrap.sh"

git -C "$source_fixture" init -q
git -C "$source_fixture" config user.email fixture@example.invalid
git -C "$source_fixture" config user.name fixture
git -C "$source_fixture" add -f .
git -C "$source_fixture" commit -qm 'tools phase integration fixture'
git clone -q --bare "$source_fixture" "$transport"
chmod 0700 "$transport"
source_commit="$(git -C "$source_fixture" rev-parse --verify HEAD^{commit})"

if [[ "$root_tools_mode" == 1 ]]; then
  /usr/bin/chown "$root_tools_uid:$root_tools_gid" "$fixture_home"
fi
fixture_runtime_args=()
if [[ "$root_tools_mode" == 1 ]]; then
  fixture_runtime_args+=(--fixture-runtime-uid "$root_tools_uid" --fixture-runtime-gid "$root_tools_gid")
fi
/usr/bin/bash "$repo_root/scripts/ubuntu/install-trusted-launcher.sh" \
  --origin https://github.com/nathanestone-alt/herdr-workstation-bootstrap.git \
  --commit "$source_commit" \
  --fixture-root "$fixture_root" \
  --fixture-transport "$transport" \
  --fixture-home "$fixture_home" \
  "${fixture_runtime_args[@]}" \
  > "$test_root/launcher-install.out"
launcher="$fixture_root/usr/local/libexec/herdr-workstation-bootstrap"

make_version_tool() {
  local path="$1"
  local output="$2"
  mkdir -p -- "$(dirname "$path")"
  cat > "$path" <<EOF
#!/usr/bin/bash
set -euo pipefail
if [[ "\$1" == '--version' ]]; then
  printf '%s\\n' '$output'
fi
EOF
  chmod 0755 "$path"
}

mkdir -p -- "$fixture_root/bin"
cat > "$fixture_root/bin/ps" <<'EOF'
#!/usr/bin/bash
printf '%s\n' systemd
EOF
chmod 0755 "$fixture_root/bin/ps"
make_version_tool "$fixture_root/bin/bash" 'GNU bash, version 5.2.15(1)-release (x86_64-pc-linux-gnu)'
make_version_tool "$fixture_root/bin/git" 'git version 2.48.0'
make_version_tool "$fixture_root/bin/gh" 'gh version 2.75.0'
make_version_tool "$fixture_root/bin/pwsh" "PowerShell $POWERSHELL_VERSION"
cat > "$fixture_root/bin/tailscale" <<EOF
#!/usr/bin/bash
set -euo pipefail
if [[ "\$1" == version ]]; then
  printf '%s\\n' '$TAILSCALE_VERSION'
else
  printf '%s\\n' '$TAILSCALE_VERSION'
fi
EOF
chmod 0755 "$fixture_root/bin/tailscale"

mkdir -p -- \
  "$fixture_home/.cargo/bin" \
  "$fixture_home/.config/herdr-workstation" \
  "$fixture_home/.local/bin" \
  "$fixture_home/.local/state/herdr-workstation-bootstrap" \
  "$fixture_home/.local/lib/herdr-workstation/uv/$UV_VERSION" \
  "$fixture_home/.local/lib/herdr-workstation/python" \
  "$fixture_home/.local/lib/node-v$NODE_VERSION-linux-x64/bin" \
  "$fixture_home/.local/lib/node-v$NODE_VERSION-linux-x64/lib/node_modules/@openai/codex/bin" \
  "$fixture_home/.local/lib/node-v$NODE_VERSION-linux-x64/lib/node_modules/@anthropic-ai/claude-code" \
  "$fixture_home/.local/lib/node-v$NODE_VERSION-linux-x64/lib/node_modules/bun" \
  "$fixture_home/code"
touch "$fixture_home/.local/state/herdr-workstation-bootstrap/base-complete"

uv_dir="$fixture_home/.local/lib/herdr-workstation/uv/$UV_VERSION/$UV_PLATFORM"
python_runtime_root="$fixture_home/.local/lib/herdr-workstation/python/$PYTHON_VERSION-$PYTHON_RELEASE-$PYTHON_PLATFORM"
python_stdlib_root="$python_runtime_root/lib/python3.13"
mkdir -p -- "$uv_dir" "$python_runtime_root/bin" "$python_stdlib_root"
cat > "$uv_dir/uv" <<EOF
#!/usr/bin/bash
printf '%s\\n' 'uv $UV_VERSION ($UV_PLATFORM)'
EOF
chmod 0755 "$uv_dir/uv"

cat > "$python_runtime_root/bin/python3.13" <<EOF
#!/usr/bin/bash
set -euo pipefail
fixture_user_home='$fixture_home'
fixture_runtime_root='$python_runtime_root'
fixture_python_version='$PYTHON_VERSION'
self_path="\$(/usr/bin/realpath -e -- "\$0" 2>/dev/null || true)"
if [[ "\$1" == '--version' ]]; then
  printf 'Python %s\\n' "\$fixture_python_version"
  exit 0
fi
if [[ "\$1" == '-c' ]]; then
  code="\$2"
  if [[ "\$code" == *json.dumps* ]]; then
    IFS=. read -r major minor micro <<< "\$fixture_python_version"
    printf '{"version":"%s","version_info":[%s,%s,%s,"final",0],"implementation":"CPython","executable":"%s","prefix":"%s/.local","base_prefix":"%s","stdlib":"%s/lib/python3.13"}\\n' \\
      "\$fixture_python_version" "\$major" "\$minor" "\$micro" "\$self_path" \\
      "\$fixture_user_home" "\$fixture_runtime_root" "\$fixture_runtime_root"
  elif [[ "\$code" == *platform.machine* ]]; then
    printf '%s|x86_64|linux\\n' "\$fixture_python_version"
  else
    printf '%s\\n' 0
  fi
fi
EOF
chmod 0755 "$python_runtime_root/bin/python3.13"
printf '%s\n' 'fixture stdlib' > "$python_stdlib_root/fixture.py"

make_version_tool "$fixture_home/.cargo/bin/rustup" "rustup $RUSTUP_VERSION"
make_version_tool "$fixture_home/.cargo/bin/cargo" 'cargo 1.97.1 (fixture)'
make_version_tool "$fixture_home/.cargo/bin/rustc" "rustc $RUST_TOOLCHAIN (fixture)"

node_dir="$fixture_home/.local/lib/node-v$NODE_VERSION-linux-x64"
npm_invocation_marker="$fixture_home/.local/state/herdr-workstation-bootstrap/pinned-node-npm.marker"
codex_invocation_marker="$fixture_home/.local/state/herdr-workstation-bootstrap/pinned-node-codex.marker"
cat > "$node_dir/bin/node" <<EOF
#!/usr/bin/bash
set -euo pipefail
fixture_node_dir='$node_dir'
fixture_ambient_node_dir='$fixture_ambient_node_dir'
fixture_npm_marker='$npm_invocation_marker'
fixture_codex_marker='$codex_invocation_marker'
case "\${1:-}" in
  --version)
    printf 'v%s\\n' '$NODE_VERSION'
    ;;
  /proc/self/fd/*/bin/npm)
    npm_real="\$(/usr/bin/realpath -e -- "\$1" 2>/dev/null || true)"
    [[ "\$npm_real" == "\$fixture_node_dir/bin/npm" ]] || {
      echo "Pinned Node received an unexpected npm path: \$npm_real" >&2
      exit 24
    }
    case "\${2:-}" in
      install)
        lifecycle_anchor_fd=''
        if [[ "\$PATH" =~ ^/proc/self/fd/([0-9]+)/bin: ]]; then
          lifecycle_anchor_fd="\${BASH_REMATCH[1]}"
        fi
        for lifecycle_fd_path in /proc/self/fd/*; do
          lifecycle_fd="\${lifecycle_fd_path##*/}"
          [[ "\$lifecycle_fd" =~ ^[0-9]+$ && "\$lifecycle_fd" -gt 2 ]] || continue
          eval "exec \${lifecycle_fd}<&-" 2>/dev/null || true
        done
        if [[ -n "\$lifecycle_anchor_fd" ]]; then
          eval "exec \${lifecycle_anchor_fd}<\"\$fixture_ambient_node_dir\""
        fi
        lifecycle_path0="\${PATH%%:*}"
        [[ "\$lifecycle_path0" == "\$fixture_node_dir"/.herdr-node-lifecycle.* &&
          "\$lifecycle_path0" != "\$fixture_node_dir/bin" &&
          -d "\$lifecycle_path0" ]] || {
          echo "Npm lifecycle PATH[0] is not the dedicated Node shim: \$lifecycle_path0" >&2
          exit 24
        }
        lifecycle_entries="\$(find "\$lifecycle_path0" -mindepth 1 -maxdepth 1 -printf '%f\\n')"
        [[ "\$lifecycle_entries" == node ]] || {
          echo "Npm lifecycle Node shim contains unexpected entries: \$lifecycle_entries" >&2
          exit 24
        }
        lifecycle_node_path="\$(command -v node || true)"
        [[ -n "\$lifecycle_node_path" ]] || {
          echo 'Npm lifecycle could not resolve node.' >&2
          exit 24
        }
        lifecycle_node_version="\$(command "\$lifecycle_node_path" --version)"
        [[ "\$lifecycle_node_version" == "v$NODE_VERSION" ]] || {
          echo 'Npm lifecycle did not resolve the locked Node version.' >&2
          exit 24
        }
        lifecycle_node_real="\$(/usr/bin/realpath -e -- "\$lifecycle_node_path" 2>/dev/null || true)"
        [[ "\$lifecycle_node_real" == "\$fixture_node_dir/bin/node" ]] || {
          echo "Npm lifecycle resolved node to an unexpected path: \$lifecycle_node_real" >&2
          exit 24
        }
        printf '%s\\n' 'pinned-node-executed-npm-install' > "\$fixture_npm_marker"
        printf '%s\\n' 'pinned-node-lifecycle-node' >> "\$fixture_npm_marker"
        ;;
      --version)
        printf '%s\\n' 'pinned-node-executed-npm-version' >> "\$fixture_npm_marker"
        printf '%s\\n' '10.9.3'
        ;;
      *)
        echo "Pinned Node received unexpected npm arguments: \$*" >&2
        exit 24
        ;;
    esac
    ;;
  /proc/self/fd/*/bin/codex)
    codex_real="\$(/usr/bin/realpath -e -- "\$1" 2>/dev/null || true)"
    [[ "\$codex_real" == "\$fixture_node_dir/lib/node_modules/@openai/codex/bin/codex.js" ]] || {
      echo "Pinned Node received an unexpected Codex path: \$codex_real" >&2
      exit 24
    }
    [[ "\${2:-}" == '--version' ]] || {
      echo "Pinned Node received unexpected Codex arguments: \$*" >&2
      exit 24
    }
    printf '%s\n' 'pinned-node-executed-codex-version' >> "\$fixture_codex_marker"
    printf '%s\n' 'codex-cli $CODEX_VERSION'
    ;;
  *)
    echo "Pinned Node received unexpected arguments: \$*" >&2
    exit 24
    ;;
esac
EOF
chmod 0755 "$node_dir/bin/node"
cat > "$node_dir/bin/npm" <<'EOF'
#!/usr/bin/env node
process.exit(91);
EOF
chmod 0755 "$node_dir/bin/npm"
make_version_tool "$node_dir/bin/npx" '10.9.3'
make_version_tool "$node_dir/bin/corepack" '0.31.0'
cat > "$node_dir/lib/node_modules/@openai/codex/bin/codex.js" <<'EOF'
#!/usr/bin/env node
process.exit(91);
EOF
chmod 0755 "$node_dir/lib/node_modules/@openai/codex/bin/codex.js"
ln -s -- "$node_dir/lib/node_modules/@openai/codex/bin/codex.js" "$node_dir/bin/codex"
make_version_tool "$node_dir/bin/claude" "$CLAUDE_VERSION fixture"
make_version_tool "$node_dir/bin/bun" "$BUN_VERSION"
make_version_tool "$node_dir/bin/bunx" "$BUN_VERSION"

cat > "$fixture_root/herdr-fixture" <<EOF
#!/usr/bin/bash
printf '%s\\n' 'herdr $HERDR_VERSION'
EOF
chmod 0755 "$fixture_root/herdr-fixture"

mkdir -p -- "$test_root/rtk-root"
cat > "$test_root/rtk-root/rtk" <<EOF
#!/usr/bin/bash
printf '%s\\n' 'rtk $official_rtk_version'
EOF
chmod 0755 "$test_root/rtk-root/rtk"
tar -C "$test_root/rtk-root" -czf "$fixture_root/rtk-official-fixture.tar.gz" rtk
if [[ "$root_tools_mode" == 1 ]]; then
  /usr/bin/chmod 0644 "$fixture_root/rtk-official-fixture.tar.gz"
  /usr/bin/chown -R --no-dereference "$root_tools_uid:$root_tools_gid" "$fixture_home"
  /usr/bin/mkdir -p -- "$fixture_root/etc/stmodel/issue-961"
  /usr/bin/chmod 0755 "$fixture_root/etc/stmodel" "$fixture_root/etc/stmodel/issue-961"
  /usr/bin/chown 0:0 "$fixture_root/etc/stmodel" "$fixture_root/etc/stmodel/issue-961"
else
  /usr/bin/chmod 0600 "$fixture_root/rtk-official-fixture.tar.gz"
fi

mkdir -p -- "$test_root/no-node-path"
set +e
/usr/bin/env -i HOME="$fixture_home" PATH="$test_root/no-node-path" \
  "$node_dir/bin/codex" --version > "$test_root/direct-codex.out" 2>&1
direct_codex_status=$?
set -e
(( direct_codex_status != 0 )) || {
  cat "$test_root/direct-codex.out" >&2
  echo 'Codex fixture unexpectedly succeeded through its ambient shebang.' >&2
  exit 1
}

run_tools() {
  /usr/bin/env -i HOME="$fixture_home" PATH=/usr/sbin:/usr/bin:/sbin:/bin \
    BASH_ENV= ENV= LC_ALL=C TZ=UTC \
    "$launcher" --entrypoint bootstrap -- --phase tools
}

if ! run_tools > "$test_root/tools.out" 2>&1; then
  cat "$test_root/tools.out" >&2
  exit 1
fi
lifecycle_shim_residue="$(find "$fixture_home" -type d -name '.herdr-node-lifecycle.*' -print -quit)"
[[ -z "$lifecycle_shim_residue" ]] || {
  echo "Tools phase left Node lifecycle shim residue: $lifecycle_shim_residue" >&2
  exit 1
}
[[ -f "$fixture_home/.local/state/herdr-workstation-bootstrap/tools-complete" ]] || {
  cat "$test_root/tools.out" >&2
  echo 'Tools phase did not publish its completion marker.' >&2
  exit 1
}
rtk_path="$fixture_home/.cargo/bin/rtk"
[[ -f "$rtk_path" && ! -L "$rtk_path" && -x "$rtk_path" ]] || exit 1
[[ "$("$rtk_path" --version)" == "rtk $official_rtk_version" ]] || exit 1
release_stage_count="$(find "$fixture_home/.cargo/bin" -maxdepth 1 -name '.rtk-release.*' -print | wc -l)"
(( release_stage_count == 0 )) || {
  echo 'RTK publication leaked a staging file after the tools phase.' >&2
  exit 1
}
[[ ! -e "$fixture_home/.local/bin/rtk" && ! -L "$fixture_home/.local/bin/rtk" ]] || {
  echo 'Tools phase left a managed RTK alias beside the canonical publication.' >&2
  exit 1
}

manifest="$fixture_home/.local/state/herdr-workstation-bootstrap/toolchain-manifest.txt"
grep -Fqx "rtk_version=rtk $official_rtk_version" "$manifest"
grep -Fqx "rtk_url=$official_rtk_url" "$manifest"
grep -Fqx "receipt_authority_path=$fixture_root/etc/stmodel/issue-961/receipt-authority.json" "$manifest"
grep -Fqx 'apt:fixture=tools-phase' "$manifest"
[[ -f "$fixture_root/etc/stmodel/issue-961/receipt.json" &&
  -f "$fixture_root/etc/stmodel/issue-961/receipt-authority.json" ]] || {
  echo 'Tools phase did not hand off and publish the receipt pair.' >&2
  exit 1
}
[[ "$(< "$fixture_root/receipt-handoff.complete")" == "$fixture_home" ]] || {
  echo 'Tools phase receipt handoff marker is incorrect.' >&2
  exit 1
}
[[ "$(jq -r '.rtk_release.version' "$fixture_root/etc/stmodel/issue-961/receipt.json")" == "$official_rtk_version" ]]
[[ "$(jq -r '.rtk_release.url' "$fixture_root/etc/stmodel/issue-961/receipt.json")" == "$official_rtk_url" ]]
[[ "$(jq -r '.rtk_release.sha256' "$fixture_root/etc/stmodel/issue-961/receipt.json")" == "$official_rtk_sha256" ]]
[[ "$(jq -r '.role_identities.rtk.version' "$fixture_root/etc/stmodel/issue-961/receipt.json")" == "rtk $official_rtk_version" ]]
grep -Fqx 'pinned-node-executed-npm-install' "$npm_invocation_marker"
grep -Fqx 'pinned-node-lifecycle-node' "$npm_invocation_marker"
grep -Fqx 'pinned-node-executed-npm-version' "$npm_invocation_marker"
grep -Fqx "codex=codex-cli $CODEX_VERSION" "$manifest"
grep -Fqx 'pinned-node-executed-codex-version' "$codex_invocation_marker"

good_rtk="$fixture_home/.cargo/bin/rtk-good"
mv -- "$rtk_path" "$good_rtk"
ln -s -- "$good_rtk" "$rtk_path"
symlink_output="$test_root/rtk-symlink.out"
set +e
run_tools > "$symlink_output" 2>&1
symlink_status=$?
set -e
(( symlink_status != 0 )) || {
  echo 'Tools phase accepted a pre-existing canonical RTK symlink.' >&2
  exit 1
}
expected_symlink_diagnostic="A pre-existing canonical RTK symlink is not migrated: $rtk_path -> $good_rtk. Inspect and remove it out of band before rerunning the tools phase."
grep -Fqx -- "$expected_symlink_diagnostic" "$symlink_output" || {
  cat "$symlink_output" >&2
  echo 'Pre-existing RTK symlink diagnostic was not exact.' >&2
  exit 1
}
[[ -L "$rtk_path" && "$(readlink -- "$rtk_path")" == "$good_rtk" ]] || {
  echo 'Tools phase changed the pre-existing RTK symlink while rejecting it.' >&2
  exit 1
}
rm -- "$rtk_path"
mv -- "$good_rtk" "$rtk_path"
echo 'Bootstrap tools phase fixture passed.'
