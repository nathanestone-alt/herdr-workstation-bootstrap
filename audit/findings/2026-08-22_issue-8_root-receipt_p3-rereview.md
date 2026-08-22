# Issue #8 P3 correction independent re-review

- Workflow: `[WF:2369b600]`
- Request relay: `[HR:d237b08e]`
- Reviewer pane: `w1:p10` (STM-T-C1), session `c62a6d98-6e3d-4c14-b226-a33e71125348`
- Candidate: `294b09e6ed088b3567d96d27d116e2d87d2c2ee1`
- Parent: `86a14069d5cf65ca2ca3571aa595661bfd502a17`
- Worktree: `/tmp/herdr-bootstrap-issue-8-cross-review-294b09e6` (read-only; clean before and after)
- Prior review: `/tmp/issue-8-r5-cross-review-return.md`
- Builder return: `/tmp/issue-8-cross-review-p3-correction-return.md`

## Scope confirmed

`git diff --name-only 86a14069..294b09e6` → `tests/test-trusted-launcher.sh` only.
32 insertions, 2 deletions. `git diff --check`: clean. `bash -n`: clean.
No production file, config, workflow, or doc changed.

## Verification performed

Read-only. No edits, commits, pushes, installs, sudo, GitHub mutation, or agent
dispatch. Mutation testing was run against a `git clone --no-local` copy in the
session scratchpad, never against the review worktree.

Baseline: `bash tests/test-trusted-launcher.sh` as uid 1000 → exit 0
(root-gated privilege-drop block correctly SKIPped). `bash
tests/test-receipt-authority.sh` → exit 0 (unchanged sibling suite, no
regression).

### Brief item 1 — selector proves the intended branch, exact status and diagnostic

`tests/test-trusted-launcher.sh:350-372` (`expect_invalid_payload_mode_selector`)
calls `launcher_capability_expected_entry_mode` in isolation — no
`launcher_capability_owner_mode` call follows it — and asserts
`(( status == 24 ))` and `[[ "$output" == 'herdr launcher capability: payload
mode selector is invalid' ]]`. That string is byte-exact against
`scripts/ubuntu/launcher-capability.sh:6` (`echo "herdr launcher capability:
$*"`) plus `:56` (`launcher_capability_fail 'payload mode selector is
invalid'`), and 24 is the literal at `:7`. Invoked at `:385-386` for both
selectors.

Four mutations of `scripts/ubuntu/launcher-capability.sh`, each run against the
full suite:

| # | Mutation | Result |
|---|---|---|
| A | `*) launcher_capability_fail '...' ;;` → `*) : ;;` | FAIL — `invalid-selector selector did not fail with status 24` |
| B | diagnostic text `invalid` → `bogus`, exit 24 kept | FAIL — `invalid-selector selector emitted the wrong diagnostic` |
| C | `exit 24` → `exit 1`, diagnostic kept | FAIL — `invalid-selector selector did not fail with status 24` |
| G | added `'') launcher_capability_entry_mode=755 ;;` (resolver silently accepts empty) | FAIL — `empty-selector selector did not fail with status 24` |

Mutation A is the exact scenario P3-1 identified: under the parent commit that
mutation still "passed", because `launcher_capability_owner_mode` returned 1 on
the empty expected mode (`launcher-capability.sh:39`). It now fails. Mutation G
proves the `empty-selector` case fires independently rather than being masked by
`invalid-selector` failing first. Confirmed.

### Brief item 2 — Git-tree assertion

`tests/test-trusted-launcher.sh:308-313` iterates
`scripts/ubuntu/launcher-capability.sh` and `scripts/ubuntu/receipt-authority.sh`
and requires `git -C "$repo_root" ls-tree HEAD -- "$blob" | awk '{print $1}'` to
equal `100755`.

- Reads the committed tree at candidate HEAD, not the index or worktree, so it is
  immune to `core.fileMode=false` and to local `chmod`. This is exactly the
  object P3-4 named.
- Non-recursive `ls-tree` with a full nested pathspec does resolve to the blob
  entry — verified directly; both return `100755 blob …`.
- Fail-closed on absence: a missing/renamed path yields empty output, which is
  `!= 100755`. Verified by mutation F (`git mv receipt-authority.sh …-renamed.sh`)
  → FAIL.
- Mutation D (`update-index --chmod=-x` + commit on `launcher-capability.sh`) →
  FAIL. Mutation E (same on `receipt-authority.sh`) → FAIL. Both fire on the
  Git-tree assertion, before the mode-contract fixtures.
- Portability: `/usr/bin/awk` matches the file's existing convention
  (`:133,:165,:186`); `{print $1}` is mawk/gawk-neutral. `git -C "$repo_root"`
  is not a new environmental requirement — `tests/test-install-payload.sh:676`
  already requires `repo_root` to be a git repo with history.

Confirmed.

### Brief item 3 — helper shell semantics

`expect_invalid_payload_mode_selector` is byte-for-byte faithful to the
established pattern in this file (`run_parser_file_fixture:186-200`,
`run_parent_capability_fixture:272-289`, `run_capability_mode_fixture:326-341`):

- `local output status` is declared without assignment, so `$?` is not clobbered
  by `local` (the classic `local x=$(...)` masking bug is absent).
- `set +e` precedes the substitution; `status=$?` is the immediately following
  statement; `set -e` restores the ambient state set at `:2`
  (`set -euo pipefail`), which nothing in the file persistently disables.
- `2>&1` is inside the subshell, so the diagnostic is captured, and command
  substitution strips the trailing newline — hence the exact-match comparison
  succeeds.
- False-positive path checked: `$helper_definitions` is the awk-truncated
  prefix of the production helper (`:165-166`, cut at `:445`). I regenerated it
  and confirmed it contains function definitions only — zero top-level
  executable statements — so sourcing cannot itself exit 24 with that
  diagnostic. The status and message can only originate from the resolver.

Confirmed.

### Brief item 4 — no production change, no new regression

Only the test file changed. The production call site
(`launcher-capability.sh:269-272`), the entrypoint mode check (`:360-361`), and
the helper mode check (`:366-367`) are untouched. The two replaced
`run_capability_mode_fixture` invocations lose no meaningful coverage: they had
only been exercising `launcher_capability_owner_mode` against an empty expected
mode, an artifact of the old wiring, while the ten remaining fixtures still
cover the full payload/installed-launcher mode matrix. No new binary, no new
network or filesystem reach, no new privilege. `capability_blob` is a fresh
top-level loop variable with no collision. Confirmed.

## Findings

### P1

None.

### P2

None.

### P3

**P3-8 — the Git-tree pin covers two of the four load-bearing blobs.**
`tests/test-trusted-launcher.sh:308-310` pins `launcher-capability.sh` and
`receipt-authority.sh`. But `launcher_capability_owner_mode "$entry_path" …
"$entry_expected_mode"` (`scripts/ubuntu/launcher-capability.sh:360`) applies to
whichever entrypoint is selected, and `:445` accepts three:
`bootstrap`, `receipt-authority`, and `verify`. `scripts/ubuntu/bootstrap.sh`
and `scripts/ubuntu/verify.sh` therefore carry the identical P3-4 hazard — if
either were ever committed `100644`, that role's payload receipt would fail
closed the same way — and neither is pinned. Both are `100755` in the candidate
tree today, so nothing is broken.
*Safety-relevant: yes* (availability of the trusted path, fail-closed — no
integrity loss). *Recommendation: accept for this commit* — the correction
discharges P3-4 exactly as it was scoped and worded ("pinning both blobs"), and
extending the list is a one-line follow-up, not a defect in what shipped.

**P3-9 — the new assertion carries no rationale comment.**
`tests/test-trusted-launcher.sh:308-313` sits above the mode-contract comment
block at `:315-322` without stating why `100755` is load-bearing. A future
editor reading it as a redundant lint could delete it and silently reopen P3-4.
The `fail_test` message is self-describing, which limits the risk.
*Safety-relevant: no.* *Recommendation: accept*; optionally add a one-line
pointer to `source-attestation.sh:687,780` and `launcher-capability.sh:360-367`.

## Disposition of the prior review's P3 findings

| ID | Prior recommendation | Status in `294b09e6` |
|---|---|---|
| P3-1 | fix | **Fixed.** `:350-372,385-386` assert status 24 and the exact diagnostic; mutations A/B/C/G all now fail the suite. |
| P3-2 | accept | **Accepted, unchanged.** The resolver is still exercised inside `$( ( … ) )` at `:353-361`, so the "aborts the real process, not a subshell" rationale (`launcher-capability.sh:49-50`) remains untested as such. As the prior review predicted, fixing P3-1 partially addresses it: exit-24 propagation is now proven, only the non-subshell context is not. Production call site `:269` is still not in a command substitution. |
| P3-3 | accept | **Accepted, unchanged.** `launcher-capability.sh:271-272` is still unreachable and still correct as belt-and-braces. Not touched by this commit. |
| P3-4 | fix | **Fixed.** `:308-313` pins both named blobs to `100755` at candidate HEAD; mutations D/E/F all fail the suite. Residual scope noted as P3-8. |
| P3-5 | accept | **Accepted, unchanged.** `tests/test-receipt-authority.sh:407-409` untouched; that file is not in this diff. |
| P3-6 | accept | **Accepted, unchanged.** `:379,384` still pass `capability_mode_foreign_uid` as the expected uid rather than chowning; the two remaining foreign-owner fixtures are unaffected by the selector rewrite. |
| P3-7 | accept | **Accepted, unchanged.** `tests/test-receipt-authority.sh:550` untouched; not in this diff. Sibling suite re-run green. |

All seven prior findings are explicitly disposed: two fixed and independently
verified by mutation, five accepted for the reasons the prior review gave, none
regressed.

## Summary

The commit is test-only, minimal, and does exactly what P3-1 and P3-4 asked for.
Both fixes are genuine rather than cosmetic: seven independent mutations — four
against the resolver's fail-closure and three against the committed Git modes —
each turn the suite red, and none of them did so before this commit. The new
helper follows the file's established status-capture idiom precisely and
introduces no false-positive path. No production code, no new dependency, no new
portability constraint. The two new P3s are residual scope and a documentation
nit; neither blocks.

PASS FOR CROSS-REVIEW
