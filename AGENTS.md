# herdr-workstation-bootstrap

Agent practices for this repo live in **[docs/agent-practices.md](docs/agent-practices.md)** — read it.

Non-negotiables:
- "Done" = the live launcher `verify` exits 0 (`--entrypoint verify`, 0 FAIL lines). Pin it from the start.
- Any `scripts/ubuntu/verify.sh` parser change must be proven with a differential test against the real CPython `site.py` before fixing (see the verify-parity method in docs/agent-practices.md). Never reason about the consumer from memory.
- Test fixtures must model production's symlink-into-lib layout, not plain files in `~/.local/bin`.
- Deploys need root — arrange durable sudo up front (see docs/agent-practices.md).
