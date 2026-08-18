# Migration Payload

The installable payload is the tracked `agents-skills/` and `claude-skills/`
trees. `config/payload-manifest.sha256` is the authority for their sorted
relative paths and SHA-256 values; `payload/README.md` is documentation only.

Run `bash scripts/ubuntu/install-payload.sh` only from a clean, identified Git
commit. The installer rejects dirty or uncommitted source, manifest/path/hash
drift, symlinks, unsafe Git destinations and failed post-copy verification. It
stages both managed destinations transactionally and records
`~/.local/state/herdr-workstation-bootstrap/payload-runtime-receipt.txt` with
the source commit, manifest hash, per-file source/installed hashes, tool
versions and the ten named regression commands.

An ignored root-level `LOCAL-COMMISSIONING-LOG.md` may remain outside the
manifest. No other ignored or untracked payload file is accepted.

On the old Surface, run `scripts/windows/Export-MigrationPayload.ps1` to create
an allowlisted skill payload. Review every exported file for secrets and
machine-specific paths before intentionally force-adding reviewed files to this
private repository.

Never add authentication/session files, plugin caches, SSH keys, browser
profiles, Office workbooks/client data, backup credentials, or recovery keys.
Reinstall the official Herdr skill from the new Herdr binary; do not export its
source tree.
