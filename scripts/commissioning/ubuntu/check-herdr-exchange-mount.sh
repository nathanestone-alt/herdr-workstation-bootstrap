#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: check-herdr-exchange-mount.sh [options]

Read-only preflight plus a disposable write/remove probe for the commissioned
Ubuntu SMB mount. The credential file is inspected only for owner, mode, and
file type; its contents are never read or printed.

Options:
  --host NAME              Windows host (default: herdr-win)
  --share NAME             SMB share (default: HerdrExchange)
  --mount-point PATH       Mount point (default: /srv/herdr-exchange)
  --credentials-file PATH  Credential path (default: /etc/herdr-exchange.credentials)
  --bridge-user NAME       Expected SMB session account (default: HerdrBridge)
  --owner NAME             Expected Ubuntu mount owner (default: current user)
EOF
  exit 2
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

windows_host="herdr-win"
share_name="HerdrExchange"
mount_point="/srv/herdr-exchange"
credentials_file="/etc/herdr-exchange.credentials"
bridge_user="HerdrBridge"
owner_name="$(id -un)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      [[ $# -ge 2 ]] || usage
      windows_host="$2"
      shift 2
      ;;
    --share)
      [[ $# -ge 2 ]] || usage
      share_name="$2"
      shift 2
      ;;
    --mount-point)
      [[ $# -ge 2 ]] || usage
      mount_point="$2"
      shift 2
      ;;
    --credentials-file)
      [[ $# -ge 2 ]] || usage
      credentials_file="$2"
      shift 2
      ;;
    --bridge-user)
      [[ $# -ge 2 ]] || usage
      bridge_user="$2"
      shift 2
      ;;
    --owner)
      [[ $# -ge 2 ]] || usage
      owner_name="$2"
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

if [[ ! "$mount_point" =~ ^/[A-Za-z0-9._/-]+$ ]] ||
   [[ "$mount_point" == *//* || "$mount_point" == */./* || "$mount_point" == */../* ||
      "$mount_point" == */. || "$mount_point" == */.. || "$mount_point" == */ ]]; then
  fail "mount point contains unsupported characters or path components"
fi
case "$mount_point" in
  /|/boot|/home|/etc|/usr|/var|/srv)
    fail "refusing protected mount point '$mount_point'"
    ;;
esac
[[ "$mount_point" =~ ^/srv/herdr-[A-Za-z0-9._-]+$ ]] ||
  fail "mount point must be a direct /srv/herdr-* child"
[[ "$windows_host" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] ||
  fail 'Windows host contains unsupported characters'
[[ "$share_name" =~ ^[A-Za-z0-9][A-Za-z0-9._$-]*$ ]] ||
  fail 'SMB share name contains unsupported characters'
[[ "$credentials_file" == /* && "$credentials_file" != */ && "$credentials_file" != *$'\n'* ]] ||
  fail 'credential path must be an absolute, single-file path'
[[ "$credentials_file" != *'/../'* && "$credentials_file" != */.. ]] ||
  fail 'credential path must not contain parent traversal'
[[ -n "$owner_name" && "$owner_name" != *$'\n'* ]] || fail 'owner name is empty or contains a newline'

for command_name in id mountpoint findmnt stat sudo awk grep; do
  command -v "$command_name" >/dev/null 2>&1 || fail "required command is missing: $command_name"
done

id "$owner_name" >/dev/null 2>&1 || fail "Ubuntu owner does not exist: $owner_name"
owner_uid="$(id -u "$owner_name")"
owner_gid="$(id -g "$owner_name")"

mountpoint -q -- "$mount_point" || fail "mount point is not mounted: $mount_point"

[[ -e "$credentials_file" ]] || fail "credential file is absent: $credentials_file"
[[ -f "$credentials_file" ]] || fail 'credential path is not a regular file'
[[ ! -L "$credentials_file" ]] || fail 'credential path must not be a symlink'
credential_uid="$(stat -c '%u' -- "$credentials_file")"
credential_gid="$(stat -c '%g' -- "$credentials_file")"
credential_mode="$(stat -c '%a' -- "$credentials_file")"
[[ "$credential_uid" == 0 && "$credential_gid" == 0 && "$credential_mode" == 600 ]] ||
  fail "credential file must be root:root mode 0600 (found ${credential_uid}:${credential_gid} mode ${credential_mode})"

fstab_entry="//${windows_host}/${share_name} ${mount_point} cifs credentials=${credentials_file},vers=3.1.1,seal,uid=${owner_uid},gid=${owner_gid},file_mode=0660,dir_mode=0770,nofail,_netdev,x-systemd.automount,x-systemd.device-timeout=15s 0 0"
managed_entry_count="$(awk -v begin='# BEGIN herdr-bootstrap excel-share' \
  -v end='# END herdr-bootstrap excel-share' -v entry="$fstab_entry" '
  $0 == begin { inside=1; next }
  $0 == end { inside=0; next }
  inside && $0 == entry { count++ }
  END { print count + 0 }
' /etc/fstab)"
[[ "$managed_entry_count" == 1 ]] ||
  fail "expected exactly one managed /etc/fstab entry for ${windows_host}/${share_name}"

unmanaged_conflict="$(awk -v begin='# BEGIN herdr-bootstrap excel-share' \
  -v end='# END herdr-bootstrap excel-share' -v source="//${windows_host}/${share_name}" \
  -v target="$mount_point" '
  $0 == begin { inside=1; next }
  $0 == end { inside=0; next }
  !inside && $0 !~ /^[[:space:]]*#/ && ($1 == source || $2 == target) { print $0; found=1 }
  END { exit found ? 0 : 1 }
' /etc/fstab 2>/dev/null || true)"
[[ -z "$unmanaged_conflict" ]] || fail 'an unmanaged /etc/fstab entry conflicts with the commissioned mount'

mount_info="$(findmnt -n -o SOURCE,FSTYPE,OPTIONS --target "$mount_point" 2>/dev/null || true)"
[[ -n "$mount_info" ]] || fail 'findmnt returned no information for the commissioned mount'
read -r mounted_source mounted_fstype mounted_options <<< "$mount_info"
[[ "$mounted_source" == "//${windows_host}/${share_name}" ]] ||
  fail "mounted source is not //${windows_host}/${share_name}"
[[ "$mounted_fstype" == cifs ]] || fail "mounted filesystem is not cifs (found $mounted_fstype)"

has_option() {
  local needle="$1"
  case ",${mounted_options}," in
    *,${needle},*) return 0 ;;
    *) return 1 ;;
  esac
}

# mount.cifs consumes credentials= in userspace; it never appears in the live
# kernel options. The managed fstab assert above pins the credential path; the
# live session is verified by the account it authenticated as.
has_option "username=${bridge_user}" || fail "live mount session is not authenticated as ${bridge_user}"
has_option seal || fail 'SMB signing/encryption option seal is absent from the live mount'
has_option "uid=${owner_uid}" || fail 'live mount uid does not match the commissioned owner'
has_option "gid=${owner_gid}" || fail 'live mount gid does not match the commissioned owner'
has_option file_mode=0660 || fail 'live mount file mode is not 0660'
has_option dir_mode=0770 || fail 'live mount directory mode is not 0770'

for child in in out logs; do
  sudo test -d "$mount_point/$child" || fail "expected exchange directory is absent: $child"
done

probe_path="$mount_point/in/.herdr-commissioning-write-${EUID:-0}-$$"
cleanup_probe() {
  sudo rm -f -- "$probe_path" >/dev/null 2>&1 || true
}
trap cleanup_probe EXIT
if ! sudo -u "$owner_name" -- sh -c 'set -eu; umask 077; printf "%s\n" "Herdr commissioning write test" > "$1"' sh "$probe_path"; then
  fail "owner '$owner_name' could not write to the exchange input directory"
fi
sudo test -f "$probe_path" || fail 'write probe did not create a file'
cleanup_probe
trap - EXIT

printf 'PASS mount=%s source=%s owner=%s uid=%s gid=%s credential_metadata=root:root:0600 write_test=PASS\n' \
  "$mount_point" "$mounted_source" "$owner_name" "$owner_uid" "$owner_gid"
