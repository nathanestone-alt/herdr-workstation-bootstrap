VERDICT: PASS
MERGE-OK

Independent gate r2 for bootstrap issue 23. Reviewed the frozen range `5cc8d1d..eaeda0a` at HEAD `eaeda0a07fb6c98a694272f337f05122456e4215`. The range contains seven implementation/test/documentation files plus the committed r1 verdict, eight files in total. Entry verification exited 0 with `NOT_APPLICABLE` for the headless node.

No P1, P2, or P3 findings. The r1 P2 is closed. An unexpected `crontab -l` failure now returns 1 from `read_crontab`. Installation reads the table before creating directories or copying files. The independent permission-denied fixture returned 1 and preserved all fixture file contents and modes, including its table and write counter. `--check` also returned 1 with `FAIL could not read the crontab`. Both an absent table reported as `no crontab for test` and an existing empty table installed successfully with exactly the intended cron line.

All three repo/live pairs have equal SHA-256 values:

| Repo file | Live counterpart | SHA-256 |
|---|---|---|
| `scripts/ubuntu/backup/herdr-backup` | `~/.local/bin/herdr-backup` | `d1d9d9a3f02a2ce87677f957fb491b7dcae9e4f6e5be5be61bef4ea7c2d5a737` |
| `scripts/ubuntu/backup/restic.env` | `~/.config/restic/env` | `da488c721ab82a51be278681a7147a5edd740d7404b5e0673682dd7bfcd989ea` |
| `scripts/ubuntu/backup/restic-excludes` | `~/.config/restic/excludes` | `cf4de58a4b178780f9075d7227ec917a536ed15b96c78799b4acb36b08f60605` |

The reviewed diff contains no password or key material. `restic.env` references `RESTIC_PASSWORD_FILE=$HOME/.config/restic/password` and has no inline password. The live password file exists and `stat -c %a` reports 600. Its contents were never read, printed, or hashed.

`bash tests/test-herdr-backup-install.sh` exited 0 and printed `PASS test-herdr-backup-install`. The unchanged test hard-codes `/tmp` for its fixture allocation. A PATH shim redirected only `mktemp -d /tmp/herdr-backup-install-test.*` into this node's `$TMPDIR`. All other `mktemp` calls used the real program. The candidate test and installer were unchanged; all fixture HOME and crontab writes stayed in scratch.

The test is non-vacuous. Each independent installer mutation in a scratch copy exited 1:

| Mutation | Test failure |
|---|---|
| Append the cron line on every run | `FAIL cron line not exactly once` |
| Drop unrelated crontab entries | `FAIL unrelated cron line lost` |
| Ignore the initial crontab read error | `FAIL install succeeded on an unreadable crontab` |
| Always return success from `--check` | `FAIL --check passed without a password` |

The bounded correctness question is answered with no bug found in the installer or test. Twenty direct runs covered the candidate test, four mutants, and independent fixture cases. A repeated install kept comments, `SHELL` and `MAILTO` assignments, and an unrelated job byte for byte without calling the crontab write shim again. Installation and checking succeeded with a HOME containing spaces and a colon. The pair extraction splits at the fixed repo-file separator, so the colon in HOME did not corrupt a destination.

A clean fixture returned 0 from `--check`. Separate drift in each installed file, a missing password, a missing cron line, a duplicate cron line, and an unreadable table each returned 1. Snapshot comparisons confirmed that every fixture `--check`, including failures, left fixture file contents and modes unchanged. Existing duplicate entries are detected rather than repaired. An unknown argument returned 64. A failed crontab write propagated exit 1 and left the fixture table intact.

The exercised `set -e` and `pipefail` paths behaved correctly. A zero grep count does not abort installation, the no-table path handles its unsuccessful nonempty-string test, the failed initial read prevents installation, and pipeline write failures propagate. File operands are quoted. The installer and test use the exact literal cron string `30 8 * * * $HOME/.local/bin/herdr-backup`.

The real-HOME `install-herdr-backup.sh --check` exited 1 with `FAIL could not read the crontab`; stderr reported `crontabs/nathan/: fopen: Permission denied`. The permitted live `crontab -l` also exited 1 with that error. Exact equality to the host's cron line is UNANSWERED in this sandbox. This is the specific environment limitation accepted by brief section 2a, not a candidate defect. The brief reports that the orchestrator's outside-sandbox `--check` exited 0; that is supplied evidence, not an observation from this review. PASS relies on the brief's explicit exception for the denied live read.

`git diff --check 5cc8d1d..eaeda0a` and `bash -n` on both new shell scripts and the test exited 0. The `Validate-Repository.ps1` delta only registers the new test and required files. The full validator and live launcher verify were not run; this review brief prohibits sudo and reserves full validation for the orchestrator.

Evidence is in `review-probes.py`, `review-probes.json`, `review-probes.log`, and `live-checks.json` under `/home/nathan/.cache/stm-scratch/STModel-Private-a9176bfdd476d72d/bootstrap-23-review-r2-fac45e63d2f9d47d`. All subprocesses finished before this verdict was written. No candidate file, Git state, live backup file, or real crontab was modified. No password content, network, sudo, backup execution, merge, or push was used. The findings document remains untracked for the orchestrator to commit.
