# O2 tooling-arc close-out handoff — 2026-08-26

Durable save-down of the O2 lane (tooling dispatch plan 2026-08-24, LANE O2). A fresh
session needs nothing but this file, the per-repo `.coord/` ledgers, and the issues.
Phone-friendly runbook (same content as §3): https://claude.ai/code/artifact/49c625d1-aeb3-4538-b3a4-45d5f671ca63

## 1. Arc state — all nodes returned, all reviews clean

| Node | Verdict | Candidate / evidence |
|---|---|---|
| A `b-dirty-reconcile` | PASS, review CONFIRMED | 36-file disposition (14 landed / 22 drift / 0 preserved); snapshot `o2/b-dirty-snapshot-2026-08-24` @ 70cb17d (local only, deliberately unmerged); local main fast-forwarded to origin (user-authorized) |
| B `b2-vps-inventory` | PASS | `docs/vps-inventory/2026-08-24/` on main (65 records: 23 migrate / 22 keep / 8 retire / 12 investigate) |
| C `a125-b31-reprove` (+review) | BLOCK-as-contracted; review PASS 0 findings | STModel-Agent-Private main @ f33a57a (`audit/implementations/2026-08-24-issue-125-b31-prep/`); run leg gated on STM #957/#961 |
| E `herdr-update-policy` (+review) | PASS; review PASS 0 findings | herdr 0.8.2 lock FLOOR, converge never downgrades, honest `herdr_newer_than_lock` attestation; commit c1cc6b4, merged |
| D `s957-commission-prep` (+3 review rounds) | PASS after r1 P1 (secret-in-argv) and r2 P2 (weak guard) repairs; r3 PASS 0 findings | commissioning kit C-01–C-24; commits 37f9cb7 → 248e395 → d24ff90, merged |
| F `vps-backup-plan` | PASS | branch `o2/vps-backup-plan-2026-08-25` @ d4a6317 — **UNMERGED, awaiting user merge authorization** |

Merged + pushed (user-authorized 2026-08-24): bootstrap `main` = **18bcfda** (herdr fix + #957 kit + inventory docs); STModel-Agent-Private `main` = **f33a57a**. Evidence comments posted on bootstrap #11/#2, STM #961/#957, agent #125. **No issue closed yet** (each has an unmet condition). Ledgers: `.coord/` in this repo and in STModel-Agent-Private (untracked by design; append-only `ledger.jsonl` is the record).

## 2. User decisions locked 2026-08-25

1. **herdr deploy**: user runs the trusted-launcher deploy (sudo — see §3). After green verify, Claude closes #11.
2. **#957**: walk Ubuntu legs now where possible; full Windows sitting scheduled separately. Reality: most Ubuntu legs (C-09–C-13) depend on the Windows share existing first, so today's Ubuntu work = §3 deploy (+ optionally C-22 self-test).
3. **VPS**: backups-first — plan authored (node F). Merge, then execute its immediate legs; migrate/retire gates on a PASSED restore rehearsal.
4. **OpenClaw**: retire only after the 12 root-blocked "investigate" items are resolved in a sudo VPS sitting.

## 3. THE PENDING USER STEPS (verbatim commands — nothing depends on chat history)

**Step 1 — deploy the herdr no-downgrade fix** (sudo on herdr-ubuntu, ~5 min). Direct
script invocation is refused by design; the trusted launcher must be re-pinned to the
merged commit first. Installer hash was independently cross-checked (local git blob ==
GitHub raw).

```bash
installer=/tmp/herdr-install-trusted-launcher.sh
curl --proto '=https' --tlsv1.2 --fail -sS -L -o "$installer" https://raw.githubusercontent.com/nathanestone-alt/herdr-workstation-bootstrap/18bcfda873ed70560d8207161d3780f0c6d86fe5/scripts/ubuntu/install-trusted-launcher.sh
printf '%s  %s\n' 08052064dd5734b9c7e46729572c6c8a41ee4aff51f33bf879f9acc5b078282b "$installer" | sha256sum --check --status && bash -n "$installer" && echo installer-OK
sudo bash "$installer" --re-pin --origin https://github.com/nathanestone-alt/herdr-workstation-bootstrap.git --commit 18bcfda873ed70560d8207161d3780f0c6d86fe5 --run-as-user nathan
sudo /usr/local/libexec/herdr-workstation-bootstrap --entrypoint bootstrap --phase tools
sudo /usr/local/libexec/herdr-workstation-bootstrap --entrypoint verify
herdr --version   # expect 0.8.2
```

Expected: `installer-OK`; re-pin succeeds; tools converge completes; verify exit 0 /
no FAIL; herdr 0.8.2. Failure modes: `--origin` literal mismatch at re-pin (first
install may have used a different literal — check with the installing admin record,
fail-closed, harmless); verify FAIL lines → paste to Claude, do not blind-retry.
Until this deploy, any converge still downgrades herdr to 0.8.0; after it, user
herdr upgrades are permanently downgrade-proof.

**Step 2 — tell Claude "verify done"** (or paste verify tail). Claude closes
bootstrap #11 citing the green verify (closure precondition per the #11 comment).

**Step 3 — authorize "merge the backup plan"**: merge `o2/vps-backup-plan-2026-08-25`
(@ d4a6317, one doc: `docs/vps-inventory/2026-08-24/backup-restore-plan.md`) to main
and push. **Arc is then closed** — everything else is a scheduled sitting.

## 4. Scheduled sittings (post-arc, not blocking)

- **VPS sudo sitting** (~30 min): execute backup plan immediate legs, then the
  restore rehearsal on herdr-ubuntu (PASS criteria in the plan; note only ~28G free
  local — plan re-checks capacity first); same sitting resolves the 12 root-blocked
  investigate items → unlocks migrate/retire + OpenClaw retirement decisions (#2).
- **Windows sitting** (~1–2 h): #957 checklist `docs/issue-957-commissioning-checklist.md`
  C-02→C-08 (HerdrBridge identity, encrypted Tailscale-scoped share, ACL negative
  tests), then Ubuntu C-09→C-13 + C-22, then OneDrive/Excel legs C-14→C-21, C-23/24.
  Green #957 (+#961) unblocks agent #125's two-Excel run leg, which unblocks STM #980.

## 5. Issue-closure conditions (none met yet)

| Issue | Closes when |
|---|---|
| bootstrap #11 | §3 step 1 verify green (then Claude closes, pre-authorized by user 2026-08-25 decision 1) |
| bootstrap #2 | user keep/migrate decisions + tested backups + end-state architecture confirmed |
| STM #961 | O1's `n961-consume-verify` consumes the disposition evidence (comment posted); remaining commissioning-evidence item |
| STM #957 | commissioning checklist walked, evidence posted by user (C-24) |
| agent #125 | run leg after #957/#961 green |

## 6. Operational notes for a successor session

- Worker routing: `STModel-Private/docs/AI/00_meta/worker_routing_policy.json` — builder
  = OpenAI gpt-5.6-luna/max/priority, verification = gpt-5.6-sol/medium/priority; codex
  CLI launches; NEVER inherit orchestrator route.
- codex headless: stdin MUST be `/dev/null` (hangs otherwise); network needs
  `-c sandbox_workspace_write.network_access=true`; watchdog pattern per
  `~/code/o2-lane2-prompt.md` (copy `/home/nathan/code/.coord/watchdog.py`, register
  per launch, unfiltered polls).
- O2 hard boundaries stand: never write `~/code/STModel-Private`, never touch
  `/home/nathan/code/.coord` (O1's ledger). The main STModel-Private checkout currently
  sits on `integration/tooling-arc` @ d569a16d with STM-T-O1's staged n950 work — NOT
  O2's; #1009 relocation belongs to STM-T-O1 (WB-O1 notified 2026-08-25).
- bootstrap #11 hardening idea deliberately NOT implemented (only noted): generic
  refuse-to-downgrade for other tools; herdr-only floor was the locked scope.
