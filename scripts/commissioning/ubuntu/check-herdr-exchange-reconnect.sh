#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: check-herdr-exchange-reconnect.sh --confirm-disruption [options]

Unmounts the commissioned mount, verifies that the x-systemd.automount path
reconnects on access, and reruns the ownership/write probe. It will not
disrupt a live mount without the explicit confirmation flag.

Options are the same as check-herdr-exchange-mount.sh:
  --host NAME, --share NAME, --mount-point PATH,
  --credentials-file PATH, --owner NAME
EOF
  exit 2
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
check_script="$script_dir/check-herdr-exchange-mount.sh"
windows_host="herdr-win"
share_name="HerdrExchange"
mount_point="/srv/herdr-exchange"
credentials_file="/etc/herdr-exchange.credentials"
owner_name="$(id -un)"
confirm_disruption=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm-disruption)
      confirm_disruption=true
      shift
      ;;
    --host|--share|--mount-point|--credentials-file|--owner)
      [[ $# -ge 2 ]] || usage
      case "$1" in
        --host) windows_host="$2" ;;
        --share) share_name="$2" ;;
        --mount-point) mount_point="$2" ;;
        --credentials-file) credentials_file="$2" ;;
        --owner) owner_name="$2" ;;
      esac
      shift 2
      ;;
    --help|-h)
      usage
      ;;
    *)
      usage
      ;;
  esac
done

[[ "$confirm_disruption" == true ]] ||
  fail 'refusing to unmount a live exchange; pass --confirm-disruption after reviewing the maintenance window'
[[ -x "$check_script" ]] || fail "mount check script is not executable: $check_script"
command -v sudo >/dev/null 2>&1 || fail 'sudo is required for the reconnect check'
command -v mountpoint >/dev/null 2>&1 || fail 'mountpoint is required for the reconnect check'

check_args=(--host "$windows_host" --share "$share_name" --mount-point "$mount_point" \
  --credentials-file "$credentials_file" --owner "$owner_name")
"$check_script" "${check_args[@]}" >/dev/null

remounted=false
restore_mount() {
  if [[ "$remounted" != true ]] && ! mountpoint -q -- "$mount_point"; then
    sudo mount -- "$mount_point" >/dev/null 2>&1 || true
  fi
}
trap restore_mount EXIT

sudo umount -- "$mount_point" || fail "could not unmount '$mount_point'; no reconnect result was recorded"

for attempt in $(seq 1 15); do
  # Accessing the automount path is intentional: it is the reconnect event.
  if [[ -d "$mount_point/in" ]] && mountpoint -q -- "$mount_point"; then
    remounted=true
    break
  fi
  sleep 1
done

[[ "$remounted" == true ]] || fail 'x-systemd.automount did not reconnect the exchange within 15 seconds'
"$check_script" "${check_args[@]}" >/dev/null
trap - EXIT

printf 'PASS reconnect mount=%s source=//%s/%s automount=PASS write_test=PASS\n' \
  "$mount_point" "$windows_host" "$share_name"
