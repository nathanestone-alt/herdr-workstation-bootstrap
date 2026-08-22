#!/usr/bin/env bash
set -euo pipefail
umask 022

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d /tmp/herdr-rtk-release-test.XXXXXX)"
trap 'rm -rf -- "$test_root"' EXIT

# This focused fixture suite never downloads or publishes on the host. Every
# target is inside test_root; the production helper is source-attested before
# bootstrap uses it.
# shellcheck source=/dev/null
source "$repo_root/scripts/ubuntu/rtk-release.sh"

version='0.45.0'

write_rtk_binary() {
  local path="$1"
  local binary_version="$2"
  cat > "$path" <<EOF
#!/usr/bin/bash
if [[ "\${1:-}" == --version ]]; then
  printf 'rtk %s\\n' '$binary_version'
  exit 0
fi
printf 'fixture\\n'
EOF
  chmod 0755 "$path"
}

valid_root="$test_root/valid"
valid_archive="$test_root/rtk-valid.tar.gz"
mkdir -p "$valid_root"
write_rtk_binary "$valid_root/rtk" "$version"
/usr/bin/tar --create --gzip --file="$valid_archive" --format=gnu -C "$valid_root" rtk
chmod 0600 "$valid_archive"
valid_sha="$(/usr/bin/sha256sum -- "$valid_archive" | /usr/bin/gawk '{print $1}')"

new_target() {
  local name="$1"
  local parent="$test_root/targets/$name/.cargo/bin"
  mkdir -p "$parent"
  printf '%s\n' "$parent/rtk"
}

assert_rejected() {
  local label="$1"
  local archive="$2"
  local target="$3"
  local expected_diagnostic="${4:-}"
  local archive_sha
  local good_id good_hash
  archive_sha="$(/usr/bin/sha256sum -- "$archive" | /usr/bin/gawk '{print $1}')"
  write_rtk_binary "$target" "$version"
  good_id="$(stat -Lc '%d:%i' -- "$target")"
  good_hash="$(/usr/bin/sha256sum -- "$target" | /usr/bin/gawk '{print $1}')"
  if rtk_release_install_archive "$archive" "$archive_sha" "$version" "$target" \
    > "$test_root/$label.log" 2>&1; then
    echo "RTK release fixture unexpectedly accepted $label." >&2
    exit 1
  fi
  [[ -f "$target" && ! -L "$target" &&
    "$(stat -Lc '%d:%i' -- "$target")" == "$good_id" &&
    "$(/usr/bin/sha256sum -- "$target" | /usr/bin/gawk '{print $1}')" == "$good_hash" &&
    "$("$target" --version)" == "rtk $version" ]] || {
    echo "RTK release fixture did not preserve the good installed $label payload." >&2
    exit 1
  }
  [[ -z "$(find "${target%/*}" -maxdepth 1 -name '.rtk-release.*' -print -quit)" ]] || {
    echo "RTK release fixture leaked a publication staging file for $label." >&2
    exit 1
  }
  if [[ -n "$expected_diagnostic" ]]; then
    grep -Fqx -- "$expected_diagnostic" "$test_root/$label.log" || {
      cat "$test_root/$label.log" >&2
      echo "RTK release fixture emitted the wrong $label diagnostic." >&2
      exit 1
    }
  fi
}

# Positive path: the only public mutation is an atomic replacement of the
# canonical user cargo target, and mode/version/content are verified.
positive_target="$(new_target positive)"
write_rtk_binary "$positive_target" '0.40.0'
rtk_release_install_archive "$valid_archive" "$valid_sha" "$version" "$positive_target"
[[ -f "$positive_target" && ! -L "$positive_target" ]] || exit 1
[[ "$(stat -c '%a:%F' -- "$positive_target")" == '755:regular file' ]] || exit 1
[[ "$(realpath -e -- "$positive_target")" == "$positive_target" ]] || exit 1
[[ "$("$positive_target" --version)" == "rtk $version" ]] || exit 1
[[ -z "$(find "${positive_target%/*}" -maxdepth 1 -name '.rtk-release.*' -print -quit)" ]] || exit 1

# A checksum mismatch fails before extraction or publication.
checksum_target="$(new_target checksum-mismatch)"
write_rtk_binary "$checksum_target" "$version"
checksum_good_id="$(stat -Lc '%d:%i' -- "$checksum_target")"
checksum_good_hash="$(/usr/bin/sha256sum -- "$checksum_target" | /usr/bin/gawk '{print $1}')"
if rtk_release_install_archive "$valid_archive" \
  '0000000000000000000000000000000000000000000000000000000000000000' \
  "$version" "$checksum_target" > "$test_root/checksum-mismatch.log" 2>&1; then
  echo 'RTK release fixture accepted a checksum mismatch.' >&2
  exit 1
fi
[[ -f "$checksum_target" && ! -L "$checksum_target" &&
  "$(stat -Lc '%d:%i' -- "$checksum_target")" == "$checksum_good_id" &&
  "$(/usr/bin/sha256sum -- "$checksum_target" | /usr/bin/gawk '{print $1}')" == "$checksum_good_hash" ]] || exit 1
[[ -z "$(find "${checksum_target%/*}" -maxdepth 1 -name '.rtk-release.*' -print -quit)" ]] || exit 1

# Version validation is performed by executing the staged binary before the
# canonical name is changed.
version_root="$test_root/version-mismatch"
version_archive="$test_root/rtk-version-mismatch.tar.gz"
mkdir -p "$version_root"
write_rtk_binary "$version_root/rtk" '0.44.0'
/usr/bin/tar --create --gzip --file="$version_archive" --format=gnu -C "$version_root" rtk
chmod 0600 "$version_archive"
version_target="$(new_target version-mismatch)"
assert_rejected version-mismatch "$version_archive" "$version_target"

# Hostile archive layouts: traversal, absolute names, links, duplicate
# payloads, unexpected payloads, and unsafe payload modes are rejected before
# a public target is created.
traversal_archive="$test_root/rtk-traversal.tar.gz"
/usr/bin/tar --create --gzip --file="$traversal_archive" --format=gnu \
  --transform='s#^rtk$#../escape#' -C "$valid_root" rtk >/dev/null 2>&1
chmod 0600 "$traversal_archive"
assert_rejected traversal "$traversal_archive" "$(new_target traversal)"

absolute_archive="$test_root/rtk-absolute.tar.gz"
/usr/bin/tar --create --gzip --file="$absolute_archive" --format=gnu \
  --absolute-names "$valid_root/rtk" >/dev/null 2>&1
chmod 0600 "$absolute_archive"
assert_rejected absolute "$absolute_archive" "$(new_target absolute)"

link_root="$test_root/link"
link_archive="$test_root/rtk-link.tar.gz"
mkdir -p "$link_root"
ln -s "$valid_root/rtk" "$link_root/rtk"
/usr/bin/tar --create --gzip --file="$link_archive" --format=gnu --no-recursion \
  -C "$link_root" rtk
chmod 0600 "$link_archive"
assert_rejected link "$link_archive" "$(new_target link)"

duplicate_archive="$test_root/rtk-duplicate.tar.gz"
/usr/bin/tar --create --gzip --file="$duplicate_archive" --format=gnu \
  -C "$valid_root" rtk rtk
chmod 0600 "$duplicate_archive"
assert_rejected duplicate "$duplicate_archive" "$(new_target duplicate)"

unexpected_root="$test_root/unexpected"
unexpected_archive="$test_root/rtk-multiple-members.tar.gz"
mkdir -p "$unexpected_root"
cp -- "$valid_root/rtk" "$unexpected_root/rtk"
printf 'unexpected\n' > "$unexpected_root/other"
/usr/bin/tar --create --gzip --file="$unexpected_archive" --format=gnu \
  -C "$unexpected_root" rtk other
chmod 0600 "$unexpected_archive"
assert_rejected multiple-members "$unexpected_archive" "$(new_target multiple-members)"

unexpected_name_root="$test_root/unexpected-name"
unexpected_name_archive="$test_root/rtk-unexpected-name.tar.gz"
mkdir -p "$unexpected_name_root"
write_rtk_binary "$unexpected_name_root/other" "$version"
/usr/bin/tar --create --gzip --file="$unexpected_name_archive" --format=gnu \
  -C "$unexpected_name_root" other
chmod 0600 "$unexpected_name_archive"
assert_rejected unexpected-name "$unexpected_name_archive" "$(new_target unexpected-name)" \
  'RTK release install: RTK archive contains an unexpected payload: "other"'

wrong_mode_root="$test_root/wrong-mode"
wrong_mode_archive="$test_root/rtk-wrong-mode.tar.gz"
mkdir -p "$wrong_mode_root"
cp -- "$valid_root/rtk" "$wrong_mode_root/rtk"
chmod 0644 "$wrong_mode_root/rtk"
/usr/bin/tar --create --gzip --file="$wrong_mode_archive" --format=gnu \
  -C "$wrong_mode_root" rtk
chmod 0600 "$wrong_mode_archive"
assert_rejected wrong-mode "$wrong_mode_archive" "$(new_target wrong-mode)"

# Replacement race: the archive pathname is replaced after the source and
# private descriptors are bound. Identity validation must fail closed.
race_archive="$test_root/rtk-race.tar.gz"
cp -- "$valid_archive" "$race_archive"
chmod 0600 "$race_archive"
race_target="$(new_target replacement-race)"
race_ready="$test_root/race-ready"
race_continue="$test_root/race-continue"
rtk_release_race_pause() {
  local phase="$1"
  if [[ "$phase" == after-rtk-archive-bind ]]; then
    : > "$race_ready"
    while [[ ! -e "$race_continue" ]]; do
      /usr/bin/sleep 0.01
    done
  fi
}
rtk_release_install_archive "$race_archive" "$valid_sha" "$version" "$race_target" \
  rtk_release_race_pause > "$test_root/replacement-race.log" 2>&1 &
race_pid=$!
for _ in $(seq 1 200); do
  [[ -e "$race_ready" ]] && break
  /usr/bin/sleep 0.01
done
if [[ ! -e "$race_ready" ]]; then
  : > "$race_continue"
  wait "$race_pid" || true
  echo 'RTK release race fixture did not reach its bind pause.' >&2
  exit 1
fi
mv -- "$race_archive" "$race_archive.original"
cp -- "$valid_archive" "$race_archive"
chmod 0600 "$race_archive"
: > "$race_continue"
if wait "$race_pid"; then
  echo 'RTK release fixture accepted an archive replacement race.' >&2
  exit 1
fi
[[ ! -e "$race_target" && ! -L "$race_target" ]] || exit 1

printf '%s\n' 'RTK release fixtures passed.'
