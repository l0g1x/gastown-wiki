# Work Binding Layer — Investigation

> Reflects upstream commit: `ae11c53c`

**Date:** 2026-02-28
**Investigator:** Sherlock
**Source tree:** `/home/krystian/gt/gastown/crew/sherlock/internal/`

---

## 1. Architecture Overview

Work binding is the process of durably attaching a unit of work (a "bead") to an agent so that:
1. The bead enters a terminal-enough state (`hooked` or `in_progress`) preventing double-assignment.
2. The agent's **agent bead** records the current work bead ID in its `hook_bead` slot.
3. On session start/resume, `gt prime` reads the hook and injects the **AUTONOMOUS WORK MODE** block to propel the agent into execution immediately.

There are two primary write paths: `gt hook` (attach only, no session start) and `gt sling` (attach + start/nudge, with optional auto-spawn). These converge on the same low-level primitives and are documented below.

---

## 2. Key Data Structures

### 2.1 The Bead Status Field (`--status=hooked`)

A bead is a record in a Dolt-backed beads database, managed by the `bd` CLI. The binding primitive is the bead's `status` field:

```
open       → available, unassigned
hooked     → attached to an agent's hook (durable, survives restarts)
in_progress → agent has begun active work (may be set by session start)
closed     → work complete
```

The `assignee` field records which agent ID holds the hook:

```
gastown/polecats/Toast
gastown/crew/max
mayor/
gastown/witness
```

These are set atomically by `bd update <bead-id> --status=hooked --assignee=<agent-id>`.

### 2.2 The Agent Bead `hook_bead` Slot

Every agent has an **agent bead** (type=`agent`, label=`gt:agent`) whose description carries structured fields. The authoritative hook pointer is stored as a **database slot** via `bd slot set <agent-bead-id> hook <work-bead-id>`. The `hook_bead` field is also mirrored in the description text as `hook_bead: <id>` for backward compatibility.

Agent bead ID format:
- Polecat: `<prefix>-<rig>-polecat-<name>` (e.g., `gt-gastown-polecat-Toast`)
- Crew: `<prefix>-<rig>-crew-<name>`
- Witness: `<prefix>-<rig>-witness`
- Mayor: `hq-mayor`
- Deacon: `hq-deacon`

The `AgentFields` struct (`internal/beads/beads_agent.go:36`) captures the full agent bead shape:

```go
type AgentFields struct {
    RoleType          string // polecat, witness, refinery, deacon, mayor
    Rig               string
    AgentState        string // spawning, working, done, stuck, escalated, idle, running, nuked
    HookBead          string // Currently attached work bead ID
    CleanupStatus     string // git state self-report
    ActiveMR          string // Current merge request bead ID
    NotificationLevel string
    Mode              string // "" (normal) or "ralph"
    // Completion metadata:
    ExitType          string
    MRID, Branch      string
    MRFailed          bool
    CompletionTime    string
}
```

### 2.3 The `AttachmentFields` on the Work Bead

When a formula (molecule workflow) is applied to a work bead, metadata is embedded in the work bead's description as `key: value` lines. These fields are parsed by `gt prime` to determine what workflow the agent should follow:

```
attached_molecule: <wisp-root-id>    // The molecule (wisp) containing steps
attached_formula: mol-polecat-work   // Human-readable formula name (inline steps from binary)
attached_at: <iso8601>
attached_args: "patch release"       // Natural language instructions from --args
dispatched_by: <agent-id>
no_merge: true/false
mode: "" | "ralph"
convoy_id: hq-cv-abc
merge_strategy: direct | mr | local
```

Parsed by `beads.ParseAttachmentFields()` in `internal/beads/fields.go:27`.

### 2.4 The `SlingContextFields` (Deferred Dispatch Only)

When `max_polecats > 0` (capacity-controlled mode), work is not dispatched immediately but instead queued. An ephemeral **sling context bead** (label `gt:sling-context`) stores the full dispatch parameters as JSON in its description:

```go
// internal/scheduler/capacity/pipeline.go:18
type SlingContextFields struct {
    Version          int
    WorkBeadID       string  // The work bead to sling
    TargetRig        string  // Which rig to spawn into
    Formula          string  // mol-polecat-work or override
    Args, Vars       string
    EnqueuedAt       string
    Merge, BaseBranch, Account, Agent, Mode string
    NoMerge, HookRawBead, Owned bool
    DispatchFailures int     // circuit breaker
    LastFailure      string
}
```

The context bead has a `tracks` dependency pointing to the work bead. The daemon's dispatch loop reads these, calls `ReconstructFromContext()` to rebuild `DispatchParams`, and calls `executeSling()`.

---

## 3. Storage Locations

| Data | Where Stored | How Written |
|------|-------------|-------------|
| Bead `status=hooked` + `assignee` | Dolt beads DB (prefix-routed) | `bd update <id> --status=hooked --assignee=<agent>` |
| Agent bead `hook_bead` slot | Dolt agent bead (slot) | `bd slot set <agent-bead-id> hook <work-bead-id>` via `beads.SetHookBead()` |
| Agent bead description mirror | Same Dolt agent bead | `bd update <agent-bead-id> --description=...` |
| `AttachmentFields` on work bead | Work bead description in Dolt | `storeFieldsInBead()` via `bd update` |
| SlingContext bead (deferred) | Town root beads DB (`.beads/`) | `beads.CreateSlingContext()` |
| Scheduler state (`paused`, timestamps) | `<townRoot>/.runtime/scheduler-state.json` | JSON file, atomic write |
| Agent identity lock | `<workDir>/.runtime/agent.lock` | File lock via `lock.Acquire()` |

There is no separate file-based hook state. The Dolt beads database is the single source of truth. The `.runtime/` directory holds only ephemeral operational state (scheduler pause/resume, session IDs, identity locks).

---

## 4. Code Paths

### 4.1 `gt hook <bead-id>` — Attach Without Starting

File: `internal/cmd/hook.go`

```
runHookOrStatus()                       hook.go:188
  → runHook()                           hook.go:207
      1. Guard: polecats cannot hook    hook.go:221
      2. verifyBeadExists()
      3. resolveTargetAgent() or resolveSelfTarget()  sling_target.go:19/58
      4. beads.ResolveHookDir() — find correct DB dir
      5. b.List(StatusHooked, Assignee) — check existing hook
         a. If existing complete bead: close/unpin it
         b. If incomplete + --force: unpin it
         c. If incomplete, no --force: error
      6. bd update <bead-id> --status=hooked --assignee=<agentID>
         (with 5x retry, exponential backoff at hookBaseBackoff=500ms)
      7. updateAgentHookBead(agentID, beadID, workDir, townBeadsDir)
         sling_helpers.go:539 — sets agent bead's hook slot
      8. events.LogFeed(TypeHook, ...)
```

**Key difference from sling:** `gt hook` does NOT start a session, spawn a polecat, apply formulas, or nudge the agent. It is a pure "attach and persist" operation.

### 4.2 `gt sling <bead> <target>` — Unified Dispatch (Single Bead Path)

File: `internal/cmd/sling.go` — `runSling()` starting at line 161.

```
runSling()
  1. Guard: polecats cannot sling                      sling.go:176
  2. Validate --merge flag
  3. BD_DOLT_AUTO_COMMIT=off                           sling.go:201
  4. Handle --stdin
  5. Get townRoot
  6. Normalize trailing slashes from args
  7. ValidateTarget()
  8. shouldDeferDispatch()  →  if deferred mode → scheduleBead() / runBatchSchedule()
  9. Batch detection: len(args) > 2 with rig last → runBatchSling()
 10. Parse beadID and formulaName (verify existence)
 11. tryAcquireSlingBeadLock(townRoot, beadID)         sling_helpers.go — flock
 12. getBeadInfo(beadID)
     Guard: closed/tombstone/deferred/flag-like title
     Guard: already hooked/in_progress → idempotency check or auto-force (dead agent)
 13. resolveTarget(target, opts)                       sling_target.go:127
     → "" / "." → resolveSelfTarget()
     → dog target → DispatchToDog() (deferred session start)
     → rig name → spawnPolecatForSling() — allocates/reuses polecat worktree
     → existing agent path → resolveTargetAgent() → find tmux session pane
 14. Cross-rig guard: checkCrossRigGuard()
 15. Force path: if reassigning a live agent:
     → Send LIFECYCLE:Shutdown mail to old rig's witness
     → bd update <bead-id> --status=open --assignee= (unhook old agent)
 16. Auto-convoy: isTrackedByConvoy() → createAutoConvoy()
 17. Auto-apply mol-polecat-work for polecat targets (unless --hook-raw-bead)
 18. Burn stale molecules if re-slinging with --force
 19. Dry-run exit
 20. InstantiateFormulaOnBead() — creates wisp, bonds to bead
     → result.WispRootID = attachedMoleculeID
 21. hookBeadWithRetry(beadID, targetAgent, hookDir)   sling_helpers.go
     → bd update <bead-id> --status=hooked --assignee=<agent> (with retry)
 22. events.LogFeed(TypeSling, ...)
 23. updateAgentHookBead(targetAgent, beadID, ...)     sling_helpers.go:539
 24. storeFieldsInBead(beadID, fieldUpdates)
     → single read-modify-write: dispatcher, args, attached_molecule,
       attached_formula, no_merge, mode
 25. Start delayed dog session (if dog target)
 26. newPolecatInfo.StartSession()                     polecat_spawn.go:304
     → polecatSessMgr.Start() (tmux new-window)
     → t.WaitForRuntimeReady() — prompt polling
     → SetAgentStateWithRetry("working")
     → SetState(StateWorking) — sets in_progress on the hooked bead
 27. Nudge existing agents (injectStartPrompt to tmux pane)
     or report "self-sling, will process on next turn"
```

### 4.3 `executeSling()` — Unified Batch/Queue Dispatch Path

File: `internal/cmd/sling_dispatch.go:84`

Used by **batch sling** and **queue dispatch** (deferred mode). The single-sling `runSling()` does NOT yet use this path (see TODO comment at line 600 of `sling.go`).

```
executeSling(params SlingParams)
  0. Check rig parked/docked
  1. getBeadInfo() + status guards
  2. Dead-agent auto-force detection
  3. Shutdown mail to old polecat's witness (if force-stealing)
  4. Burn stale molecules (if formula + force)
  5. spawnPolecatForSling()                 polecat_spawn.go:60
     → FindIdlePolecat() (persistent polecat pool, reuse)
     → AllocateName() → AddWithOptions() / ReuseIdlePolecat()
     → polecat.AddOptions{HookBead: params.BeadID} ← ATOMIC HOOK SET AT SPAWN
  6. createAutoConvoy() (unless NoConvoy)
  7. CookFormula()
  8. InstantiateFormulaOnBead()
  9. hookBeadWithRetry(beadToHook, targetAgent, hookDir)
 10. events.LogFeed(TypeSling, ...)
 11. updateAgentHookBead()
 12. storeFieldsInBead()
 13. spawnInfo.StartSession()
```

**Key difference from `runSling`**: The hook bead is set **atomically at spawn time** (step 5, via `polecat.AddOptions.HookBead`). This means the polecat's agent bead has `hook_bead` set before the tmux session is created, eliminating the TOCTOU race. `runSling` does it post-spawn in step 23.

### 4.4 `gt hook` Subcommands

All subcommands delegate to two underlying functions:

| Subcommand | Implementation |
|------------|---------------|
| `gt hook` (no args) | `runMoleculeStatus()` — show status |
| `gt hook <bead>` | `runHook()` — attach |
| `gt hook status` | `runMoleculeStatus()` |
| `gt hook show [agent]` | `runHookShow()` — compact one-line display |
| `gt hook attach <bead> [target]` | `runHook()` |
| `gt hook detach <bead> [target]` | `runUnslingWith()` |
| `gt hook clear [bead] [target]` | `runUnslingWith()` via `runHookClear()` |

`hookShowCmd` performs a multi-level search:
1. Local rig beads: `b.List(StatusHooked, Assignee=target)`
2. Town beads (for `hq-*` convoy beads): `townBeads.List(...)`
3. If still empty and town-level role: `scanAllRigsForHookedBeads()`

### 4.5 `gt mol attach` — Molecule Binding

File: `internal/cmd/molecule_attach.go:15`

This attaches an existing molecule to a hook (pinned) bead. Used when a molecule was created independently of sling.

```
runMoleculeAttach(args)
  1. findLocalBeadsDir()
  2. If 1 arg: auto-detect pinnedBeadID via b.FindHandoffBead(role)
  3. b.AttachMolecule(pinnedBeadID, moleculeID)
     → reads current issue, sets attachment fields in description
     → beads.SetAttachmentFields(issue, fields)
     → b.Update(pinnedBeadID, UpdateOptions{Description: &newDesc})
```

`b.AttachMolecule()` is in `internal/beads/handoff.go:190`. It performs a read-modify-write on the work bead description, embedding `attached_molecule: <id>` and `attached_at: <timestamp>`.

### 4.6 `gt mol attach-from-mail` — Mail-to-Hook Bridge

File: `internal/cmd/molecule_attach_from_mail.go:19`

This is the integration point between the mail system and work binding. When an agent receives a mail containing a molecule ID, it can attach it directly to its hook.

```
runMoleculeAttachFromMail(mailID)
  1. detectAgentRole and identity from GT_ROLE / cwd
  2. router.GetMailbox(agentIdentity)
  3. mailbox.Get(mailID)
  4. extractMoleculeIDFromMail(msg.Body)
     Scans for: attached_molecule:, molecule_id:, molecule:, mol: patterns
  5. b.List(StatusPinned, Assignee=agentIdentity) → find hook bead
  6. b.Show(moleculeID) → verify exists
  7. b.AttachMolecule(hookBead.ID, moleculeID)
  8. mailbox.MarkRead(mailID)
```

This is a lower-level flow where the **caller is responsible** for finding the mail with the molecule reference. The pattern enables remote coordination: Mayor sends a mail containing `attached_molecule: <id>`, a crew agent calls `gt mol attach-from-mail <mail-id>`, and the molecule is now bound.

### 4.7 `gt unsling` / `gt unhook` / `gt hook clear` — Work Removal

File: `internal/cmd/unsling.go:57`

```
runUnslingWith(args, dryRun, force)
  1. Parse args: [bead-id] [target-agent]
  2. resolveTargetAgent() or resolveSelfTarget()
  3. agentIDToBeadID() — convert to agent bead ID
  4. beads.ResolveHookDir() — find correct DB
  5. b.Show(agentBeadID) — get agent bead (fallback: query by status)
  6. Read hookedBeadID from agentBead.HookBead
     Fallback 1: query b.List(StatusHooked, Assignee=agentID) — stale beads
     Fallback 2: town beads (for hq-* beads, GT-dtq7)
  7. Guard: if bead incomplete and !force → error
  8. b.ClearHookBead(agentBeadID)    → bd slot clear <agent-bead> hook
  9. hookedB.Update(hookedBeadID, {Status: "open", Assignee: ""})
     → resets bead status from "hooked" back to "open"
 10. events.LogFeed(TypeUnhook, ...)
```

`cleanStaleHookedBeads()` handles the consistency case where `hook_bead` was cleared (e.g., by another process) but the bead's own `status` was not reset — finds and resets these.

### 4.8 `gt done` — Completion Signaling

File: `internal/cmd/done.go` (brief coverage per spec).

`gt done` is the inverse of sling from the polecat's perspective:
1. Submits branch to merge queue (`gt mq submit`)
2. Writes completion metadata to agent bead (`beads.UpdateAgentCompletion()`)
3. Sends POLECAT_DONE notification to witness (nudge, not mail)
4. Transitions polecat to IDLE state (sandbox preserved)

The witness reads `exit_type`, `mr_id`, `branch`, `completion_time` from the agent bead description to discover completion state rather than waiting for a mail.

---

## 5. Propulsion: How `gt prime` Triggers Execution

File: `internal/cmd/prime.go` — `checkSlungWork()` at line 421.

When `gt prime --hook` runs at session start (Claude Code `SessionStart` hook), the flow is:

```
runPrime()
  1. handlePrimeHookMode() — read session ID from stdin, persist it
  2. checkHandoffMarker() — detect compaction/handoff cycles
  3. GetRoleWithContext() — detect agent role
  4. isCompactResume() → if true: runPrimeCompactResume() (lighter output)
  5. outputRoleContext() — emit role-specific docs/context
  6. checkSlungWork(ctx)                               prime.go:421
     → findAgentWork(ctx)                             prime.go:449
         Primary: agent bead's hook_bead slot
           → ab.Show(agentBeadID) → agentBead.HookBead → hb.Show(hookBead)
           → returns if status == "hooked" or "in_progress"
         Fallback: b.List(StatusHooked, Assignee=agentID)
         Fallback: in_progress beads
         Fallback: town beads (hq-* for rig-level agents)
         Retry loop (3x, 2s delay) for polecats/crew (race with SetHookBead)
     → if bead found:
         outputAutonomousDirective(ctx, hookedBead, hasMolecule)
         outputHookedBeadDetails(hookedBead)
         if hasMolecule:
           outputMoleculeWorkflow(ctx, attachment)    prime.go:601
             → showFormulaStepsFull(formulaName)     prime_molecule.go:136
               (reads embedded formula binary, prints checklist)
             or showMoleculeExecutionPrompt()         prime_molecule.go:36
               (calls bd mol current, shows next step)
         else:
           outputBeadPreview(hookedBead)              (bd show output)
  7. If no hooked work: outputStartupDirective(ctx) — normal startup
```

### The `## 🚨 AUTONOMOUS WORK MODE 🚨` Block

Generated by `outputAutonomousDirective()` at `prime.go:543`:

```
## 🚨 AUTONOMOUS WORK MODE 🚨

Work is on your hook. After announcing your role, begin IMMEDIATELY.

This is physics, not politeness...

1. Announce: "Rig Polecat Toast, checking in." (ONE line, no elaboration)
2. This bead has an ATTACHED FORMULA (workflow checklist) [if molecule]
3. Work through formula steps in order — see checklist below [if molecule]
4. When all steps complete, run `gt done`
OR
2. Then IMMEDIATELY run: `bd show <bead-id>` [if no molecule]
3. Begin execution - no waiting for user input

DO NOT: wait for user, ask questions, describe what you're going to do, check mail first
```

This is the propulsion: it injects a mandatory execution directive into the LLM's context at session start. The agent's role-specific prime content appeared before this, but this block overrides the normal startup directive.

---

## 6. Auto-Spawning: How `gt sling` Creates a Polecat

File: `internal/cmd/polecat_spawn.go` — `SpawnPolecatForSling()` at line 60.

Triggered when `resolveTarget()` sees a rig name as target (`IsRigName(target)` returns true).

```
SpawnPolecatForSling(rigName, opts)
  1. workspace.FindFromCwdOrError()
  2. Load rigs.json config
  3. polecatMgr.CheckDoltHealth()        — pre-spawn Dolt reachability
  4. polecatMgr.CheckDoltServerCapacity() — admission control (prevent storms)
  5. polecatMgr.FindIdlePolecat()        — persistent polecat pool reuse
     if idle found:
       polecatMgr.ReuseIdlePolecat(name, AddOptions{HookBead: opts.HookBead})
       or RepairWorktreeWithOptions() as fallback
     else:
       polecatMgr.AllocateName()          — from namepool
       polecatMgr.AddWithOptions(name,    — creates git worktree
         polecat.AddOptions{HookBead: opts.HookBead, BaseBranch: baseBranch})
  6. verifyWorktreeExists(clonePath)
  7. Return SpawnedPolecatInfo{..., Pane: ""}  — session start DEFERRED
     (StartSession() called separately after hook is set)
```

`SpawnedPolecatInfo.StartSession()` at `polecat_spawn.go:304`:
```
  1. Load rig config, resolve account
  2. polecatSessMgr.Start(polecatName, startOpts) — tmux new-window
  3. t.WaitForRuntimeReady() — poll for "❯ " prompt (Claude) or delay
  4. polecatMgr.SetAgentStateWithRetry("working")
  5. polecatMgr.SetState(StateWorking)  — hooked → in_progress on work bead
  6. getSessionPane(sessionName) → s.Pane
```

The deliberate deferral of `StartSession()` (after hook + formula are set) ensures the polecat sees its work when `gt prime` fires on session start. There is no race between hook-write and prime.

**Integration branch auto-detection:** Before spawn, `beads.DetectIntegrationBranch()` checks if the hooked bead's parent epic has an integration branch. If so, `baseBranch = "origin/<integration-branch>"` — the polecat worktree branches from the epic's integration branch rather than `main`.

---

## 7. Molecule State vs. Hook State

| Aspect | Hook State | Molecule State |
|--------|-----------|---------------|
| What it is | A bead assigned to an agent | A workflow scaffold (wisp tree) bonded to the work bead |
| Where stored | Work bead `status=hooked`, agent bead `hook_bead` slot | Bead description `attached_molecule: <wisp-id>` |
| Created by | `gt hook` or `gt sling` | `gt sling` auto-applies `mol-polecat-work`, or `gt mol attach` |
| Required | Yes — without `hooked` status, agent won't pick up work | No — polecats can work raw beads via `--hook-raw-bead` |
| Survives unsling? | No — unsling resets status to `open` | Partially — molecule wisp persists until burned; `attached_molecule` field is cleared |
| Read by prime? | Yes — `findAgentWork()` looks for hooked beads | Yes — `outputMoleculeWorkflow()` shows formula steps |

**Can you have one without the other?**

- **Hook without molecule:** Yes. Use `--hook-raw-bead` flag with `gt sling`, or `gt hook <bead>`. Prime shows a `bd show` preview instead of formula steps.
- **Molecule without hook:** Yes, but the agent won't pick it up automatically. `gt mol attach <bead> <molecule>` binds a molecule to a bead without hooking it. The agent must then be explicitly hooked via `gt hook`.

In normal polecat dispatch, both are set together: sling hooks the bead AND attaches `mol-polecat-work`. The formula wisp contains the step-by-step workflow checklist.

---

## 8. Interfaces to Adjacent Systems

### Session Container (Polecat Auto-Spawn)

`resolveTarget()` in `sling_target.go:127` dispatches to `spawnPolecatForSling()` when the target is a rig name. The `SpawnedPolecatInfo.StartSession()` method (deferred) wires the session lifecycle to the hook state.

### Prompt Assembly (Propulsion)

`gt prime --hook` is registered as a Claude Code `SessionStart` hook in `.claude/settings.json`. It reads the agent bead's `hook_bead` slot, fetches the work bead, and injects:
- The `## AUTONOMOUS WORK MODE` block (urgent)
- Hooked bead details
- Formula checklist (inline from embedded binary) or `bd mol current` output

### Communication (Mail-to-Hook)

`gt mol attach-from-mail <mail-id>` bridges mail to work binding. The mail body must contain one of: `attached_molecule:`, `molecule_id:`, `molecule:`, or `mol:` fields. This is used for remote coordination where a coordinator sends molecule IDs by mail.

`gt sling --force` sends `LIFECYCLE:Shutdown` mail to the old polecat's witness when force-stealing a bead, via `mail.Router.Send()`.

### Capacity Scheduler (Deferred Dispatch)

When `max_polecats > N` in `mayor/town.json`, `gt sling` redirects to `scheduleBead()` → `beads.CreateSlingContext()`. The daemon's dispatch loop polls for context beads with `LabelSlingContext`, calls `ReconstructFromContext()`, and invokes `executeSling()`.

### Witness (Coordination)

`wakeRigAgents(rigName)` in `sling_helpers.go:589` is called after polecat spawn to boot the rig and nudge the witness. The witness monitors polecat state and handles `LIFECYCLE:Shutdown` messages.

---

## 9. Full Control Flow Traces

### Trace A: `gt sling gt-abc gastown` (rig target, normal mode)

```
runSling()                              sling.go:161
  shouldDeferDispatch() → false         (max_polecats <= 0)
  tryAcquireSlingBeadLock(beadID)
  getBeadInfo("gt-abc")                 status=open, ok
  resolveTarget("gastown", opts)        sling_target.go:127
    IsRigName("gastown") → true
    IsRigParkedOrDocked() → false
    spawnPolecatForSling("gastown", {HookBead:"gt-abc"})
      polecatMgr.FindIdlePolecat() → nil (no idle)
      polecatMgr.AllocateName() → "Toast"
      polecatMgr.AddWithOptions("Toast", {HookBead:"gt-abc"})
        → git worktree add rig/polecats/Toast
        → beads.CreateOrReopenAgentBead("gt-gastown-polecat-Toast", ...)
           with HookBead="gt-abc" → bd slot set ... hook gt-abc  (ATOMIC)
      return SpawnedPolecatInfo{PolecatName:"Toast", ClonePath:..., Pane:""}
    wakeRigAgents("gastown")
    return ResolvedTarget{Agent:"gastown/polecats/Toast", NewPolecatInfo:..., HookSetAtomically:true}
  checkCrossRigGuard("gt-abc", "gastown/polecats/Toast") → ok
  createAutoConvoy("gt-abc", "Fix the widget bug", ...)
  formulaName = "mol-polecat-work"      (auto-applied)
  InstantiateFormulaOnBead("mol-polecat-work", "gt-abc", ...)
    → bd cook mol-polecat-work
    → bd mol wisp mol-polecat-work --var feature="Fix..." --var issue="gt-abc"
    → bd mol bond <wisp-root> gt-abc
    → return {WispRootID: "gt-abc.1"}
  hookBeadWithRetry("gt-abc", "gastown/polecats/Toast", hookDir)
    → bd update gt-abc --status=hooked --assignee=gastown/polecats/Toast
  events.LogFeed(TypeSling, ...)
  updateAgentHookBead("gastown/polecats/Toast", "gt-abc", ...)  ← skipped (HookSetAtomically=true)
  storeFieldsInBead("gt-abc", {Dispatcher:..., AttachedMolecule:"gt-abc.1", ...})
    → bd update gt-abc --description="attached_molecule: gt-abc.1\n..."
  newPolecatInfo.StartSession()
    → polecatSessMgr.Start("Toast", ...)       ← tmux new-window gt-gastown-p-Toast
    → t.WaitForRuntimeReady(...)               ← poll for "❯ "
    → polecatMgr.SetAgentStateWithRetry("working")
    → polecatMgr.SetState(StateWorking)        ← bd update gt-abc --status=in_progress
  return nil   (success)

... (polecat Toast starts) ...

gt prime --hook   (SessionStart hook fires in Toast's session)
  handlePrimeHookMode()                  ← reads session_id from stdin
  GetRoleWithContext() → polecat, rig=gastown, name=Toast
  checkSlungWork(ctx)
    findAgentWork(ctx)
      agentBeadID = "gt-gastown-polecat-Toast"
      ab.Show("gt-gastown-polecat-Toast") → agentBead.HookBead = "gt-abc"
      hb.Show("gt-abc") → status=in_progress → FOUND
    outputAutonomousDirective(...)
      → "## 🚨 AUTONOMOUS WORK MODE 🚨" ...
      → "1. Announce: gastown Polecat Toast, checking in."
      → "2. This bead has an ATTACHED FORMULA"
    outputHookedBeadDetails(hookedBead)
    outputMoleculeWorkflow(ctx, attachment)
      showFormulaStepsFull("mol-polecat-work")
        → reads embedded formula binary
        → prints step checklist
  → agent sees AUTONOMOUS WORK MODE, announces, begins immediately
```

### Trace B: `gt hook attach gt-abc gastown/polecats/Toast`

```
runHook(cmd, ["gt-abc", "gastown/polecats/Toast"])
  Guard: not a polecat
  verifyBeadExists("gt-abc") → ok
  resolveTargetAgent("gastown/polecats/Toast")      sling_target.go:19
    resolveRoleToSession("gastown/polecats/Toast")
    sessionToAgentID(sessionName) → "gastown/polecats/Toast"
    getSessionPane(sessionName) → pane
    t.GetPaneWorkDir(sessionName) → /path/to/rig/polecats/Toast
  agentBeadID = agentIDToBeadID("gastown/polecats/Toast", townRoot)
    → "gt-gastown-polecat-Toast"
  beadsPath = beads.ResolveHookDir(townRoot, agentBeadID, fallbackPath)
  b.List(StatusHooked, Assignee="gastown/polecats/Toast") → [] (empty)
  (no existing hook to replace)
  bd update gt-abc --status=hooked --assignee=gastown/polecats/Toast
    (with 5x retry at 500ms exponential backoff)
  updateAgentHookBead("gastown/polecats/Toast", "gt-abc", workDir, townBeadsDir)
    → bd.SetHookBead("gt-gastown-polecat-Toast", "gt-abc")
       → bd slot set gt-gastown-polecat-Toast hook gt-abc
  events.LogFeed(TypeHook, ...)
```

Note: `gt hook attach` does NOT start a session, spawn, apply formula, or nudge. The agent will pick up the work at next `gt prime` invocation (session restart or compact/resume cycle).

---

## 10. Edge Cases and Guards

| Scenario | Guard | Location |
|----------|-------|----------|
| Re-slinging a live agent's bead | Check `isHookedAgentDeadFn()`, auto-force if dead | `sling.go:551`, `sling_dispatch.go:147` |
| Slinging a closed bead | Rejected; reopen first | `sling.go:532`, `sling_dispatch.go:133` |
| Slinging a deferred bead | Rejected unless `--force` | `sling.go:539`, `sling_dispatch.go:161` |
| Batch sling on closed bead | Graceful skip, not error | `sling_batch.go` |
| Formula already applied | Rejected unless `--force` (burns old molecule) | `sling.go:754` |
| Cross-rig bead/polecat mismatch | Error with suggestion | `sling.go:946` |
| Polecat parked/docked | Blocked before spawn | `sling_target.go:186`, `sling_dispatch.go:115` |
| hook_bead slot occupied | Clear + retry | `beads_agent.go:469` |
| Concurrent sling same bead | Per-bead flock lock | `sling.go:510`, `sling_dispatch.go:98` |
| Polecats calling sling | Blocked entirely | `sling.go:176`, `hook.go:221` |
| Stale hook (agent bead says hooked, bead cleared) | `cleanStaleHookedBeads()` resets bead status | `unsling.go:278` |
| Hook set but DB not propagated yet (timing race) | 3x retry with 2s sleep in `findAgentWork()` | `prime.go:459` |

---

## 11. Summary Answers to Investigation Questions

**Q1. What is a "hook"?**
A hook is a durable work assignment: bead `status=hooked` + `assignee=<agent-id>` in Dolt, plus `hook_bead=<bead-id>` in the agent's agent bead slot (`bd slot`). Stored exclusively in Dolt (no separate file).

**Q2. `gt sling` end-to-end?**
See Trace A above. Core flow: lock bead → guard checks → resolve/spawn target → convoy → formula → hook bead (bd update) → store fields → start session → nudge.

**Q3. `gt hook` subcommands?**
`attach` → `runHook()`: bd update + slot set + event log. `detach`/`clear` → `runUnslingWith()`: clear slot + reset bead to open. `show` → query by status=hooked + compact output. `status` → `runMoleculeStatus()`.

**Q4. `gt mol attach`?**
Writes `attached_molecule: <id>` and `attached_at:` into the work bead's description via read-modify-write (`beads.AttachMolecule()`). Does not change bead status.

**Q5. `gt mol attach-from-mail`?**
Reads a mail message, extracts a molecule ID from the body using regex patterns, finds the agent's pinned bead, calls `b.AttachMolecule()`. Marks mail read on success.

**Q6. Hook state persistence?**
Stored entirely in Dolt (bead `status`+`assignee` field, plus agent bead `hook` slot). Survives session restarts, compaction, and handoffs. No file-based state.

**Q7. What triggers propulsion?**
`gt prime --hook` (Claude Code SessionStart hook) calls `checkSlungWork()` → `findAgentWork()`. If a hooked bead is found, `outputAutonomousDirective()` injects the `## 🚨 AUTONOMOUS WORK MODE 🚨` block.

**Q8. Auto-spawning?**
`resolveTarget()` detects rig names via `IsRigName()`. It calls `spawnPolecatForSling()` which: checks Dolt health/capacity, tries idle polecat reuse (persistent polecat pool), otherwise allocates new name + creates git worktree. Session start is always deferred until after hook is set.

**Q9. `gt unsling`/`gt release`?**
`runUnslingWith()`: clears `hook_bead` slot on agent bead (`bd slot clear`), resets work bead to `status=open`, `assignee=""`.

**Q10. Hook state vs. molecule state?**
Independent. Hook state = bead status + agent slot. Molecule state = `attached_molecule` in bead description + wisp tree. Can have hook without molecule (`--hook-raw-bead`). Can have molecule without hook (attached but not hooked). Normal polecat dispatch sets both simultaneously.

**Q11. `SlingContext`?**
An ephemeral bead (`gt:sling-context` label) containing JSON-serialized `SlingContextFields` (work bead ID, target rig, formula, args, vars, enqueued time, circuit breaker failure count). Used only in deferred/capacity-controlled mode. Has a `tracks` dependency to the work bead. The daemon's dispatch loop reads these and reconstructs `DispatchParams` via `ReconstructFromContext()`.
