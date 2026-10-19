VERDICT: BLOCK
MERGE-BLOCKED

Independent gate for bootstrap issue 23, candidate `5cc8d1d..6863e72`. Worktree HEAD was `6863e72070c7a10cb8042a94254eaa0a71f3b74a`. All seven changed files were reviewed. Entry verification exited 0 with `NOT_APPLICABLE` for this headless node.

P2: `scripts/ubuntu/backup/install-herdr-backup.sh:49` suppresses crontab listing errors and can discard unrelated jobs. `cron_count` at line 23 turns a failed `crontab -l` into a count of zero. Line 49 suppresses the second read failure, and line 50 installs a table containing only the backup job. The installer exits 0 and prints `OK herdr-backup installed` if that write succeeds. `set -euo pipefail` cannot protect these reads because both use `|| true`.

The scratch reproducer used the unchanged candidate installer with a temporary HOME and a crontab shim. Its existing table contained a comment, `SHELL=/bin/bash`, and `0 8 * * * unrelated-job`. The shim returned exit 1 and `crontab: simulated read failure` for `-l`, and accepted replacement text for `-`. The installer exited 0. The resulting table contained exactly:

```text
30 8 * * * $HOME/.local/bin/herdr-backup
```

No real crontab write occurred. Before acceptance, distinguish an absent table from a listing error and refuse replacement after an unexpected read failure. Add a regression that preserves an existing table when listing fails. The current test does not exercise this failure.

The required live `--check` exited 1 with `FAIL crontab needs exactly one line: 30 8 * * * $HOME/.local/bin/herdr-backup`. A separate read-only `crontab -l` exited 1 with `crontabs/nathan/: fopen: Permission denied`. Live cron identity is therefore UNANSWERED in this sandbox. This is an environment limitation, not proof that the host has no backup job. A host-side read and successful live `--check` remain required.

The three repo/live pairs passed `sha256sum` byte-identity checks:

| Repo file | Live counterpart | Matching SHA-256 |
|---|---|---|
| `scripts/ubuntu/backup/herdr-backup` | `~/.local/bin/herdr-backup` | `d1d9d9a3f02a2ce87677f957fb491b7dcae9e4f6e5be5be61bef4ea7c2d5a737` |
| `scripts/ubuntu/backup/restic.env` | `~/.config/restic/env` | `da488c721ab82a51be278681a7147a5edd740d7404b5e0673682dd7bfcd989ea` |
| `scripts/ubuntu/backup/restic-excludes` | `~/.config/restic/excludes` | `cf4de58a4b178780f9075d7227ec917a536ed15b96c78799b4acb36b08f60605` |

No password or key material appears in the candidate diff. `restic.env` uses `RESTIC_PASSWORD_FILE=$HOME/.config/restic/password` and contains no inline password. The live password file exists; `stat -c %a` reported 600. Its contents were never read or hashed.

`bash tests/test-herdr-backup-install.sh` exited 0 and printed `PASS test-herdr-backup-install`. The test hard-codes `/tmp` for its fixture. A PATH shim redirected only its `mktemp -d /tmp/herdr-backup-install-test.*` allocation into the assigned `$TMPDIR`; the candidate test and installer were unchanged. All fixture HOME and crontab writes stayed under that directory.

The test is non-vacuous. Three independent scratch mutations each exited 1:

| Installer mutation | Test failure |
|---|---|
| Append the cron job on every run | `FAIL cron line not exactly once` |
| Discard existing crontab entries | `FAIL unrelated cron line lost` |
| Always exit 0 from `--check` | `FAIL --check passed without a password` |

Additional fixture probes confirmed installation with no table exits 0 and creates the exact literal cron line. A repeated install preserves comments, environment assignments, and unrelated jobs without writing the table again. A HOME containing spaces and a colon works for installation and checking. Snapshot comparisons confirmed that successful `--check` changes no fixture file content. Each of the three file drifts, a missing password, a duplicate cron line, and a missing cron line caused `--check` to exit 1. A clean fixture exited 0, an unknown argument exited 64, and a crontab write failure propagated exit 1. Existing duplicate entries are detected rather than repaired.

Apart from the suppressed read errors, the exercised `set -e` and `pipefail` paths behaved correctly. A zero grep count and an empty existing table do not abort installation; a failed table write does. File operands and pair extraction handle the tested HOME path. The cron string is single-quoted in the installer and remains literal `$HOME` in the table. Its equality to the real host line could not be established because the live read was denied.

`git diff --check 5cc8d1d..6863e72` and `bash -n` for both new scripts and the test exited 0. The `Validate-Repository.ps1` delta only adds test/file registrations. The full validator was not run, as required by the brief. No candidate file, Git state, live backup file, or real crontab was modified. No network, sudo, backup execution, merge, or push was used.

Reproducer and detailed observations remain at `$TMPDIR/review-probes.py`, `$TMPDIR/review-probes.json`, and `$TMPDIR/candidate-test.log`, where this run's TMPDIR is `/home/nathan/.cache/stm-scratch/STModel-Private-a9176bfdd476d72d/bootstrap-23-review-r1-a0ace758a40cfd07`. The Python harness runs only scratch fixtures and mutant copies. All subprocesses finished before this verdict was written.
