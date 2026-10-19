#!/usr/bin/env bash
set -euo pipefail
umask 022
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d /tmp/herdr-backup-install-test.XXXXXX)"
trap 'rm -rf -- "$test_root"' EXIT
# Every write lands in test_root: HOME is a fixture and crontab is a shim that
# keeps its table in a file, so the real user crontab is never read or changed.
installer="$repo_root/scripts/ubuntu/backup/install-herdr-backup.sh"
export HOME="$test_root/home"
mkdir -p "$HOME" "$test_root/bin"
cat > "$test_root/bin/crontab" <<EOF
#!/usr/bin/env bash
table="$test_root/crontab.txt"
case "\${1:-}" in
  -l) [[ -f "$test_root/crontab.fail" ]] && { echo "crontabs/test/: fopen: Permission denied" >&2; exit 1; }
      [[ -f "\$table" ]] && cat "\$table" || { echo "no crontab for test" >&2; exit 1; } ;;
  -) cat > "\$table" ;;
  *) echo "unexpected crontab args: \$*" >&2; exit 2 ;;
esac
EOF
chmod 0755 "$test_root/bin/crontab"
export PATH="$test_root/bin:$PATH"
cron_line='30 8 * * * $HOME/.local/bin/herdr-backup'

fail() { echo "FAIL $*"; exit 1; }

# No crontab and no password yet: install succeeds, warns, and never creates a password.
printf '0 8 * * * other-job\n' > "$test_root/crontab.txt"
out="$("$installer")"
grep -q 'WARN .*password not found' <<<"$out" || fail "missing password warning"
[[ ! -e "$HOME/.config/restic/password" ]] || fail "installer created a password file"
cmp -s "$repo_root/scripts/ubuntu/backup/herdr-backup" "$HOME/.local/bin/herdr-backup" || fail "script not installed"
cmp -s "$repo_root/scripts/ubuntu/backup/restic.env" "$HOME/.config/restic/env" || fail "env not installed"
cmp -s "$repo_root/scripts/ubuntu/backup/restic-excludes" "$HOME/.config/restic/excludes" || fail "excludes not installed"
[[ -x "$HOME/.local/bin/herdr-backup" ]] || fail "script not executable"
[[ -d "$HOME/.local/state/herdr-backup" ]] || fail "state dir missing"

# --check fails without the password, then passes once it exists.
if "$installer" --check >/dev/null; then fail "--check passed without a password"; fi
install -m 0600 /dev/null "$HOME/.config/restic/password"
"$installer" --check >/dev/null || fail "--check failed on a clean install"

# Idempotent: a second run keeps exactly one backup line and the unrelated line.
"$installer" >/dev/null
[[ "$(grep -cxF -- "$cron_line" "$test_root/crontab.txt")" == 1 ]] || fail "cron line not exactly once"
grep -qxF '0 8 * * * other-job' "$test_root/crontab.txt" || fail "unrelated cron line lost"
[[ "$(wc -l < "$test_root/crontab.txt")" == 2 ]] || fail "unexpected crontab size"

# Drift is caught.
echo '# drift' >> "$HOME/.config/restic/excludes"
if "$installer" --check >/dev/null; then fail "--check missed drift"; fi
"$installer" >/dev/null
"$installer" --check >/dev/null || fail "reinstall did not repair drift"

# An unreadable crontab (not "no crontab") aborts both modes and never rewrites the table.
table_before="$(cat "$test_root/crontab.txt")"
touch "$test_root/crontab.fail"
if "$installer" >/dev/null 2>&1; then fail "install succeeded on an unreadable crontab"; fi
if "$installer" --check >/dev/null 2>&1; then fail "--check passed on an unreadable crontab"; fi
rm -f "$test_root/crontab.fail"
[[ "$(cat "$test_root/crontab.txt")" == "$table_before" ]] || fail "unreadable crontab was rewritten"

# No crontab at all is an empty table: install creates it with the one line.
rm -f "$test_root/crontab.txt"
"$installer" >/dev/null
[[ "$(cat "$test_root/crontab.txt")" == "$cron_line" ]] || fail "fresh crontab not created"

# The repo env never carries an inline password.
if grep -qE '^(export )?RESTIC_PASSWORD=' "$repo_root/scripts/ubuntu/backup/restic.env"; then
  fail "restic.env holds an inline password"
fi

echo "PASS test-herdr-backup-install"
