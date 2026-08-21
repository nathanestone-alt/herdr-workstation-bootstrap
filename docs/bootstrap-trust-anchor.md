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
| Pinned policy | `/etc/herdr-workstation/bootstrap-policy.conf` | `root:root`, `0644` |
| Staging namespace | `/var/lib/herdr-workstation/bootstrap/staging` | `root:root`, `0755`; each run is a root-owned non-writable child |

The policy has exactly three logical lines: one
`herdr-bootstrap-policy-v1` header, one canonical `origin=` HTTPS URL, and one
full lowercase `commit=` object identifier. The committed example is at
`config/bootstrap-policy.example`; it is documentation, not a live policy.

## One-time provisioning

After reviewing and approving a candidate commit, an administrator runs the
installer from that clean checkout. The command below selects the workstation
account whose home is used by the user-scoped bootstrap and verification
entrypoints:

```bash
sudo /path/to/approved-checkout/scripts/ubuntu/install-trusted-launcher.sh \
  --source-root /path/to/approved-checkout \
  --origin https://github.com/nathanestone-alt/herdr-workstation-bootstrap.git \
  --commit "$(git -C /path/to/approved-checkout rev-parse --verify HEAD^{commit})" \
  --run-as-user "$USER"
```

The installer requires root, a clean source checkout whose `HEAD` and origin
match the arguments, and refuses to replace an existing launcher or policy.
Publication uses private temporary files and atomic rename. It does not create
or modify these system paths during repository tests; fixture tests redirect
the three paths below into a sealed temporary root.

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
never used as the trust anchor.
