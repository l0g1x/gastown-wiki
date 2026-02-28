# 09 — Work Delivery Layer

> Reflects upstream commit: `7a6c8189`

**Investigation date:** 2026-02-28
**Source tree:** `/home/krystian/gt/gastown/crew/sherlock/`

---

## Architecture: The Work Delivery System End-to-End

Work delivery is the sequence of operations by which a polecat signals that its
assigned task is finished, hands off the git artifact (branch) to the merge
queue, and triggers all downstream bookkeeping: bead status transitions, convoy
completion checks, audit logging, and Witness notification.

The system has two primary paths:

1. **Polecat path (`gt done`)** — the canonical, heavily-guarded end-to-end
   flow used by ephemeral worker agents.
2. **Wasteland path (`gt wl done`)** — a separate completion protocol for
   claimed items in the Wasteland (open bounty board), requiring explicit
   evidence URLs.

There is also a lower-level **`gt mq submit`** command used for manual or
scripted MR submission without the polecat lifecycle machinery.

---

## Code Paths: Key Functions with File:Line References

### `gt done` — Primary Polecat Work Delivery

**Entry point:** `internal/cmd/done.go:81` — `func runDone`

The full call graph for `runDone`:

```
runDone (done.go:81)
  ├── telemetry.RecordDone (defer, telemetry/recorder.go:413)
  ├── workspace.FindFromCwdWithFallback (workspace/find.go)
  ├── git.NewGit / g.CheckUncommittedWork / g.BranchPushedToRemote
  ├── getAgentBeadID (agent_state.go)
  ├── getIssueFromAgentHook (done.go:1250) — reads hook_bead from agent bead
  ├── setDoneIntentLabel (done.go:957) — writes done-intent:<type>:<ts> label
  ├── readDoneCheckpoints (done.go:1027) — reads done-cp:* labels for resume
  ├── [COMPLETED path]
  │   ├── g.CommitsAhead — verifies work exists
  │   ├── getConvoyInfoFromIssue / getConvoyInfoForIssue — reads merge strategy
  │   ├── [direct strategy] g.Push(branch:main) → bd.ForceCloseWithReason
  │   ├── [local strategy] skip push entirely
  │   ├── [no_merge flag] mail dispatcher READY_FOR_REVIEW
  │   ├── [mr strategy, default]
  │   │   ├── g.Push("origin", branch+":"+branch) — push branch to remote
  │   │   ├── g.RemoteBranchExists — verify push landed
  │   │   ├── writeDoneCheckpoint(CheckpointPushed) (done.go:1017)
  │   │   ├── beads.DetectIntegrationBranch — find target branch
  │   │   ├── bd.FindMRForBranch — idempotency check
  │   │   ├── bd.Create(type=merge-request, ephemeral=true) — create MR bead
  │   │   ├── bd.Show(mrID) — verify MR bead readable
  │   │   ├── bd.UpdateAgentActiveMR — cross-reference on agent bead
  │   │   └── writeDoneCheckpoint(CheckpointMRCreated) (done.go:1017)
  ├── notifyWitness: [label: notifyWitness]
  │   ├── nudgeRefinery (if mrID != "") — tmux send-keys to refinery session
  │   ├── completionBd.UpdateAgentCompletion — write CompletionMetadata to agent bead
  │   ├── nudgeWitness — tmux send-keys: "POLECAT_DONE <name> exit=<type>"
  │   ├── writeDoneCheckpoint(CheckpointWitnessNotified) (done.go:1017)
  │   ├── LogDone (cmd/log.go:398) → townlog.EventDone
  │   └── events.LogFeed(TypeDone, ...) — writes to .events.jsonl
  ├── updateAgentStateOnDone (done.go:1086)
  │   ├── bd.Show(agentBeadID) — read agent bead
  │   ├── closeDescendants — close molecule step children
  │   ├── bd.ForceCloseWithReason(wisp root)
  │   ├── bd.Close(hookedBeadID) — close the work bead
  │   ├── bd.ClearHookBead(agentBeadID) — clear hook_bead slot
  │   ├── bd.Run("agent", "state", agentBeadID, "done"/"stuck")
  │   ├── bd.UpdateAgentCleanupStatus — ZFC self-report
  │   ├── clearDoneIntentLabel (done.go:973)
  │   └── clearDoneCheckpoints (done.go:1052)
  └── [isPolecat] sync worktree to main, delete old branch
```

### `gt close` — Bead Closure with Convoy Check

**Entry point:** `internal/cmd/close.go:44` — `func runClose`

```
runClose (close.go:44)
  ├── exec.Command("bd", "close", args...) — delegate to bd CLI
  ├── extractBeadIDs(args) — parse bead IDs from raw flags
  └── checkConvoyCompletion(beadIDs) (close.go:127)
      └── convoy.CheckConvoysForIssue (convoy/operations.go:37)
          ├── getTrackingConvoys — GetDependentsWithMetadata filtered by type="tracks"
          ├── isConvoyClosed / isConvoyStaged — status guards
          ├── runConvoyCheck — exec("gt convoy check <convoy-id>")
          └── feedNextReadyIssue — reactive convoy feeding
```

### `gt mq submit` — Manual MR Submission

**Entry point:** `internal/cmd/mq_submit.go:78` — `func runMqSubmit`

```
runMqSubmit (mq_submit.go:78)
  ├── parseBranchName — extract issue, worker from branch
  ├── beads.DetectIntegrationBranch — find target branch
  ├── bd.FindMRForBranch — idempotency check
  ├── bd.Create(type=merge-request, ephemeral=true)
  └── nudgeRefinery
```

### `gt wl done` — Wasteland Completion

**Entry point:** `internal/cmd/wl_done.go:44` — `func runWlDone`

```
runWlDone (wl_done.go:44)
  ├── wasteland.LoadConfig — read rig handle
  ├── generateCompletionID(wantedID, rigHandle) — sha256(id|rig|ts)[:8] → "c-<hex>"
  └── submitDone (wl_done.go:79)
      ├── store.QueryWanted(wantedID) — verify status=claimed and claimed_by=rig
      └── store.SubmitCompletion(completionID, wantedID, rigHandle, evidence)
          → sets wanted item status to "in_review"
```

### `gt convoy check` — Convoy Completion Check

**Entry point:** `internal/cmd/convoy.go:648` — `func runConvoyCheck`

```
runConvoyCheck (convoy.go:648)
  ├── [specific convoy] checkSingleConvoy (convoy.go:682)
  │   ├── bd show <convoyID> --json — read convoy
  │   ├── getTrackedIssues — read "tracks" dependencies
  │   ├── [allClosed] bd close <convoyID> -r "All tracked issues completed"
  │   └── notifyConvoyCompletion
  └── [all] checkAndCloseCompletedConvoys
```

### `gt mq post-merge` — Post-Merge Cleanup

**Entry point:** `internal/cmd/mq.go:500` — `func runMQPostMerge`

```
runMQPostMerge (mq.go:500)
  ├── mgr.PostMerge(mrID) — close MR bead (status=merged) + close source issue
  └── rigGit.DeleteRemoteBranch("origin", mr.Branch) — delete feature branch
```

---

## State: MQ State, Bead State Transitions, Activity/Event Records

### Bead State Machine for Work Items

The bead status field follows this progression for an issue dispatched to a polecat:

```
open
  └─[gt sling]──→ hooked          (agent hook_bead slot set)
                    └─[gt done / COMPLETED]──→ closed   (hooked bead closed in updateAgentStateOnDone)
                    └─[gt done / ESCALATED]──→ (stays hooked, polecat → stuck state)
                    └─[gt done / DEFERRED]───→ (stays open, hook cleared)
```

The agent bead tracks its own state via the `agent_state` field:
- `working` — actively working on a task
- `done` — `gt done` completed (transitions to `idle` after Witness survey)
- `stuck` — escalation exit (needs human intervention)
- `idle` — ready for new assignment (persistent polecat model)

### Merge Request Bead State Machine

The MR bead (type=`merge-request`, ephemeral wisp) goes through two parallel state
tracks:

**Beads status field** (coarse, backward-compat):
```
open → in_progress → closed
```

**MR Phase field** (fine-grained, stored in bead description checkpoints):
```
ready → claimed → preparing → prepared → merging → merged  (success path)
                            → rejected                       (diagnosis failure)
                ↑───────────── failed ──────────────────    (transient, retryable)
```

Phase transition validation is enforced in `internal/refinery/types.go:93` via
`ValidPhaseTransitions`.

### Convoy State Machine

```
staged_ready / staged_warnings   (pre-launch)
  └─[gt convoy launch]──→ open
                            └─[gt convoy check, all tracked closed]──→ closed
                            └─[gt convoy add]──→ open (re-opened with new issues)
```

Convoy closure triggers `notifyConvoyCompletion` which sends mail to subscribers
recorded in the convoy's description.

### Activity/Event Records Written on Work Delivery

Every `gt done` invocation writes to multiple audit sinks:

| Sink | Location | Format | Written by |
|---|---|---|---|
| TownLog | `logs/town.log` | Human-readable text | `LogDone` → `townlog.Logger` |
| Events feed | `.events.jsonl` | JSONL (flock-protected) | `events.LogFeed(TypeDone)` |
| Agent bead | beads DB (Dolt/SQLite) | Description fields | `UpdateAgentCompletion` |
| Agent bead labels | beads DB | `done-cp:*` labels | `writeDoneCheckpoint` |
| Telemetry | OTel → VictoriaLogs | OTel log record | `telemetry.RecordDone` |
| Molecule audit log | `.beads/audit.log` | JSONL | `DetachMoleculeWithAudit` (if applicable) |

---

## Interfaces: How Work Delivery Connects to Other Layers

### Connection to Work Binding (Hook Clearing)

The hook is the binding between a polecat and its assigned work bead. Delivery
is the act of releasing that binding:

1. `updateAgentStateOnDone` (done.go:1086) reads `agentBead.HookBead`
2. Closes the work bead hierarchy: molecule steps → molecule root → hooked bead
3. Calls `bd.ClearHookBead(agentBeadID)` — sets `hook_bead` slot to empty
4. Sets `agent_state = "done"` (or `"stuck"` for ESCALATED)

This sequence is non-fatal: if the agent bead has already been deleted by the
Witness, the function warns and returns rather than failing the entire `gt done`.

### Connection to Communication (Completion Notification)

`gt done` uses two notification mechanisms:

1. **Bead-based (nudge-over-mail redesign, gt-a6gp):** writes `CompletionMetadata`
   fields to the agent bead, then sends a tmux nudge to the Witness session.
   The Witness `survey-workers` step reads the bead fields directly (no Dolt
   commit overhead from mail).

2. **Refinery nudge:** `nudgeRefinery` sends a tmux message to the refinery
   session: `"MERGE_READY received - check inbox for pending work"`. This wakes
   the Refinery immediately rather than waiting for its polling cycle.

The legacy `gt mail send` path for `POLECAT_DONE` is deprecated (replaced by
the bead-based approach). `gt mq submit` (the lower-level command) still uses
`exec.Command("gt", "mail", "send", ...)` for lifecycle requests via
`polecatCleanup` (mq_submit.go:271).

### Connection to Lifecycle (Landing the Plane)

"Landing the plane" in the polecat model means:

1. Branch pushed to `origin/<branch>` (not to `main` directly).
2. MR bead created (type=merge-request, ephemeral, with `branch:`, `target:`,
   `source_issue:`, `rig:`, `agent_bead:` fields in description).
3. Refinery nudged to wake and process.
4. Agent bead updated: `CompletionMetadata` written + `agent_state=done`.
5. Witness nudged.
6. Work bead closed, hook cleared.
7. Worktree synced to `main`, old branch deleted locally (persistent polecat).

**There is no harness enforcement of "landing the plane" as a prompt convention.**
The entire sequence is in code. Key safeguards:

- **Uncommitted work guard** (done.go:352): `gt done` refuses to complete if
  `git status` shows uncommitted changes.
- **Zero-commit guard** (done.go:381): refuses to complete if branch has no
  commits ahead of `origin/main` (unless `--cleanup-status=clean` is set for
  report-only tasks).
- **Push verification** (done.go:577): after `git push`, calls
  `RemoteBranchExists` to confirm the branch actually landed on the remote.
- **MR bead verification** (done.go:800): after `bd.Create`, reads the MR back
  with `bd.Show` to confirm it is readable before nuking the worktree.
- **Checkpoint resume** (done.go:312): `done-cp:*` labels on the agent bead
  allow `gt done` to resume from where it left off if interrupted by SIGTERM or
  context exhaustion.

---

## Control Flow: Full Traces

### Full Trace: `gt done` for a Polecat (COMPLETED, MR strategy)

```
polecat session runs: gt done
│
├─ 1. Guard check: BD_ACTOR must be polecats/* (done.go:87)
├─ 2. workspace.FindFromCwdWithFallback → townRoot, cwd (done.go:105)
├─ 3. Determine rigName from path or GT_RIG env (done.go:122)
├─ 4. Reconstruct polecat cwd if shell reset cwd (done.go:149)
├─ 5. Normalize to git repo root (walk up from cwd to find .git) (done.go:172)
├─ 6. git.NewGit(cwd) (done.go:188)
├─ 7. g.CurrentBranch() → branch (done.go:214)
├─ 8. g.CheckUncommittedWork() → auto-detect cleanup status (done.go:234)
├─ 9. parseBranchName(branch) → issueID, worker (done.go:262)
├─ 10. GetRoleWithContext → agentBeadID (done.go:280)
├─ 11. getIssueFromAgentHook → fallback issueID from hook_bead (done.go:298)
├─ 12. setDoneIntentLabel → done-intent:COMPLETED:<ts> on agent bead (done.go:315)
├─ 13. readDoneCheckpoints → resume map (done.go:316)
│
├─ [COMPLETED path begins]
├─ 14. g.CommitsAhead(origin/main, HEAD) → verify work exists (done.go:363)
├─ 15. getConvoyInfoFromIssue/getConvoyInfoForIssue → mergeStrategy (done.go:455)
├─ 16. [mr strategy] g.Push("origin", branch+":"+branch) (done.go:533)
│       ├─ fallback: bareRepoPath push (done.go:540)
│       └─ fallback: mayorPath push (done.go:552)
├─ 17. g.RemoteBranchExists("origin", branch) → verify push (done.go:577)
├─ 18. [cleanup_status = "clean"] (done.go:600)
├─ 19. writeDoneCheckpoint(CheckpointPushed, branch) (done.go:607)
├─ 20. beads.DetectIntegrationBranch → target branch (done.go:707)
├─ 21. bd.Show(issueID) → inherit priority (done.go:718)
├─ 22. bd.FindMRForBranch(branch) → idempotency check (done.go:739)
├─ 23. bd.Create({type="merge-request", title="Merge: <issueID>",
│       description="branch: <branch>\ntarget: <target>\nsource_issue: <issueID>\n
│       rig: <rigName>\nworker: <worker>\nagent_bead: <agentBeadID>\n
│       retry_count: 0\nlast_conflict_sha: null\nconflict_task_id: null",
│       ephemeral=true}) → mrIssue (done.go:767)
├─ 24. bd.Show(mrID) → verify MR bead readable (done.go:800)
├─ 25. bd.UpdateAgentActiveMR(agentBeadID, mrID) (done.go:810)
├─ 26. writeDoneCheckpoint(CheckpointMRCreated, mrID) (done.go:827)
│
├─ [label: notifyWitness]
├─ 27. nudgeRefinery(rigName, "MERGE_READY ...") (done.go:853)
│       → tmux send-keys to gt-<rig>-refinery session
├─ 28. beads.New(beadsDir).UpdateAgentCompletion(agentBeadID, CompletionMetadata{
│       ExitType: "COMPLETED", MRID: mrID, Branch: branch,
│       HookBead: issueID, MRFailed: false, CompletionTime: RFC3339}) (done.go:863)
├─ 29. nudgeWitness(rigName, "POLECAT_DONE <polecatName> exit=COMPLETED") (done.go:878)
│       → tmux send-keys to gt-<rig>-witness session
├─ 30. writeDoneCheckpoint(CheckpointWitnessNotified, "ok") (done.go:884)
├─ 31. LogDone(townRoot, sender, issueID) → logs/town.log (done.go:888)
├─ 32. events.LogFeed(TypeDone, sender, {bead: issueID, branch: branch})
│       → .events.jsonl (done.go:891)
│
├─ 33. updateAgentStateOnDone (done.go:896)
│   ├─ bd.Show(agentBeadID) → read agent bead (done.go:1151)
│   ├─ [if hook_bead set]
│   │   ├─ bd.Show(hookedBeadID) → check status=hooked (done.go:1163)
│   │   ├─ ParseAttachmentFields → find attached molecule (done.go:1169)
│   │   ├─ closeDescendants(molecule) → close step children (done.go:1175)
│   │   ├─ bd.ForceCloseWithReason("done", molecule) (done.go:1183)
│   │   └─ bd.Close(hookedBeadID) (done.go:1198)
│   ├─ bd.ClearHookBead(agentBeadID) (done.go:1208)
│   ├─ bd.Run("agent", "state", agentBeadID, "done") (done.go:1223)
│   ├─ bd.UpdateAgentCleanupStatus(agentBeadID, "clean") (done.go:1232)
│   ├─ clearDoneIntentLabel (done.go:1242)
│   └─ clearDoneCheckpoints (done.go:1243)
│
└─ 34. [isPolecat] sync worktree to main
    ├─ g.Checkout(main) (done.go:920)
    ├─ g.Pull("origin", main) (done.go:922)
    └─ g.DeleteBranch(oldBranch, true) (done.go:931)
```

### Full Trace: Crew Direct-Push Workflow

Crew agents (persistent, not polecats) do not call `gt done`. They push directly
to `main` or use `gt mq submit` for more controlled delivery. The typical crew
workflow:

```
crew agent: git commit -m "..."
crew agent: git push origin main          # or: git push origin feature:main
crew agent: gt close <issueID>            # or: bd close <issueID>
  └─ runClose (close.go:44)
      ├─ exec.Command("bd", "close", issueID)
      └─ checkConvoyCompletion([issueID])
          └─ convoy.CheckConvoysForIssue(...)
              └─ runConvoyCheck → bd close <convoyID> if all done

# Alternatively for review-gated work:
crew agent: gt mq submit --no-cleanup
  └─ runMqSubmit (mq_submit.go:78)
      ├─ bd.Create(type=merge-request, ephemeral=true)
      └─ nudgeRefinery
```

The key difference: crew agents bypass the polecat-specific machinery:
- No `setDoneIntentLabel` / done-intent safety net
- No `CompletionMetadata` on agent bead (crew agents are persistent)
- No worktree sync / branch deletion
- No Witness nudge (witness patrols polecats, not crew)
- No `gt done` zero-commit guard

---

## MR Bead Submission Format

An MR bead created by `gt done` or `gt mq submit` has this structure:

```
Type:        merge-request
Title:       "Merge: <issueID>"
Priority:    inherited from source issue
Ephemeral:   true  (wisp)
Labels:      ["gt:merge-request"]
Description: |
  branch: polecat/furiosa-mkb0vq9f
  target: main
  source_issue: gt-abc
  rig: gastown
  worker: furiosa
  agent_bead: gt-xyz123
  retry_count: 0
  last_conflict_sha: null
  conflict_task_id: null
```

The Refinery reads the `branch:` line to find the git branch, `target:` for
the merge destination, and `source_issue:` to close the work item post-merge.

MR ID generation: `internal/mq/id.go` — `GenerateMRID(prefix, branch)`:
```
SHA256(branch + ":" + timestamp.UnixNano() + ":" + 8 random bytes)[:10 hex chars]
→ e.g., "gt-mr-abc1234567"
```

---

## How `bd close` Works — Evidence Captured

`gt close` is a thin wrapper around `bd close` (close.go:64). The `bd close`
CLI is the Beads SDK binary; Gas Town does not own that code path.

What Gas Town adds on top of `bd close`:
1. Converts `--comment` flag to `--reason` alias (close.go:51).
2. After successful `bd close`, calls `checkConvoyCompletion` for all closed
   bead IDs.

Evidence captured by the close operation is stored inside the beads Dolt
database:
- `status` field set to `"closed"`
- `closed_at` timestamp
- `close_reason` field (the `--reason` argument)
- `assignee` field preserved (for audit — `gt audit` queries `assignee` on
  closed beads to attribute work, cmd/audit.go:295)

The `DetachMoleculeWithAudit` function (beads/audit.go:32) writes an explicit
audit log entry to `.beads/audit.log` (JSONL) for molecule detach operations,
capturing: timestamp, operation type, pinned bead ID, detached molecule ID,
who triggered the detach, reason, and previous state.

---

## How Convoy Tracking Records Completion

Convoy tracking is stored as Beads dependency edges of type `"tracks"` between
the convoy bead and each tracked issue. Completion detection:

**Primary path (event-driven):** triggered from `gt close` (close.go:74):
```
bd close <issueID>
  → checkConvoyCompletion([issueID])
      → convoy.CheckConvoysForIssue
          → store.GetDependentsWithMetadata(issueID) filtered by type="tracks"
          → for each tracking convoy: runConvoyCheck
              → bd show <convoyID> --json (get tracked deps)
              → all status=closed or tombstone? → bd close <convoyID>
```

**Secondary path (polling-based):** the daemon's deacon patrol runs `gt convoy
check` on a schedule as a backup, catching cases where the event-driven path
failed.

**Auto-close behavior:** when `checkSingleConvoy` determines all tracked issues
are closed, it runs `bd close <convoyID> -r "All tracked issues completed"`
then calls `notifyConvoyCompletion` to mail subscribers. An empty convoy (zero
tracked issues) is treated as definitionally complete and is also auto-closed
(done.go comment: "tracking deps were likely lost").

**Convoy does not auto-reopen:** once closed, a convoy is immutable unless
explicitly reopened via `gt convoy add` which adds new tracked issues.

---

## Metadata Attached to Delivered Work

### On the Agent Bead (written by `gt done`)

- `exit_type`: COMPLETED / ESCALATED / DEFERRED
- `mr_id`: ID of the created MR bead (empty if no MR)
- `branch`: the polecat working branch
- `hook_bead`: the work item ID (issueID)
- `mr_failed`: boolean
- `completion_time`: RFC3339 timestamp
- `cleanup_status`: clean / uncommitted / stash / unpushed / unknown
- `active_mr`: the MR bead ID cross-reference

Labels on agent bead (transient, cleared on clean exit):
- `done-intent:COMPLETED:<unix-ts>` — written early for Witness zombie detection
- `done-cp:pushed:<branch>:<ts>` — checkpoint: push completed
- `done-cp:mr-created:<mrID>:<ts>` — checkpoint: MR created
- `done-cp:witness-notified:ok:<ts>` — checkpoint: Witness nudged

### On the MR Bead (written at creation)

- `branch`, `target`, `source_issue`, `rig`, `worker`, `agent_bead` in description
- `retry_count`, `last_conflict_sha`, `conflict_task_id` (conflict resolution tracking)
- `merge_commit` (written by Refinery after successful merge)
- `close_reason` (written by Refinery: "Merged in <commit>")

### In the Events Log (`.events.jsonl`)

```json
{"ts":"2026-02-28T04:30:00Z","source":"gt","type":"done",
 "actor":"gastown/polecats/furiosa","payload":{"bead":"gt-abc","branch":"polecat/furiosa-mkb0vq9f"},
 "visibility":"feed"}
```

### In the TownLog (`logs/town.log`)

```
2026-02-28 04:30:00 [done] gastown/polecats/furiosa completed gt-abc
```

### In OTel Telemetry (VictoriaLogs via OTLP)

`RecordDone` (telemetry/recorder.go:413) emits:
- Counter: `gastown.done.total` with labels `status=ok/error`, `exit_type=COMPLETED`
- Log event: body=`"done"`, attrs: `exit_type`, `status`, `error`

---

## `gt audit` and `gt trail` — Querying Work History

### `gt audit` (cmd/audit.go)

Queries four data sources and merges into a unified timeline:

1. **Git commits** (`collectGitCommits`): `git log --format=%H|%aI|%an|%s --all`
   filtered by author name extracted from actor (e.g., `"greenplace/crew/joe"` →
   `"joe"`). Limited to 100 commits.

2. **Beads** (`collectBeadsActivity`): calls `bd.List(status=all)` on the
   gastown beads path and filters by `created_by` and `assignee` fields.
   Produces `bead_created` and `bead_closed` entries.

3. **TownLog** (`collectTownlogEvents`): reads `logs/town.log`, parses each
   line, filters by agent prefix match. Covers spawn, done, handoff, crash,
   kill, nudge events.

4. **Events feed** (`collectFeedEvents`): reads `.events.jsonl` line by line,
   filters by actor. Covers all `LogFeed`-written events.

Output is sorted newest-first and limited (default 50 entries). Supports
`--since` duration filter and `--json` output.

### `gt trail` (cmd/trail.go)

Three subcommands:
- `gt trail commits` — `git log` filtered by agent email domain suffix
- `gt trail beads` — calls `beads query` CLI (with `runTrailBeadsSimple`
  fallback to `beads list`)
- `gt trail hooks` — reads `.events.jsonl` backwards, filters for
  `TypeHook` / `TypeUnhook` events, returns last N hook/unhook entries

---

## `internal/beads/recording.go` — Is There an Audit Log?

There is **no file named `recording.go` in `internal/beads/`**. The file that
exists is `internal/beads/audit.go` which provides:

- `DetachAuditEntry` struct (timestamp, operation, pinnedBeadID,
  detachedMolecule, detachedBy, reason, previousState)
- `DetachMoleculeWithAudit` — remove molecule attachment + log to audit file
- `LogDetachAudit` — append JSONL entry to `.beads/audit.log` (fsync'd)

This covers only molecule detach/burn/squash operations. There is no general
"action recording" for all bead operations.

The file `internal/plugin/recording.go` provides `plugin.Recorder` which
records plugin run results as ephemeral beads with labels `type:plugin-run`,
`plugin:<name>`, `result:success/failure/skipped`, `rig:<name>`. This is
queried by `GetLastRun` / `GetRunsSince` for cooldown gate logic.

---

## `internal/activity/` — Relation to Work Evidence

`internal/activity/activity.go` provides purely **display-layer** logic:

- Calculates `Info{Duration, FormattedAge, ColorClass}` from a `last_activity`
  timestamp.
- Color thresholds: green <5 min (active), yellow 5-10 min (stale), red >10
  min (stuck).
- Used by the web dashboard and TUI feed to color-code agent status indicators.

It has **no connection to work evidence or delivery**. The `last_activity`
timestamp it operates on is read from agent bead fields or tmux pane activity
data (sourced from elsewhere). `activity.Calculate` is a pure function — it
neither reads nor writes any state.

---

## Key File References Summary

| File | Role |
|---|---|
| `internal/cmd/done.go` | Primary `gt done` implementation (1389 lines) |
| `internal/cmd/close.go` | `gt close` → `bd close` + convoy check |
| `internal/cmd/mq.go` | MQ command definitions and `runMQPostMerge` |
| `internal/cmd/mq_submit.go` | `gt mq submit` manual MR creation |
| `internal/cmd/wl_done.go` | Wasteland item completion |
| `internal/cmd/convoy.go` | Convoy commands including `runConvoyCheck` |
| `internal/cmd/audit.go` | `gt audit` — unified work history query |
| `internal/cmd/trail.go` | `gt trail` — recent commits, beads, hooks |
| `internal/cmd/activity.go` | `gt activity emit` — manual event emission |
| `internal/mq/id.go` | MR ID generation (SHA256-based) |
| `internal/refinery/types.go` | MR state machine, phase transitions |
| `internal/refinery/manager.go` | Refinery session management |
| `internal/convoy/operations.go` | `CheckConvoysForIssue`, `feedNextReadyIssue` |
| `internal/beads/audit.go` | Molecule detach audit log (`.beads/audit.log`) |
| `internal/beads/beads_agent.go` | `CompletionMetadata`, `UpdateAgentCompletion` |
| `internal/beads/beads_mr.go` | `FindMRForBranch` idempotency check |
| `internal/events/events.go` | Event types, `LogFeed` → `.events.jsonl` |
| `internal/townlog/logger.go` | `EventDone` → `logs/town.log` |
| `internal/telemetry/recorder.go` | `RecordDone` → OTel metrics + logs |
| `internal/activity/activity.go` | Display-only activity age calculation |
| `internal/plugin/recording.go` | Plugin run recording as ephemeral beads |
