VERDICT: PASS
MERGE-OK

# Receipt no-expiry independent gate, round 1

Base `579619e7a485289ce0c285f791f35720b98c490d`.
Head `bdc8e1bdc1a96afc67b9203ee547b086d04509a9`.
Reviewed scope `579619e..bdc8e1b`, with specific review of the previously unreviewed `c09c174..6fa56bc` timestamp correction and the design B commit `5a6013c..bdc8e1b`.
Entry verification exited 0 with `NOT_APPLICABLE` for the headless node.

## Suite results

The shell suites do not emit total assertion counts. Their counts below are completed suites; the receipt suite separately emits the 14-case expiry count. Base reruns are conditional on candidate failures after the authorized scratch adjustment. All required candidate suites completed successfully. The verify-path comparator also passed, so candidate failures and base failures are both empty.

| Suite | Host | Base | Candidate |
| --- | --- | --- | --- |
| `tests/test-receipt-authority.sh` | herdr-ubuntu | Not required | 1/1 suite; 14/14 expiry cases; exit 0 |
| `tests/test-verify-path.sh` | herdr-ubuntu | 1/1 suite; exit 0; 257.1 s | 1/1 suite; exit 0; 270.4 s |
| `tests/test-trusted-launcher.sh` | herdr-ubuntu | Not required | 1/1 suite; exit 0 |
| `tests/Test-WindowsReceiptAuthority.ps1` | herdr-ubuntu, `/usr/bin/pwsh` | Not required | 64/64 assertions; exit 0 |
| `tests/Test-WindowsReceiptAuthority.ps1` | herdr-win, pwsh 7.6.7 | Not required | 87/87 assertions; exit 0 |

The receipt and verify suites initially stopped at read-only `/tmp` allocations. They ran from an archive of `bdc8e1b` under the granted scratch directory, with literal `/tmp` references redirected there. Source attestation clears `TMPDIR`, so its four argument-free `mktemp` calls also received explicit scratch templates. These are temporary-path substitutions only, in the scratch copy. The successful launcher run used the unmodified worktree. A scratch launcher attempt stopped because an archive has no Git tree; the unmodified worktree run passed.

The first fully redirected verify-path run hit the local runner's 240-second limit before its final summary. Candidate and base were then run with matching 600-second bounds in separate scratch copies. This was a runner timeout, with no reported assertion failure.

Root-only Ubuntu production-ownership/payload cases and bundle-owner substitution were skipped because uid 1000 cannot run them. No live launcher verification or production installer ran.

SSH initially supplied an administrator token. The fixture guard refused that token before creating scratch. Linked-token launches were unavailable in that SSH logon. The successful run used a SAFER normal-user token, created with `SaferCreateLevel(0x20000)` and `SaferComputeTokenFromLevel`, and printed `ELEVATED=False`. Candidate `scripts/windows` and `tests` files came directly from Git blobs in a fresh `%TEMP%\stm1658-gate-<timestamp>` directory. The native transaction fixture executed against scratch files. Its existing substitutions cover host-owner ACL operations, ancestor handles, and uv identity discovery; production elevation and commissioning paths were reviewed in code. The remote run exited 0 and printed `SCRATCH_REMOVED=True`.

## Syntax and whitespace

`bash -n` passed for both changed shell files. PowerShell AST parsing passed for all eight changed `.ps1` files. `git diff --check 579619e..bdc8e1b` exited 0.

## Bounded-question answer

No contract-refused receipt/pair acceptance or unsafe `-Replace` publication was found on the changed surface.

- Ubuntu emits schema 1, `expiry_policy:"none"`, and explicit JSON null at `scripts/ubuntu/receipt-authority.sh:1879`. Its validator requires the exact policy, an explicit expiry field, and JSON null; legacy expiry must be a canonical UTC string that GNU date accepts and must be in the future (`:1945`). The receipt always reaches this validator, and a companion carrying either expiry field also reaches it (`:1994`). Existing digest, provenance, identity, and file-security checks precede expiry (`:1956`).
- Windows checks raw JSON types with `JsonDocument`, accepts only the exact string `none` with JSON null, and otherwise requires an exact UTC timestamp and future age (`scripts/windows/WindowsReceiptAuthority.ps1:61`). Check applies it to the receipt and any companion carrying expiry fields (`:526`). New receipt construction keeps schema 1 and emits policy/null (`:335`). The `c09c174..6fa56bc` delta replaces the coerced DateTime-to-string read with this raw JSON reader; invariant-culture `ParseExact` and explicit UTC styles retain the original timestamp across locales (`:69`, `:91`).
- The producer requires administrator elevation (`scripts/windows/Install-WindowsReceiptAuthority.ps1:2`, `:35`), permits `-Replace` only with Install (`:38`), obtains the live runtime process/creation/session/SID proof (`:48`), validates all five commissioning values (`:63`), and checks the source commit, clean source, manifest, payload, allowlist, producer script, and measured identities before publication (`:74`). Replacement branches only after constructing that generation (`:103`).
- Replacement calls the ordinary existing-pair Check with only the legacy age comparison skipped (`scripts/windows/WindowsReceiptAuthority.ps1:647`, `:689`). That Check retains path, owner/ACL, live-token namespace access, receipt digest, pair identity, role hash, executable hash, and uv resolution checks (`:485`). Malformed legacy timestamps and invalid policies remain refused even with the skip (`:83`, `:101`).
- Stage writes, ACL protection, exact-byte hashes, pair coherence, expiry, and runtime-access checks finish before publication (`:662`). The backup is a timestamp/GUID child of Issue961 (`:650`). A single transaction moves both old files into the backup and both new files into place (`:625`), removes the emptied stage and commits (`:604`); failure rolls back before closing the transaction (`:614`). The 87-assertion native run covers pre-publication rejection, held-reader failure, fourth-move rollback, exact backup bytes, and successful replacement (`tests/Test-WindowsReceiptAuthority.ps1:288`). First install continues to refuse an existing pair (`scripts/windows/WindowsReceiptAuthority.ps1:429`).

## Protected surfaces

Compared `5a6013c..bdc8e1b`. Ubuntu receipt-authority bytes before receipt construction, including identity and sealed-bundle logic, are identical. Its entire `--install` tail is identical, retaining receipt publication, digest calculation, then authority publication (`scripts/ubuntu/receipt-authority.sh:2000`). Windows identity-measurement and first-install functions are identical. Only the expiry reader, receipt constructor, and expiry dispatch in Check changed among existing Windows authority functions. The ACL-policy and runtime-token files are byte-identical, as are Ubuntu `bootstrap.sh` and `verify.sh`. New replacement code uses the existing ACL policy. No protected-surface change was found.

## Findings and disposition

No P1, P2, or P3 findings. All brief acceptance items are answered. Recommend merge of this candidate. This is a gate recommendation; deployment and the final mint were outside this review.
The verdict is left untracked for the orchestrator to commit. The tracked worktree remains unchanged.

Logs are under `/home/nathan/.cache/stm-scratch/STModel-Private-a9176bfdd476d72d/tl1-1658-bootstrap-gate-r1-e7835763a4252708/gate-logs/`: `receipt-redirected.log`, `verify-candidate-complete.log`, `verify-base-complete.log`, `verify-comparison-summary.txt`, `launcher.log`, `windows-linux.log`, and `windows-herdr-win-limited.log`. `protected-surfaces.txt` records unchanged protected-file blob identities; `scratch-redirection.txt` lists files with literal temporary-path substitutions. These scratch logs are supporting evidence, not a substitute for this report.
