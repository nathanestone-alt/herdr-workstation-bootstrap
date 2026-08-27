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

if [[ "$mount_point" != /* ]]; then
  echo 'Mount point must be an absolute path.' >&2
  exit 2
fi
case "$mount_point" in
  /|/boot|/home|/etc|/usr|/var|/srv)
    echo "Mount point '$mount_point' is a protected system path." >&2
    exit 2
    ;;
esac
if [[ ! "$mount_point" =~ ^/[A-Za-z0-9._/-]+$ ]] ||
   [[ "$mount_point" == *//* || "$mount_point" == */./* || "$mount_point" == */../* ||
      "$mount_point" == */. || "$mount_point" == */.. || "$mount_point" == */ ]]; then
  echo 'Mount point contains unsupported characters or path components.' >&2
  exit 2
fi
if [[ ! "$mount_point" =~ ^/srv/herdr-[A-Za-z0-9._-]+$ ]]; then
  echo 'Mount point must be a direct /srv/herdr-* child.' >&2
  exit 2
fi
if [[ ! "$windows_host" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
  echo 'Windows host contains unsupported characters.' >&2
  exit 2
fi
if [[ ! "$share_name" =~ ^[A-Za-z0-9][A-Za-z0-9._$-]*$ ]]; then
  echo 'SMB share name contains unsupported characters.' >&2
  exit 2
fi
if [[ ! "$windows_user" =~ ^[A-Za-z0-9][A-Za-z0-9._@-]*$ ]]; then
  echo 'Windows user contains unsupported characters.' >&2
  exit 2
fi

command -v mount.cifs >/dev/null 2>&1 || {
  echo 'mount.cifs is missing; run scripts/ubuntu/bootstrap.sh --phase base first.' >&2
  exit 20
}

if [[ -z "$owner_name" ]]; then owner_name="$(id -un)"; fi
id "$owner_name" >/dev/null 2>&1 || { echo "Ubuntu owner '$owner_name' does not exist." >&2; exit 2; }
owner_uid="$(id -u "$owner_name")"
owner_gid="$(id -g "$owner_name")"

mount_point_exists=false
if mountpoint -q "$mount_point"; then
  mount_point_exists=true
elif sudo test -e "$mount_point"; then
  if ! sudo test -d "$mount_point"; then
    echo "Mount point '$mount_point' exists but is not a directory." >&2
    exit 22
  fi
  mount_point_metadata="$(sudo stat -c '%a:%U:%G' -- "$mount_point")"
  if [[ "$mount_point_metadata" != '750:root:root' ]]; then
    echo "Existing mount point '$mount_point' must already be mode 0750 and owned by root:root; found $mount_point_metadata. Refusing to change it." >&2
    exit 22
  fi
  mount_point_exists=true
fi

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

if [[ "$mount_point_exists" != true ]]; then
  sudo install -d -m 0750 -o root -g root "$mount_point"
fi
sudo install -m 0600 -o root -g root "$credential_tmp" "$credentials_file"
fstab_changed=false
if ! cmp -s "$fstab_current" "$replacement"; then
  stamp="$(date +%Y%m%d-%H%M%S)-$$"
  sudo cp /etc/fstab "/etc/fstab.${stamp}.herdr-backup"
  sudo install -m 0644 -o root -g root "$replacement" /etc/fstab
  fstab_changed=true
fi
if mountpoint -q "$mount_point"; then
  echo "Unmounting $mount_point after the replacement credential passed an isolated SMB write test."
  if ! sudo umount "$mount_point"; then
    echo "The replacement credential is installed and fstab_changed=$fstab_changed, but the existing SMB session remains mounted because $mount_point is busy." >&2
    if command -v fuser >/dev/null 2>&1; then
      sudo fuser -m "$mount_point" >&2 || true
    fi
    echo 'Close processes using the mount and rerun this script; do not rotate the Windows password again.' >&2
    exit 24
  fi
fi
sudo systemctl daemon-reload
# Mounting the path directly would leave the generated .automount unit dead
# until reboot, so any later unmount would never reconnect on access. Arm the
# trigger and let path access perform the mount, proving reconnect semantics.
automount_unit="$(systemd-escape --path --suffix=automount "$mount_point")"
if ! sudo systemctl restart "$automount_unit"; then
  echo 'The replacement credential and fstab are installed, but the automount unit failed to start. Correct the reported systemd error and rerun this script; do not rotate the Windows password again.' >&2
  exit 24
fi
if ! ls -- "$mount_point" >/dev/null ||
  [[ "$(findmnt -n -o FSTYPE --target "$mount_point" 2>/dev/null)" != cifs ]]; then
  echo 'The replacement credential and fstab are installed, but the live mount failed. Correct the reported mount error and rerun this script; do not rotate the Windows password again.' >&2
  exit 24
fi
test_file="$mount_point/in/.ubuntu-write-test-$$"
sudo -u "$owner_name" sh -c 'printf "%s\n" "Herdr Ubuntu VM SMB write test" > "$1"; rm -f "$1"' sh "$test_file"
echo "PASS mounted //${windows_host}/${share_name} at $mount_point for $owner_name (uid=$owner_uid,gid=$owner_gid) with a successful write test."
