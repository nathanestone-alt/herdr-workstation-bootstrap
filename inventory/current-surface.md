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

## Pinned RTK customization

The installed RTK binary was built from a clean worktree:

- Repository: `https://github.com/nathanestone-alt/rtk.git`
- Branch: `fix/native-fallback-current`
- Commit: `c1819ceff1ab8d75b88c1ff7a63f497914e8fe99`

The Ubuntu bootstrap pins this exact commit by default. Change it only after verifying a released/upstream build includes the required native fallback and session behavior.

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
