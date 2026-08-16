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
if mountpoint -q "$mount_point"; then
  echo "Unmounting $mount_point so the supplied credential is exercised by a new SMB session."
  sudo umount "$mount_point"
fi
credential_tmp="$(mktemp)"
fstab_current="$(mktemp)"
desired_block="$(mktemp)"
replacement="$(mktemp)"
trap 'rm -f "$credential_tmp" "$fstab_current" "$desired_block" "$replacement"' EXIT
{
  printf 'username=%s\n' "$windows_user"
  printf 'password=%s\n' "$windows_password"
} > "$credential_tmp"
sudo install -m 0600 -o root -g root "$credential_tmp" "$credentials_file"
unset windows_password

fstab_entry="//${windows_host}/${share_name} ${mount_point} cifs credentials=${credentials_file},vers=3.1.1,seal,uid=${UID},gid=$(id -g),file_mode=0660,dir_mode=0770,nofail,_netdev,x-systemd.automount,x-systemd.device-timeout=15s 0 0"
fstab_marker='# BEGIN herdr-bootstrap excel-share'
fstab_end_marker='# END herdr-bootstrap excel-share'
printf '%s\n%s\n%s\n' "$fstab_marker" "$fstab_entry" "$fstab_end_marker" > "$desired_block"
sudo cat /etc/fstab > "$fstab_current"
mapfile -t begin_lines < <(grep -nFx "$fstab_marker" "$fstab_current" | cut -d: -f1)
mapfile -t end_lines < <(grep -nFx "$fstab_end_marker" "$fstab_current" | cut -d: -f1)
if ! awk -v begin="$fstab_marker" -v end="$fstab_end_marker" \
    -v source="//${windows_host}/${share_name}" -v target="$mount_point" '
      $0 == begin { managed=1; next }
      $0 == end { managed=0; next }
      !managed && $0 !~ /^[[:space:]]*#/ && ($1 == source || $2 == target) {
        printf "unmanaged /etc/fstab entry at line %d: %s\n", NR, $0 > "/dev/stderr"
        conflict=1
      }
      END { exit conflict ? 1 : 0 }
    ' "$fstab_current"; then
  echo 'Refusing to manage an SMB source or mount point that already has an unmanaged /etc/fstab entry.' >&2
  exit 22
fi
if (( ${#begin_lines[@]} == 0 && ${#end_lines[@]} == 0 )); then
  cp "$fstab_current" "$replacement"
  if [[ -s "$replacement" && "$(tail -c 1 "$replacement" | wc -l)" -eq 0 ]]; then printf '\n' >> "$replacement"; fi
  printf '\n' >> "$replacement"
  cat "$desired_block" >> "$replacement"
elif (( ${#begin_lines[@]} == 1 && ${#end_lines[@]} == 1 && begin_lines[0] < end_lines[0] )); then
  begin="${begin_lines[0]}"
  end="${end_lines[0]}"
  if (( begin > 1 )); then head -n "$((begin - 1))" "$fstab_current" > "$replacement"; fi
  cat "$desired_block" >> "$replacement"
  tail -n "+$((end + 1))" "$fstab_current" >> "$replacement"
else
  echo 'Managed Excel-share markers in /etc/fstab are missing, duplicated, or out of order.' >&2
  exit 22
fi
if ! cmp -s "$fstab_current" "$replacement"; then
  stamp="$(date +%Y%m%d-%H%M%S)-$$"
  sudo cp /etc/fstab "/etc/fstab.${stamp}.herdr-backup"
  sudo install -m 0644 -o root -g root "$replacement" /etc/fstab
fi

sudo systemctl daemon-reload
sudo mount "$mount_point"
test_file="$mount_point/in/.ubuntu-write-test-$$"
printf 'Herdr Ubuntu VM SMB write test\n' > "$test_file"
rm -f "$test_file"
echo "PASS mounted //${windows_host}/${share_name} at $mount_point with a successful write test."
