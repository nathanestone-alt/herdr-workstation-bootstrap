# Migration Payload

This directory is ignored except for this file.

On the old Surface, run `scripts/windows/Export-MigrationPayload.ps1` to create an allowlisted skill payload. Review every exported file for secrets and machine-specific paths. Only then intentionally force-add reviewed files to this private repository.

Never add authentication/session files, plugin caches, private SSH keys, browser profiles, Office workbooks/client data, backup credentials, or recovery keys.

