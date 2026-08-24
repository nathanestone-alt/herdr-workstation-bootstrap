# Issue #8 verifier-schema cross-review — blocked

- Candidate: `56a3820c3a6909ccb6868fb345012932fd1542dd`
- Parent: `896a66e2ad7e4f69591d1470c9fb98e899861d9e`
- Reviewer route: OpenAI `gpt-5.6-luna`, reasoning `max`, service tier `priority`
- Verdict: `BLOCK FOR CORRECTION`

## Findings

- P1: none.
- P2: `scripts/ubuntu/verify.sh:460-472` parses `pyvenv.cfg` with `-F=` and reads `$2`, ignoring content after additional `=` characters. Malformed `home`, `version`, or site-package values can therefore pass strict validation. Tracked in [#9](https://github.com/nathanestone-alt/herdr-workstation-bootstrap/issues/9).
- P3: `tests/test-verify-path.sh:416-457` lacks duplicate-key regression coverage and only one of the five new keys has a missing-key assertion. Tracked in [#10](https://github.com/nathanestone-alt/herdr-workstation-bootstrap/issues/10).

Per user direction, findings were ticketed and were not corrected inline. The P2 blocks neutral-runner commissioning, live deployment, merge, and Issue #8 completion.
