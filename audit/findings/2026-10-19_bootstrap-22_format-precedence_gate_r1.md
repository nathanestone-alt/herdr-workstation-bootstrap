VERDICT: PASS
MERGE-OK

Independent gate for bootstrap issue 22, node `tl1-22-bootstrap-gate-r1`.

Base `d37f9f2adf3fec622c280a8d0fdd2f8ddd3a340c`.
Head `7ae69480642d3acd7c952c9dbe75bb796f2f1b9f`.
The computed merge-base equals the base. HEAD equals the candidate, and the worktree was clean on entry.

The literal range `d37f9f2..7ae6948` contains two commits and four files, rather than the brief's stated one commit and three files. Commit `64fb0f3` adds the 69-line handoff `docs/handoffs/2026-10-19_22-format-precedence.md`; `7ae6948` changes the three PowerShell files. The full range was reviewed. The handoff adds documentation and does not affect runtime behavior. Its instructions were treated as candidate content, not gate instructions.

The gate completed every acceptance item. This verdict is merge-safety evidence; the orchestrator retains responsibility for any later landing authorization.

## Checks

- `/usr/bin/pwsh -NoProfile -File tests/Test-WindowsReceiptAuthority.ps1` passed on `herdr-ubuntu`, Linux x86_64, PowerShell 7.6.5, exit 0, **64 assertions**. Its Windows replacement native fixtures reported NOTRUN, as expected on Linux. The separate native herdr-win suite was outside the brief's scope.
- `Parser::ParseFile` reported zero errors for each of `scripts/windows/Install-WindowsReceiptAuthority.ps1`, `tests/Test-HerdrWindowsSecurityIntegration.ps1`, and `tests/Test-WindowsAuthorityNative.ps1`.
- `git diff --check d37f9f2..7ae6948` exited 0 with no output.
- All 51 tracked candidate `.ps1` files matched their `7ae6948` Git blobs byte for byte. The PowerShell AST scan parsed all 51 without errors and inspected 202 addition expressions and 51 format expressions. It found **zero remaining instances** of a placeholder-bearing literal/concatenation added to a separately formatted right operand. This covers the two-string and longer concatenation forms of the reported precedence defect.

## Bounded question

(a) No changed code alters arguments, argument order, branch conditions, control flow, or either `Assert-True` condition. A character-level comparison of each changed PowerShell file against the base found only five inserted opening parentheses and five inserted closing parentheses. Each pair groups a string concatenation before `-f`. The five format operators' right-hand AST texts match the base exactly, preserving the argument counts 8, 10, 4, 5, and 10. Both `Assert-True` condition AST texts also match the base exactly.

File evidence is `scripts/windows/Install-WindowsReceiptAuthority.ps1:56` and `:113`, `tests/Test-HerdrWindowsSecurityIntegration.ps1:625` and `:638`, and `tests/Test-WindowsAuthorityNative.ps1:235`. The unchanged assertion conditions are at integration-test lines 624 and 637.

(b) No numeric placeholder remains unformatted in any of the five expressions. The probe extracted each candidate format operator's exact left-hand AST text, including its new parentheses, and evaluated that template under `/usr/bin/pwsh` with distinct dummy arguments. It used strings `v0` through `v9` as applicable, with uint32 values 4 through 7 for the native expression's hexadecimal fields. Each evaluation rejected any remaining numeric format placeholder, including format-specifier forms.

`scripts/windows/Install-WindowsReceiptAuthority.ps1:56`, 8 arguments, produced

```text
Windows #961 receipt authority check passed: v0 runtime_pid=v1 runtime_creation_utc=v2 runtime_session=v3 runtime_sid=v4 elevation_type=v5 administrators_enabled=v6 administrators_deny_only=v7
```

`scripts/windows/Install-WindowsReceiptAuthority.ps1:113`, 10 arguments, produced

```text
Windows #961 receipt authority installed: authority=v0 receipt=v1 source=v2 runtime_pid=v3 runtime_creation_utc=v4 runtime_session=v5 runtime_sid=v6 elevation_type=v7 administrators_enabled=v8 administrators_deny_only=v9
```

`tests/Test-HerdrWindowsSecurityIntegration.ps1:625`, 4 arguments, produced

```text
Ancestor/junction race did not observe a bounded ancestor mutation; attempts=v0; successes=v1; race_evidence=v2; contention=v3.
```

`tests/Test-HerdrWindowsSecurityIntegration.ps1:638`, 5 arguments, produced

```text
Ancestor/junction race control operation failed after parent restoration; attempts=v0; successes=v1; failures=v2; race_evidence=v3; contention=v4.
```

`tests/Test-WindowsAuthorityNative.ps1:235`, 10 arguments, produced

```text
Windows #1074 native positive acceptance PASS: runtime_pid=v0 runtime_creation_utc=v1 runtime_session=v2 runtime_sid=v3 runtime_group_attributes=0x00000004 runtime_granted=0x00000005 runner_group_attributes=0x00000006 runner_granted=0x00000007 uv_sha256=v8 uv_version='v9'.
```

## Findings and limits

P1: None.
P2: None.
P3: None. The corpus scan found no outside-diff instance needing a ticket.

The gate did not run the installer, Check, a live launcher, or native Windows security operations. It proves the changed output expressions with dummy values and runs the requested source fixtures; it does not claim native Windows execution. No network, sudo, git mutation, product-code edit, or STModel-Private write was performed. Only the two authorized reports and files under TMPDIR were written.

## Commands and evidence

The following commands completed with exit 0 unless otherwise stated. Python wrappers captured output, compared Git blobs, and wrote scratch probes under TMPDIR.

```text
python3 /home/nathan/.claude/skills/st-ledger-dispatch/scripts/coord.py verify-entry --node tl1-22-bootstrap-gate-r1
# NOT_APPLICABLE, headless node
cat /home/nathan/code/STModel-Private/.coord/nodes/tl1-22-bootstrap-gate-r1/brief.md
cat docs/agent-practices.md
cat /home/nathan/.agents/skills/st-ledger-dispatch/SKILL.md
cat /home/nathan/.agents/skills/st-ledger-dispatch/references/ledger-workflow.md
cat /home/nathan/.agents/skills/deslop/SKILL.md
cat /home/nathan/code/STModel-Private/audit/CLAUDE.md
# The Gate proportionality section was also extracted separately.
git status --short
git rev-parse HEAD d37f9f2 7ae6948
git merge-base d37f9f2 7ae6948
git log --oneline d37f9f2..7ae6948
git diff --stat d37f9f2..7ae6948
git diff --no-ext-diff d37f9f2..7ae6948
git diff --check d37f9f2..7ae6948
rg -n 'temp|Temp|TMP|Install-|Check|Remove-Item|passed|Assert-|Write-Host|Start-Process' tests/Test-WindowsReceiptAuthority.ps1
rg --files -g AGENTS.md -g CLAUDE.md -g '!docs/handoffs/**'
/usr/bin/pwsh -NoProfile -File tests/Test-WindowsReceiptAuthority.ps1
# Output redirected to $TMPDIR/gate-logs/source-fixture.log.
git ls-tree -r --name-only 7ae6948
# Python selected .ps1 paths and compared each file with git show 7ae6948:<path>.
# git show d37f9f2:<changed-path> supplied base files for character and AST comparisons.
/usr/bin/pwsh -NoProfile -File "$TMPDIR/gate-logs/check-format.ps1"
```

Scratch evidence is under `/home/nathan/.cache/stm-scratch/STModel-Private-a9176bfdd476d72d/tl1-22-bootstrap-gate-r1-7cf412cb14941285/gate-logs`. `source-fixture.log` records the suite output; `text-delta.json` records the ten parenthesis insertions; `candidate-ps1.json` enumerates the scanned corpus; `check-format.ps1` contains the parse, comparison, evaluation, and scan probe; `format-results.json` records the five evaluated outputs and scan counts. The evaluated outputs and all acceptance results are reproduced above so this report remains self-contained after scratch cleanup.

The verdict was checked against the deslop prose rules. The report retains the measured counts, exact candidate identities, output evidence, and native-execution limit.
