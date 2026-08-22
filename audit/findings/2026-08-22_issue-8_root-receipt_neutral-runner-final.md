All deterministic checks passed.

- Repository: `pwd -P` and Git root both `/tmp/herdr-bootstrap-issue-8-cross-review-294b09e6`; HEAD is `294b09e6ed088b3567d96d27d116e2d87d2c2ee1`; detached (`git symbolic-ref` rc=1); clean status rc=0.
- `86a14069..294b09e6`: only `tests/test-trusted-launcher.sh`; `git diff --check` rc=0.
- Base range changed three files; `bash -n` returned rc=0 for all three.
- Current uid: `1000` (non-root). All required tests returned rc=0.
- `git ls-tree HEAD` shows both requested scripts as `100755`.
- Invalid and empty selector cases assert status `24` and diagnostic `herdr launcher capability: payload mode selector is invalid`.
- HEAD’s parent is the supplied parent; last commit changes only `tests/test-trusted-launcher.sh`.
- Pre- and post-test tracked/untracked status was empty; no files were created.

Limitation: expected root-only test sections were skipped because uid 1000; the supplied prior root gate covers those suites. An auxiliary grep wrapper initially had a quoting error, corrected successfully; no requested check failed.

PASS FOR NEUTRAL RUNNER