# Current Surface Tool Baseline

Captured 2026-08-16. These versions document the working ARM64 environment; AMD64 binaries must be freshly installed.

| Tool | Working Surface version |
|---|---|
| PowerShell | 7.6.4 |
| WSL | 2.7.8 |
| RTK | 0.42.4 |
| Codex CLI | 0.147.0 |
| Claude Code | 2.1.233 |
| Herdr | 0.8.0-preview.2026-08-04-d78e3d3b5126 |
| Git | 2.53.0.windows.3 |
| GitHub CLI | 2.92.0 |
| Node.js | 24.15.0 |
| npm | 11.12.1 |
| Bun | 1.3.13 |
| Python | 3.12.10 and 3.13.12 ARM64 |
| uv | 0.11.19 |

## Pinned RTK release

The Ubuntu bootstrap installs the official upstream Linux release and keeps
customization in configuration and hooks:

- Version: `0.45.0`
- Asset: `rtk-x86_64-unknown-linux-musl.tar.gz`
- SHA-256: `c4c036fbf181fc55ef329786c8c17e0d427972b053b825944d968a6aafef1ba4`

Forking or source-building is deferred until a concrete upstream gap is
proven.

## Installed Codex plugins

- Browser
- Sites
- Visualize
- GitHub
- OpenAI Templates
- Plugin Management
- Google Calendar
- Slack
- context-mode 1.0.169

Reinstall through supported marketplaces and reconnect accounts. Do not copy caches.
