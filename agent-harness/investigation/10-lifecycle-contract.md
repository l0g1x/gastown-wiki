# Investigation 10: The Lifecycle Contract

> Reflects upstream commit: `ae11c53c`

**Scope**: The universal spawn → start → run → handoff → stop contract shared by all Gas Town agent roles.

**Primary sources examined**:
- `internal/session/` — lifecycle.go, startup.go, identity.go, stale.go, town.go, pidtrack.go, registry.go
- `internal/cmd/handoff.go` — handoff command (1500+ lines)
- `internal/cmd/prime.go` + `prime_session.go` — startup protocol
- `internal/cmd/crew_lifecycle.go` — crew start/stop
- `internal/cmd/polecat_spawn.go` — polecat spawn for sling
- `internal/cmd/seance.go` — predecessor session access
- `internal/cmd/checkpoint_cmd.go` — crash recovery surface
- `internal/checkpoint/checkpoint.go` — checkpoint data structure
- `internal/krc/krc.go`, `autoprune.go`, `decay.go` — keep-running chronicle
- `internal/keepalive/keepalive.go` — activity heartbeat
- `internal/beads/handoff.go` — handoff bead state

---

## 1. Architecture: The Lifecycle Contract End-to-End

Every Gas Town agent — regardless of role — follows the same lifecycle contract:

```
SPAWN (allocate identity + worktree)
  ↓
START (create tmux session, inject env, apply theme)
  ↓
PRIME (SessionStart hook → gt prime --hook → inject context)
  ↓
RUN (agent works; keepalive pings; checkpoint writes)
  ↓
HANDOFF (save state → mail-to-self → respawn pane)
  ↓
STOP (Ctrl-C → wait → KillSessionWithProcesses)
```

The key design principle is **tmux session reuse**: `gt handoff` does not kill and recreate a tmux session. It calls `tmux respawn-pane -k` which atomically replaces the running process inside the existing pane. The session name (e.g., `gt-gastown-crew-max`) is permanent; only the agent process inside it rotates.

---

## 2. State Machine

Each agent role participates in a universal state machine:

```
[NOT RUNNING]
     │
     │  spawn + start
     ▼
[PRIMING]  (gt prime --hook runs, session ID persisted, role context injected)
     │
     │  prime complete
     ▼
[READY / IDLE]  (no hooked work; waiting for assignment)
     │
     │  bead hooked / sling / mail
     ▼
[AUTONOMOUS]  (gt hook shows work; gt prime runs in AUTONOMOUS WORK MODE)
     │
     │  work complete → gt done / gt handoff
     ▼
[HANDOFF]  (state saved, mail sent, pane respawned)
     │                      │
     │  successor starts     │  crash / OOM / timeout
     ▼                      ▼
[PRIMING] ←←←←←←←← [CRASH-RECOVERY]
                       (checkpoint found by next prime)
```

The four `SessionState.State` values are enumerated in `prime_session.go`:
- `"normal"` — fresh start, no special state
- `"post-handoff"` — handoff marker file found (`.runtime/handoff`)
- `"crash-recovery"` — checkpoint file found (`.polecat-checkpoint.json`)
- `"autonomous"` — hooked/in-progress bead detected

---

## 3. `session.StartSession()` — The Unified Startup Path

**File**: `internal/session/lifecycle.go:136`

`StartSession` is the single function that all role managers call to create a tmux session. It replaced per-role duplicated startup logic across polecat, mayor, boot, deacon, witness, refinery, crew, and dog session managers.

### Signature

```go
func StartSession(t *tmux.Tmux, cfg SessionConfig) (_ *StartResult, retErr error)
```

### SessionConfig fields

| Field | Purpose |
|---|---|
| `SessionID` | Tmux session name (e.g., `gt-crew-max`) |
| `WorkDir` | Working directory for the session |
| `Role` | Agent role string (e.g., `"polecat"`, `"crew"`) |
| `TownRoot` | Root of the Gas Town workspace |
| `RigPath` | Rig directory (empty for town-level agents) |
| `RigName` | Rig name for env vars and theming |
| `AgentName` | Crew/polecat name within rig |
| `Command` | Pre-built startup command (skips beacon-based construction) |
| `Beacon` | Startup beacon config for `/resume` discovery |
| `Instructions` | Appended after beacon in startup prompt |
| `AgentOverride` | Non-default agent alias (e.g., `"opencode"`) |
| `ExtraEnv` | Additional env vars beyond standard set |
| `Theme` | Tmux theme to apply |
| `WaitForAgent` | Poll until agent command appears in pane |
| `WaitFatal` | If WaitForAgent fails → kill session + return error |
| `AcceptBypass` | Accept bypass permissions dialog |
| `ReadyDelay` | Wait for agent readiness (prompt polling or sleep) |
| `AutoRespawn` | Set auto-respawn hook (session survives crashes) |
| `RemainOnExit` | Set remain-on-exit immediately |
| `TrackPID` | Track pane PID to `.runtime/pids/<session>.pid` |
| `VerifySurvived` | Verify session is still alive after startup |

### Execution sequence (13 steps)

```
1.  ResolveRoleAgentConfig(role, townRoot, rigPath)
      → determines which agent binary to run (claude, opencode, codex…)

2.  EnsureSettingsForRole(settingsDir, workDir, role, runtimeConfig)
      → creates agent settings files if they don't exist

3.  buildPrompt(cfg)
      → FormatStartupBeacon() or BuildStartupPrompt()
      → Format: "[GAS TOWN] <recipient> <- <sender> • <timestamp> • <topic>"

4.  buildCommand(cfg, prompt)
      → config.BuildAgentStartupCommand(role, rigName, townRoot, rigPath, prompt)
      → OR BuildAgentStartupCommandWithAgentOverride(…, agentOverride)

5.  PrependEnv(command, ExtraEnv)  [if ExtraEnv set]

6.  t.NewSessionWithCommand(sessionID, workDir, command)
      → creates the tmux session with the agent invocation as its shell command

7.  t.SetRemainOnExit(sessionID, true)  [if RemainOnExit]

8.  AgentEnv(role, rig, agentName, townRoot, …)
      → GT_ROLE, GT_RIG, GT_AGENT, GT_PROCESS_NAMES, GT_ROOT, BD_ACTOR, …
    MergeRuntimeLivenessEnv(envVars, runtimeConfig)
      → adds GT_AGENT, GT_PROCESS_NAMES for liveness detection
    t.SetEnvironment(sessionID, k, v)  for each var

9.  t.ConfigureGasTownSession(sessionID, theme, rigName, agentName, role)
      [if Theme != nil]

10. t.WaitForCommand(sessionID, shells, timeout)
      [if WaitForAgent]

11. t.SetAutoRespawnHook(sessionID)  [if AutoRespawn]

12. t.AcceptStartupDialogs(sessionID)  [if AcceptBypass]

13. t.WaitForRuntimeReady(sessionID, runtimeConfig, timeout)
      [if ReadyDelay]
      → Prompt-polling for agents with ReadyPromptPrefix
      → ReadyDelayMs sleep for agents without prompt detection
```

Then optionally: verify session survived, track PID.

### Beacon format

```
[GAS TOWN] <recipient> <- <sender> • 2025-12-30T15:42 • <topic[:mol-id]>

Recipient examples: "crew max (rig: gastown)", "polecat Toast (rig: gastown)"
Sender: "mayor", "deacon", "self" (for handoff)
Topic: "cold-start", "handoff", "assigned", "patrol", "ready"
```

The beacon serves two purposes:
1. **Identity**: Makes sessions findable in `/resume` picker for predecessor discovery (`gt seance`)
2. **Propulsion**: The topic field tells the agent what to do immediately on startup

For `handoff`, `cold-start`, and `attach` topics, the beacon includes explicit instructions:
```
Check your hook and mail, then act on the hook if present:
1. `gt hook` - shows hooked work (if any)
2. `gt mail inbox` - check for messages
3. If work is hooked → execute it immediately
4. If nothing hooked → wait for instructions
```

---

## 4. Spawning by Entry Point

### 4a. `gt crew start <name>` — Crew Spawn

**File**: `internal/cmd/crew_lifecycle.go:263` (`runCrewStart`)

```
runCrewStart(args)
  → getCrewManager(rigName)            // resolve rig from cwd or arg
  → enumerate crewNames (or --all)
  → config.ResolveAccountConfigDir()  // resolve Claude account
  → [parallel] for each name:
      crewMgr.Start(name, crew.StartOptions{
          Account, ClaudeConfigDir, AgentOverride, ResumeSessionID,
          KillExisting, Topic
      })
```

Inside `crewMgr.Start()` (internal/crew package, not shown but called from here):
- Creates crew worktree at `<townRoot>/<rig>/crew/<name>/` if needed
- Calls `session.StartSession()` with `Role="crew"`, `SessionID="<prefix>-crew-<name>"`
- Sets `WaitForAgent=true`, `AutoRespawn=true`, `TrackPID=true`

Session name format: `gt-crew-<name>` (prefix = rig's beads prefix)

### 4b. `gt sling <bead> <rig>` → polecat spawn

**File**: `internal/cmd/polecat_spawn.go:60` (`SpawnPolecatForSling`)

Two-phase design: **spawn** (allocate + prepare worktree) is separate from **start** (create tmux session).

```
Phase 1: SpawnPolecatForSling(rigName, opts)
  → CheckDoltHealth()                    // pre-spawn health check
  → CheckDoltServerCapacity()            // admission control
  → polecatMgr.FindIdlePolecat()         // try to reuse idle polecat
      → if found: ReuseIdlePolecat() or RepairWorktreeWithOptions()
      → if not: AllocateName() → AddWithOptions() or RepairWorktreeWithOptions()
  → verifyWorktreeExists(clonePath)      // sanity check
  → events.LogFeed(TypeSpawn, …)
  → return SpawnedPolecatInfo{…, Pane: ""}

Phase 2 (called by sling after bead attachment):
  SpawnedPolecatInfo.StartSession()
  → polecat.NewSessionManager(t, r).Start(name, opts)
      → session.StartSession() with Role="polecat", WaitForAgent=true
  → t.WaitForRuntimeReady(sessionName, runtimeConfig, 30s)
  → polecatMgr.SetAgentStateWithRetry(name, "working")
  → polecatMgr.SetState(name, StateWorking)
  → getSessionPane(sessionName)   // verify session survived
```

The two-phase design is intentional: the hook (bead assignment) must be attached **before** the session starts so that `gt prime` on session start sees the hooked work and enters AUTONOMOUS WORK MODE immediately.

Session name format: `<prefix>-<polecatName>` (e.g., `gt-Toast`)

### 4c. Witness/Refinery start via `gt rig start` / `gt witness start`

**File**: `internal/cmd/witness.go:157` (`runWitnessStart`)

```
runWitnessStart(rigName)
  → checkRigNotParkedOrDocked(rigName)
  → witness.NewManager(r)
  → mgr.Start(foreground, agentOverride, envOverrides)
      → session.KillExistingSession() if checkAlive and zombie
      → OR return ErrAlreadyRunning if live session found
      → session.StartSession() with:
          Role="witness"
          SessionID="<prefix>-witness"
          WaitForAgent=true
          AutoRespawn=true  (witness must survive crashes)
          TrackPID=true
```

Refinery follows the same pattern. Both use `session.StartSession()` — the unified path.

---

## 5. The Startup Protocol (GUPP)

**GUPP** = Gas Town Universal Propulsion Principle

When an agent session starts, the startup protocol is:

```
Agent binary starts with beacon prompt in first turn
   ↓
SessionStart hook fires: gt prime --hook
   ↓
gt prime reads session ID from stdin JSON:
   {"session_id": "<uuid>", "source": "startup|resume|compact"}
   ↓
gt prime persists session ID to .runtime/session_id
   ↓
gt prime checks for handoff marker: .runtime/handoff
   → if found: output handoff warning, remove marker, set primeHandoffReason
   ↓
gt prime detects role from cwd + GT_ROLE
   ↓
gt prime calls setupPrimeSession():
   → acquireIdentityLock (prevents double-start)
   → ensureBeadsRedirect (sets BEADS_DIR for role context)
   → emitSessionEvent (logs to .events.jsonl for seance discovery)
   ↓
isCompactResume()? (source == "compact"|"resume" or reason == "compaction")
   → YES: runPrimeCompactResume() — lighter path, skip full role context
   → NO: outputRoleContext() — full formula + context file + handoff content
   ↓
detectSessionState() → "normal"|"post-handoff"|"crash-recovery"|"autonomous"
   ↓
if autonomous (hooked work found):
   outputMoleculeContext()
   outputCheckpointContext()   (if crash-recovery)
   [skip startup directive — agent goes directly to work]
else:
   outputStartupDirective()    (wait for instructions)
```

**File references**:
- `prime.go:101` — `runPrime()` orchestrates the above
- `prime_session.go:266` — `handlePrimeHookMode()` — reads session ID from stdin
- `prime_session.go:321` — `setupPrimeSession()` — identity lock + beads redirect + event emission
- `prime.go:187` — `runPrimeCompactResume()` — lighter compact/resume path
- `prime_session.go:214` — `detectSessionState()` — returns SessionState
- `prime_session.go:321` — `checkHandoffMarker()` — reads + removes `.runtime/handoff`

---

## 6. `gt handoff` — The Most Important Operation

**File**: `internal/cmd/handoff.go`

Handoff is the canonical way to end any agent session. It has three modes:

### Mode A: Normal handoff (most common)

```
runHandoff(args)
  → handoffAuto? → runHandoffAuto()
  → handoffCycle? → runHandoffCycle()
  → detect isPolecat via GT_ROLE
      → if polecat: exec "gt done --status DEFERRED" (Witness handles lifecycle)
  → handoffCollect? → collectHandoffState() into message
  → resolve callerSocket, townTmux
  → get pane from TMUX_PANE
  → getCurrentTmuxSession() → prefer GT_ROLE over tmux display-message
  → warnHandoffGitStatus()   (uncommitted/unpushed work warning)
  → if arg is bead ID: hookBeadForHandoff(arg)
  → if arg is role name: resolveRoleToSession(arg) → targetSession
  → buildRestartCommand(targetSession)
  → if targetSession != currentSession: handoffRemoteSession()
  → [SELF-HANDOFF]
  → cleanupMoleculeOnHandoff()
  → LogHandoff() + events.LogFeed(TypeHandoff, …)
  → if dry-run: print and exit
  → updateSessionEnvForHandoff()  (update GT_AGENT + GT_PROCESS_NAMES in tmux env)
  → sendHandoffMail(subject, message)
      → bd create --assignee <self> --ephemeral --priority 1 …
      → bd update <beadID> --status=hooked --assignee=<self>
      → returns beadID
  → write .runtime/handoff marker (predecessor session name)
  → t.SetRemainOnExit(pane, true)   (pane survives process death)
  → t.ClearHistory(pane)            (reset scrollback)
  → t.RespawnPane(pane, restartCmd) (ATOMIC: kills old process, starts new)
```

### The restart command

`buildRestartCommandWithOpts()` at `handoff.go:742` constructs:

```bash
cd <roleWorkDir> && export GT_ROLE=<gtRole> BD_ACTOR=<gtRole> GT_ROOT=<townRoot> \
  ANTHROPIC_API_KEY=<val> OTEL_*=<vals> NODE_OPTIONS=<agentVal|""> \
  GT_AGENT=<agent> GT_PROCESS_NAMES=<names> … && \
  exec <agentCmd> --settings <settingsPath> --print "<beacon>"
```

The beacon for self-handoff uses `topic: "handoff"` and `sender: "self"`.

If `ContinueSession=true` (for context cycling), the restart command uses `--continue` instead of a beacon, and the agent resumes its previous conversation silently.

### Mode B: `--auto` (state-save only, no respawn)

```
runHandoffAuto()
  → collectHandoffState()
  → sendHandoffMail(subject, message)
  → write .runtime/handoff marker
  → events.LogFeed(TypeHandoff, …)
```

Used by the **PreCompact hook** to save state before the LLM runtime compacts context. No tmux operations — the session continues after compaction.

### Mode C: `--cycle` (full session replacement, for PreCompact)

```
runHandoffCycle()
  → collectHandoffState()
  → sendHandoffMail() with auto-hooked mail
  → write .runtime/handoff marker with "\n<reason>" (e.g., "compaction")
  → LogHandoff() + events.LogFeed()
  → buildRestartCommandWithOpts(currentSession, {ContinueSession: true})
      → adds --continue flag, uses continuation prompt
  → t.SetRemainOnExit() + ClearHistory()
  → t.RespawnPane(pane, restartCmd)
```

The key difference from normal handoff: `--cycle` adds `--continue` so the new session resumes the conversation thread instead of starting fresh.

### Remote handoff (`gt handoff crew`, `gt handoff mayor`)

When `targetSession != currentSession`:
```
handoffRemoteSession(townTmux, targetSession, restartCmd)
  → t.HasSession(targetSession)
  → getSessionPane(targetSession)
  → t.SetRemainOnExit(targetPane, true)
  → t.KillPaneProcesses(targetPane)  [kill explicitly — remote doesn't self-kill]
  → t.ClearHistory(targetPane)
  → t.RespawnPane(targetPane, restartCmd)
  → if --watch: tmux switch-client -t targetSession
```

---

## 7. Handoff State Persistence

Three persistence mechanisms work together:

### 7a. Handoff mail (primary work state)

Created by `sendHandoffMail()` at `handoff.go:1154`:
- **Type**: Ephemeral bead with `gt:message` label
- **Assignee**: Self (agent's own identity)
- **Status**: `hooked` (immediately, atomically set by `bd update`)
- **Priority**: 1 (high — floats above normal mail)
- **Content**: Subject + collected state (git status, inbox summary, ready beads, in-progress)
- **Persistence**: In `.beads/` Dolt database

Because the mail is hooked to self, the successor session finds it via `gt hook` and `gt prime` sees it during `detectSessionState()` → `"autonomous"` state.

### 7b. Handoff marker file (anti-loop protection)

Written to: `<workDir>/.runtime/handoff`
Content: `<session_name>\n[reason]`
Cleared by: `gt prime` on next startup (after outputting the warning)

Purpose: prevents the "handoff loop bug" where a new session sees `/handoff` in its inherited context and incorrectly reruns it. The marker tells the new session: "handoff is DONE, that `/handoff` in context was from your predecessor."

**File**: `handoff.go:298-302` (write), `prime_session.go:321-341` (read + remove)

### 7c. Hook state (work assignment)

The hooked bead (`status=hooked`) on the agent identity bead's `hook_bead` field persists across session boundaries. It is not cleared on handoff — it remains hooked so the successor picks it up.

**File**: `beads/handoff.go` — `FindHandoffBead()`, `GetOrCreateHandoffBead()`, `AttachMolecule()`

The pinned "handoff bead" (role + "Handoff") is a permanent record that accumulates molecule attachment history. It is distinct from the ephemeral handoff mail.

---

## 8. Successor Session Pickup

After `RespawnPane` fires, the new agent instance starts in the same pane:

```
New agent starts with beacon: "[GAS TOWN] <role> <- self • <ts> • handoff"
  ↓
Beacon tells agent: "Check your hook and mail, then act on the hook if present"
  ↓
SessionStart hook fires: gt prime --hook
  ↓
gt prime reads handoff marker → prints warning → removes marker
  ↓
gt prime detects role (same as before, same workDir)
  ↓
detectSessionState() finds:
  - agent bead's hook_bead field → hooked bead
  - OR: bd list --status=hooked --assignee=<self> → hooked bead
  → state = "autonomous"
  ↓
outputMoleculeContext() — if molecule attached
outputCheckpointContext() — if checkpoint exists
[no startup directive — agent enters AUTONOMOUS WORK MODE immediately]
  ↓
Agent reads hook: "gt hook" → sees the handoff mail
Agent reads mail: "gt mail inbox" → sees the collected state
Agent continues work from where predecessor left off
```

---

## 9. Context Cycling

Context cycling is the mechanism for handling full context windows:

```
Context fills up (LLM token limit approaching)
  ↓
LLM runtime fires PreCompact hook
  ↓
[Mode A: --auto]: gt handoff --auto --reason compaction
  → save state, write marker, NO respawn
  → LLM runtime compacts context
  → LLM runtime fires SessionStart hook with source="compact"
  → gt prime reads source="compact" → isCompactResume() = true
  → runPrimeCompactResume() — brief identity + hook check, skip full re-init

[Mode B: --cycle]: gt handoff --cycle --reason compaction
  → save state, write marker with "\ncompaction", respawn pane with --continue
  → new session starts, reads handoff marker, primeHandoffReason = "compaction"
  → isCompactResume() = true (primeHandoffReason == "compaction")
  → runPrimeCompactResume() — continuation directive, not full restart
```

The `isCompactResume()` function at `prime.go:298`:
```go
func isCompactResume() bool {
    return primeHookSource == "compact" || primeHookSource == "resume" ||
           primeHandoffReason == "compaction"
}
```

This prevents agents from "re-announcing" and re-initializing after compaction. Instead, they get a brief continuation: `"Context compacted. Continue your previous task."`.

---

## 10. `gt seance` — Predecessor Session Access

**File**: `internal/cmd/seance.go`

Seance lets agents talk to their predecessor sessions by resuming them with `--fork-session`.

```
gt seance --talk <session-id>
  → resolveSeanceCommand()  [find agent with SupportsForkSession=true]
  → cleanupOrphanedSessionSymlinks()
  → resolveSessionPrefix(townRoot, sessionID)  [expand prefix to full UUID]
  → symlinkSessionToCurrentAccount(townRoot, sessionID)
      → findSessionLocation(townRoot, sessionID)
          → search accounts.json → scan sessions-index.json files
          → fallback: scan ~/.claude/projects/ directly
      → create symlink: ~/.claude/projects/<projectDir>/<sessionID>.jsonl
      → update sessions-index.json (file-locked)
      → return cleanup func
  → exec: <agentCmd> --fork-session --resume <sessionID> [--print <prompt>]
```

Session discovery reads from `~/<townRoot>/.events.jsonl` looking for `session_start` events, which are emitted by `gt prime` via `emitSessionEvent()`.

`gt seance` (without `--talk`) lists discovered sessions:
```
gt seance [--role crew] [--rig gastown] [--recent 20]
  → discoverSessions(townRoot) — reads .events.jsonl, filters TypeSessionStart
  → sort by timestamp descending
  → display table: SESSION_ID, ROLE, STARTED, TOPIC
```

---

## 11. `internal/checkpoint/` — Crash Recovery

**File**: `internal/checkpoint/checkpoint.go`

Checkpoints are written by agents (polecats and crew only) at safe points. If the session crashes, the next session finds the checkpoint via `gt prime` → `detectSessionState()`.

### Checkpoint structure

```go
type Checkpoint struct {
    MoleculeID    string    // current molecule
    CurrentStep   string    // step ID in progress
    StepTitle     string    // human-readable step title
    ModifiedFiles []string  // git status --porcelain
    LastCommit    string    // git rev-parse HEAD
    Branch        string    // git rev-parse --abbrev-ref HEAD
    HookedBead    string    // bead ID on hook
    Timestamp     time.Time
    SessionID     string    // session that wrote checkpoint
    Notes         string    // optional context
}
```

### Checkpoint file location

`<polecatWorkDir>/.polecat-checkpoint.json`

### Checkpoint lifecycle

```
Agent writes checkpoint:
  gt checkpoint write [--notes "…"] [--molecule <id>] [--step <id>]
  → checkpoint.Capture(cwd)        [git state]
  → detectMoleculeContext()        [in-progress bead]
  → detectHookedBead()             [hooked bead]
  → checkpoint.Write(cwd, cp)      [atomic write]

Agent crashes / session dies

Next session starts → gt prime → detectSessionState():
  → checkpoint.Read(cwd)
  → if !IsStale(24h) → state = "crash-recovery"

gt prime outputs crash-recovery context to agent:
  outputCheckpointContext(ctx) — shows checkpoint summary

Agent sees: "Found checkpoint from <time> ago: molecule X, step Y, <N> modified files"
Agent continues work from checkpoint state
```

**Stale threshold**: 24 hours (`prime_session.go:230`). Older checkpoints are ignored.

---

## 12. `gt krc` — Key Record Chronicle (NOT "keep-running command")

**File**: `internal/cmd/krc.go`, `internal/krc/krc.go`

KRC manages TTL-based lifecycle for **Level 0 ephemeral operational data** — event streams, not agents. The acronym stands for "Key Record Chronicle."

KRC is **not** an agent auto-restart mechanism. It manages the `.events.jsonl` and `.feed.jsonl` files.

### Event TTLs (defaults)

| Event type | TTL | Decay curve |
|---|---|---|
| `patrol_*`, `polecat_checked`, `polecat_nudged` | 1 day | rapid |
| `session_start`, `session_end`, `nudge` | 3 days | steady |
| `handoff` | 7 days | steady |
| `hook`, `unhook`, `sling`, `done` | 14 days | slow |
| `mail`, `session_death` | 30 days | flat |
| `mass_death` | 90 days | flat |
| `merge_*` | 30 days | flat |

### Decay curves

- **Rapid** (f(x) = 2^(-4x)): value drops quickly — heartbeats, patrol noise
- **Steady** (linear): session events, nudges, handoffs
- **Slow** (f(x) = 2^(-x/0.75)): errors, escalations, work events
- **Flat**: full value until 90% of TTL, then cliff drop — audit events

### Auto-prune

```
gt krc prune --auto
  → LoadAutoPruneState(townRoot)     [.krc-autoprune.json]
  → ShouldPrune(PruneInterval)?      [default: 1 hour]
  → Pruner.Prune()                   [atomic: write .tmp → rename]
  → SaveAutoPruneState()
```

Called by the daemon (deacon) periodically. Keeps at least 100 events regardless of TTL.

---

## 13. "Landing the Plane" Protocol

"Landing the plane" is informal Gas Town terminology for graceful agent shutdown. The formal mechanism is:

```
[Agent is ready to stop]
  ↓
Agent runs: gt handoff
  OR
Operator runs: gt crew stop <name>  /  gt witness stop <rig>  / gt down
  ↓
[gt handoff path]
  → save state to hooked mail bead
  → write handoff marker
  → tmux respawn-pane (kills agent process, starts new)
  → NEW SESSION takes over work

[gt crew stop / gt down path]
  → send Ctrl-C to session (graceful shutdown signal)
  → WaitForSessionExit(timeout: constants.GracefulShutdownTimeout)
  → t.KillSessionWithProcesses(sessionID)
      → kills all processes in pane
      → then kills tmux session
```

`session.StopSession()` at `lifecycle.go:267`:
```go
func StopSession(t *tmux.Tmux, sessionID string, graceful bool) error {
    // check session exists
    if graceful {
        t.SendKeysRaw(sessionID, "C-c")
        WaitForSessionExit(t, sessionID, constants.GracefulShutdownTimeout)
    }
    t.KillSessionWithProcesses(sessionID)
}
```

Town-level shutdown order (from `town.go:22`):
```go
func TownSessions() []TownSession {
    return []TownSession{
        {"Mayor", MayorSessionName()},
        {"Boot", BootSessionName()},   // Boot first — stops Deacon watchdog
        {"Deacon", DeaconSessionName()},
    }
}
```

Boot must be stopped before Deacon, otherwise Boot restarts Deacon.

---

## 14. `internal/session/stale.go` — Stale Session Detection

**File**: `internal/session/stale.go`

Staleness is detected by comparing **message timestamps** against **session creation time**.

```go
func StaleReasonForTimes(messageTime, sessionCreated time.Time) (bool, string) {
    if messageTime.Before(sessionCreated) {
        return true, fmt.Sprintf("message=%s session_started=%s", ...)
    }
    return false, ""
}
```

A message is stale if it was sent **before the current session started**. This prevents agents from re-processing mail that was already handled by a predecessor session.

`SessionCreatedAt(sessionName)` uses `tmux.GetSessionInfo()` to read the session creation timestamp.

---

## 15. Keepalive Mechanism

**File**: `internal/keepalive/keepalive.go`

Keepalive signals agent activity to the daemon without blocking any operations.

```go
// Touch is called by gt commands inside the agent:
func Touch(command string)  // best-effort, silently ignores errors
```

Written to: `<workspaceRoot>/.runtime/keepalive.json`
```json
{
    "last_command": "gt hook",
    "timestamp": "2025-12-30T15:42:00Z"
}
```

Read by daemon via:
```go
state := keepalive.Read(workspaceRoot)
if state.Age() > 5*time.Minute {
    // Agent is idle — consider nudge or restart
}
```

**Nil sentinel pattern**: `Read()` returns nil if file missing/invalid. `State.Age()` accepts nil receiver and returns 365 days — "maximally stale". This simplifies daemon logic: no nil guards needed.

---

## 16. PID Tracking

**File**: `internal/session/pidtrack.go`

Defense-in-depth orphan prevention. Written to `<townRoot>/.runtime/pids/<sessionName>.pid`.

```
TrackSessionPID(townRoot, sessionID, t)
  → t.GetPanePID(sessionID)
  → processStartTime(pid)   [ps -o lstart= -p <pid>]
  → write "<pid>|<startTime>" to .runtime/pids/<sessionID>.pid
```

On shutdown: `KillTrackedPIDs(townRoot)` reads all `.pid` files, verifies start time (prevents PID reuse kills), sends SIGTERM, removes file.

---

## 17. Identity and Session Name Taxonomy

**File**: `internal/session/identity.go`, `internal/session/names.go`

### Session name format

| Role | Session name | Work dir |
|---|---|---|
| Mayor | `hq-mayor` | `<townRoot>/mayor/` |
| Deacon | `hq-deacon` | `<townRoot>/deacon/` |
| Boot | `hq-boot` | `<townRoot>/deacon/dogs/boot/` |
| Overseer | `hq-overseer` | `<townRoot>/deacon/` |
| Witness | `<prefix>-witness` | `<townRoot>/<rig>/witness/` |
| Refinery | `<prefix>-refinery` | `<townRoot>/<rig>/refinery/rig/` |
| Crew | `<prefix>-crew-<name>` | `<townRoot>/<rig>/crew/<name>/` |
| Polecat | `<prefix>-<name>` | `<townRoot>/<rig>/polecats/<name>/` |

The `<prefix>` is the rig's beads prefix (e.g., `gt` for `gastown`, `bd` for `beads`).

### Mail address format

```
mayor            → "mayor"
deacon           → "deacon"
gastown/witness  → "<rig>/witness"
gastown/refinery → "<rig>/refinery"
gastown/crew/max → "<rig>/crew/<name>"
gastown/polecats/Toast → "<rig>/polecats/<name>"
```

The `AgentIdentity.GTRole()` method returns the `GT_ROLE` env var value (same as `Address()` for most roles).

---

## 18. Code Path Summary

### Key function locations

| Function | File | Line | Purpose |
|---|---|---|---|
| `StartSession()` | `session/lifecycle.go` | 136 | Universal session creation |
| `StopSession()` | `session/lifecycle.go` | 267 | Universal session stop |
| `KillExistingSession()` | `session/lifecycle.go` | 350 | Kill zombie sessions |
| `FormatStartupBeacon()` | `session/startup.go` | 69 | Format beacon string |
| `BuildStartupPrompt()` | `session/startup.go` | 128 | Build beacon + instructions |
| `ParseSessionName()` | `session/identity.go` | 99 | Session name → AgentIdentity |
| `StaleReasonForTimes()` | `session/stale.go` | 32 | Detect stale messages |
| `TrackSessionPID()` | `session/pidtrack.go` | 44 | PID tracking |
| `KillTrackedPIDs()` | `session/pidtrack.go` | 85 | Orphan cleanup |
| `TownSessions()` | `session/town.go` | 22 | Shutdown order |
| `runHandoff()` | `cmd/handoff.go` | 89 | Main handoff flow |
| `runHandoffAuto()` | `cmd/handoff.go` | 338 | State-save-only handoff |
| `runHandoffCycle()` | `cmd/handoff.go` | 402 | Full cycle handoff |
| `buildRestartCommandWithOpts()` | `cmd/handoff.go` | 742 | Respawn command builder |
| `sendHandoffMail()` | `cmd/handoff.go` | 1154 | Create + hook ephemeral mail |
| `collectHandoffState()` | `cmd/handoff.go` | 1338 | Collect git + work state |
| `runPrime()` | `cmd/prime.go` | 101 | Prime orchestration |
| `runPrimeCompactResume()` | `cmd/prime.go` | 187 | Compact/resume lighter path |
| `isCompactResume()` | `cmd/prime.go` | 298 | Detect compact/resume |
| `handlePrimeHookMode()` | `cmd/prime.go` | 266 | Read session ID from stdin |
| `setupPrimeSession()` | `cmd/prime.go` | 320 | Lock + redirect + events |
| `detectSessionState()` | `cmd/prime_session.go` | 214 | Detect session state |
| `checkHandoffMarker()` | `cmd/prime_session.go` | 321 | Read + remove handoff marker |
| `emitSessionEvent()` | `cmd/prime_session.go` | 156 | Emit session_start event |
| `runCrewStart()` | `cmd/crew_lifecycle.go` | 263 | Crew start entry point |
| `runCrewStop()` | `cmd/crew_lifecycle.go` | 549 | Crew stop entry point |
| `SpawnPolecatForSling()` | `cmd/polecat_spawn.go` | 60 | Polecat phase 1 (allocate) |
| `SpawnedPolecatInfo.StartSession()` | `cmd/polecat_spawn.go` | 308 | Polecat phase 2 (start) |
| `runWitnessStart()` | `cmd/witness.go` | 157 | Witness start entry point |
| `runSeance()` | `cmd/seance.go` | 85 | Seance entry point |
| `runSeanceTalk()` | `cmd/seance.go` | 208 | Spawn fork-session agent |
| `checkpoint.Capture()` | `checkpoint/checkpoint.go` | 118 | Capture git state |
| `checkpoint.Read()` | `checkpoint/checkpoint.go` | 61 | Read checkpoint file |
| `checkpoint.Write()` | `checkpoint/checkpoint.go` | 81 | Write checkpoint file |
| `AutoPrune()` | `krc/autoprune.go` | 94 | Scheduled event pruning |
| `keepalive.Touch()` | `keepalive/keepalive.go` | 53 | Signal agent activity |
| `keepalive.Read()` | `keepalive/keepalive.go` | 103 | Read activity state |
| `beads.FindHandoffBead()` | `beads/handoff.go` | 29 | Find pinned handoff bead |
| `beads.AttachMolecule()` | `beads/handoff.go` | 183 | Attach molecule to pinned bead |

---

## 19. Interface Summary

The lifecycle contract connects to four major subsystems:

### Session container (tmux)
- Birth: `t.NewSessionWithCommand()` + `t.SetEnvironment()` + `t.ConfigureGasTownSession()`
- Death: `t.KillSessionWithProcesses()` (+ optional `t.SendKeysRaw("C-c")` for graceful)
- Handoff (birth-in-place): `t.RespawnPane(pane, restartCmd)` — atomic kill + respawn

### Prompt assembly (gt prime)
- Re-prime: SessionStart hook → `gt prime --hook`
- Context: formula file + handoff content + molecule context + checkpoint context
- State: `detectSessionState()` → normal/post-handoff/crash-recovery/autonomous
- Continuation: `runPrimeCompactResume()` for compact/resume (lighter path)

### Work binding (beads)
- Hook persistence: `status=hooked` bead survives across handoffs
- Handoff mail: ephemeral `status=hooked` mail bead created by `sendHandoffMail()`
- Pinned handoff bead: permanent `status=pinned` per-role bead with molecule attachment
- Checkpoint: `.polecat-checkpoint.json` in work directory

### Communication (mail/events)
- Handoff: ephemeral mail bead auto-hooked to self
- Session events: `.events.jsonl` via `events.LogFeed(TypeSessionStart, …)`
- Feed: `.feed.jsonl` for activity monitoring
- Seance: sessions discovered from `.events.jsonl` session_start events

---

## 20. Critical Design Decisions

### Tmux session reuse (not recreation)

Sessions are permanent containers. `gt handoff` uses `respawn-pane -k`, not `kill-session` + `new-session`. This means:
- The session name never changes across handoffs
- Environment variables persist in the tmux session (set via `SetEnvironment`)
- The pane ID may change but the session identity is stable
- The handoff marker prevents the new agent from accidentally re-running `/handoff`

### Polecat session start is deferred

`SpawnPolecatForSling()` returns a `SpawnedPolecatInfo` with empty `Pane`. The session is not started until `StartSession()` is called separately. This allows the bead hook to be attached before the session starts, ensuring `gt prime` sees the work assignment immediately.

### Liveness via process names, not session state

`GT_PROCESS_NAMES` contains the list of process names to check for agent liveness (e.g., `claude,node`). This is set in the tmux session environment and updated on every handoff. The daemon uses this to detect when an agent has died without going through `gt handoff`.

### "Discover, don't track" principle

Session events are discovered from the events feed, not from a central registry. `gt seance` reads `.events.jsonl` to find predecessor sessions. `gt prime` reads the handoff marker from the filesystem. The system is designed to work from observable filesystem state, not from explicitly maintained session registries.
