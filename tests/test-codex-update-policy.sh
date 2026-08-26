#!/usr/bin/env bash
set -euo pipefail
umask 022

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d /tmp/codex-update-policy-test.XXXXXX)"
trap 'rm -rf -- "$test_root"' EXIT

extract_function() {
  local function_name="$1"
  awk -v name="$function_name" '
    $0 ~ "^" name "\\(\\) \\{$" { capture=1; depth=0 }
    capture {
      print
      opens=gsub(/\{/, "{")
      closes=gsub(/\}/, "}")
      depth += opens - closes
      if (depth == 0) exit
    }
  ' "$repo_root/scripts/ubuntu/bootstrap.sh"
}

harness="$test_root/codex-harness.sh"
{
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
  printf '%s\n' "readonly bootstrap_sort_bin='/usr/bin/sort'"
  printf '%s\n' "readonly bootstrap_trusted_path='/usr/sbin:/usr/bin:/sbin:/bin'"
  extract_function bootstrap_version_at_least
  extract_function bootstrap_version_greater
  extract_function bootstrap_codex_attestation
  extract_function converge_codex
  cat <<'EOF'
export CODEX_VERSION='0.148.0'
node_anchor="$HOME/node"
node_lifecycle_dir="$HOME/lifecycle"
codex_version_file="$HOME/codex-version"
codex_npm_log="$HOME/codex-npm.log"
mkdir -p "$node_anchor/bin" "$node_anchor/lib/node_modules/@openai/codex/bin" "$node_lifecycle_dir"
: > "$codex_npm_log"
cat > "$node_anchor/bin/node" <<'NODE'
#!/usr/bin/env bash
set -euo pipefail
node_anchor='__NODE_ANCHOR__'
codex_version_file='__CODEX_VERSION_FILE__'
codex_npm_log='__CODEX_NPM_LOG__'
script="${1:-}"
shift || true
case "$script" in
  "$node_anchor/bin/codex")
    printf 'codex-cli %s\n' "$(< "$codex_version_file")"
    ;;
  "$node_anchor/bin/npm")
    printf '%s\n' "$*" >> "$codex_npm_log"
    for arg in "$@"; do
      if [[ "$arg" == "@openai/codex@$CODEX_VERSION" ]]; then
        printf '%s\n' "$CODEX_VERSION" > "$codex_version_file"
      fi
    done
    ;;
  *)
    echo "unexpected pinned Node script: $script" >&2
    exit 24
    ;;
esac
NODE
sed -i \
  -e "s|__NODE_ANCHOR__|$node_anchor|g" \
  -e "s|__CODEX_VERSION_FILE__|$codex_version_file|g" \
  -e "s|__CODEX_NPM_LOG__|$codex_npm_log|g" \
  "$node_anchor/bin/node"
chmod 0755 "$node_anchor/bin/node"
cat > "$node_anchor/lib/node_modules/@openai/codex/bin/codex.js" <<'CODEX'
#!/usr/bin/env node
exit 91
CODEX
chmod 0755 "$node_anchor/lib/node_modules/@openai/codex/bin/codex.js"
ln -s -- "$node_anchor/lib/node_modules/@openai/codex/bin/codex.js" "$node_anchor/bin/codex"
cat > "$node_anchor/bin/npm" <<'NPM'
#!/usr/bin/env node
exit 91
NPM
chmod 0755 "$node_anchor/bin/npm"

run_converge() {
  : > "$codex_npm_log"
  converge_codex "$node_anchor" "$node_lifecycle_dir" "${1:-0}"
}

assert_no_codex_install() {
  ! grep -Fq -- "@openai/codex@$CODEX_VERSION" "$codex_npm_log"
}

printf '%s\n' "$CODEX_VERSION" > "$codex_version_file"
run_converge
assert_no_codex_install
[[ "$(< "$codex_version_file")" == "$CODEX_VERSION" ]]

newer_version='0.149.1'
printf '%s\n' "$newer_version" > "$codex_version_file"
target_before="$(sha256sum -- "$node_anchor/lib/node_modules/@openai/codex/bin/codex.js" | awk '{print $1}')"
run_converge
assert_no_codex_install
[[ "$(< "$codex_version_file")" == "$newer_version" ]]
[[ "$(sha256sum -- "$node_anchor/lib/node_modules/@openai/codex/bin/codex.js" | awk '{print $1}')" == "$target_before" ]]

printf '%s\n' '0.147.9' > "$codex_version_file"
run_converge
grep -Fq -- "@openai/codex@$CODEX_VERSION" "$codex_npm_log"
[[ "$(< "$codex_version_file")" == "$CODEX_VERSION" ]]

printf '%s\n' "$newer_version" > "$codex_version_file"
run_converge 1
grep -Fq -- "@openai/codex@$CODEX_VERSION" "$codex_npm_log"
[[ "$(< "$codex_version_file")" == "$CODEX_VERSION" ]]

printf '%s\n' "$newer_version" > "$codex_version_file"
receipt="$HOME/codex-receipt"
attestation="$(bootstrap_codex_attestation "$node_anchor/bin/node" "$node_anchor/bin/codex")"
IFS=$'\t' read -r codex_output codex_version codex_newer_than_lock <<< "$attestation"
{
  printf 'codex=%s\n' "$codex_output"
  printf 'codex_version=%s\n' "$codex_version"
  printf 'codex_newer_than_lock=%s\n' "$codex_newer_than_lock"
} > "$receipt"
grep -Fqx "codex=codex-cli $newer_version" "$receipt"
grep -Fqx "codex_version=$newer_version" "$receipt"
grep -Fqx 'codex_newer_than_lock=true' "$receipt"

echo 'Codex update-policy convergence, floor ordering, explicit downgrade, and receipt attestation tests passed.'
EOF
} > "$harness"
chmod 0755 "$harness"

HOME="$test_root/home" PATH=/usr/sbin:/usr/bin:/sbin:/bin \
  /usr/bin/bash "$harness"
