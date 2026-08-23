# Issue #8 privilege transaction — terminal verdict

- Controlling issue: `nathanestone-alt/herdr-workstation-bootstrap#8`
- Base: `2e3a2cc63c2e81a2e695951687e385decd02b7a5`
- Exact substantive candidate: `ca863b98902dca85f16513f9a934d4d1046b001c`
- Evidence receipt commit: `e3ec16113e6f622416359a6c0bf814f87f5886f7`

## Independent evidence

The bounded Anthropic / `claude-opus-5` / high / normal-tier final cross-review passed at the exact substantive candidate with no P1 or P2 findings.

- Review: `audit/findings/2026-08-23_issue-8_privilege-transaction_cross-review-final.md`
  - SHA-256: `e34cb74cb45ff58f605aab9ca2315e238345d779df834a4ef8d5fa32c99d3dbc`
  - Workflow: `[WF:1513ea5b]`
  - Verdict: `PASS FOR CROSS-REVIEW`
- Independent OpenAI / `gpt-5.6-luna` / max / priority host-neutral runner: `audit/findings/2026-08-23_issue-8_privilege-transaction_neutral-runner-host-final.md`
  - SHA-256: `b6a8e471e10c31bf68b81e8a11027b29dd0db4a3c46bc9bc041704c195fcaa41`
  - Workflow: `[WF:9fbb7537]`
  - Result: PASS
- Root gate: `audit/findings/2026-08-23_issue-8_privilege-transaction_root-gate.md`
  - SHA-256: `cc10cf0b222c923f1d403772d21dbb35721668f1f989ca24d36ee5f924052ca0`
  - Four independently invoked suites returned explicit `rc=0` markers.

The earlier neutral sandbox ownership failure is disposed as a UID-remapping artifact: the sandbox represented root-owned `/usr/bin` executables as UID 65534. The unchanged candidate was rerun independently against host ownership semantics and passed. Builder workflow `[WF:6496c4e1]` confirmed no candidate change, so D-GOV-12 preserves the final Opus review as terminal.

## P3 disposition

All twelve review observations are accepted as nonblocking and remain fully documented in the review artifact:

1. The fixture `.gitconfig` assertion is inert, but live argv/HOME checks independently catch the regression.
2. `/root` lacks an extra trust-path validation; only root can retarget it.
3. `bootstrap_root_home` remains mutable solely for the isolated fixture override and is not environment-influenced.
4. `git lfs install --system` is an operator-documentation gap, while being the correct system provisioning behavior.
5. Trust-anchor documentation omits the `base-user` child and fd pool, but states no incorrect behavior.
6. Validator token registration could more directly pin three root-scoped seams; the suite and launcher identity pins are registered.
7. The fixture omits fd-path rewriting in a path unreachable from `install_base` today.
8. The fixture runner passes an inert cwd argument to a fixture that ignores it.
9. Read-only policy descriptors reach the root receipt hand-off but expose only public pin data and do not escalate privilege.
10. Manifest emission remains duplicated but byte-equivalent for the two intended paths.
11. `bootstrap_exec_privileged` keys on mode; every call site maintains the same mode/argument invariant.
12. Fenced directory creation crosses into a runtime-user-controlled tree but is fd-anchored, no-dereference checked, and writes no file content through those anchors.

No P3 is safety-blocking. Follow-up tightening may be ticketed separately without reopening this candidate.

## D-GOV-12 terminal validation

The delta from substantive candidate `ca863b9` to evidence receipt `e3ec161` contains exactly three Markdown files under `audit/findings/`.

- `git diff --check ca863b9..e3ec161`: PASS
- `git diff --exit-code ca863b9..e3ec161 -- scripts tests config docs`: PASS
- Candidate and receipt tree objects are identical:
  - `scripts`: `4d657f54735bbbb675a706d56182a843bdd13f75`
  - `tests`: `7d434db9beca04d99d2a8c9990344efd7ab74df7`
  - `config`: `cdeebf5e703d15b0fc3175322d6de13c000c6a21`
  - `docs`: `baf32bd9d72db85420b814b55c17a39ef23dc8da`

This verdict is itself evidence-only Markdown and does not create a new substantive candidate.

## Verdict

The exact candidate is independently reviewed, neutrally verified, and root-gated. Installation must fetch and pin the substantive candidate `ca863b98902dca85f16513f9a934d4d1046b001c`, not an evidence-only successor.

`PASS FOR MERGE, PUSH, PINNED INSTALLATION, AND ISSUE CLOSURE`
