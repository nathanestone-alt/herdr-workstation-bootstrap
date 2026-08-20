---
name: herdr-coordination
description: "Coordinate live Claude and Codex sessions through Herdr using stable lane labels, a dynamically discovered Coordination tab, and an append-only shared log. Use for cross-talk, multi-agent notification, workflow handoff, blocker routing, coordinator discovery or recovery, stable lane-label enforcement, and shared status across Herdr panes. Requires HERDR_ENV=1 and complements the official herdr control skill."
---

# Herdr Coordination

## Tracked source and installation

Treat `the tracked coordination-skill repository checkout` as the editable source of
truth. Do not make durable edits directly in the installed
`$HOME/.agents/skills/herdr-coordination` checkout. Commit and push
source changes to its configured origin, then run:

```powershell
rtk pwsh -NoProfile -File scripts/sync_installed_skill.ps1 -Action install
```

Use `-Action check` to prove that the installed skill is clean and at the exact
source commit. The synchronizer refuses dirty source or installed checkouts and
uses only a fast-forward Git update; it never reconstructs files from the
currently focused pane.

Coordinate existing agents without hard-coding workspace, tab, pane, terminal, or native session IDs. Use the official `herdr` skill as the authority for topology changes and pane control; this skill adds a shared-message protocol and deterministic coordinator discovery.

## Guardrails

1. Verify `HERDR_ENV=1` before any Herdr control command using the agent's native host-shell tool. Never make this decision inside context-mode, an MCP server, a sandboxed executor, or a detached helper because those subprocesses may strip pane-scoped `HERDR_*` variables. If such a subprocess reports them missing, recheck directly; stop only when the direct host-shell check fails.

   For registration and any pane/agent operation that requires live pane metadata, make an explicit host-access preflight by running `herdr pane get <live-pane-id>` from that native host shell; `HERDR_ENV=1` alone is not proof that pane access is available. If the preflight returns `PermissionDenied` or `Operation not permitted`, classify the attempt as `host_access_unavailable`, do not issue or retry registration from the same sandbox, and obtain host-level execution before retrying the preflight. Run the authorized initialization command only after the preflight succeeds. If a legacy attempt already failed before that preflight, allow at most one host-level retry, then stop and report that no session identity was returned.
2. Run `herdr --help` and the relevant command group when command syntax has not been established in the current turn.
3. Discover live IDs from Herdr JSON. Never persist or predict an ID. The reviewed 0.8.0 preview still lets `--current` fall back to UI focus when `HERDR_PANE_ID` is absent, so require the native workspace/tab/pane IDs and use the explicit pane ID; never use `--current` as identity recovery.
4. Read a target pane before waiting for new output or recovering input.
5. Do not interrupt active work merely to deliver a routine notification. Herdr's agent prompt transport accepts prompts for working agents.
6. Never broadcast, focus, close, move, or restart panes without matching user authorization.
7. Keep project work out of the coordinator. It may inspect state, append messages, and relay prompts only unless the user expands its scope.
8. Stable lane identity is MANDATORY, not cosmetic. Use the canonical repository/lane/role name assigned by Coordination, and put the current issue, PR, or no-issue feature in pane display metadata. A pane requests naming changes; it does not rename itself.

## Review compatibility after every Herdr update

Compatibility reviewed for Herdr `0.8.0-preview.2026-08-04-d78e3d3b5126` on 2026-08-05.

Treat every Herdr update as invalidating the previous skill-compatibility review. Before new cross-tab automation:

1. Compare `herdr --version`, `herdr --skill`, `herdr --help`, `herdr agent`, and `herdr pane` with every command used by this skill and its scripts.
2. Refresh both `.agents/skills/herdr/SKILL.md` and `.claude/skills/herdr/SKILL.md` from the bundled control-skill baseline while preserving this skill's tracked-relay overlay.
3. Search live skills and scripts for removed command forms. Do not replace current `agent prompt --wait`, `agent wait`, or `pane wait-output` primitives with ad hoc status polling.
4. Run `scripts/test_herdr_skill_compatibility.ps1`,
   `scripts/test_herdr_coordination.ps1`,
   `scripts/test_codex_session_refresh.ps1`,
   `scripts/test_claude_session_refresh.ps1`, and skill frontmatter validation.
5. Update the reviewed-version markers only after all checks pass, then notify existing sessions of exact migrations because their context may still contain stale syntax.

This is a standing order for every Herdr update, including preview builds and patch releases.

The reviewed `0.8.0-preview.2026-08-04-d78e3d3b5126` binary makes `agent wait` available and makes `agent prompt --wait` fail with `agent_prompt_stalled` when a non-working target does not show a lifecycle change within five seconds. Omitting `--wait` still returns only the unproven `agent_prompted` transport receipt; it does not prove that the composer submitted or the agent started. Never use that receipt as submission proof. All cross-tab relays must use this skill's tracked helper, which binds the pane and native session, watches the lifecycle, and permits a bounded proof-bound Enter recovery with at most two attempts when the exact HC token remains active in the same composer with no identity/session change, no user input, and no sequence change. Idle/done must remain unchanged; a false-positive idle-to-working transition is retryable only when `state_change_seq` is unchanged. The second attempt is never sent after identity, session, user-input, lifecycle, or deadline evidence changes. Do not replace it with raw `agent prompt` or manual Enter.

## Shared state

- Coordinator tab label: `Coordination`
- Default log: `/tmp/herdr-coordination.md`
- Override the log with `HERDR_COORDINATION_LOG` when needed.
- Treat the log as append-only. Never rewrite or delete another agent's entry.
- Format entries as `FROM <pane-id|external> TO <pane-id|ALL>: <message>`; the helper adds the timestamp.

The log is durable coordination evidence, not an automatic message bus. Agents must read it at task start, before overlapping work, at major handoffs, and when a coordinator message arrives.

## Use the helper

Resolve the installed skill once per shell:

```powershell
$coordSkill = Join-Path $HOME ".agents/skills/herdr-coordination"
```

Discover the coordinator dynamically:

```powershell
rtk pwsh -NoProfile -File "$coordSkill/scripts/herdr_coordination.ps1" -Action discover
```

Append a normal handoff or status message:

```powershell
rtk pwsh -NoProfile -File "$coordSkill/scripts/herdr_coordination.ps1" `
  -Action append -To ALL -Message "Validation passed; evidence is at audit/findings/example.md."
```

Append and urgently deliver a message to the coordinator:

```powershell
rtk pwsh -NoProfile -File "$coordSkill/scripts/herdr_coordination.ps1" `
  -Action send -To coordinator -Message "Blocked on workbook ownership; no files changed."
```

Parse the helper's JSON response. `delivered` is retained only for backwards
compatibility and means the compact pointer was submitted; it never means the
durable body was read. Use `notice_submitted`, `delivery_scope`, and
`body_read` for the precise state. A send can be logged while
`notice_submitted` is false when the coordinator is missing or ambiguous;
report that distinction.

To append and deliver directly to a specific live pane, use that explicit pane
ID as `-To`:

```powershell
rtk pwsh -NoProfile -File "$coordSkill/scripts/herdr_coordination.ps1" `
  -Action send -To <discovered-pane-id> `
  -ExpectedTabLabel "<exact-live-stable-label>" `
  -ExpectedAgent <codex|claude> -ExpectedSession <native-session-id> `
  -Message "The exact review completed PASS; read the durable relay."
```

`send` writes the complete message to the durable log with a unique `[HR:...]`
relay reference, then sends only a compact notice containing that reference,
sender, recipient, and log path. `-To coordinator` dynamically discovers and
wakes the coordinator. `-To <explicit-pane-id>` delivers directly to that exact
pane; it never relies on the coordinator to forward the message. Other
recipients such as `ALL` are rejected by `send`; use `append` for log-only
entries. The recipient must read the exact matching log entry before acting,
then run the exact `ack-read` command included in the notice. After running
`ack-read` (or the workflow ACK command in a `WORK REQUEST`), immediately
execute the instructions in the relay body as the current task; the ACK is a
receipt, not completion, and the agent must not end its turn after ACKing.
`ack-read` is accepted only from the recorded recipient pane with matching injected Herdr
IDs and stable native agent-session proof. It appends one durable `[HA:...]`
receipt and is idempotent on retry. Do not put the full relay body back into
the prompt: long pasted prompts can collapse in agent TUIs, hide the HC token,
and strand the message awaiting manual Enter.

Inspect whether a relay body was actually acknowledged:

```powershell
rtk pwsh -NoProfile -File "$coordSkill/scripts/herdr_coordination.ps1" `
  -Action relay-status -RelayRef "[HR:...]"
```

`relay-status.body_read=true` requires an anchored, semantic `[HA:...]`
receipt returned by the intended pane. A later textual mention, quoted route,
transport receipt, visible pointer, or `notice_submitted=true` does not count.

Every explicit-pane `send` is a role-bearing dispatch and therefore requires
`-ExpectedTabLabel`. Select the intended stable lane label from the work role
first, resolve that exact label to one live pane, then bind the explicit pane,
live label, expected agent kind, and native session in the helper call. Never
select a pane ID first and accept whichever label it currently has. The helper
resolves the pane's current `tab_id` and compares the live tab label exactly
before generating an `[HR:...]`, appending the log entry, or touching prompt/key
transport. Missing, unresolved, ambiguous, renamed, or mismatched labels fail
with a nonzero exit and no new relay. The assertion is repeated immediately
before prompt submission so a pane moved to another tab cannot receive the
dispatch.

The durable log keeps the machine-authoritative prefix as `FROM <pane-id> TO
<pane-id>:`. Its body automatically adds `[ROUTE <pane-id> (<tab label>) ->
<pane-id> (<tab label>)]`, and bare live pane references in helper-managed
messages are expanded to `pane-id (tab label)`. This preserves exact ID parsing
while making the relay readable from the sidebar.

Deliver a verified message to a specific live pane without adding another log entry:

```powershell
rtk pwsh -NoProfile -File "$coordSkill/scripts/herdr_coordination.ps1" `
  -Action deliver -PaneId <discovered-pane-id> `
  -ExpectedTabLabel "<exact-live-stable-label>" `
  -ExpectedAgent <codex|claude> -ExpectedSession <native-session-id> `
  -Message "Read the latest coordination handoff."
```

`deliver` and `send` require Herdr 0.7.5 or newer. They attach a short `[HC:...]` tracking token and a live route annotation, then submit through `herdr agent prompt`, which verifies that the target still hosts a live agent and uses Herdr's server-owned prompt transport as the primary path. The route format is `[ROUTE <source-pane> (<source-tab-label>) -> <target-pane> (<target-tab-label>)]`, for example `[ROUTE w1:pJ (Coordination) -> w1:pA (#567 - Independent review)]`. Resolve labels from each explicit pane's current `tab_id`; never infer them from sidebar order. Pane IDs remain authoritative, labels are informational, and an unavailable label falls back to the pane ID alone. The `[HR:...]` reference identifies a durable coordination-log entry; the `[HC:...]` token tracks the short transport prompt.

Before submitting to any agent, the helper starts a hidden proof-bound watcher whenever it can establish either the preferred native-session proof or the stable agent-process lease described below. This includes `idle` and `done` targets: Herdr can return a successful `agent_prompted` receipt while the exact text remains unsubmitted in the composer, so a successful receipt is not final proof and must retain watcher ownership. For an agent that is not already working, the helper also waits up to seven seconds for an observed lifecycle change. The preferred recovery proof is the unchanged explicit target identity plus the exact `[HC:...]` token as active input—not merely visible elsewhere in detection. A narrow exception handles an agent UI that suppresses or misclassifies its composer: after the explicit `agent prompt` call itself returns `agent_prompt_stalled`, the helper may send one receipt-bound `Enter` if the same pane, agent, native session or complete process lease remains proven and the agent is still `idle` or `done`. This applies when the fresh token is absent, or when it appears only in history while `state_change_seq` is unchanged and the current prompt is empty or an exact built-in Codex placeholder. If different user-authored text occupies the current prompt, lifecycle sequence changed, or the pre-send agent is blocked, recovery fails closed and sends no key. A recovery must then observe a matching lifecycle/sequence or queue-history proof. The helper never uses UI focus, reconstructs a caller/session, substitutes another pane, or sends more than one recovery key.

For an already-working agent, the helper uses Herdr's queued-prompt path; the sender does not wait for the unrelated active turn. For an available agent, the same watcher closes the false-positive receipt gap. The helper reads Herdr through `rtk proxy`, requests `--format text`, and pins native-command output to UTF-8 so hidden processes receive the same Unicode prompt markers as visible shells. From launch, the watcher repeatedly verifies the same identity and classifies the tracked token using the last prompt-marker line. It polls every 250 ms for the first ten seconds and then every second through the remaining watcher lifetime. If the exact token is active, it sends `Enter` and requires the token to move from active input into history/the queued-message region or requires a matching lifecycle/sequence transition. If the token remains active after the first key, it may send one second bounded `Enter` only after an immediate identity/session/token re-read; idle/done must remain unchanged, or a working transition must retain the same `state_change_seq`. It records delivery without sending a key only when the exact token is already in transcript history and a post-availability lifecycle transition or sequence advance proves that the turn ran. Token history, token disappearance, elapsed time, a successful prompt receipt, and current `working` status alone are never success. If verified submission proof is still absent after 60 seconds, the watcher emits one local `Cross-talk delivery stalled` notification while continuing to seek proof; notification failure never changes the transport result. If identity changes or proof remains ambiguous, it fails without another key. Watchers time out after 15 minutes and append their result to `/tmp/herdr-coordination-watch.md`.

An empty detection snapshot is a transient observation, not an error and not
proof that the prompt was accepted. The watcher must keep polling the same
proof-bound pane without sending a key until the exact token becomes active or
another permitted lifecycle proof appears.

Native `agent_session` is the preferred watcher identity. If it is temporarily absent, Windows recovery may use a stable agent-process lease containing the explicit pane ID, detected agent kind, Herdr agent revision, terminal ID, shell PID, and the single direct or foreground native agent PID. Revalidate the whole lease immediately before and after Enter. Use process identity only as a continuity lease; never parse command arguments or derive a native session ID from it. If neither native-session proof nor a complete stable process lease exists, fail closed and send no key.

The result includes `transport`, `delivery_state`, `prompt_waited`, `enter_recovered`, `recovery_key`, `watch_started`, `watch_completed`, `watch_process_id`, and `error`. An asynchronous working-target acceptance reports `accepted_while_working_watch_started`; an available-target receipt with retained watcher ownership reports `accepted_while_available_watch_started`; final watcher evidence is written to the watcher log. If Herdr accepts a prompt but neither native-session proof nor a stable process lease can bind a watcher, report `submitted: false`, `delivery_state: failed`, and send no key; server acceptance alone is not verified delivery. Successful immediate and queued recoveries report `accepted_after_enter_recovery`, `accepted_after_receipt_enter_recovery`, or `accepted_after_queued_enter_recovery`; a queued token already present in transcript history reports `accepted_queued_without_recovery`. If Enter was sent but the lifecycle or post-send identity proof fails after the bounded retry, it reports `submitted: false`, `delivery_state: recovery_unverified`, and `enter_recovered: true`; inspect it but never send another recovery key outside the helper's bounded proof path. Treat every other `submitted: false` result as a delivery failure requiring inspection. Outside the helper's proof-bound recovery, do not reconstruct success from screen text or automatically send `Enter`, `Tab`, or `Ctrl+Y` after a failed prompt.

Use the same `pane-id (tab label)` notation in every human-written session
note, ACK, status update, handoff, and verdict relay whenever a pane is named.
Never write a bare summary such as `w1:pQ accepted`; write `w1:pQ (#561 -
Review PASS (idle)) accepted`. Resolve the label live from the pane's current
`tab_id`; never infer it from sidebar order. The helper enriches live pane
references automatically, but agents must still follow this notation when
writing outside the helper.

## Track critical work requests

Use the workflow wrapper for reviews, merge gates, release gates, and other work where a lost prompt would stop progress. It adds reviewer preflight, a durable append-only JSONL ledger, duplicate suppression, a separate work ACK, and completion deadlines. A transport acceptance only proves prompt submission; it is not a work ACK.

Before dispatch, preflight the explicit target:

```powershell
rtk pwsh -NoProfile -File "$coordSkill/scripts/herdr_workflow.ps1" `
  -Action preflight -PaneId <discovered-pane-id> `
  -ExpectedTabLabel "<exact-live-stable-reviewer-label>"
```

Preflight requires the same explicit pane, a detected agent, matching native-session provenance, and a dispatchable status. It refuses blocked/unknown agents, an already-working agent unless `-AllowWorking` is explicit, background-agent waiting screens, collapsed pasted-text composers, and permission or approval UI. UI blockers are classified only in the current interactive region beginning at the final `›`, `❯`, or `>` prompt marker, so completed transcript history cannot strand a reviewer after a new empty prompt appears. If no prompt marker exists because a composer is suppressed or an overlay is active, preflight retains fail-closed full-buffer classification. Never substitute another pane or use UI focus.

Create a tracked request with stable task, candidate, and review-type identifiers:

```powershell
rtk pwsh -NoProfile -File "$coordSkill/scripts/herdr_workflow.ps1" `
  -Action request -TaskId "#567" -CandidateId "<commit-or-artifact-id>" `
  -ReviewType "independent-review" -PaneId <discovered-pane-id> `
  -ExpectedTabLabel "<exact-live-stable-reviewer-label>" `
  -Message "Review the exact candidate and return PASS or BLOCK." `
  -ArtifactPath "/tmp/review-567.md"
```

The normalized task/candidate/type tuple is the idempotency key. Repeating the same request returns the existing `[WF:...]` workflow and does not redeliver it. `request` requires `-ExpectedTabLabel`; preflight compares it exactly with the target's live tab label before reserving or logging work, and the delivery helper revalidates the same label together with agent/session proof. The wrapper appends the full `[HR:...] [WF:...]` request to the coordination log, sends a compact prompt, and records the source and target pane, stable labels, agent kinds, native sessions, `[HC:...]` transport token, work-ACK deadline, and completion timeout in `/tmp/herdr-workflow-ledger.jsonl`.

The receiving agent must ACK immediately from the same pane and native session:

```powershell
rtk pwsh -NoProfile -File "$coordSkill/scripts/herdr_workflow.ps1" `
  -Action ack -WorkflowRef "[WF:...]" -Message "Accepted; review started."
```

On completion, the same proven session records the outcome and durable artifact:

```powershell
rtk pwsh -NoProfile -File "$coordSkill/scripts/herdr_workflow.ps1" `
  -Action complete -WorkflowRef "[WF:...]" -Outcome PASS `
  -ArtifactPath "/tmp/review-567.md" `
  -Message "Self-contained verdict summary and remaining limitations."
```

`complete` mirrors the readable verdict artifact (up to 64 KiB) into a durable
completion relay and sends only its compact pointer directly to the exact
originating requester recorded by `request`. If the artifact is unavailable,
non-text, or larger than the bound, `-Message` must contain a self-contained
verdict body; otherwise the return fails closed. The request ledger binds
`source_pane`, `source_agent`, and `source_session`; the return revalidates all
three and passes the expected agent/session into the verified delivery helper.
It never substitutes another pane or reconstructs provenance. The coordinator
still receives the durable `WORK COMPLETE` evidence, including whether the
origin notice was submitted, its body-read ACK is pending, or the return failed.

After reading the exact durable completion relay, the originating requester
must record consumption from the same pane and native session:

```powershell
rtk pwsh -NoProfile -File "$coordSkill/scripts/herdr_workflow.ps1" `
  -Action ack-return -WorkflowRef "[WF:...]"
```

Only `completion_return_read` / `ack-return.body_read=true` means the verdict
body reached the requester. `completion_returned`, the `[HC:...]` watcher,
`notice_submitted`, or a visible PASS/artifact pointer proves transport only.

Tracked relays created by the current helper also carry the recipient agent
type, tab ID, stable-label encoding, and an exact payload SHA-256. If compaction
or a pane-local restart rotates the native session after delivery, `ack-read`
must keep the original relay unread and automatically append one exact-payload
successor with `[REISSUE-OF [HR:...]]`, bound to the new live session. This is
allowed only when the pane, tab, stable label, agent type, payload hash, and
live native-session proof all agree. `relay-status` then reports the immutable
original as `body_read=false`, its replacement lineage, and
`effective_body_read=true` after the successor receipt. Missing rotation-safe
metadata, a changed pane/tab/label/agent, an altered payload, ambiguous
successors, or missing live session proof must still fail closed. Do not retry
the old ACK manually or ask the sender to reconstruct the body when this safe
automatic path succeeds.

Every read receipt and workflow mutation also requires the invoking process to
be descended from the exact live pane agent process. Copied `HERDR_*` values or
a session ID from relay metadata are public routing facts, not caller proof.
Same-session ACKs validate the stored payload hash, tab ID, and stable label
before writing `[HA:...]`. The generic `append` action refuses receipt-shaped
HA entries and lineage-bearing HR entries; only `ack-read` and the tracked
successor path may create those protocol records.

`ack-return` uses the same successor mechanism when the originating builder's
session rotates after a completion was returned. The workflow ledger records
the original session and tab ID, the new actor session, and the effective
replacement relay rather than treating either timeout or the new session as
the old one. Moving the pane to a different tab fails closed even if its label
is reused.

Before a work-request ACK, a dormant target may rotate its native session when
it is resumed. The workflow helper records the original request relay and ACK
deadline, then permits at most one deterministic replacement delivery on the
same explicit pane, agent, tab ID, and stable label. The original delivery
attempt is marked superseded; the workflow, candidate, and artifact key remain
unchanged so a replacement cannot create a second review or artifact collision.
The replacement is refused if the pane/tab/agent proof changes, the original
deadline has expired, the request is legacy and lacks its exact message/tab
metadata, or native model, reasoning effort, and service tier continuity are
not structured and unchanged. Coordination never infers, repairs, downshifts, or
upshifts a user-selected model profile: restore it manually and retry when
profile continuity is unavailable or changed. A successful replacement keeps
the original `ack_deadline_utc`; it never extends the hard budget. Repeating the
same rotated ACK is idempotent and cannot create another replacement.

Initial workflow delivery also records an immutable ACK deadline, exact body,
artifact, tab ID, and execution profile in the reservation before transport.
Duplicate recovery may use only that stored body and one fencing claim. A
delivery claim is never reclaimed merely because its lease is expired or
malformed; without a durable terminal event, retry fails closed so an original
process cannot race a duplicate prompt. Request and reissue terminal events
carry their claim/attempt ID. Same-session ACKs re-read the live pane inside the
ledger transaction and require the exact tab ID and stable label; a label match
alone is not identity proof.

Completion return is idempotent by workflow plus completion event. Repeating
`complete` from the same proven reviewer session does not redeliver a pending
or acknowledged return, and repeating `ack-return` does not append a second
read receipt. A failed return is recorded as `completion_return_failed` and
the same reviewer may retry the exact `complete` command after the original
requester session proof is restored; a successful retry records the submitted
`completion_returned` notice, which remains pending until
`completion_return_read`. A changed outcome or artifact, changed reviewer
provenance, changed requester provenance, or a legacy request without recorded
origin-session proof fails closed. `scan` reports completion-return failures,
asynchronous return-watcher failures, and overdue body-read acknowledgements.
`ack` and `complete` re-read and transition the ledger under one path-scoped
lock; completion is refused before a durable work ACK, and concurrent
conflicting PASS/BLOCK commands can append only one verdict. Artifact text,
length, and SHA-256 come from one locked, strict-UTF-8 snapshot of at most 64
KiB; the completion event records that hash and a retry fails if the file at
the same path changed. A crash that leaves only a current-format
`request_reserved` event resumes the same workflow and relay identity rather
than remaining permanently stranded.

### Report the native execution profile

Before a newly launched or restored worker accepts a tracked review, report its
selected execution profile from the worker's native dispatch configuration:

```powershell
rtk pwsh -NoProfile -File "$coordSkill/scripts/herdr_workflow.ps1" `
  -Action report-profile -Provider openai -Model gpt-5.6-luna `
  -ReasoningEffort max -ServiceTier priority
```

Use the exact provider, model, reasoning effort, and service tier selected for
that worker; the example reflects the default Luna Max/priority route. The
action proves the caller's live pane and native session, stores a
session-bound Herdr metadata report, and fails closed if Herdr cannot expose
the exact values. Workflow preflight reads this native report (or equivalent
native agent fields) and never infers execution profile from UI text.

If a reviewer produced a durable verdict but `complete` was refused during a temporary native-session proof gap, never fabricate completion or close the ledger from pane identity alone. Prefer having the original target retry `complete` after its exact native session is restored. When that is impractical, only the dynamically discovered `Coordination` pane may run `-Action reconcile-completion`, and only while all of these proofs agree:

- the request and work ACK name the same target pane, agent, and native session;
- the original target currently exposes that same restored native session and is `idle` or `done`;
- one exact `[HR:...]` entry has that HR ID in its own relay field at the physical log-line prefix, is `FROM` the target `TO coordinator`, and contains the workflow, request relay, candidate tuple, outcome, and artifact path; quoted routes or later textual mentions are not authoritative entries, and `[HR:xxxxxxxx]` plus standard `[re HR:xxxxxxxx]` are compared as the same exact semantic relay ID;
- the requested artifact path is unchanged, its contents contain the workflow, request relay, candidate tuple, and outcome, and its current SHA-256 matches the explicit argument;
- no existing completion conflicts.

```powershell
rtk pwsh -NoProfile -File "$coordSkill/scripts/herdr_workflow.ps1" `
  -Action reconcile-completion -WorkflowRef "[WF:...]" `
  -PaneId <original-target-pane> -ExpectedTargetSession "<original-native-session>" `
  -CandidateId "<exact-candidate-tuple>" -Outcome PASS `
  -ArtifactPath "/tmp/review-567.md" -ArtifactSha256 "<64-hex-sha256>" `
  -EvidenceRelayRef "[HR:...]"
```

Successful reconciliation writes a distinct `completion_reconciled` ledger event containing the coordinator session, restored target-session proof, target revision/sequence, evidence-line hash, artifact hash/length, and proof policy. Repeating the exact command is idempotent; a changed outcome, candidate, target, artifact, hash, relay, missing session, or non-coordinator caller fails closed.
The reconciled completion uses the same proof-bound, idempotent return path to
wake the recorded originating requester.

Inspect one or all workflows with `-Action status`. Reconcile transport failures, missing work ACKs, and overdue completions with `-Action scan`; add `-Notify` for one idempotent local notification per alert kind. For a bounded monitor, run `herdr_workflow_watchdog.ps1 -Iterations <count> -IntervalSeconds <seconds> -Notify`. Do not start an unbounded background monitor or a live stress run without confirming that it will not disrupt active work.

## Notify multiple agents

When the user explicitly asks to notify several sessions:

1. Run `herdr workspace list`.
2. Run `herdr pane list --workspace <workspace-id>` for every in-scope workspace.
3. Exclude the caller and coordinator unless they are intended recipients.
4. Record one `TO ALL` log entry stating the shared message and recipient scope. Do not use `TO ALL` for ordinary reviews or gates; route those through a tracked request to one explicit pane.
5. Deliver to each explicit pane with the helper's `-Action deliver`.
6. Parse every response. Every proof-capable delivery, including an `idle` or `done` target, must report `watch_started: true`; a working pane must also report `queued: true`. The watcher immediately inspects that explicit pane and remains responsible through final proof.
7. Accept `accepted_after_enter_recovery`, `accepted_after_queued_enter_recovery`, and `accepted_queued_without_recovery` as verified delivery. Inspect the watcher log for asynchronous failures and report any `submitted: false` result rather than retrying repeatedly.

Do not infer recipients from sidebar order. Report unavailable, unknown, or ambiguous panes rather than guessing.

## Handle a failed prompt delivery

1. Let the helper handle immediate `agent_prompt_stalled`, false-positive successful receipts on available targets, and delayed working-queue stalls. Prefer exact-token active-input proof, including wrapped continuation lines after the final `›`/`❯` marker and the expanded detection window. For a non-working target only, the helper may also use the narrow receipt-bound recovery above when `agent_prompt_stalled` proves the explicit transport attempt but the agent UI suppresses the composer.
2. Treat `submitted: false` or `delivery_state: failed` as a real failure; read the returned `error`. `pending_watch_after_prompt_error` is not submitted or accepted: only the exact-token watcher may later prove it.
3. Inspect the explicit target with `agent get` and `agent read`; do not use UI focus or infer a different target.
4. Do not retry a failed recovery automatically. A missing token, absent or changed session ID, target mismatch, or missing lifecycle transition must remain failed.
5. Outside the helper, use `agent send-keys` only for an explicitly authorized, inspected UI interaction.

Never infer acceptance from a missing token, elapsed time, or agent status alone.

## Preserve native session proof

Register the managed `herdr-agent-state.ps1 session` hook for Claude `SessionStart`, `UserPromptSubmit`, and `Stop`. A Herdr agent revision can invalidate the previous native-session proof while the same Claude process remains live; prompt-submit and turn-stop events must re-report the native session for the current revision.

On Windows, route those Claude events through the adjacent custom
`herdr-agent-state-async.mjs` wrapper. The wrapper must parse only the native
top-level hook payload, invoke the absolute Herdr reporter directly, wait for
its bounded exit, and preserve the payload plus a failure log when reporting
fails. Do not detach a PowerShell child with discarded output: that path can
return hook success while silently losing the session report.

Never replay the newest or most recent `%TEMP%` hook payload as a generic
recovery step. That directory is shared by multiple Claude panes, so recency,
cwd, pane focus, and filename are not provenance. A preserved payload may be
replayed only after its own top-level `session_id` exactly matches the native
session already intended for the same proven pane; replay is then merely a
retry of known evidence, never a way to discover or substitute identity. If no
matching payload exists, recovery is unavailable and must stop. Never rewrite
a payload, borrow one from another session, or bind its session to the current
pane from UI focus.

For Codex, keep Herdr's managed `SessionStart` hook and register a separate local refresh hook for `UserPromptSubmit` and `Stop`; the refresh hook must accept only a native payload carrying its own `session_id` and delegate through Herdr's managed Codex provenance checks. Do not edit either managed integration file because integration updates overwrite it.

After every `herdr integration install codex`, rerun the Codex refresh test
against the newly installed managed schema. Integration v7 requires the native
`transcript_path` as well as `session_id`; the local refresh hook must forward
both, while leaving the managed hook responsible for `CODEX_THREAD_ID` and
agent-kind validation.

If `agent get` lacks `agent_session`, keep session-bound operations fail-closed and continue trying to restore native proof. Cross-talk Enter recovery may use only the complete stable agent-process continuity lease above plus the exact active HC token. Never reconstruct provenance from UI focus, screen text, process command lines, agent history, or transcript filenames. Restore native proof only from a top-level agent hook event carrying its own `session_id`, or restart/resume the exact known session.

## Go idle after a verified handoff

After a handoff is positively accepted with verified delivery evidence, stop active polling and let the builder go idle. The tracked workflow's proof-bound completion return wakes the builder directly; the coordinator copy remains durable evidence. Continue active polling only for a delivery failure, a blocker requiring coordination, or an explicit monitoring request.

Make returned handoffs and verdicts idempotent by their `[HR:...]` or `[HC:...]` reference plus the artifact/candidate SHA or other stable task ID. If the same result returns again, reuse and acknowledge the existing durable record; do not rerun the review, create duplicate log or artifact entries, redeliver repeatedly, or keep the builder working.

## Restore the coordinator

1. Discover the `Coordination` tab and its pane with the helper.
2. Inspect `pane get` and recent unwrapped output.
3. If Codex is still present and `idle` or `done`, it is ready; do not relaunch it.
4. If the pane is at a shell after Codex exited, recover the exact native session ID from pane metadata or the transcript's `codex resume <id>` line.
5. Run `codex resume <exact-id>` in that same pane and verify `idle` or `done`.
6. If no recoverable session ID exists, ask before creating a replacement conversation.

Do not use `codex --resume`; the supported form is `codex resume <session-id>`.

## Create the coordinator only when requested

If no coordinator exists and the user asks to create one:

1. Ask for or infer only from explicit context the workspace and working directory.
2. Create one `Coordination` tab with `--no-focus`.
3. Launch the normal interactive `codex` executable in its root pane.
4. Wait for `idle`, then instruct it to act only as the coordination relay and use the shared log.
5. Verify the helper returned `submitted: true`; treat any agent-prompt error as a failed coordinator initialization.
6. Record its registration in the log and notify only the requested agents.

Keep one pane in the tab for phone/SSH readability unless the user requests a split.

## Use canonical pane names and work subtitles

Coordination owns names. Ordinary panes report facts and request a name; they
must not rename themselves or another pane. Use these canonical forms:

- assigned work: `<REPO>-<LANE>-<ROLE><SLOT>`, for example `STM-WB-O1`;
- unassigned exploration: `<REPO>-E<SLOT>`, only while no concrete task exists;
- reserved Hdr panes: `Coordination` and `Fix`.

Repository codes are `STM` for STModel and `AGT` for STModelAgent. Lane codes
are `T`, `M`, `LSP`, `WB`, `MCP`, `OPS`, and `RES`. Role codes are `O`
(orchestrator/owner), `B` (builder), `R` (independent reviewer), and `C`
(cross-reviewer). Provider remains separate semantic metadata; never encode
Claude or Codex in the canonical name.

The pane subtitle is current work, not identity:

- issue: `#<number> · <short title>`;
- pull request: `PR#<number> · <short title>`;
- assigned work without a ticket: `NO-ISSUE · <short description>`;
- genuinely unassigned work: `EXPLORE · <short topic>`.

Coordinator must report the same subtitle through both `--title` and
`--display-agent`. This preview's default sidebar row falls back to `Claude` or
`Codex` when `display_agent` is absent even if `title` is present. The override
is display-only: the semantic `agent` field still preserves the real provider.

### When to request a rename

A pane must send one tracked `PANE NAMING REQUEST` to Coordination:

1. immediately after accepting its first concrete assignment;
2. immediately when its issue, PR, or no-issue feature changes, including a
   redirect such as `#829` to `#828`;
3. immediately when repository, lane, role, or slot changes;
4. before retirement when its task is complete and the pane should close.

Retirement is a terminal lifecycle, not an ordinary subtitle update. Use
`-NamingLifecycle retirement`, keep the pane open after sending the request,
and close it only after `naming-status` reports either `applied` or
`retirement_target_gone` for that exact relay. A read-ACK is not completion.
If Coordination is unavailable, keep the pane open or ask the user; never send
the request and immediately exit.

Ordinary progress, phase changes, PASS/BLOCK results, and status changes do not
rename the pane. If only the ticket changes, keep the canonical name and update
only the subtitle. Send the naming request before further cross-pane routing so
other agents do not dispatch against stale human context.

The request body must state the live repository identity, repo code, lane code,
role code, work kind, issue/PR number when present, short title, and previous
canonical name/subtitle when this is an update. Report `NOT-ESTABLISHED` rather
than guessing. Coordination validates the exact live pane/tab/session tuple,
asks only for missing facts, assigns the lowest available slot, applies the tab
name plus pane metadata, records the mapping, and returns a tracked confirmation.

Use the dedicated helper so the request format is validated and the relay is
created atomically:

```powershell
rtk pwsh -NoProfile -File "$coordSkill/scripts/herdr_coordination.ps1" `
  -Action name-request -RepoCode AGT -LaneCode T -RoleCode R `
  -WorkKind issue -IssueNumber 828 `
  -WorkTitle "UserForm diagnostic coordinate mapping" `
  -PreviousName AGT-T-R1 -PreviousWork "#829"
```

`name-request` routes only to the discovered Coordination pane and fails closed
if the request fields are incomplete, contain newlines, or the delivery proof
fails. A pane must issue it immediately after an assignment or redirect. The
request explicitly instructs Coordination to run the coordinator-owned
`apply-name` action and return `APPLIED` proof; a read receipt or ACK alone is
not completion. Naming is asynchronous: while APPLIED is pending, the pane
continues work and routes only by the stable explicit pane ID (never by the
stale human label). A delayed rename must never block useful work.

For retirement, make the lifecycle explicit and retain the previous identity:

```powershell
rtk pwsh -NoProfile -File "$coordSkill/scripts/herdr_coordination.ps1" `
  -Action name-request -NamingLifecycle retirement `
  -RepoCode AGT -LaneCode T -RoleCode R -WorkKind issue -IssueNumber 828 `
  -WorkTitle "retired" -PreviousName AGT-T-R1 -PreviousWork "#828 · completed"
```

New requests carry the requester's exact pane, tab, agent, and native session.
Coordination refuses to mutate a live pane when that tuple no longer matches.

### How Coordination completes a naming request

Reading a naming request is not completing it. Coordination must consume every
accepted `PANE NAMING REQUEST` relay and leave proof on the log:

```powershell
rtk pwsh -NoProfile -File "$coordSkill/scripts/herdr_coordination.ps1" `
  -Action consume-name-requests
```

`consume-name-requests` is coordinator-owned. It reads outstanding naming
requests addressed to this Coordination pane, assigns the lowest available slot,
applies the canonical name and work subtitle to the exact requesting pane, and
appends an `[HN:...]` `APPLIED` proof bound to the relay, the target pane, and
the coordinator's own pane. A request is only consumed after its read-ACK
exists; a request still `awaiting_read_ack` is reported and left alone.

`apply-name` is relay-bound. Pass `-RelayRef "[HR:...]"` and the target is
resolved from the relay's own sender rather than a hand-passed pane ID, and the
same `[HN:...]` `APPLIED` proof is appended. Use it to complete one specific
request; use `consume-name-requests` to drain the backlog.

Consumption is idempotent. A request that already carries a valid `APPLIED`
proof is never re-applied. An explicit retirement request whose target is
confirmed absent twice receives a coordinator-authored
`retirement_target_gone` disposition rather than a false `APPLIED` proof.
Both terminal results are skipped on later sweeps. An unfinished
`APPLY-STARTED` intent reports `uncertain_apply` and fails closed for
reconciliation.

Naming is coordinator-owned and fails closed. A caller that is not the
discovered Coordination pane, a request routed to a different Coordination pane,
and a target pane that now hosts a different native session are all refused
before any rename or metadata write. `APPLIED` proofs cannot be fabricated
through `append`.

### Watch for naming requests that stalled

A naming request that was read-ACKed but never applied used to fail silently.
Check for that directly:

```powershell
rtk pwsh -NoProfile -File "$coordSkill/scripts/herdr_coordination.ps1" `
  -Action naming-status -NamingDeadlineSeconds 300
```

`naming-status` is a read-only bounded watchdog. It reports each request as
`awaiting_read_ack`, `read_acked_unapplied`, `overdue_unapplied`, `applied`,
`retirement_target_gone`, `uncertain_apply`, or `reconciliation_required`,
and raises `overdue` when a read-ACKed request has no matching `APPLIED` proof
past the deadline. It never contacts Herdr and never mutates anything, so any
pane may run it and a stalled coordinator cannot suppress its own alarm. Scope
it to one request with `-RelayRef "[HR:...]"`, and bound a large log with
`-MaxNamingRequests`. Coordination-log stamps have minute resolution, so a
deadline below 60 seconds is measured against a coarser clock than it implies.

Treat any `overdue_unapplied` request as an open naming failure: run
`consume-name-requests`, then confirm the state is `applied`. Meanwhile the
requesting pane keeps working and keeps routing by its stable explicit pane ID.

When a durable pane registry is active, route human references as
`@pane[STM-WB-O1]`; the helper resolves and revalidates the exact registry ID,
binding ID, canonical name, and generation before transport. Before activation,
labels are explicitly provisional: Coordination must resolve the label to a
fresh exact pane ID and include the live session/label proof on every dispatch.
Never route from sidebar order, a bare old label, or UI focus.

At every handoff and end-of-turn check:

1. verify the canonical name still matches repository, lane, role, and slot;
2. verify the subtitle still matches the active issue, PR, or feature;
3. request a naming update if either changed;
4. close completed panes only after the exact retirement naming request reaches
   `applied` or `retirement_target_gone`, unless the user explicitly keeps
   the pane for another assignment.
