# Herdr adapter workflow reference

## Contents

1. Helper resolution and discovery
2. Dispatch brief
3. Plain send versus tracked workflow
4. ACK, completion, and return acknowledgement
5. Bounded monitoring and recovery
6. Independent gate packet
7. Pane naming
8. Stop conditions

## 1. Helper resolution and discovery

Run Herdr helpers through the native host shell:

```powershell
if ($env:HERDR_ENV -ne "1") { throw "HERDR_ENV is not 1" }
$coordRoots = @(
  (Join-Path $env:USERPROFILE ".agents\skills\herdr-coordination"),
  (Join-Path $env:USERPROFILE ".claude\skills\herdr-coordination")
)
$coordSkill = $coordRoots | Where-Object {
  Test-Path -LiteralPath (Join-Path $_ "scripts\herdr_coordination.ps1")
} | Select-Object -First 1
if (-not $coordSkill) { throw "No installed coordination helper found" }
$coord = Join-Path $coordSkill "scripts\herdr_coordination.ps1"
$workflow = Join-Path $coordSkill "scripts\herdr_workflow.ps1"
$watchdog = Join-Path $coordSkill "scripts\herdr_workflow_watchdog.ps1"
pwsh -NoProfile -File "$coord" -Action discover
```

Record the workspace ID, tab ID, pane ID, stable tab label, live agent kind,
native session, terminal identity, revision, and current status. Re-resolve and
re-assert the tuple immediately before sending. If the native session is absent
or changed, fail closed.

## 2. Dispatch brief

```text
DISPATCH BRIEF
Task: <stable task or issue identifier>
Candidate: <branch, commit, or artifact identity>
Worktree: <absolute worktree path>
Controlling issue / Decision: <exact identifiers or NONE>
Objective: <one sentence>
Write boundary: <directories and files this request may change>
Prohibited actions: <explicit limits from current repository governance>
Resolved worker: <provider, model, reasoning effort, service tier; all required>
Subagent scope: delegated work retains this worktree and write boundary
Required return artifact: <exact path and format>
Evidence and stopping rule: <checks, budgets, and failure conditions>
Naming wiring: <name-request instruction or NONE>
```

Do not broaden ownership because an adjacent surface appears related. Scratch
output belongs in an approved scratch location, not an untracked repository root.

## 3. Plain send versus tracked workflow

Use plain coordination send only for non-blocking status or naming traffic where
losing the prompt cannot stop the work:

```powershell
pwsh -NoProfile -File "$coord" -Action send -To "<pane-id>" `
  -ExpectedTabLabel "<stable-label>" -ExpectedAgent "<agent-kind>" `
  -ExpectedSession "<native-session>" -Message "<bounded message>"
```

Use the workflow wrapper for builds, reviews, gates, releases, or any task that
needs work ACK, completion, deadline, or artifact enforcement:

```powershell
pwsh -NoProfile -File "$workflow" -Action preflight `
  -PaneId "<pane-id>" -ExpectedTabLabel "<stable-label>"
pwsh -NoProfile -File "$workflow" -Action request `
  -TaskId "<task-id>" -CandidateId "<candidate-id>" `
  -ReviewType "<work-kind>" -PaneId "<pane-id>" `
  -ExpectedTabLabel "<stable-label>" `
  -Message "Read the exact brief, ACK, execute it, and return the named artifact." `
  -ArtifactPath "<artifact-path>"
```

Do not substitute a pasted body, raw prompt, broadcast, focus change, or guessed
Enter key for the tracked request.

## 4. ACK, completion, and return acknowledgement

The recipient reads the exact durable relay body, then ACKs from the same proven
pane and session:

```powershell
pwsh -NoProfile -File "$workflow" -Action ack -WorkflowRef "[WF:...]"
```

ACK is receipt, not completion. Execute the task, write the named self-contained
artifact, then complete:

```powershell
pwsh -NoProfile -File "$workflow" -Action complete `
  -WorkflowRef "[WF:...]" -Outcome PASS `
  -ArtifactPath "<artifact-path>" `
  -Message "Self-contained outcome, evidence, and limitations."
```

The requester must read the exact completion relay and acknowledge its body:

```powershell
pwsh -NoProfile -File "$workflow" -Action ack-return -WorkflowRef "[WF:...]"
```

Only `ack-return.body_read=true` proves the return body arrived.

## 5. Bounded monitoring and recovery

```powershell
pwsh -NoProfile -File "$workflow" -Action scan
pwsh -NoProfile -File "$watchdog" -Iterations 5 -IntervalSeconds 30 -Notify
```

Use bounded monitoring only. Missing ACK, overdue completion, failed return
transport, or pending body-read acknowledgement is a coordination blocker.

## 6. Independent gate packet

```text
GATE BRIEF
Candidate: <exact candidate SHA>
Base: <exact base SHA>
Scope: git diff <base>..<candidate> only
Candidate write permission: read-only
Gate write permission: one fresh report at <path>
Independent context: <proved execution identity>
Resolved worker: <explicit provider/model/effort/tier>
Default runner: mechanical checks within <budget>
Stopping rule: stop on unavailable prerequisite, scope escape, or budget expiry
Required assertions: <machine-checkable assertions tied to the diff>
Prohibited: <limits from current repository governance>
Verdict: PASS or BLOCK with P1/P2/P3 file-and-line evidence
Authority boundary: recommendation only
```

Do not expand a gate into unrelated repository research. Missing independent
evidence is INCOMPLETE, not PASS.

## 7. Pane naming

Naming is asynchronous and never blocks useful work. Request a canonical name
after concrete assignment, on task/role change, and before retirement:

```powershell
pwsh -NoProfile -File "$coord" -Action name-request `
  -RepoCode "<repo>" -LaneCode "<lane>" -RoleCode "<role>" `
  -WorkKind issue -IssueNumber <number> -WorkTitle "<short title>"
```

Route by explicit pane ID while naming is pending. A request is not proof the
coordinator applied the name.

## 8. Stop conditions

Stop and return `ERROR/INCOMPLETE` when:

- explicit provider/model/effort/tier is missing or cannot be preserved;
- exact candidate, worktree, pane, stable label, or native session cannot be proved;
- source or installed skill checkout is dirty or mismatched;
- the target is ambiguous, moved, or waiting on approval;
- the required artifact path is unavailable or changed after hashing;
- the request exceeds its scope, budget, write boundary, or governing Decision.

Never infer success from elapsed time, transport acceptance, status alone, or a
missing failure token.
