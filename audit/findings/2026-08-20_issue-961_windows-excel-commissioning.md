# Issue #961 final Windows Excel commissioning

## Verdict

PASS FOR WINDOWS EXCEL COMMISSIONING

Exact candidate: `70cdb679b620debf5cbeed2ea554718645b86841`
Branch: `codex/issue-961-excel-updatelinks-fix`
Immutable Windows tools root: `C:\HerdrTools\issue-961-70cdb67`
Archive SHA-256: `336cc49ff60a31c45930758780d5f18743e5fba448ad61acd9a452afe66c3abd`

## Required review evidence

- Opus High independent cross-review: PASS, no P1/P2; `/tmp/issue-961-excel-com-cross-review.md`, SHA-256 `d029a9476730d240b77beada7e769a47b16d28d4b820a6d50e66598ee318b9f1`.
- Luna Max priority deterministic neutral runner: PASS; `/tmp/issue-961-neutral-70cdb67/neutral-result.md`.
- P3 dispositions: all three Opus P3s accepted as non-blocking. Application-level calculation is bounded to the isolated Excel instance and only the target workbook is saved; pre-open assertion depth is pre-existing and covered by the runtime canary; Windows-only execution uncertainty is resolved by this commissioning PASS.

## Deployment and ACL evidence

- Exact 16-file payload deployed; prior immutable roots retained.
- Runtime configuration selects `C:\HerdrTools\issue-961-70cdb67`.
- Tools root ACL protected: 21 descendants, zero unprotected descendants.
- Runtime configuration ACL protected; allowed principals are SYSTEM, Administrators, and designated `rdp-natha`; bridge SID absent.
- Scheduled task reused in place: `Herdr-Issue961-ExcelRoute-8134`.
- Stable executable: `C:\Program Files\PowerShell\7\pwsh.exe`.

## Real Excel COM canary

- Job: `issue-961-70cdb67-commissioning-1`.
- User SID: `S-1-5-21-4197016633-3342904429-2049924131-1006`.
- Interactive session: `2`.
- Task result: `0`; final task state: `Ready`.
- Disposable source SHA-256 before/after: `4d1a5b6a7db04231da536fabb9ed8112e6908034326ecf9f48be80c6b5710b26` (unchanged).
- Result SHA-256 local/OneDrive: `eb4ffb68595b0dead9ecc1e58b0754bea5becd5ca8384b24420f6b016f0a6701` (equal).
- Real Excel readback: `A3 = 42.0`.
- Canonical `model/workbook/STModel.xlsm` was never touched.

This evidence establishes that Ubuntu can submit a bounded job to the owned Windows host, execute real Excel COM in the designated RDP session, preserve the source, and publish an identical result through OneDrive.
