# Ubuntu bootstrap trust anchor

Ubuntu entrypoints are not launched from a mutable checkout. The one-time
administrative installer publishes an external launcher and a root-owned
policy, then the launcher fetches the policy commit from the canonical HTTPS
origin into a protected staging tree. Only the exact committed entrypoint is
executed after object, mode, ownership, and lifetime checks pass.

Production paths are fixed:

| Object | Path | Required owner/mode |
| --- | --- | --- |
| External launcher | `/usr/local/libexec/herdr-workstation-bootstrap` | `root:root`, `0755` |
| Pinned policy | `/etc/herdr-workstation/bootstrap-policy.conf` | `root:root`, `0600` |
| Staging namespace | `/var/lib/herdr-workstation/bootstrap/staging` | `root:root`, `0755`; each run is a root-owned non-writable child |

The policy has exactly three logical lines: one
`herdr-bootstrap-policy-v1` header, one canonical `origin=` HTTPS URL, and one
full lowercase `commit=` object identifier. The committed example is at
`config/bootstrap-policy.example`; it is documentation, not a live policy.

## One-time provisioning

Provisioning has two separate trust inputs: the installer bytes, verified by
an independent channel, and a reviewed full commit literal supplied by the
administrator. A local checkout, its HEAD, its object database, and its
remote configuration are never used as the external anchor. The installer
fetches the literal commit from the canonical HTTPS origin into root-owned
temporary storage and renders the launcher from the fetched committed blob.

Before the first privileged command, obtain these values independently from
the review record or release operator:

origin='https://github.com/nathanestone-alt/herdr-workstation-bootstrap.git'
reviewed_commit='<40-lowercase-hex-reviewed-commit>'
installer_sha256='<64-lowercase-hex-reviewed-installer-sha256>'

Fetch and verify the installer itself out of band. Do not compute the literal
from a local Git HEAD, and do not execute a copy from a mutable checkout:

```bash
installer=/tmp/herdr-install-trusted-launcher.sh
/usr/bin/curl --proto '=https' --tlsv1.2 --fail --silent --show-error \
  --location --output "$installer" \
  "https://raw.githubusercontent.com/nathanestone-alt/herdr-workstation-bootstrap/$reviewed_commit/scripts/ubuntu/install-trusted-launcher.sh"
printf '%s  %s\n' "$installer_sha256" "$installer" | /usr/bin/sha256sum --check --status
/usr/bin/bash -n "$installer"
/usr/bin/chmod 0755 "$installer"
[[ -x /usr/bin/gawk ]] || {
  echo 'Install gawk through the separately approved base-package procedure first.' >&2
  exit 1
}
sudo -- "$installer" \
  --origin "$origin" --commit "$reviewed_commit" --run-as-user '<runtime-user>'
```

The administrator must replace <runtime-user> with the already-created,
non-root workstation account and independently verify that account's home.
Install gawk before this command if the base image does not already contain
/usr/bin/gawk; the normal bootstrap package phase also records and retains
that dependency. The installer refuses an existing anchor on first install,
fetches the exact commit over HTTPS, and publishes root-owned files through
private temporary files and atomic rename. It does not accept a source-root
argument.

To re-pin safely, repeat the independent review and installer-byte
verification for the new commit, confirm the existing launcher is still
root-owned with mode 0755 and the policy is root-owned with mode 0600, then
run the verified installer with --re-pin, the same canonical --origin, the
new literal --commit, and the same --run-as-user. Verify the resulting policy
literal and published launcher hash before invoking any entrypoint.
Never re-pin from a local Git HEAD, object store, or modified checkout.

Fixture tests redirect the three production paths below into a sealed
temporary root; production provisioning never does so.

The receipt authority entrypoint remains root-scoped so it can publish its
root-owned receipt. The launcher drops to the selected runtime user for
`bootstrap` and `verify`, while Python probes in receipt authority use the
explicit root-to-user `setpriv` boundary. No signing-key or signing-service
infrastructure is required.

## Invocation

Use the installed launcher, not a repository script:

```bash
sudo /usr/local/libexec/herdr-workstation-bootstrap --entrypoint bootstrap --phase base
sudo /usr/local/libexec/herdr-workstation-bootstrap --entrypoint bootstrap --phase tools
sudo /usr/local/libexec/herdr-workstation-bootstrap --entrypoint receipt-authority --install
sudo /usr/local/libexec/herdr-workstation-bootstrap --entrypoint verify
```

The launcher clears startup files, Git configuration/environment overrides,
user `PATH` resolution, and runtime import paths. It opens and binds the policy
before fetching, verifies the exact full commit and committed entrypoint blob,
rejects symlinks/special files and unsafe ownership or modes in the staged
closure, and rechecks the policy and entrypoint immediately before execution.
Local Git metadata, origin configuration, manifests, lockfiles, and hashes are
never used as the external provisioning anchor. The policy and staged Git
metadata are still checked as defense in depth after the launcher has bound
the reviewed commit.
