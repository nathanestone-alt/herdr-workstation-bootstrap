#!/usr/bin/env bash
set -euo pipefail
umask 022

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

# Bootstrap now attests the complete committed source before exposing its
# sourced functions.  Exercise the profile seam from a disposable clean
# source fixture so this test remains runnable from a developer worktree with
# unrelated edits.
source_fixture="$test_root/source"
fixture_root="$test_root/fixture"
fixture_home="$fixture_root/home"
transport="$fixture_root/transport.git"
mkdir -p "$fixture_root" "$fixture_home"
cp -a -- "$repo_root/." "$source_fixture/"
chmod 0755 "$source_fixture"
/usr/bin/rm -rf -- "$source_fixture/.agents" "$source_fixture/.codex"
rm -rf -- "$source_fixture/.git"
head -n -9 "$source_fixture/scripts/ubuntu/bootstrap.sh" > "$source_fixture/scripts/ubuntu/bootstrap.sh.tmp"
mv -T "$source_fixture/scripts/ubuntu/bootstrap.sh.tmp" "$source_fixture/scripts/ubuntu/bootstrap.sh"
cat >> "$source_fixture/scripts/ubuntu/bootstrap.sh" <<'EOF'
fixture_profile_main() {
  converge_profile_hook "$HOME/.profile"
  if [[ -e "$HOME/.bash_profile" ]]; then converge_profile_hook "$HOME/.bash_profile" true; fi
  if [[ -e "$HOME/.bash_login" ]]; then converge_profile_hook "$HOME/.bash_login" true; fi
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "$phase" in
    profile) fixture_profile_main ;;
    *) echo "Unsupported profile fixture phase: $phase" >&2; exit 2 ;;
  esac
fi
EOF
chmod 0755 "$source_fixture/scripts/ubuntu/bootstrap.sh"
git -C "$source_fixture" init -q
git -C "$source_fixture" config user.email fixture@example.invalid
git -C "$source_fixture" config user.name fixture
git -C "$source_fixture" add -f .
git -C "$source_fixture" commit -qm 'clean profile fixture'
git clone -q --bare "$source_fixture" "$transport"
chmod 0700 "$transport"
/usr/bin/bash "$repo_root/scripts/ubuntu/install-trusted-launcher.sh" \
  --origin https://github.com/nathanestone-alt/herdr-workstation-bootstrap.git \
  --commit "$(git -C "$source_fixture" rev-parse --verify HEAD^{commit})" \
  --fixture-root "$fixture_root" --fixture-transport "$transport" --fixture-home "$fixture_home" \
  > "$test_root/launcher-install.out"
launcher="$fixture_root/usr/local/libexec/herdr-workstation-bootstrap"
export HOME="$fixture_home"
mkdir -p "$HOME/.config/herdr-workstation"
printf 'export PATH="$HOME/.local/bin:$PATH"\n' > "$HOME/.config/herdr-workstation/profile.sh"
printf 'export HERDR_BASHRC_CHAINED=1\n' > "$HOME/.bashrc"
printf 'HERDR_PROFILE_COUNT=$(( ${HERDR_PROFILE_COUNT:-0} + 1 ))\nexport HERDR_PROFILE_COUNT\n[[ -f "$HOME/.bashrc" ]] && . "$HOME/.bashrc"\n' > "$HOME/.profile"

run_profile_fixture() {
  /usr/bin/env -i HOME="$HOME" PATH=/usr/sbin:/usr/bin:/sbin:/bin \
    BASH_ENV= ENV= LC_ALL=C TZ=UTC \
    "$launcher" --entrypoint bootstrap -- --phase profile
}

# Exercise the production function only through the installed launcher and
# its descriptor-bound staged entrypoint.
run_profile_fixture
[[ ! -e "$HOME/.bash_profile" ]] || {
  echo 'Bootstrap created .bash_profile and shadowed the stock .profile chain.' >&2
  exit 1
}
[[ ! -e "$HOME/.bash_login" ]] || {
  echo 'Bootstrap created .bash_login and shadowed the stock .profile chain.' >&2
  exit 1
}
/bin/bash --noprofile --norc -c '. "$HOME/.profile"; [[ "$HERDR_PROFILE_COUNT" == 1 ]]; [[ "$HERDR_BASHRC_CHAINED" == 1 ]]; [[ ":$PATH:" == *":$HOME/.local/bin:"* ]]'

printf 'export HERDR_BASH_PROFILE_PRESERVED=1\n. "$HOME/.profile"\n' > "$HOME/.bash_profile"
run_profile_fixture
before="$(sha256sum "$HOME/.bash_profile" | awk '{print $1}')"
run_profile_fixture
after="$(sha256sum "$HOME/.bash_profile" | awk '{print $1}')"
[[ "$before" == "$after" ]] || { echo '.bash_profile convergence is not byte-idempotent.' >&2; exit 1; }
/bin/bash --noprofile --norc -c '. "$HOME/.bash_profile"; [[ "$HERDR_BASH_PROFILE_PRESERVED" == 1 ]]; [[ "$HERDR_PROFILE_COUNT" == 1 ]]; [[ "$HERDR_BASHRC_CHAINED" == 1 ]]'

rm -f "$HOME/.bash_profile"
printf 'export HERDR_BASH_LOGIN_PRESERVED=1\n. "$HOME/.profile"\n' > "$HOME/.bash_login"
run_profile_fixture
before="$(sha256sum "$HOME/.bash_login" | awk '{print $1}')"
run_profile_fixture
after="$(sha256sum "$HOME/.bash_login" | awk '{print $1}')"
[[ "$before" == "$after" ]] || { echo '.bash_login convergence is not byte-idempotent.' >&2; exit 1; }
/bin/bash --noprofile --norc -c '. "$HOME/.bash_login"; [[ "$HERDR_BASH_LOGIN_PRESERVED" == 1 ]]; [[ "$HERDR_PROFILE_COUNT" == 1 ]]; [[ "$HERDR_BASHRC_CHAINED" == 1 ]]'

echo 'bootstrap profile-chain regression tests passed.'
