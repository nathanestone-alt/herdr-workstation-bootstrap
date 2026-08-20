# Issue #961 bootstrap baseline reconciliation

Status: bounded builder record; candidate SHA is returned in the required
result artifact after commit.

## Identity and boundary

- Repository: /tmp/herdr-bootstrap-961
- Branch: codex/issue-961-bootstrap-reconcile
- Clean task base: b2b40641418636bb826a7f4daab4e2331ef97d96
- Frozen dirty checkout: /home/nathan/code/herdr-workstation-bootstrap
- Frozen dirty checkout HEAD: b2b40641418636bb826a7f4daab4e2331ef97d96
- Frozen dirty checkout delta: exactly 36 tracked paths
- No source checkout, installed skill checkout, STModel-Private checkout, host,
  Windows bridge, credentials, or external service was mutated.

## Source identities and evidence hashes

- herdr-coordination source commit used for the payload:
  12cfc2bed35498100501d1926ee1b4f463849428
- herdr-coordination source tree at that commit:
  327fbd3a7145dab8c4a8c1bf38d41a1b4bcb5434
- The dirty coordination files, after CRLF normalization, compare byte-for-byte
  with that source commit. The current candidate carries the clean LF source.
- Key normalized payload SHA-256 values:
  - coordination SKILL.md:
    6dce0bd2074db6dbbd5d90cf19e1cbec78f970bfae1e17ecea11a143d7edff36
  - coordination helper:
    cc3c4805c0fb7229e83fba7dfbddc36aa9e3d316174ae7646a71d2c5cd4b4904
  - coordination regression:
    0c6d022ff9d38e8b9b0f11ff73d506371e45c3ae85c5c4ab2974d0a026bc3b7d
  - naming regression:
    87ffbaa1120b6f97ca19008b805a8803ff24f2f97f2e0da7da024342a75a239b
  - Ubuntu lock:
    8768b3491522409fd2f423f0facc9a58ab472d6075db0ab244cb35a23795c338
  - Ubuntu bootstrap:
    debc9c4547d2a2219c57f150df9c92ec51ea960cb861a34929b4a0e459d60327
- The installed st-herdr-dispatch evidence is at
  /home/nathan/.agents/skills/st-herdr-dispatch. Its six dirty-checkout paths
  are semantically identical to the clean base under
  git diff --ignore-space-at-eol; only line endings differ in the evidence
  checkout, so the clean-base content is retained.
- The installed coordination checkout was observed clean at
  ea48f686761b0e66ad359aac92c5438224457cb1. Its later source history is
  evidence only; this bounded candidate uses the exact dirty-payload source
  identity 12cfc2b.

## 36-path disposition summary

| # | Path | Dirty disposition | Candidate result |
|---:|---|---|---|
| 1 | config/ubuntu-toolchain.lock | Carry forward intentional lock change | Rust toolchain 1.88.0 -> 1.91.0 retained |
| 2 | payload/agents-skills/herdr-coordination/SKILL.md | Carry forward source @ 12cfc2b | Restored as clean LF payload |
| 3 | payload/agents-skills/herdr-coordination/agents/openai.yaml | Exclude line-ending-only delta | Clean-base semantics retained |
| 4 | payload/agents-skills/herdr-coordination/scripts/herdr_coordination.ps1 | Carry forward source @ 12cfc2b | Retained |
| 5 | payload/agents-skills/herdr-coordination/scripts/herdr_pane_registry.ps1 | Carry forward source @ 12cfc2b | Temp-root default retained |
| 6 | payload/agents-skills/herdr-coordination/scripts/herdr_workflow.ps1 | Carry forward source @ 12cfc2b | Temp-root defaults retained |
| 7 | payload/agents-skills/herdr-coordination/scripts/herdr_workflow_watchdog.ps1 | Carry forward source @ 12cfc2b | Temp-root defaults retained |
| 8 | payload/agents-skills/herdr-coordination/scripts/sync_installed_skill.ps1 | Accidental/stale deletion; restore | Restored; not a retired test |
| 9 | payload/agents-skills/herdr-coordination/scripts/test_claude_session_refresh.ps1 | Deleted regression; restore | Restored byte-identical to base |
| 10 | payload/agents-skills/herdr-coordination/scripts/test_codex_session_refresh.ps1 | Deleted regression; restore | Restored byte-identical to base |
| 11 | payload/agents-skills/herdr-coordination/scripts/test_herdr_coordination.ps1 | Deleted regression; restore current source coverage | Restored from source @ 12cfc2b |
| 12 | payload/agents-skills/herdr-coordination/scripts/test_herdr_naming_lifecycle.ps1 | Deleted regression; restore current source coverage | Restored from source @ 12cfc2b |
| 13 | payload/agents-skills/herdr-coordination/scripts/test_herdr_pane_registry.ps1 | Deleted regression; restore | Restored byte-identical to base |
| 14 | payload/agents-skills/herdr-coordination/scripts/test_herdr_pane_registry_cli.ps1 | Deleted regression; restore | Restored byte-identical to base |
| 15 | payload/agents-skills/herdr-coordination/scripts/test_herdr_skill_compatibility.ps1 | Deleted regression; restore | Restored byte-identical to base |
| 16 | payload/agents-skills/herdr-coordination/scripts/test_herdr_workflow.ps1 | Deleted regression; restore | Restored byte-identical to base |
| 17 | payload/agents-skills/herdr-coordination/scripts/test_herdr_workflow_stress.ps1 | Deleted regression; restore | Restored byte-identical to base |
| 18 | payload/agents-skills/st-herdr-dispatch/SKILL.md | Exclude line-ending-only delta | Clean-base semantics retained |
| 19 | payload/agents-skills/st-herdr-dispatch/references/herdr-workflow.md | Exclude line-ending-only delta | Clean-base semantics retained |
| 20 | payload/agents-skills/st-herdr-dispatch/reviews/2026-08-13_923_st_herdr_dispatch_cross_review_r1.md | Exclude line-ending-only delta | Clean-base semantics retained |
| 21 | payload/agents-skills/st-herdr-dispatch/reviews/2026-08-13_923_st_herdr_dispatch_cross_review_r2.md | Exclude line-ending-only delta | Clean-base semantics retained |
| 22 | payload/agents-skills/st-herdr-dispatch/scripts/sync_installed_skill.ps1 | Exclude line-ending-only delta | Clean-base semantics retained |
| 23 | payload/agents-skills/st-herdr-dispatch/scripts/test_st_herdr_dispatch.ps1 | Exclude line-ending-only delta | Clean-base semantics retained |
| 24 | payload/claude-skills/grill-with-docs-stmodel/ADR-FORMAT.md | Accidental/stale deletion; restore | Restored byte-identical to base |
| 25 | payload/claude-skills/grill-with-docs-stmodel/CONTEXT-FORMAT.md | Accidental/stale deletion; restore | Restored byte-identical to base |
| 26 | payload/claude-skills/grill-with-docs-stmodel/SKILL.md | Accidental/stale deletion; restore | Restored byte-identical to base |
| 27 | payload/claude-skills/tier1/SKILL.md | Accidental/stale deletion; restore | Restored byte-identical to base |
| 28 | payload/claude-skills/tier1/evals/evals.json | Accidental/stale deletion; restore | Restored byte-identical to base |
| 29 | payload/claude-skills/tier1/references/gate-pattern.md | Accidental/stale deletion; restore | Restored byte-identical to base |
| 30 | payload/claude-skills/tier1/references/named-range-rules.md | Accidental/stale deletion; restore | Restored byte-identical to base |
| 31 | payload/claude-skills/tier1/references/ten-principles.md | Accidental/stale deletion; restore | Restored byte-identical to base |
| 32 | payload/claude-skills/tier1/references/workbook-architecture.md | Accidental/stale deletion; restore | Restored byte-identical to base |
| 33 | payload/claude-skills/tier1/scripts/com_gate_scaffold.py | Accidental/stale deletion; restore | Restored byte-identical to base |
| 34 | payload/claude-skills/wait-what/SKILL.md | Accidental/stale deletion; restore | Restored byte-identical to base |
| 35 | payload/claude-skills/wait-what/agents/openai.yaml | Accidental/stale deletion; restore | Restored byte-identical to base |
| 36 | scripts/ubuntu/bootstrap.sh | Carry forward intentional bootstrap fix | Rust-init basename, self-update lock, post-install lock check, and executable mode retained |

The ignored nested path payload/claude-skills/claude-skills/** was observed in
the dirty checkout as local/generated state. It is outside the 36 tracked
paths and was not copied or committed.

No deletion was accepted as an intentional retirement. The two deleted
coordination tests with current source changes were restored from their named
source revision; the other seven deleted coordination regression tests and
all twelve deleted tracked Claude payload files were restored from the clean
base. There are no retired regression tests requiring replacement coverage.

## Regression-test cardinality

- Coordination regression scripts: 9 in the clean base -> 9 in the candidate.
- Dispatch regression scripts: 1 in the clean base -> 1 in the candidate.
- Repository regression test files: 9 in the clean base -> 9 in the candidate.
- Total payload behavioral regression commands wired: 10.
- Retired regression tests: 0.

## Validation wiring

scripts/Validate-Repository.ps1 now accepts the explicit
-RunPayloadRegression switch and enumerates all ten payload regression
commands. The default validator still performs parser/static checks and does
not launch payload runtime fixtures. On non-Windows hosts, the explicit switch
fails closed with a platform-runtime diagnostic; it does not silently skip or
fall through to a live Herdr/RTK command.

## Validation record

PASS:

- PowerShell parser command over all 30 tracked .ps1 files:
  PASS: PowerShell parser validation (30 files).
- Bash syntax command over all 11 .sh files: PASS.
- Python AST command over both .py files using python3: PASS.
- git diff --check: PASS.
- bash scripts/ubuntu/install-payload.sh: safely blocked at exit 30 by the
  existing Windows-specific payload preflight before any copy or install.

Environment-blocked, not silently retired:

- The ten explicit payload commands
  pwsh -NoProfile -File payload/agents-skills/herdr-coordination/scripts/test_claude_session_refresh.ps1
  pwsh -NoProfile -File payload/agents-skills/herdr-coordination/scripts/test_codex_session_refresh.ps1
  pwsh -NoProfile -File payload/agents-skills/herdr-coordination/scripts/test_herdr_coordination.ps1
  pwsh -NoProfile -File payload/agents-skills/herdr-coordination/scripts/test_herdr_naming_lifecycle.ps1
  pwsh -NoProfile -File payload/agents-skills/herdr-coordination/scripts/test_herdr_pane_registry.ps1
  pwsh -NoProfile -File payload/agents-skills/herdr-coordination/scripts/test_herdr_pane_registry_cli.ps1
  pwsh -NoProfile -File payload/agents-skills/herdr-coordination/scripts/test_herdr_skill_compatibility.ps1
  pwsh -NoProfile -File payload/agents-skills/herdr-coordination/scripts/test_herdr_workflow.ps1
  pwsh -NoProfile -File payload/agents-skills/herdr-coordination/scripts/test_herdr_workflow_stress.ps1
  pwsh -NoProfile -File payload/agents-skills/st-herdr-dispatch/scripts/test_st_herdr_dispatch.ps1
  returned 0/10 PASS on this Ubuntu runner. The coordination fixtures still
  create Windows .cmd shims and use -WindowStyle; failed invocations reached
  the real rtk/herdr lookup and stopped with server_not_running, without live
  pane mutation. The dispatch fixture stopped at its unsafe fixture-removal
  guard. Windows runtime validation remains required.
- pwsh -NoProfile -File scripts/Validate-Repository.ps1 returned exit 1 for
  the pre-existing direct-execution permission failure on
  scripts/ubuntu/configure-excel-share.sh (mode 0644; test expected exit 2
  but received 126). Its Python check also reports python unavailable because
  this host exposes python3 only. The changed payload did not cause this
  failure.

## Unresolved risks and downstream notes

- The commit-12cfc2b payload is a clean source baseline, not the later full
  Ubuntu portability implementation. Run the ten payload tests on supported
  Windows before enabling the payload. A later coordination portability node
  must replace Windows-only fixture mechanics and prove hermetic Ubuntu
  transport before changing this record to an Ubuntu PASS.
- The deferred Python 3.13 lock/verifier/receipt, OneDrive staging helper,
  Windows Excel job runner, live host convergence, package installation,
  service changes, SMB mounts, COM/Excel, and Windows execution remain
  unimplemented by design.
- The ignored local/generated Claude nested tree and all secrets/auth state
  were excluded.
