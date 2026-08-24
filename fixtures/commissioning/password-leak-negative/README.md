# Password-leak negative fixture

This fixture contains no real password and creates no repository artifact. It
uses a process-local synthetic sentinel to prove both sides of the hygiene
check: the scanner rejects a temporary copy containing a synthetic unsafe
secret-to-argv use, clean evidence passes, and evidence containing the
sentinel is rejected without the sentinel appearing in the checker’s stdout or
stderr.

Run from the repository root:

~~~bash
set -euo pipefail
fixture_root="$(mktemp -d)"
trap 'rm -rf -- "$fixture_root"' EXIT
sentinel="commissioning-synthetic-sentinel-$$"
printf '%s\n' 'clean commissioning evidence' >"$fixture_root/clean.log"
printf '%s\n' "$sentinel" >"$fixture_root/leak.log"

printf '%s\n' "$sentinel" |
  scripts/commissioning/ubuntu/test-password-hygiene.sh \
    --repo "$PWD" --scan "$fixture_root/clean.log" >/dev/null

if printf '%s\n' "$sentinel" |
    scripts/commissioning/ubuntu/test-password-hygiene.sh \
      --repo "$PWD" --scan "$fixture_root/leak.log" \
      >"$fixture_root/stdout" 2>"$fixture_root/stderr"; then
  echo 'negative fixture unexpectedly passed' >&2
  exit 1
fi
if grep -Fq "$sentinel" "$fixture_root/stdout" ||
   grep -Fq "$sentinel" "$fixture_root/stderr"; then
  echo 'negative fixture leaked its sentinel' >&2
  exit 1
fi
printf '%s\n' 'PASS password-leak negative fixture'
~~~

For the real commissioning check, replace the synthetic sentinel with one
line supplied directly by the approved password manager, and scan the local
commissioning record, every generated manifest/log, and the OneDrive Outbox
evidence path. Never put the password in a command argument, shell history,
fixture, repository file, or evidence record.
