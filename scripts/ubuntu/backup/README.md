# herdr-ubuntu nightly backup (restic)

`herdr-backup` backs up `$HOME` on herdr-ubuntu every night to `sftp:herdr-win:/C:/HerdrBackup/restic`, on the 2 TB Windows drive. Bootstrap issue 23 tracks it.

- **Schedule:** cron `30 8 * * *` UTC, which is 3:30 AM Central during daylight time.
- **Throttling:** uploads are capped at 40 MiB/s (`--limit-upload 40960`), and the backup runs under `nice` and idle-class `ionice`.
- **Retention:** 7 daily, 4 weekly and 6 monthly snapshots. A prune runs on Sundays.
- **Excludes:** `restic-excludes`. It skips `~/.cache`, which holds the STModel scratch, plus package caches and virtualenvs.
- **Log:** `~/.local/state/herdr-backup/backup.log`.

| Repo file | Live path |
|---|---|
| `herdr-backup` | `~/.local/bin/herdr-backup` |
| `restic.env` | `~/.config/restic/env` |
| `restic-excludes` | `~/.config/restic/excludes` |

**Install or refresh:** run `scripts/ubuntu/backup/install-herdr-backup.sh`. It is safe to re-run and adds the cron line only once.

**Check for drift:** run `install-herdr-backup.sh --check`. It exits 0 only when the live files match the repo byte for byte, the cron line is present exactly once, and the password file exists.

**Password:** the password is never in this repo. `restic.env` points to `~/.config/restic/password` (mode 600). On a rebuild, restore that file from the password manager.

**Not here:** `stm-scratch-cleanup` (cron 08:00 UTC) cleans STModel scratch and is owned by the skills lane (agent-skills #77).

**Test:** `tests/test-herdr-backup-install.sh`. It runs against a temporary `HOME` and a fake `crontab`, so it never touches the real crontab.
