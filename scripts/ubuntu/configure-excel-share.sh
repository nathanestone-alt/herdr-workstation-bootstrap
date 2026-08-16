#!/usr/bin/env bash
set -euo pipefail

windows_host="herdr-win"
share_name="HerdrExchange"
mount_point="/srv/herdr-exchange"
windows_user="HerdrBridge"
credentials_file="/etc/herdr-exchange.credentials"
owner_name=""
reassign_owner=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) windows_host="$2"; shift 2 ;;
    --share) share_name="$2"; shift 2 ;;
    --user) windows_user="$2"; shift 2 ;;
    --mount-point) mount_point="$2"; shift 2 ;;
    --owner) owner_name="$2"; shift 2 ;;
    --reassign-owner) reassign_owner=true; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v mount.cifs >/dev/null 2>&1 || {
  echo 'mount.cifs is missing; run scripts/ubuntu/bootstrap.sh --phase base first.' >&2
  exit 20
}

if [[ -z "$owner_name" ]]; then owner_name="$(id -un)"; fi
id "$owner_name" >/dev/null 2>&1 || { echo "Ubuntu owner '$owner_name' does not exist." >&2; exit 2; }
owner_uid="$(id -u "$owner_name")"
owner_gid="$(id -g "$owner_name")"

sudo install -d -m 0750 "$mount_point"
fstab_current="$(mktemp)"
desired_block="$(mktemp)"
replacement="$(mktemp)"
credential_tmp="$(mktemp)"
probe_mount="$(mktemp -d)"
probe_mounted=false
cleanup() {
  if [[ "$probe_mounted" == true ]]; then sudo umount "$probe_mount" >/dev/null 2>&1 || true; fi
  rm -f "$credential_tmp" "$fstab_current" "$desired_block" "$replacement"
  rmdir "$probe_mount" >/dev/null 2>&1 || true
}
trap cleanup EXIT

fstab_entry="//${windows_host}/${share_name} ${mount_point} cifs credentials=${credentials_file},vers=3.1.1,seal,uid=${owner_uid},gid=${owner_gid},file_mode=0660,dir_mode=0770,nofail,_netdev,x-systemd.automount,x-systemd.device-timeout=15s 0 0"
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
  echo 'Credential and live mount were not changed.' >&2
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
  current_entry="$(sed -n "$((begin + 1))p" "$fstab_current")"
  current_uid="$(sed -n 's/.*[, ]uid=\([0-9][0-9]*\).*/\1/p' <<< "$current_entry")"
  current_gid="$(sed -n 's/.*[, ]gid=\([0-9][0-9]*\).*/\1/p' <<< "$current_entry")"
  if [[ "$current_uid" != "$owner_uid" || "$current_gid" != "$owner_gid" ]] && [[ "$reassign_owner" != true ]]; then
    echo "Managed mount ownership is uid=${current_uid:-unknown},gid=${current_gid:-unknown}; requested owner '$owner_name' is uid=$owner_uid,gid=$owner_gid. Refusing without --reassign-owner." >&2
    echo 'Credential and live mount were not changed.' >&2
    exit 22
  fi
  if (( begin > 1 )); then head -n "$((begin - 1))" "$fstab_current" > "$replacement"; fi
  cat "$desired_block" >> "$replacement"
  tail -n "+$((end + 1))" "$fstab_current" >> "$replacement"
else
  echo 'Managed Excel-share markers in /etc/fstab are missing, duplicated, or out of order.' >&2
  echo 'Credential and live mount were not changed.' >&2
  exit 22
fi

read -r -s -p "Windows password for ${windows_user}: " windows_password
printf '\n'
[[ -n "$windows_password" ]] || { echo 'Password cannot be empty.' >&2; exit 21; }
{
  printf 'username=%s\n' "$windows_user"
  printf 'password=%s\n' "$windows_password"
} > "$credential_tmp"
chmod 0600 "$credential_tmp"
unset windows_password

probe_options="credentials=${credential_tmp},vers=3.1.1,seal,nosharesock,uid=${owner_uid},gid=${owner_gid},file_mode=0660,dir_mode=0770"
if ! sudo mount -t cifs "//${windows_host}/${share_name}" "$probe_mount" -o "$probe_options"; then
  echo 'The supplied credential could not establish a fresh isolated SMB session; the live mount and installed credential were not changed.' >&2
  exit 23
fi
probe_mounted=true
probe_test="$probe_mount/in/.ubuntu-credential-test-$$"
sudo -u "$owner_name" sh -c 'printf "%s\n" "Herdr credential test" > "$1"; rm -f "$1"' sh "$probe_test"
sudo umount "$probe_mount"
probe_mounted=false

if ! cmp -s "$fstab_current" "$replacement"; then
  stamp="$(date +%Y%m%d-%H%M%S)-$$"
  sudo cp /etc/fstab "/etc/fstab.${stamp}.herdr-backup"
  sudo install -m 0644 -o root -g root "$replacement" /etc/fstab
fi

if mountpoint -q "$mount_point"; then
  echo "Unmounting $mount_point after the replacement credential passed an isolated SMB write test."
  sudo umount "$mount_point"
fi
sudo install -m 0600 -o root -g root "$credential_tmp" "$credentials_file"
sudo systemctl daemon-reload
sudo mount "$mount_point"
test_file="$mount_point/in/.ubuntu-write-test-$$"
sudo -u "$owner_name" sh -c 'printf "%s\n" "Herdr Ubuntu VM SMB write test" > "$1"; rm -f "$1"' sh "$test_file"
echo "PASS mounted //${windows_host}/${share_name} at $mount_point for $owner_name (uid=$owner_uid,gid=$owner_gid) with a successful write test."
