#!/usr/bin/bash
set -euo pipefail

# The bootstrap sources this helper only from its independently attested
# private source snapshot.  It deliberately accepts one archive member only:
# the official RTK release asset is a single regular `rtk` executable.

rtk_release_abort() {
  echo "RTK release install: $*" >&2
  exit 24
}

rtk_release_reject_symlink_components() {
  local path="$1"
  local current='/'
  local component
  local -a components
  [[ "$path" == /* ]] || return 1
  IFS='/' read -r -a components <<< "${path#/}"
  for component in "${components[@]}"; do
    [[ -z "$component" || "$component" == '.' ]] && continue
    [[ "$component" != '..' && "$component" != *'/'* ]] || return 1
    current="$current/$component"
    [[ ! -L "$current" ]] || return 1
  done
}

rtk_release_pause() {
  local pause_hook="${1:-}"
  local phase="$2"
  [[ -z "$pause_hook" ]] && return 0
  declare -F "$pause_hook" >/dev/null 2>&1 || rtk_release_abort "pause hook is not a function: $pause_hook"
  "$pause_hook" "$phase"
}

rtk_release_assert_private_directory() {
  local path="$1"
  local expected_uid="$2"
  [[ -d "$path" && ! -L "$path" ]] || rtk_release_abort "staging path is not a directory: $path"
  [[ "$(/usr/bin/realpath -e -- "$path" 2>/dev/null || true)" == "$path" ]] ||
    rtk_release_abort "staging path is not canonical: $path"
  [[ "$(/usr/bin/stat -c '%u:%a:%F' -- "$path" 2>/dev/null || true)" == "$expected_uid:700:directory" ]] ||
    rtk_release_abort "staging path is not private: $path"
}

rtk_release_assert_file_stable() {
  local path="$1"
  local fd_path="$2"
  local expected_id="$3"
  local expected_hash="$4"
  [[ -f "$path" && ! -L "$path" ]] || return 1
  [[ "$(/usr/bin/realpath -e -- "$path" 2>/dev/null || true)" == "$path" ]] || return 1
  [[ "$(/usr/bin/stat -Lc '%d:%i' -- "$fd_path" 2>/dev/null || true)" == "$expected_id" ]] || return 1
  [[ "$(/usr/bin/stat -Lc '%d:%i' -- "$path" 2>/dev/null || true)" == "$expected_id" ]] || return 1
  [[ "$(/usr/bin/sha256sum -- "$fd_path" 2>/dev/null | /usr/bin/gawk '{print $1}')" == "$expected_hash" ]] || return 1
  [[ "$(/usr/bin/sha256sum -- "$path" 2>/dev/null | /usr/bin/gawk '{print $1}')" == "$expected_hash" ]]
}

rtk_release_require_parent() {
  local parent="$1"
  local parent_fd_path="$2"
  local expected_id="$3"
  local uid mode
  [[ -d "$parent" && ! -L "$parent" ]] || rtk_release_abort "RTK destination parent is not a directory: $parent"
  [[ "$(/usr/bin/realpath -e -- "$parent" 2>/dev/null || true)" == "$parent" ]] ||
    rtk_release_abort "RTK destination parent is not canonical: $parent"
  uid="$(/usr/bin/stat -c '%u' -- "$parent" 2>/dev/null || true)"
  mode="$(/usr/bin/stat -c '%a' -- "$parent" 2>/dev/null || true)"
  [[ "$uid" == "$(/usr/bin/id -u)" && "$mode" =~ ^[0-7]+$ && $((8#$mode & 022)) == 0 ]] ||
    rtk_release_abort "RTK destination parent is not user-owned and non-writable: $parent"
  [[ "$(/usr/bin/stat -Lc '%d:%i' -- "$parent_fd_path" 2>/dev/null || true)" == "$expected_id" ]] ||
    rtk_release_abort "RTK destination parent changed: $parent"
}

rtk_release_install_archive() (
  set -euo pipefail
  local archive_path="$1"
  local expected_sha="$2"
  local expected_version="$3"
  local target_path="$4"
  local pause_hook="${5:-}"
  local current_uid
  local source_fd source_fd_path source_id source_hash source_live_id source_live_hash
  local stage_dir bound_archive bound_fd bound_fd_path bound_id bound_hash
  local listing_file entry member archive_mode
  local extract_dir extracted_list candidate candidate_fd candidate_fd_path candidate_id candidate_hash
  local candidate_mode version_output
  local target_parent parent_fd parent_fd_path parent_id target_state target_id target_hash
  local target_owner target_mode publish_stage publish_id publish_hash publish_mode publish_owner
  local -a archive_entries extracted_entries

  [[ "$archive_path" == /* && "$target_path" == /* ]] || rtk_release_abort 'archive and target paths must be absolute'
  [[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]] || rtk_release_abort 'archive checksum is not a lowercase SHA-256 value'
  [[ "$expected_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || rtk_release_abort 'RTK version is not semantic'
  [[ "${target_path##*/}" == rtk ]] || rtk_release_abort "RTK target is not the canonical rtk filename: $target_path"
  rtk_release_reject_symlink_components "$archive_path" || rtk_release_abort 'RTK archive path contains a symlink'
  rtk_release_reject_symlink_components "$target_path" || rtk_release_abort 'RTK target path contains a symlink'
  [[ -f "$archive_path" && ! -L "$archive_path" ]] || rtk_release_abort "RTK archive is not a regular file: $archive_path"
  [[ "$(/usr/bin/realpath -e -- "$archive_path" 2>/dev/null || true)" == "$archive_path" ]] ||
    rtk_release_abort 'RTK archive path is not canonical'
  current_uid="$(/usr/bin/id -u)"
  [[ "$(/usr/bin/stat -c '%u' -- "$archive_path" 2>/dev/null || true)" == "$current_uid" ]] ||
    rtk_release_abort 'RTK archive is not owned by the installing user'
  archive_mode="$(/usr/bin/stat -c '%a' -- "$archive_path" 2>/dev/null || true)"
  [[ "$archive_mode" =~ ^[0-7]+$ && $((8#$archive_mode & 022)) == 0 ]] ||
    rtk_release_abort 'RTK archive is group/other writable'

  stage_dir="$(/usr/bin/mktemp -d /tmp/herdr-rtk-release.XXXXXX)"
  /usr/bin/chmod 0700 -- "$stage_dir"
  trap '/usr/bin/rm -rf -- "$stage_dir"' EXIT
  rtk_release_assert_private_directory "$stage_dir" "$current_uid"

  # Bind the downloaded pathname before any archive parsing.  The private
  # copy below makes a same-inode write during the copy fail its checksum, and
  # the original descriptor remains open so replacement races are rejected
  # through the final publication seam as well.
  rtk_release_pause "$pause_hook" after-rtk-download
  exec {source_fd}<"$archive_path" || rtk_release_abort 'could not open the downloaded RTK archive'
  source_fd_path="/proc/$BASHPID/fd/$source_fd"
  source_id="$(/usr/bin/stat -Lc '%d:%i' -- "$source_fd_path" 2>/dev/null || true)"
  source_live_id="$(/usr/bin/stat -Lc '%d:%i' -- "$archive_path" 2>/dev/null || true)"
  source_hash="$(/usr/bin/sha256sum -- "$source_fd_path" 2>/dev/null | /usr/bin/gawk '{print $1}')"
  source_live_hash="$(/usr/bin/sha256sum -- "$archive_path" 2>/dev/null | /usr/bin/gawk '{print $1}')"
  [[ "$source_id" =~ ^[0-9]+:[0-9]+$ && "$source_id" == "$source_live_id" && \
    "$source_hash" == "$expected_sha" && "$source_hash" == "$source_live_hash" ]] ||
    rtk_release_abort 'RTK archive changed or failed its checksum before binding'

  bound_archive="$stage_dir/archive.tar.gz"
  /usr/bin/cp -- "$source_fd_path" "$bound_archive"
  /usr/bin/chmod 0600 -- "$bound_archive"
  bound_hash="$(/usr/bin/sha256sum -- "$bound_archive" | /usr/bin/gawk '{print $1}')"
  [[ "$bound_hash" == "$expected_sha" && -f "$bound_archive" && ! -L "$bound_archive" ]] ||
    rtk_release_abort 'private RTK archive copy failed its checksum'
  exec {bound_fd}<"$bound_archive" || rtk_release_abort 'could not open the private RTK archive copy'
  bound_fd_path="/proc/$BASHPID/fd/$bound_fd"
  bound_id="$(/usr/bin/stat -Lc '%d:%i' -- "$bound_fd_path" 2>/dev/null || true)"
  [[ "$bound_id" =~ ^[0-9]+:[0-9]+$ ]] || rtk_release_abort 'private RTK archive identity is invalid'
  rtk_release_assert_file_stable "$bound_archive" "$bound_fd_path" "$bound_id" "$bound_hash" ||
    rtk_release_abort 'private RTK archive changed after binding'
  rtk_release_pause "$pause_hook" after-rtk-archive-bind
  rtk_release_assert_file_stable "$archive_path" "$source_fd_path" "$source_id" "$source_hash" ||
    rtk_release_abort 'downloaded RTK archive was replaced during validation'
  rtk_release_assert_file_stable "$bound_archive" "$bound_fd_path" "$bound_id" "$bound_hash" ||
    rtk_release_abort 'private RTK archive was replaced during validation'

  listing_file="$stage_dir/archive.list"
  if ! /usr/bin/tar --list --verbose --numeric-owner --quoting-style=c --file="$bound_fd_path" > "$listing_file"; then
    rtk_release_abort 'RTK archive could not be listed'
  fi
  mapfile -t archive_entries < "$listing_file"
  [[ "${#archive_entries[@]}" == 1 ]] ||
    rtk_release_abort "RTK archive must contain exactly one payload entry (found ${#archive_entries[@]})"
  entry="${archive_entries[0]}"
  [[ "$entry" == '-rwxr-xr-x '* ]] || rtk_release_abort 'RTK archive payload has the wrong mode or type'
  member="${entry##* }"
  # GNU tar quotes even the ordinary member name when C quoting is enabled.
  [[ "$member" == '"rtk"' ]] && member=rtk
  [[ "$member" == rtk ]] || rtk_release_abort "RTK archive contains an unexpected payload: $member"

  extract_dir="$stage_dir/extract"
  /usr/bin/mkdir -- "$extract_dir"
  /usr/bin/chmod 0700 -- "$extract_dir"
  if ! /usr/bin/tar --extract --file="$bound_fd_path" --directory="$extract_dir" \
    --no-same-owner --no-same-permissions --no-overwrite-dir --no-recursion; then
    rtk_release_abort 'RTK archive extraction failed'
  fi
  rtk_release_assert_file_stable "$archive_path" "$source_fd_path" "$source_id" "$source_hash" ||
    rtk_release_abort 'downloaded RTK archive was replaced during extraction'
  rtk_release_assert_file_stable "$bound_archive" "$bound_fd_path" "$bound_id" "$bound_hash" ||
    rtk_release_abort 'private RTK archive changed during extraction'

  extracted_list="$stage_dir/extracted.list"
  /usr/bin/find -P "$extract_dir" -mindepth 1 -maxdepth 1 -printf '%f\0' > "$extracted_list"
  mapfile -d '' -t extracted_entries < "$extracted_list"
  [[ "${#extracted_entries[@]}" == 1 && "${extracted_entries[0]}" == rtk ]] ||
    rtk_release_abort 'RTK extraction produced an unexpected payload layout'
  candidate="$extract_dir/rtk"
  [[ -f "$candidate" && ! -L "$candidate" && -x "$candidate" ]] ||
    rtk_release_abort 'extracted RTK payload is not a regular executable'
  candidate_mode="$(/usr/bin/stat -c '%a' -- "$candidate" 2>/dev/null || true)"
  [[ "$candidate_mode" =~ ^[0-7]+$ && $((8#$candidate_mode & 022)) == 0 ]] ||
    rtk_release_abort 'extracted RTK payload has unsafe permissions'
  /usr/bin/chmod 0755 -- "$candidate"
  exec {candidate_fd}<"$candidate" || rtk_release_abort 'could not open the extracted RTK binary'
  candidate_fd_path="/proc/$BASHPID/fd/$candidate_fd"
  candidate_id="$(/usr/bin/stat -Lc '%d:%i' -- "$candidate_fd_path" 2>/dev/null || true)"
  candidate_hash="$(/usr/bin/sha256sum -- "$candidate_fd_path" | /usr/bin/gawk '{print $1}')"
  [[ "$candidate_id" =~ ^[0-9]+:[0-9]+$ && "$candidate_hash" =~ ^[0-9a-f]{64} && \
    "$(/usr/bin/stat -c '%a' -- "$candidate" 2>/dev/null || true)" == 755 ]] ||
    rtk_release_abort 'extracted RTK binary identity is invalid'
  rtk_release_pause "$pause_hook" after-rtk-staging
  rtk_release_assert_file_stable "$candidate" "$candidate_fd_path" "$candidate_id" "$candidate_hash" ||
    rtk_release_abort 'extracted RTK binary was replaced during validation'
  version_output="$(/usr/bin/env -i HOME=/nonexistent PATH=/usr/sbin:/usr/bin:/sbin:/bin \
    LC_ALL=C TZ=UTC BASH_ENV= ENV= "$candidate_fd_path" --version 2>&1)" ||
    rtk_release_abort 'RTK --version failed'
  [[ "$version_output" == "rtk $expected_version" ]] ||
    rtk_release_abort "RTK version mismatch: expected 'rtk $expected_version', got '$version_output'"
  rtk_release_assert_file_stable "$candidate" "$candidate_fd_path" "$candidate_id" "$candidate_hash" ||
    rtk_release_abort 'extracted RTK binary changed after version validation'

  target_parent="${target_path%/*}"
  [[ "$target_parent" != "$target_path" && -d "$target_parent" ]] ||
    rtk_release_abort 'RTK target parent does not exist'
  rtk_release_reject_symlink_components "$target_parent" || rtk_release_abort 'RTK target parent contains a symlink'
  [[ "$(/usr/bin/realpath -e -- "$target_parent" 2>/dev/null || true)" == "$target_parent" ]] ||
    rtk_release_abort 'RTK target parent is not canonical'
  exec {parent_fd}<"$target_parent" || rtk_release_abort 'could not open the RTK target parent'
  parent_fd_path="/proc/$BASHPID/fd/$parent_fd"
  parent_id="$(/usr/bin/stat -Lc '%d:%i' -- "$parent_fd_path" 2>/dev/null || true)"
  [[ "$parent_id" =~ ^[0-9]+:[0-9]+$ ]] || rtk_release_abort 'RTK target parent identity is invalid'
  rtk_release_require_parent "$target_parent" "$parent_fd_path" "$parent_id"
  target_state=absent
  if [[ -e "$target_path" || -L "$target_path" ]]; then
    [[ -f "$target_path" && ! -L "$target_path" && -x "$target_path" ]] ||
      rtk_release_abort 'existing RTK target is not a regular executable'
    [[ "$(/usr/bin/realpath -e -- "$target_path" 2>/dev/null || true)" == "$target_path" ]] ||
      rtk_release_abort 'existing RTK target is not canonical'
    target_id="$(/usr/bin/stat -Lc '%d:%i' -- "$target_path" 2>/dev/null || true)"
    target_hash="$(/usr/bin/sha256sum -- "$target_path" | /usr/bin/gawk '{print $1}')"
    target_owner="$(/usr/bin/stat -c '%u' -- "$target_path" 2>/dev/null || true)"
    target_mode="$(/usr/bin/stat -c '%a' -- "$target_path" 2>/dev/null || true)"
    [[ "$target_id" =~ ^[0-9]+:[0-9]+$ && "$target_hash" =~ ^[0-9a-f]{64} && \
      "$target_owner" == "$current_uid" && "$target_mode" =~ ^[0-7]+$ && $((8#$target_mode & 022)) == 0 ]] ||
      rtk_release_abort 'existing RTK target identity is invalid'
    target_state=present
  fi

  # The publish file is created in the bound destination directory and is
  # checked again after the pause.  The final rename is the only public-name
  # mutation, so readers observe either the old complete file or the new one.
  publish_stage="$(/usr/bin/mktemp "$target_parent/.rtk-release.XXXXXX")"
  /usr/bin/chmod 0600 -- "$publish_stage"
  /usr/bin/cp -- "$candidate_fd_path" "$publish_stage"
  /usr/bin/chmod 0755 -- "$publish_stage"
  publish_id="$(/usr/bin/stat -Lc '%d:%i' -- "$publish_stage" 2>/dev/null || true)"
  publish_hash="$(/usr/bin/sha256sum -- "$publish_stage" | /usr/bin/gawk '{print $1}')"
  publish_mode="$(/usr/bin/stat -c '%a' -- "$publish_stage" 2>/dev/null || true)"
  publish_owner="$(/usr/bin/stat -c '%u' -- "$publish_stage" 2>/dev/null || true)"
  [[ -f "$publish_stage" && ! -L "$publish_stage" && "$publish_owner" == "$current_uid" && \
    "$publish_mode" == 755 && \
    "$publish_hash" == "$candidate_hash" && "$publish_id" =~ ^[0-9]+:[0-9]+$ ]] ||
    rtk_release_abort 'RTK publication staging identity is invalid'
  rtk_release_pause "$pause_hook" before-rtk-publish
  rtk_release_assert_file_stable "$archive_path" "$source_fd_path" "$source_id" "$source_hash" ||
    rtk_release_abort 'downloaded RTK archive was replaced before publication'
  rtk_release_require_parent "$target_parent" "$parent_fd_path" "$parent_id"
  rtk_release_assert_file_stable "$candidate" "$candidate_fd_path" "$candidate_id" "$candidate_hash" ||
    rtk_release_abort 'RTK binary changed before publication'
  rtk_release_assert_file_stable "$publish_stage" "$publish_stage" "$publish_id" "$publish_hash" ||
    rtk_release_abort 'RTK publication staging file changed'
  if [[ "$target_state" == present ]]; then
    [[ -f "$target_path" && ! -L "$target_path" && \
      "$(/usr/bin/stat -Lc '%d:%i' -- "$target_path" 2>/dev/null || true)" == "$target_id" && \
      "$(/usr/bin/sha256sum -- "$target_path" | /usr/bin/gawk '{print $1}')" == "$target_hash" ]] ||
      rtk_release_abort 'RTK target was replaced during publication'
  else
    [[ ! -e "$target_path" && ! -L "$target_path" ]] || rtk_release_abort 'RTK target appeared during publication'
  fi
  # Rename through the already-open destination directory descriptor.  The
  # final parent pathname cannot be swapped between validation and publish.
  /usr/bin/mv -T -- "$publish_stage" "$parent_fd_path/rtk"
  rtk_release_require_parent "$target_parent" "$parent_fd_path" "$parent_id"
  [[ -f "$target_path" && ! -L "$target_path" && -x "$target_path" && \
    "$(/usr/bin/realpath -e -- "$target_path" 2>/dev/null || true)" == "$target_path" && \
    "$(/usr/bin/stat -Lc '%d:%i' -- "$target_path" 2>/dev/null || true)" == "$publish_id" && \
    "$(/usr/bin/stat -c '%u' -- "$target_path" 2>/dev/null || true)" == "$current_uid" && \
    "$(/usr/bin/stat -c '%a' -- "$target_path" 2>/dev/null || true)" == 755 && \
    "$(/usr/bin/sha256sum -- "$target_path" | /usr/bin/gawk '{print $1}')" == "$candidate_hash" ]] ||
    rtk_release_abort 'RTK canonical publication failed verification'
)
