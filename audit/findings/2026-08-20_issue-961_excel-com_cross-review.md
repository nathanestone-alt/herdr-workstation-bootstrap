# Issue #961 — independent cross-review of the Windows Excel COM correction

Workflow: `[WF:254fb59b]`
Request relay: `[HR:6b3f8219]`
Reviewer role: STM-T-C1 (independent Opus cross-review, read-only)
Resolved route: provider `Anthropic`, model `opus`, reasoning effort `high`, service tier `normal`

## 1. Target, state, and scope proofs

| Item | Value |
| --- | --- |
| Worktree | `/tmp/herdr-bootstrap-961-review-70cdb67` |
| `git remote -v` origin | `https://github.com/nathanestone-alt/herdr-workstation-bootstrap.git` |
| HEAD before / after | `70cdb679b620debf5cbeed2ea554718645b86841`, detached, unchanged |
| `git status --porcelain` before / after | empty (clean), unchanged |
| Base | `d9b6d38ae65921bc0f4def63322ac51f580adf8f` |

`git diff --numstat d9b6d38..70cdb67` — **three files, 15 insertions / 3 deletions**:

```
2   2   scripts/Validate-Repository.ps1
1   1   scripts/windows/HerdrExcelJobRunner.ps1
12  0   tests/Test-HerdrExcelJobRunner.ps1
```

`git diff --check` → clean. Read-only throughout: no edit, commit, deploy, Windows/Excel run,
worktree creation, worker dispatch, GitHub contact, push, merge, or downstream leg. The only write
was this artifact.

## Verdict

The correction is **valid, minimal, correctly ordered, and non-vacuously tested**. No P1 or P2
finding. Three P3s, all dispositioned non-blocking.

## 2. `$excel.Calculate()` is a valid COM method and is correct for this instance

**The object model confirms the reported failure.** `Application.Calculate` is a documented Excel
COM method ("calculates all open workbooks"); `Worksheet.Calculate` and `Range.Calculate` also
exist. **`Workbook` exposes no `Calculate` member** — its calculation-adjacent methods are
`RefreshAll`, `UpdateLink`, and `SetLinkOnData`. So an IDispatch lookup of `Calculate` on the
`System.__ComObject` returned by `Workbooks.Open` necessarily fails, exactly as the Windows
PowerShell evidence showed. The base code was calling a method that does not exist.

**Correct for this isolated single-workbook Application.** `Application.Calculate` recalculates every
open workbook in *that* Application instance, and here that set is provably a single workbook:

- `HerdrExcelJobRunner.ps1:755` — `New-Object -ComObject Excel.Application` creates a dedicated
  Excel process (Excel's CreateObject spawns a new instance rather than attaching to a running one);
- `:762` — `$excel.Workbooks.Open($InputPath, 0, $false)` is the only `Workbooks.Open` on this
  Application (verified: 1 occurrence in the file);
- `:760` and `:765` — `Assert-HerdrExcelProcessIdentity -Excel $excel` binds the Application to one
  verified PID via `$Excel.Hwnd`, so it cannot silently be a shared or substituted instance.

Application-level is also the *semantically correct* level here: it recalculates the whole workbook
including cross-sheet dependencies in one pass, which is what a "recalculate the model" job needs,
whereas per-worksheet `Calculate` would require iteration and dependency-order care. See P3-1 for the
one residual scope nuance.

## 3. Ordering is exactly as required

`Invoke-HerdrExcelRecalculate`, `scripts/windows/HerdrExcelJobRunner.ps1`:

| Step | Line | Statement |
| --- | --- | --- |
| events disabled | `:757` | `$excel.EnableEvents = $false` |
| macros disabled | `:758` | `$excel.AutomationSecurity = 3` |
| link prompt disabled | `:759` | `$excel.AskToUpdateLinks = $false` |
| pre-open identity proof | `:760` | `Assert-HerdrExcelProcessIdentity -Excel $excel` |
| **open with `UpdateLinks=0`** | `:762` | `$workbook = $excel.Workbooks.Open($InputPath, 0, $false)` |
| **connections disabled** | `:763` | `Disable-HerdrExcelConnections -Workbook $workbook` |
| **Application Calculate** | `:764` | `$excel.Calculate()` |
| **post-calc identity proof** | `:765` | `Assert-HerdrExcelProcessIdentity -Excel $excel` |
| **`SaveCopyAs`** | `:767` | `$workbook.SaveCopyAs($ResultPath)` |
| cleanup | `:768`, `:770`, `:777`–`:778` | `Close($false)`, `Quit()`, `finally` guards |

The security-relevant adjacency is preserved: connections are disabled at `:763` **before** any
recalculation at `:764`, so the switch to Application-level calculation cannot trigger a data-connection
refresh. Link suppression likewise precedes it, at open time.

## 4. No weakening of any prior control

The production change is a **single token on a single line** — the extracted function diff against
base is exactly:

```
25c25
<         $workbook.Calculate()
---
>         $excel.Calculate()
```

Every other line of `Invoke-HerdrExcelRecalculate` is byte-identical to `d9b6d38`, and
`Invoke-HerdrExcelJob` is untouched. Verified intact at the candidate:

| Control | Evidence |
| --- | --- |
| interactive-user / session proof | both `Assert-HerdrExcelProcessIdentity -Excel $excel` calls present (2 occurrences), `:760` and `:765` |
| source immutability | `$workbook.SaveCopyAs($ResultPath)` `:767` + `Close($false)` `:768`; job-level last-mile and canonical snapshot re-checks untouched |
| bridge denial | `Assert-HerdrBridgeCannotWrite` unchanged; `Invoke-HerdrExcelJob` outside the diff |
| ACL protection (base correction) | `Protect-HostOwnedTree -TargetPath $reviewJobPath` (1), `HostOwnedTreeProtector` (4), `HerdrHostOwnedAclPolicy.ps1` (1) — all present |
| link policy | `Workbooks.Open($InputPath, 0, $false)` (1), `AskToUpdateLinks = $false`; forbidden `$workbook.UpdateLinks = 0` still enforced at `tests/Test-HerdrExcelJobRunner.ps1:276` |
| macro policy | `AutomationSecurity = 3` `:758`; `RunAutoMacros` still forbidden |
| connection policy | `Disable-HerdrExcelConnections` `:763`; `EnableRefresh`/`RefreshOnFileOpen` markers intact; `RefreshAll` still forbidden |

No regression interaction with the base ACL correction: that code lives in `Invoke-HerdrExcelJob`
(`:939`–`:945`), which this diff does not touch, and its own tests still pass.

## 5. The regression is non-vacuous and pins ordering, not presence

I evaluated the two shipped assertions (`tests/Test-HerdrExcelJobRunner.ps1:264`–`:275`) verbatim
against each commit, and then against two order-only mutations of the candidate in which **every
token remains present**:

```
BASE d9b6d38 (defect)              forbid-$workbook.Calculate=False ordering=False  (conn=39564 calc=-1    ident=-1    save=39828)
CANDIDATE 70cdb67                  forbid-$workbook.Calculate=True  ordering=True   (conn=39564 calc=39622 ident=39649 save=39825)
CANDIDATE, calc moved after save   forbid-$workbook.Calculate=True  ordering=False  (conn=39564 calc=39840 ident=-1    save=39798)
CANDIDATE, calc before connections forbid-$workbook.Calculate=True  ordering=False  (conn=39591 calc=39564 ident=39649 save=39825)
```

- **Rejects `$workbook.Calculate()`**: the forbid assertion is `False` on the base — it fails there.
- **Requires `$excel.Calculate()`**: absent → `calculateIndex = -1` → `calculateIndex > connectionIndex`
  is false → the ordering assertion fails (base row).
- **Pins ordering, not presence**: both mutations keep all four anchors in the file yet fail. Moving
  the call after `SaveCopyAs` additionally drives `postCalculateIdentityIndex` to `-1`, because the
  identity search is offset from `$calculateIndex` rather than searched from position 0 — a
  deliberate and correct choice, since `Assert-HerdrExcelProcessIdentity -Excel $excel` occurs twice
  (`:760`, `:765`) and an unoffset search would have matched the *pre-open* call and made the
  assertion vacuous.

Anchor cardinality supports the construction: `$excel.Calculate()` = 1,
`$workbook.Calculate()` = 0, `Disable-HerdrExcelConnections -Workbook $workbook` = 1,
`$workbook.SaveCopyAs($ResultPath)` = 1, `Assert-HerdrExcelProcessIdentity -Excel $excel` = 2 (the
only non-unique anchor, handled by the offset).

## 6. Validator markers are correct, non-vacuous, and weaken nothing

Four markers added — Required `'$excel.Calculate()'` and Forbidden `'$workbook.Calculate()'` on the
runner row (`Validate-Repository.ps1:275`), plus the two assertion messages on the test row (`:277`).
All four are absent at base and present at the candidate:

```
'$excel.Calculate()'                                             validator-base=False validator-cand=True
'$workbook.Calculate()'                                          validator-base=False validator-cand=True
Workbook-level Calculate is invalid and must not return.         validator-base=False validator-cand=True
Application-level Excel calculation call or ordering is missing. validator-base=False validator-cand=True
```

The Forbidden entry is non-vacuous in the direction that matters: the base runner **does** contain
`$workbook.Calculate()` and does **not** contain `$excel.Calculate()`, so both markers would flip the
validator to failure on the defective commit. No false positive exists at the candidate — the file's
other `$workbook.` members are `SaveCopyAs` and `Close`.

I parsed both commits' complete `$contentAssertions` arrays and diffed every row:

```
rows in base=24  rows in candidate=24  weakened-or-removed=0
```

No row was dropped and no `Required` or `Forbidden` entry was lost from any of the 24 rows. Net
additions are exactly the four markers above.

## 7. Commands, results, and platform skips

| Command | Exit | Output |
| --- | --- | --- |
| `git diff --numstat d9b6d38..70cdb67` | 0 | three files, 15 insertions / 3 deletions |
| `git diff --check d9b6d38..70cdb67` | 0 | clean |
| `pwsh -NoProfile -File tests/Test-HerdrExcelJobRunner.ps1` | 0 | `Herdr Excel job runner regression test passed.` |
| `pwsh -NoProfile -File tests/Test-HerdrReviewStaging.ps1` | 0 | `Herdr review staging regression test passed.` |
| `pwsh -NoProfile -File tests/Test-HerdrWindowsSecurityIntegration.ps1` | 0 | runspace + race-fixture PASS; Windows fixtures skipped |
| `pwsh -NoProfile -File tests/Test-HostOwnedAclPolicy.ps1` | 0 | `SKIP: Windows ACL policy checks require Windows security principals.` |
| `pwsh -NoProfile -File tests/Test-HerdrWindowsPathPolicy.ps1` | 0 | `SKIP: Windows native path-policy checks require Windows.` |
| `pwsh -NoProfile -File scripts/Validate-Repository.ps1` | 0 | `Repository validation passed.` |

**Platform skips, reported precisely** (all Ubuntu, all expected):

- Python syntax validation — Python unavailable.
- `SKIP: Windows ACL policy checks require Windows security principals.` (`Test-HostOwnedAclPolicy.ps1`)
- `SKIP: Windows path-policy checks require Windows path semantics.` (`Test-ExchangePathPolicy.ps1`)
- `SKIP: Windows native path-policy checks require Windows.` (`Test-HerdrWindowsPathPolicy.ps1`, not invoked by the validator)
- `SKIP: Windows handle, ACL, process-identity, and Excel COM integration fixtures require Windows.` (`Test-HerdrWindowsSecurityIntegration.ps1`)
- The disposable real-Excel canary is additionally gated at `Test-HerdrWindowsSecurityIntegration.ps1:378`
  on `HERDR_RUN_EXCEL_CANARY=1`.

No Windows runtime, Excel COM, or OneDrive behavior was executed and none is claimed.

## 8. Findings

**P1 (blocking): none.**
**P2 (blocking): none.**

### P3-1 — `Application.Calculate` also covers any auto-loaded workbook in the instance

`HerdrExcelJobRunner.ps1:764` recalculates *all* workbooks open in the Application. That set is the
single target workbook in normal operation, but an automation-launched Excel can, in some host
configurations, additionally load XLSTART or add-in workbooks, which would then be recalculated too.

**Disposition: accepted, non-blocking.** The blast radius is inert here: only `$workbook` is written
out (`SaveCopyAs`, `:767`), nothing else is saved, `Close($false)`/`Quit()` discard all in-memory
state, and macro and event side effects are already neutralised by `AutomationSecurity = 3` (`:758`)
and `EnableEvents = $false` (`:757`). A narrower `$workbook.Worksheets | ForEach-Object { $_.Calculate() }`
would be more precisely scoped but more code and weaker on cross-sheet dependency ordering.
Application-level is the right trade here; recording the nuance so it is a known property rather than
an assumption.

### P3-2 — the ordering assertion pins the post-open chain only

`tests/Test-HerdrExcelJobRunner.ps1:266`–`:275` pins connections → calculate → identity → `SaveCopyAs`,
but the pre-open settings remain **presence-only** in the marker loop at `:261`. A regression that
moved `$excel.AutomationSecurity = 3` (`:758`) or `$excel.EnableEvents = $false` (`:757`) to *after*
`$excel.Workbooks.Open($InputPath, 0, $false)` (`:762`) would keep every marker present and pass the
suite, while allowing `Auto_Open` to run at open time.

**Disposition: accepted, non-blocking.** The gap is pre-existing, not introduced by this diff, and
the real-Excel canary would catch it at runtime — `Test-HerdrWindowsSecurityIntegration.ps1:405`–`:425`
plants an `Auto_Open` macro and asserts it did not execute. The fix is cheap and uses the idiom this
diff just introduced: all four pre-open anchors are unique in the file
(`$excel.EnableEvents = $false`, `$excel.AutomationSecurity = 3`, `$excel.AskToUpdateLinks = $false`,
`$excel.Workbooks.Open($InputPath, 0, $false)` — each exactly 1 occurrence), so extending the index
comparison upward is four more terms.

### P3-3 — no test executes the corrected call; precise Windows-only residue

`Invoke-HerdrExcelRecalculate` is bypassed in every Ubuntu test — `Invoke-HerdrExcelJob` substitutes
`$ExcelInvoker` in TestMode — so all coverage of this change is static text analysis. The only
runtime proof path is `Test-HerdrWindowsSecurityIntegration.ps1:415`, which calls
`Invoke-HerdrExcelRecalculate` directly but is gated on Windows **and** `HERDR_RUN_EXCEL_CANARY=1`
(`:378`).

**Unresolved, Windows-only:** that `Application.Calculate` succeeds against the target host's Excel
build, and that recalculated values are what `SaveCopyAs` emits.

**Disposition: accepted, non-blocking** — this is inherent to the change, not a defect in it, and the
static tripwires are strong (§5). Worth flagging that this is the *second* COM defect in this
seven-line block found only by executing real Excel; running the canary as part of commissioning
would convert this class of finding from post-hoc to pre-merge.

## Note on a prior statement of mine

In my earlier cross-review of the `UpdateLinks` correction I described the then-unchanged
`$workbook.Calculate()` line as recalculating worksheet formulas. The Excel object model has no
`Workbook.Calculate`; that characterisation was wrong. The line was pre-existing and outside that
diff, so the verdict there is unaffected — and the correction under review here is the right fix.

## Final state proof

```
git rev-parse HEAD        -> 70cdb679b620debf5cbeed2ea554718645b86841
git symbolic-ref -q HEAD  -> (detached)
git status --porcelain    -> (empty)
```

Unchanged from the pre-review capture.

## Rationale

`Workbook` has no `Calculate` member, so the base line could never succeed; `Application.Calculate`
is the documented method and, on a freshly created Application whose only open workbook is the
target and whose process identity is asserted on both sides of the call, it recalculates exactly that
workbook. The change is one token, leaves every prior control byte-identical, and preserves the
security-critical adjacency of connection disabling before recalculation. The regression is a real
ordering tripwire, not a presence check — I drove the shipped assertions through the base defect and
two order-only mutations and watched them fail in all three. All 24 validator rows survive intact
with exactly four additive markers, each proven to flip the validator on the defective commit. The
three P3s concern scope nuance, assertion depth, and inherent Windows-only residue, not correctness.

PASS FOR CROSS-REVIEW
