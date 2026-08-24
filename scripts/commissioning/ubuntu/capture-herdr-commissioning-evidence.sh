#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: capture-herdr-commissioning-evidence.sh --output PATH [options]

Writes a local, mode-0600 commissioning record containing host facts, mount
metadata, check outcomes, and SHA-256 values for the reviewed scripts. It
never reads, hashes, copies, or prints the credential file contents.

Options:
  --output PATH             New local output file (required; outside the repo)
  --run-reconnect            Run the guarded reconnect check as part of capture
  --confirm-disruption       Required with --run-reconnect
  --host NAME, --share NAME, --mount-point PATH,
  --credentials-file PATH, --owner NAME
EOF
  exit 2
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

script_dir="$(cd -- "$(dirname -- "$BASH_SOURCE")" && pwd -P)"
repo_root="$(cd -- "$script_dir/../../.." && pwd -P)"
check_script="$script_dir/check-herdr-exchange-mount.sh"
reconnect_script="$script_dir/check-herdr-exchange-reconnect.sh"
output_path=""
run_reconnect=false
confirm_disruption=false
windows_host="herdr-win"
share_name="HerdrExchange"
mount_point="/srv/herdr-exchange"
credentials_file="/etc/herdr-exchange.credentials"
owner_name="$(id -un)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      [[ $# -ge 2 ]] || usage
      output_path="$2"
      shift 2
      ;;
    --run-reconnect)
      run_reconnect=true
      shift
      ;;
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

[[ -n "$output_path" ]] || usage
[[ -x "$check_script" && -x "$reconnect_script" ]] || fail 'commissioning check scripts are not executable'
for command_name in mktemp sha256sum git realpath sed findmnt stat awk; do
  command -v "$command_name" >/dev/null 2>&1 || fail "required command is missing: $command_name"
done

if [[ "$output_path" != /* ]]; then
  output_path="$(pwd -P)/$output_path"
fi
output_path="$(realpath -m -- "$output_path")"
output_dir="$(dirname -- "$output_path")"
[[ -d "$output_dir" ]] || fail "output directory does not exist: $output_dir"
[[ ! -e "$output_path" && ! -L "$output_path" ]] || fail "refusing to overwrite existing evidence file: $output_path"
mount_path_for_compare="$(realpath -m -- "$mount_point")"
case "$output_path" in
  "$repo_root"|"$repo_root"/*)
    fail 'evidence output must be outside the Git repository'
    ;;
  "$mount_path_for_compare"|"$mount_path_for_compare"/*)
    fail 'evidence output must be outside the SMB mount'
    ;;
esac

check_status=1
if "$check_script" --host "$windows_host" --share "$share_name" --mount-point "$mount_point" \
    --credentials-file "$credentials_file" --owner "$owner_name" >/dev/null 2>&1; then
  check_status=0
fi

reconnect_status='NOT_RUN'
if [[ "$run_reconnect" == true ]]; then
  if [[ "$confirm_disruption" != true ]]; then
    reconnect_status='NOT_RUN_MISSING_CONFIRMATION'
  elif [[ "$check_status" -ne 0 ]]; then
    reconnect_status='NOT_RUN_MOUNT_PRECHECK_FAILED'
  elif "$reconnect_script" --confirm-disruption --host "$windows_host" --share "$share_name" \
      --mount-point "$mount_point" --credentials-file "$credentials_file" --owner "$owner_name" \
      >/dev/null 2>&1; then
    reconnect_status='PASS'
  else
    reconnect_status='FAIL'
  fi
fi

host_name="$(hostname -f 2>/dev/null || hostname)"
kernel="$(uname -srmo 2>/dev/null || uname -s)"
os_name="$(awk -F= '$1 == "PRETTY_NAME" {gsub(/^"|"$/, "", $2); print $2; exit}' /etc/os-release 2>/dev/null || true)"
[[ -n "$os_name" ]] || os_name='unknown'
current_user="$(id -un)"
branch="$(git -C "$repo_root" branch --show-current 2>/dev/null || true)"
commit="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || true)"
mount_info="$(findmnt -n -o SOURCE,FSTYPE,OPTIONS --target "$mount_point" 2>/dev/null || true)"
mounted_source=""
mounted_fstype=""
mounted_options=""
if [[ -n "$mount_info" ]]; then
  read -r mounted_source mounted_fstype mounted_options <<< "$mount_info"
fi
unsafe_password_option=false
if [[ "$mounted_options" == *password=* || "$mounted_options" == *passwd=* || "$mounted_options" == *pass=* ]]; then
  unsafe_password_option=true
fi
if [[ "$unsafe_password_option" == true ]]; then
  safe_options='<redacted: unsafe password option detected>'
  check_status=1
else
  safe_options="$(printf '%s' "$mounted_options" | sed -E 's/(password|passwd|pass)=([^, ]*)/\1=<redacted>/g')"
fi
credential_metadata='missing-or-unreadable'
if [[ -f "$credentials_file" && ! -L "$credentials_file" ]]; then
  credential_metadata="$(stat -c 'uid=%u gid=%g mode=%a type=%F' -- "$credentials_file" 2>/dev/null || printf '%s' 'stat-failed')"
fi

hash_artifact() {
  local label="$1"
  local path="$2"
  if [[ -f "$path" ]]; then
    printf 'artifact_sha256.%s=%s\n' "$label" "$(sha256sum -- "$path" | awk '{print $1}')"
  else
    printf 'artifact_sha256.%s=missing\n' "$label"
  fi
}

tmp_file="$(mktemp "$output_path.tmp.XXXXXX")"
cleanup() { rm -f -- "$tmp_file"; }
trap cleanup EXIT
umask 077
chmod 0600 "$tmp_file"
{
  printf '%s\n' 'schema=herdr-ubuntu-commissioning-v1'
  printf '%s\n' 'record_type=local-host-review'
  printf 'captured_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'hostname=%s\n' "$host_name"
  printf 'kernel=%s\n' "$kernel"
  printf 'os=%s\n' "$os_name"
  printf 'operator=%s\n' "$current_user"
  printf 'repository=%s\n' "$repo_root"
  printf 'branch=%s\n' "$branch"
  printf 'commit=%s\n' "$commit"
  printf 'windows_host=%s\n' "$windows_host"
  printf 'share_name=%s\n' "$share_name"
  printf 'mount_point=%s\n' "$mount_point"
  printf 'mounted_source=%s\n' "$mounted_source"
  printf 'mounted_fstype=%s\n' "$mounted_fstype"
  printf 'mounted_options=%s\n' "$safe_options"
  printf 'credentials_file=%s\n' "$credentials_file"
  printf 'credentials_metadata=%s\n' "$credential_metadata"
  printf 'mount_check=%s\n' "$([[ "$check_status" -eq 0 ]] && printf PASS || printf FAIL)"
  printf 'reconnect_check=%s\n' "$reconnect_status"
  hash_artifact ubuntu_configure_excel_share "$repo_root/scripts/ubuntu/configure-excel-share.sh"
  hash_artifact ubuntu_mount_check "$check_script"
  hash_artifact ubuntu_reconnect_check "$reconnect_script"
  hash_artifact ubuntu_evidence_capture "$script_dir/capture-herdr-commissioning-evidence.sh"
  printf '%s\n' 'credential_contents=not-read'
  printf '%s\n' 'password_stdout_stderr=not-captured'
  printf '%s\n' 'review_note=Keep this record outside Git and attach it only through the approved user evidence path.'
} > "$tmp_file"
mv -- "$tmp_file" "$output_path"
trap - EXIT

overall_status=0
[[ "$check_status" -eq 0 ]] || overall_status=1
if [[ "$run_reconnect" == true && "$reconnect_status" != PASS ]]; then
  overall_status=1
fi
if [[ "$overall_status" -eq 0 ]]; then
  printf 'PASS evidence_record=%s mount_check=PASS reconnect_check=%s\n' "$output_path" "$reconnect_status"
else
  printf 'FAIL evidence_record=%s mount_check=%s reconnect_check=%s\n' "$output_path" \
    "$([[ "$check_status" -eq 0 ]] && printf PASS || printf FAIL)" "$reconnect_status"
fi
exit "$overall_status"
