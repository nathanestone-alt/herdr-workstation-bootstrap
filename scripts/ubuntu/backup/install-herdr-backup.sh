#!/usr/bin/env bash
# Install the nightly restic backup of herdr-ubuntu (bootstrap issue 23).
#   install-herdr-backup.sh          install or refresh; safe to re-run
#   install-herdr-backup.sh --check  exit 0 only if the live copies match this repo
# The restic password is never installed or read here: it stays in
# ~/.config/restic/password (mode 600) and the password manager.
set -euo pipefail

src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin_dir="$HOME/.local/bin"
cfg_dir="$HOME/.config/restic"
state_dir="$HOME/.local/state/herdr-backup"
cron_line='30 8 * * * $HOME/.local/bin/herdr-backup'

# repo file -> live path
pairs=(
  "herdr-backup:$bin_dir/herdr-backup"
  "restic.env:$cfg_dir/env"
  "restic-excludes:$cfg_dir/excludes"
)

# Print the user crontab. "no crontab for <user>" is an empty table; any other
# listing failure aborts, so a failed read can never be written back as empty.
read_crontab() {
  local out err
  err="$(mktemp)"
  if out="$(crontab -l 2>"$err")"; then
    rm -f -- "$err"; [[ -n "$out" ]] && printf '%s\n' "$out"; return 0
  fi
  if grep -q '^no crontab for' "$err"; then rm -f -- "$err"; return 0; fi
  echo "ERROR crontab -l failed: $(head -c 300 "$err")" >&2
  rm -f -- "$err"; return 1
}

cron_count() {
  local table
  table="$(read_crontab)" || return 1
  grep -cxF -- "$cron_line" <<<"$table" || true
}

if [[ "${1:-}" == --check ]]; then
  fail=0
  for pair in "${pairs[@]}"; do
    repo_file="$src/${pair%%:*}"; live="${pair#*:}"
    if ! cmp -s -- "$repo_file" "$live"; then
      echo "FAIL differs from repo: $live"; fail=1
    fi
  done
  if ! count="$(cron_count)"; then
    echo "FAIL could not read the crontab"; fail=1
  elif [[ "$count" != 1 ]]; then
    echo "FAIL crontab needs exactly one line: $cron_line"; fail=1
  fi
  [[ -f "$cfg_dir/password" ]] || { echo "FAIL missing $cfg_dir/password"; fail=1; }
  [[ $fail == 0 ]] && echo "OK herdr-backup live copies match the repo"
  exit "$fail"
elif [[ $# -gt 0 ]]; then
  echo "usage: $0 [--check]" >&2; exit 64
fi

# Read the crontab before touching anything; an unreadable table stops the install.
current="$(read_crontab)" || exit 1

mkdir -p "$bin_dir" "$cfg_dir" "$state_dir"
install -m 0755 "$src/herdr-backup" "$bin_dir/herdr-backup"
install -m 0644 "$src/restic.env" "$cfg_dir/env"
install -m 0644 "$src/restic-excludes" "$cfg_dir/excludes"

if ! grep -qxF -- "$cron_line" <<<"$current"; then
  { [[ -n "$current" ]] && printf '%s\n' "$current"; printf '%s\n' "$cron_line"; } | crontab -
fi

[[ -x "$bin_dir/restic" ]] || echo "WARN $bin_dir/restic not found; install restic before the first run"
[[ -f "$cfg_dir/password" ]] || echo "WARN $cfg_dir/password not found; restore it from the password manager (mode 600)"
echo "OK herdr-backup installed"
