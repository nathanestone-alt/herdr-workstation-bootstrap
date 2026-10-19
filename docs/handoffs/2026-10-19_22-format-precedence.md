herdr-workstation-bootstrap: read docs/handoffs/2026-10-19_22-format-precedence.md in the worktree herdr-workstation-bootstrap-worktrees/issue-22-format-precedence-20261019 and do it.

# Handoff: bootstrap #22, `-f` precedence prints literal `{0}` placeholders

**Goal.** Fix the operator-facing success lines (and the same pattern in three test messages) so every placeholder is formatted. This is cosmetic: no behavior change.
**Controlling issue.** herdr-workstation-bootstrap #22 (https://github.com/nathanestone-alt/herdr-workstation-bootstrap/issues/22). It was filed from STModel-Private #1658, which is closed.

## State of the work

- **Claim.** `TOOLING-CLAIM v1` posted on #22 (issuecomment-6270692147), lane STM-TL1, status ACTIVE, entry SHA `d37f9f2` (origin/main).
- **Worktree.** `/home/nathan/code/herdr-workstation-bootstrap-worktrees/issue-22-format-precedence-20261019`, branch `issue-22/format-precedence`, cut from origin/main `d37f9f2`. The only commit on it is this handoff.
- **Not started.** The source fix, the gate, the landing.
- **The bug.** In PowerShell, `-f` binds tighter than `+`. So `("a {0} " + "b {4}" -f $x, ...)` formats only the second string, and the first string's placeholders print literally. The issue body shows the output from the real #1658 Windows mint.
- **Hits on origin/main `d37f9f2`.** Found by scanning every `.ps1` for a line ending in `" +` whose next line carries `-f`:

  | File | Line | Kind | Named in #22? |
  |---|---|---|---|
  | `scripts/windows/Install-WindowsReceiptAuthority.ps1` | 56 | Check success `Write-Host` | yes |
  | `scripts/windows/Install-WindowsReceiptAuthority.ps1` | 113 | Install success `Write-Host` | yes |
  | `tests/Test-HerdrWindowsSecurityIntegration.ps1` | 625 | `Assert-True` failure message | no |
  | `tests/Test-HerdrWindowsSecurityIntegration.ps1` | 638 | `Assert-True` failure message | no |
  | `tests/Test-WindowsAuthorityNative.ps1` | 235–237 | native PASS `Write-Host` (three strings) | no |

## Decisions already made

- The user directed this arc on 2026-10-19 with `/bshandoff bootstrap #22`. That covers building it and running the independent gate (D-GOV-18).
- **It does NOT cover merging or pushing.** The #1658 words "phase b and on pass" were scoped to #1658 only. After the gate returns PASS, ask the user for merge-and-push authorization and wait.
- The fix shape is the one #22 proposes: wrap the concatenation, `(("..." + "...") -f ...)`, or join the pieces into one string. Pick one and use it at every hit.

## Open questions

- **Fold in the three test-file hits?** My recommendation is yes: they are the same defect class, the fix is identical, and the failure messages lose their diagnostics today. If the user prefers the issue's literal scope, only the two installer lines change. Do not stop to ask. Fold them in and say so in the commit and in the #22 comment.

## Next steps

1. `cd` into the worktree. Run `git log --oneline -2` and `git fetch origin`, and check that `origin/main` is still `d37f9f2` (if it moved, merge origin/main first). Re-read #22's comments (`gh issue view 22 -R nathanestone-alt/herdr-workstation-bootstrap --comments`). Any newer claim from another lane is a hard stop.
2. **Edit the five sites.** Re-scan with the awk check above to confirm zero hits remain. Parse each changed file with `/usr/bin/pwsh -NoProfile -Command '[System.Management.Automation.Language.Parser]::ParseFile(...)'`.
3. **Prove the output** on Ubuntu with `/usr/bin/pwsh`. Evaluate each changed format expression with dummy values and assert the result contains no `{digit}` placeholder. A small scratch script under the session scratchpad is enough; do not commit it.
4. **Run the source fixture suite:** `/usr/bin/pwsh -NoProfile -File tests/Test-WindowsReceiptAuthority.ps1`. The #1658 r1 gate reported 64 tests on Linux.
5. Commit on the branch with the subject `windows: format every placeholder in the authority success lines (bootstrap issue 22)`. Keep "fix", "close" and "resolve" out of the message entirely: the commit-msg hook rejects closing keywords next to an issue number.
6. **Gate it** through `st-ledger-dispatch`, with the ledger in STModel-Private.
   - `export COORD_ROOT=/home/nathan/code/STModel-Private/.coord`.
   - Copy `/home/nathan/code/STModel-Private/.coord/briefs/tl1-1658-bootstrap-gate-r3.md` to `tl1-22-bootstrap-gate-r1.md` and adapt it:
     - node id, scope `git diff d37f9f2..<candidate>` (re-derive the base with `git merge-base`), the changed files, and the verdict path `audit/findings/2026-10-19_bootstrap-22_format-precedence_gate_r1.md`;
     - the bounded question: does any changed line alter behavior beyond the formatted text, and does any `{n}` remain unformatted?
     - Drop the native herdr-win item (these lines are never reached by the native suite), and drop `network_access`.
   - Then run `coord.py check-brief`.
   - Launch exactly like r3: provider OpenAI, model gpt-6.1-sol, effort high, tier priority, `--sandbox workspace-write`, `--codex-executable /home/nathan/.local/bin/codex`, `--cwd <worktree>`, timeout 2400, retry window 2640, watchdog cap 2640.
   - Arm the background watcher (exit 0 = PASS, 10 = BLOCK).
7. On PASS, commit the verdict on the branch, then **stop and ask the user to authorize merge and push**. Give them the one-line summary and the verdict path.
8. **Once authorized:**
   - `git merge --no-ff` into bootstrap `main` from the main checkout `/home/nathan/code/herdr-workstation-bootstrap`.
   - In the same merge, `git mv` this handoff to `docs/handoffs/_resolved/`.
   - Write `.coord/authorizations/<date>-bootstrap-22-<head9>-main-push.md` in STModel-Private, generated from `git log --oneline origin/main..main`. guard-git needs it.
   - Push with `STMODEL_PUSH_AUTHORIZATION=<record> git -C /home/nathan/code/herdr-workstation-bootstrap push origin main`.
   - Remove the worktree and branch, post the release comment on #22, then close #22, citing the verdict and the merge SHA.
9. No host step and no re-mint: the installed Windows authority is unaffected. Save down: update the STM-TL1 memory note.

## Suggested skills

`st-ledger-dispatch` (gate node, step 6); `handoff` / `bshandoff` at the save-down.

## Traps

- **`-f` precedence also bites the fix itself.** Verify by evaluating the expression (step 3), not by reading it.
- **Herdr-win clones must use `core.autocrlf=false`,** or the blob hashes stop matching. This only matters if you clone there; this arc does not need herdr-win.
- **`st-land` is STModel-only.** Bootstrap lands by hand (step 8), and guard-git still demands the authorization record.
- **Never type a SHA a tool has not printed.** Compute the merge-base; do not copy it from this doc if origin/main has moved.
- **Read worker returns bounded** (`sed -n 1,40p .coord/nodes/<id>/return.md | cut -c1-300`). Strip `RETURN-TOKEN` before committing anything copied from a return.
