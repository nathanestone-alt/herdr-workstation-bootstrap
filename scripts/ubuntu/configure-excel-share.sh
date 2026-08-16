#!/usr/bin/env bash
set -euo pipefail

windows_host="herdr-win"
share_name="HerdrExchange"
mount_point="/srv/herdr-exchange"
windows_user="HerdrBridge"
credentials_file="/etc/herdr-exchange.credentials"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) windows_host="$2"; shift 2 ;;
    --share) share_name="$2"; shift 2 ;;
    --user) windows_user="$2"; shift 2 ;;
    --mount-point) mount_point="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v mount.cifs >/dev/null 2>&1 || {
  echo 'mount.cifs is missing; run scripts/ubuntu/bootstrap.sh --phase base first.' >&2
  exit 20
}

read -r -s -p "Windows password for ${windows_user}: " windows_password
printf '\n'
[[ -n "$windows_password" ]] || { echo 'Password cannot be empty.' >&2; exit 21; }

sudo install -d -m 0750 "$mount_point"
credential_tmp="$(mktemp)"
trap 'rm -f "$credential_tmp"' EXIT
{
  printf 'username=%s\n' "$windows_user"
  printf 'password=%s\n' "$windows_password"
} > "$credential_tmp"
sudo install -m 0600 -o root -g root "$credential_tmp" "$credentials_file"
unset windows_password

fstab_entry="//${windows_host}/${share_name} ${mount_point} cifs credentials=${credentials_file},vers=3.1.1,seal,uid=${UID},gid=$(id -g),file_mode=0660,dir_mode=0770,nofail,_netdev,x-systemd.automount,x-systemd.device-timeout=15s 0 0"
if ! grep -Fq "//${windows_host}/${share_name} " /etc/fstab; then
  printf '%s\n' "$fstab_entry" | sudo tee -a /etc/fstab >/dev/null
fi

sudo systemctl daemon-reload
sudo mount "$mount_point"
test_file="$mount_point/in/.ubuntu-write-test-$$"
printf 'Herdr Ubuntu VM SMB write test\n' > "$test_file"
rm -f "$test_file"
echo "PASS mounted //${windows_host}/${share_name} at $mount_point with a successful write test."
