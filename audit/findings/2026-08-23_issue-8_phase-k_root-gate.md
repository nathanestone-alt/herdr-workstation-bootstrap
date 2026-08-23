# Issue #8 Phase K pinned-Node — final root gate

- Substantive candidate: `164da46011b12e476d236ebe276f22a53fe58374`
- Execution: authenticated B1 shell, `sudo -n`, uid-0 root fixtures
- Date: 2026-08-23 UTC
- Verdict: **PASS**

All four required root suites returned zero:

| Suite | Result | Log | SHA-256 |
|---|---:|---|---|
| `tests/test-bootstrap-privilege-model.sh` | 0 | `/tmp/issue-8-164da-root-privilege.log` | `f52a46092b227b4b314c060a8cb47b2b32157993eaf01a9c5dc253e4931f810f` |
| `tests/test-trusted-launcher.sh` | 0 | `/tmp/issue-8-164da-root-trusted-launcher.log` | `16aaa370c02e58ca8f39ac8cef8043d13d1f4f8f133f8fc639c7c6dd6332f1dd` |
| `tests/test-receipt-authority.sh` | 0 | `/tmp/issue-8-164da-root-receipt-authority.log` | `7d504935db08861120d85d62f0d191782f4b2bdc361c66c658414c668dd092ac` |
| `tests/test-bootstrap-fencing.sh` | 0 | `/tmp/issue-8-164da-root-fencing.log` | `36ca111795fc1701548220bb81eafe0a0fb5e21d8c4c7223d747481c4ca60d97` |

The suites proved the corrected root/runtime privilege split, parent capability descriptors and `no_new_privs`, launcher privilege drop, immutable policy/exact-byte and alias-reopen boundaries, receipt-authority reconciliation and tamper rejection, and launcher fencing/dirty-checkout/forged-marker/pre-line-10 behavior.

Immediately before this record, the only paths changed after the substantive candidate were the git-tracked final cross-review and neutral-runner findings under `audit/findings/`. No substantive source, test, lock, launcher, receipt, or installation surface changed after independent review. This root-gate record is evidence-only under D-GOV-12 and does not create a new review candidate.
