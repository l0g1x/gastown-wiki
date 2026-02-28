# Gas Town Prompt Assembly — Deep Investigation

> Reflects upstream commit: `ae11c53c`

**Date:** 2026-02-28
**Source:** `/home/krystian/gt/gastown/crew/sherlock/`
**Investigator:** Sherlock (Claude Sonnet 4.6)

---

## Architecture: The Complete Prompt Assembly Pipeline

Gas Town prompt assembly is a layered, role-aware, hook-driven system. It does not use a single monolithic "system prompt." Instead, context arrives through multiple injection mechanisms that stack on top of each other:

```
[Claude Code native loading]          ← CLAUDE.md hierarchy (always)
         +
[SessionStart hook → gt prime --hook] ← Role template, CONTEXT.md,
                                         handoff, attachment, molecule,
                                         checkpoint, bd prime, mail,
                                         escalations, autonomous directive
         +
[UserPromptSubmit hook]               ← gt mail check --inject
                                         (mail + queued nudges, each turn)
```

The primary assembly entrypoint is `gt prime`, which outputs a stream of Markdown sections to stdout. Claude Code captures this output and prepends it to the agent's context window at session start (and after compaction).

---

## Code Paths: Key Functions with File References

### Entry Point

**`runPrime`** — `/home/krystian/gt/gastown/crew/sherlock/internal/cmd/prime.go:101`

The full call graph for a fresh startup:

```
runPrime
  └─ validatePrimeFlags()                    prime.go:231
  └─ resolvePrimeWorkspace()                 prime.go:243
  └─ handlePrimeHookMode()                   prime.go:267  (if --hook)
       └─ readHookSessionID()                prime_session.go:31
            └─ readStdinJSON()               prime_session.go:53
       └─ persistSessionID()                 prime_session.go:88
  └─ checkHandoffMarker()                    prime_session.go:321
  └─ GetRoleWithContext()                    role.go:170
  └─ warnRoleMismatch()                      prime.go:303
  └─ setupPrimeSession()                     prime.go:322
       └─ acquireIdentityLock()              prime.go:756
       └─ ensureBeadsRedirect()              prime.go:852
       └─ emitSessionEvent()                 prime_session.go:156
  └─ isCompactResume()                       prime.go:298
  └─ outputRoleContext()                     prime.go:337
       └─ outputSessionMetadata()            prime_session.go:182
       └─ outputPrimeContext()               prime_output.go:22
            └─ templates.New()               templates/templates.go:121
            └─ tmpl.RenderRole()             templates/templates.go:141
       └─ outputContextFile()                prime_output.go:344
       └─ outputHandoffContent()             prime_output.go:358
       └─ outputAttachmentStatus()           prime_output.go:479
  └─ outputMoleculeContext()                 prime_molecule.go:183
  └─ outputCheckpointContext()               prime_output.go:607
  └─ runPrimeExternalTools()                 prime.go:356
       └─ runBdPrime()                       prime.go:368
       └─ runMailCheckInject()               prime.go:395
  └─ checkPendingEscalations()               prime.go:867  (mayor only)
  └─ checkSlungWork()                        prime.go:421
       └─ findAgentWork()                    prime.go:449
       └─ outputAutonomousDirective()        prime.go:542
  └─ outputStartupDirective()                prime_output.go:387
```

### Role Detection

**`GetRoleWithContext`** — `/home/krystian/gt/gastown/crew/sherlock/internal/cmd/role.go:170`

Priority:
1. `GT_ROLE` env var (authoritative)
2. `GT_RIG` / `GT_CREW` / `GT_POLECAT` env vars (fill gaps in compound role strings)
3. CWD-based detection via `detectRole()` — role.go:242

**`detectRole`** — `role.go:242`

Parses the path relative to town root by string matching:
- `mayor/...` → RoleMayor
- `deacon/dogs/boot/...` → RoleBoot
- `deacon/dogs/<name>/...` → RoleDog
- `deacon/...` → RoleDeacon
- `<rig>/mayor/...` → RoleMayor
- `<rig>/witness/...` → RoleWitness
- `<rig>/refinery/...` → RoleRefinery
- `<rig>/polecats/<name>/...` → RolePolecat
- `<rig>/crew/<name>/...` → RoleCrew

### Template Rendering

**`outputPrimeContext`** — `/home/krystian/gt/gastown/crew/sherlock/internal/cmd/prime_output.go:22`

Maps role → template name → calls `templates.New()` then `tmpl.RenderRole(roleName, data)`.

**`templates.New`** — `/home/krystian/gt/gastown/crew/sherlock/internal/templates/templates.go:121`

Loads embedded templates from the binary (`//go:embed roles/*.md.tmpl messages/*.md.tmpl`). No filesystem reads at runtime — templates are baked into the `gt` binary.

**`RenderRole`** — `templates.go:141`

Executes `<role>.md.tmpl` with a `RoleData` struct.

---

## State: What Inputs Feed Assembly

### The `RoleData` Struct

**Location:** `/home/krystian/gt/gastown/crew/sherlock/internal/templates/templates.go:54`

```go
type RoleData struct {
    Role          string   // "mayor", "witness", "refinery", "polecat", "crew", "deacon"
    RigName       string   // e.g., "greenplace"
    TownRoot      string   // e.g., "/home/krystian/gt"
    TownName      string   // e.g., "gt" — town identifier for session names
    WorkDir       string   // current working directory
    DefaultBranch string   // default branch for merges (e.g., "main")
    Polecat       string   // polecat/crew member name
    Polecats      []string // list of polecats (for witness role)
    DogName       string   // dog name (for dog role)
    BeadsDir      string   // BEADS_DIR path
    IssuePrefix   string   // beads issue prefix (e.g., "gt-")
    MayorSession  string   // e.g., "gt-ai-mayor"
    DeaconSession string   // e.g., "gt-ai-deacon"
}
```

All values are populated by `outputPrimeContext` at `prime_output.go:58–81` from the workspace, rig config, and session packages.

### Template Variables Available in Templates

Templates call `{{ .RigName }}`, `{{ .TownRoot }}`, `{{ .Polecat }}`, `{{ .WorkDir }}`, `{{ .MayorSession }}`, `{{ .DeaconSession }}`, `{{ .DefaultBranch }}`, `{{ .IssuePrefix }}` directly.

The `{{ cmd }}` function returns `$GT_COMMAND` or `"gt"`.

### Runtime State Sources

| Source | File / Path | Purpose |
|--------|------------|---------|
| `GT_ROLE` env var | set by sling or user | Authoritative role |
| `GT_RIG`, `GT_POLECAT`, `GT_CREW` | set by rig launch | Supplement compound role strings |
| `GT_SESSION_ID` / `CLAUDE_SESSION_ID` | set by hook mode | Session identity |
| stdin JSON | Claude Code → hook | `session_id`, `transcript_path`, `source` |
| `.runtime/session_id` | written by hook | Persisted session ID for seance |
| `.runtime/handoff_marker` | written by `gt handoff` | Post-handoff detection |
| `.beads/` (agent bead's `hook_bead` field) | Dolt DB | What work is on hook |
| `CONTEXT.md` at town root | operator-written | Custom per-town instructions |
| Handoff bead (pinned, role-keyed) | beads DB | Context from prior session |
| Checkpoint file | `.runtime/checkpoint.json` | Crash recovery for polecats/crew |
| `state.json` | `deacon/`, `witness/` etc. | Patrol tracking |
| Rig `settings/config.json` | `<rig>/settings/config.json` | Merge queue vars for refinery patrol |

---

## Interfaces: How Prompt Assembly Consumes Identity/Config

### Session Beacon (hook mode)

When `--hook` is set, `handlePrimeHookMode` (prime.go:267) reads stdin JSON:

```json
{"session_id": "uuid", "transcript_path": "/path/to/transcript", "source": "startup"}
```

The `source` field controls subsequent behavior:
- `"startup"` → full prime
- `"resume"` → compact/resume path (lighter output)
- `"compact"` → compact/resume path
- `"clear"` → compact/resume path

Session ID is written to stdout as `[session:uuid]` and source as `[source:startup]`. The ID is also persisted to `.runtime/session_id` in both cwd and town root.

### Role Template Selection

`outputPrimeContext` (prime_output.go:22) maps role to template:

| Role | Template |
|------|----------|
| `RoleMayor` | `roles/mayor.md.tmpl` |
| `RoleDeacon` | `roles/deacon.md.tmpl` |
| `RoleWitness` | `roles/witness.md.tmpl` |
| `RoleRefinery` | `roles/refinery.md.tmpl` |
| `RolePolecat` | `roles/polecat.md.tmpl` |
| `RoleCrew` | `roles/crew.md.tmpl` |
| `RoleBoot` | `roles/boot.md.tmpl` |
| `RoleDog` | `roles/dog.md.tmpl` |
| `RoleUnknown` | fallback hardcoded text |

Fallback path (`outputPrimeContextFallback`, prime_output.go:93) uses hardcoded Go string output if template loading fails.

### CONTEXT.md Injection

`outputContextFile` (prime_output.go:344) reads `<townRoot>/CONTEXT.md` and prints it verbatim. This is an operator-controlled plugin point visible to all agents. No CONTEXT.md means nothing is injected.

### CLAUDE.md Hierarchy

Claude Code natively loads CLAUDE.md files by walking up the directory tree. The Gas Town convention:

- **Actual role context** is stored in agent git worktrees (e.g., `mayor/rig/CLAUDE.md`), but these files are intentionally minimal stubs:
  ```markdown
  # Mayor Context (gastown)
  > **Recovery**: Run `gt prime` after compaction, clear, or new session
  Full context is injected by `gt prime` at session start.
  ```
- The rich context comes from the template rendered by `gt prime --hook` at session start.
- `AGENTS.md` files exist for compatibility with non-Claude agents, contain the same stub pointing to CLAUDE.md.

This means: CLAUDE.md provides minimal identity cues; `gt prime --hook` provides the full operational context.

---

## Control Flow: Full Trace of `gt prime --hook` for a Polecat

Scenario: Polecat `nux` in rig `gastown`, fresh startup (source=startup, work hooked).

### Phase 1: Hook Activation

Claude Code fires `SessionStart` hook from `.claude/settings.json`:
```json
{"command": "export PATH=... && gt prime --hook"}
```

Claude Code pipes to stdin:
```json
{"session_id": "abc-123", "transcript_path": "/tmp/transcript.jsonl", "source": "startup"}
```

### Phase 2: Entry — `runPrime` (prime.go:101)

1. `validatePrimeFlags()` — confirms `--hook` is compatible with other flags.
2. `resolvePrimeWorkspace()` — finds cwd = `/home/krystian/gt/gastown/polecats/nux`, townRoot = `/home/krystian/gt`.
3. `handlePrimeHookMode(townRoot, cwd)` — reads stdin JSON:
   - Parses `session_id="abc-123"`, `source="startup"`.
   - Writes `session_id` to `/home/krystian/gt/.runtime/session_id` and `/home/krystian/gt/gastown/polecats/nux/.runtime/session_id`.
   - Sets `GT_SESSION_ID=abc-123`.
   - Outputs: `[session:abc-123]\n[source:startup]\n`
   - Sets `primeHookSource = "startup"`.

### Phase 3: Handoff Check

`checkHandoffMarker(cwd)` (prime_session.go:321) — looks for `.runtime/handoff_marker`. Not found (fresh startup), nothing emitted.

### Phase 4: Role Detection

`GetRoleWithContext("/home/krystian/gt/gastown/polecats/nux", "/home/krystian/gt")`:
- `GT_ROLE` not set → falls back to `detectRole`.
- `detectRole` parses relative path `gastown/polecats/nux`:
  - `parts[0] = "gastown"` → rig = "gastown"
  - `parts[1] = "polecats"` → RolePolecat
  - `parts[2] = "nux"` → Polecat = "nux"
- Returns `RoleInfo{Role: RolePolecat, Rig: "gastown", Polecat: "nux"}`.

`warnRoleMismatch` — no mismatch, no output.

### Phase 5: Session Setup

`setupPrimeSession(ctx, roleInfo)`:
- `acquireIdentityLock` — writes `.runtime/agent.lock` in polecat's workdir (polecats/crew only).
- `ensureBeadsRedirect` — checks `.beads/redirect` exists (polecats share rig beads).
- `emitSessionEvent` — writes to `~/gt/.events.jsonl`.

### Phase 6: Full Prime (not compact/resume since source="startup")

`isCompactResume()` returns false.

### Phase 7: `outputRoleContext(ctx)` — main content assembly

**Step 7a: Session metadata** (`outputSessionMetadata`, prime_session.go:182):
```
[GAS TOWN] role:gastown/polecats/nux pid:12345 session:abc-123
```

**Step 7b: Role template** (`outputPrimeContext`, prime_output.go:22):
- Loads `templates.New()` (embedded binary).
- Builds `RoleData{Role:"polecat", RigName:"gastown", TownRoot:"/home/krystian/gt", Polecat:"nux", DefaultBranch:"main", MayorSession:"gt-gt-mayor", ...}`.
- Renders `roles/polecat.md.tmpl` → full polecat context document (~430 lines).
- Outputs to stdout.

**Step 7c: CONTEXT.md** (`outputContextFile`, prime_output.go:344):
- Checks `/home/krystian/gt/CONTEXT.md`. If present, prints verbatim.

**Step 7d: Handoff content** (`outputHandoffContent`, prime_output.go:358):
- Queries beads for a pinned handoff bead with roleKey="polecat".
- If found, prints `## 🤝 Handoff from Previous Session` + description.

**Step 7e: Attachment status** (`outputAttachmentStatus`, prime_output.go:479):
- Queries pinned beads assigned to `gastown/polecats/nux`.
- If a pinned bead has `attached_molecule` field, prints `## 🎯 ATTACHED WORK DETECTED`.

### Phase 8: Molecule Context

`outputMoleculeContext(ctx)` (prime_molecule.go:183) — polecats skip this (molecule steps are shown inline via `outputMoleculeWorkflow` when hooked work is found).

### Phase 9: Checkpoint Context

`outputCheckpointContext(ctx)` (prime_output.go:607) — reads `.runtime/checkpoint.json`. If a non-stale checkpoint exists, prints `## 📌 Previous Session Checkpoint`.

### Phase 10: External Tools

`runPrimeExternalTools(cwd)` (prime.go:356):
- Runs `bd prime` in polecat's workdir → outputs beads workflow context.
- Runs `gt mail check --inject` → checks inbox and outputs mail as `<system-reminder>` blocks.

### Phase 11: Escalation Check (mayor only)

Skipped for polecat.

### Phase 12: Autonomous Work Mode Check

`checkSlungWork(ctx)` (prime.go:421):
- `findAgentWork(ctx)` (prime.go:449):
  - Builds agent bead ID: `"gt-gastown-polecat-nux"` via `buildAgentBeadID`.
  - Checks agent bead's `hook_bead` field in Dolt DB.
  - If `hook_bead` exists and is `hooked` or `in_progress`, returns that bead.
  - Polecats retry up to 3 times with 2-second delays to handle timing races.
- If hooked bead found:
  - `outputAutonomousDirective(ctx, hookedBead, hasMolecule)` → prints `## 🚨 AUTONOMOUS WORK MODE 🚨`.
  - `outputHookedBeadDetails(hookedBead)` → prints bead ID, title, truncated description.
  - `outputMoleculeWorkflow(ctx, attachment)` if molecule attached → shows formula checklist inline.
  - `outputBeadPreview(hookedBead)` if no molecule → runs `bd show <id>` and shows first 15 lines.
  - Returns `true` → skips startup directive.

### Phase 13: Startup Directive (if no hooked work)

`outputStartupDirective(ctx)` (prime_output.go:387) — for polecat with no work:
```
**STARTUP PROTOCOL**: You are a polecat with NO WORK on your hook.
1. Run `gt prime` (loads full context, mail, and pending work)
2. Check if any mail was injected above in this output
3. If you have mail with work instructions → execute that work
4. If NO mail → run `gt done` IMMEDIATELY
```

### Complete Output Order (for a fresh polecat startup with hooked work)

```
[session:abc-123]
[source:startup]

[GAS TOWN] role:gastown/polecats/nux pid:12345 session:abc-123

# Polecat Context                          ← polecat.md.tmpl rendered
(~430 lines of role instructions)

<CONTEXT.md contents if present>

## 🤝 Handoff from Previous Session       ← if handoff bead exists
(handoff description)

## 🎯 ATTACHED WORK DETECTED              ← if pinned attachment exists
(attachment details)

<checkpoint context if present>            ← ## 📌 Previous Session Checkpoint

<bd prime output>                          ← beads workflow context

<gt mail check --inject output>            ← <system-reminder> if unread mail

## 🚨 AUTONOMOUS WORK MODE 🚨             ← if work is hooked
(propulsion directive)

## Hooked Work
  Bead ID: gt-abc
  Title: Fix auth timeout

## 🧬 ATTACHED FORMULA (WORKFLOW CHECKLIST)  ← if molecule attached
(formula steps)
```

---

## How `gt prime --hook` Works as a SessionStart Hook

### Stdin Contract

Claude Code sends a single-line JSON object on stdin:

```json
{
  "session_id": "uuid-string",
  "transcript_path": "/path/to/transcript.jsonl",
  "source": "startup|resume|clear|compact"
}
```

This is decoded by `readStdinJSON` (prime_session.go:53):
- Checks if stdin is a pipe (not a terminal).
- Reads exactly one line.
- Parses into `hookInput` struct (prime_session.go:23).

### Output Contract

`gt prime --hook` writes to stdout. Claude Code captures this as the initial context for the session.

The `source` field determines the output path:
- `"startup"` → full prime (all sections)
- `"resume"`, `"compact"` → `runPrimeCompactResume` (lighter output)
- Handoff reason `"compaction"` from marker file → compact/resume path (GH#1965)

`isCompactResume()` (prime.go:298):
```go
return primeHookSource == "compact" || primeHookSource == "resume" || primeHandoffReason == "compaction"
```

---

## What `gt prime --state` Does

**Location:** prime.go:142, prime_session.go:202

`--state` exits immediately after detecting session state (no side effects). Used by daemon/orchestration to query agent state without priming:

```go
type SessionState struct {
    State         string // "normal", "post-handoff", "crash-recovery", "autonomous"
    Role          Role
    PrevSession   string // for post-handoff
    CheckpointAge string // for crash-recovery
    HookedBead    string // for autonomous
}
```

Detection order (first match wins):
1. `.runtime/handoff_marker` exists → `"post-handoff"`
2. Valid non-stale checkpoint for polecat/crew → `"crash-recovery"`
3. Agent bead has `hook_bead` in active status → `"autonomous"`
4. Assignee query finds hooked/in_progress bead → `"autonomous"`
5. Otherwise → `"normal"`

Output format (plain or `--json`):
```
state: autonomous
role: polecat
hooked_bead: gt-abc-123
```

---

## Mail Injection: `gt mail check --inject`

**Location:** `/home/krystian/gt/gastown/crew/sherlock/internal/cmd/mail_check.go`

### When Called

- During `gt prime` via `runMailCheckInject` (prime.go:395)
- On every user turn via the `UserPromptSubmit` hook in `.claude/settings.json`

### What it Does

1. Detects the agent's mail address via `detectSender()` (uses cwd/role).
2. Opens the mailbox via `mail.NewRouter(workDir).GetMailbox(address)`.
3. Lists unread messages.
4. Calls `formatInjectOutput(messages)` to format as `<system-reminder>`.
5. Acknowledges delivery (marks messages as acked).
6. Drains queued nudges from `.runtime/nudge_queue/<session>/` via `nudge.Drain()`.
7. Formats nudges via `nudge.FormatForInjection()`.

### Output Format

Mail and nudges are both wrapped in `<system-reminder>` blocks that Claude Code injects into the conversation context at the turn boundary.

**Mail output (three tiers by priority):**

Urgent mail (interrupts immediately):
```xml
<system-reminder>
URGENT: 1 urgent message(s) require immediate attention.

- hq-abc123 from mayor: CRITICAL: service down

Run 'gt mail read <id>' to read urgent messages.
</system-reminder>
```

High-priority mail (process at task boundary):
```xml
<system-reminder>
You have 2 high-priority message(s) in your inbox.

- hq-def from witness: MERGE_READY alpha

Continue your current task. When it completes, process these messages
before going idle: 'gt mail inbox'
</system-reminder>
```

Normal mail (informational):
```xml
<system-reminder>
You have 1 unread message(s) in your inbox.

- hq-ghi from deacon: Status check

Continue your current task. When it completes, check these messages
before going idle: 'gt mail inbox'
</system-reminder>
```

**Queued nudge output:**
```xml
<system-reminder>
QUEUED NUDGE (1 message(s)):

  [from witness] Check your git status before pushing

This is a background notification. Continue current work unless the nudge is higher priority.
</system-reminder>
```

---

## Nudge Delivery: Immediate vs Queue

**Location:** `/home/krystian/gt/gastown/crew/sherlock/internal/nudge/queue.go`

### Immediate Mode (default)

`gt nudge <target> "message"` with `--mode=immediate` sends directly via `tmux send-keys`. This interrupts whatever the agent is doing. Used for urgent coordination.

### Queue Mode

`gt nudge <target> "message" --mode=queue` writes a JSON file to:
```
<townRoot>/.runtime/nudge_queue/<session>/<timestamp-hex>.json
```

The `QueuedNudge` struct:
```go
type QueuedNudge struct {
    Sender    string    `json:"sender"`
    Message   string    `json:"message"`
    Priority  string    `json:"priority"`   // "normal" or "urgent"
    Timestamp time.Time `json:"timestamp"`
    ExpiresAt time.Time `json:"expires_at"` // 30min normal, 2hr urgent
}
```

Queued nudges are drained by `nudge.Drain(townRoot, session)` inside `gt mail check --inject`, which runs on every `UserPromptSubmit` hook. The agent sees them as `<system-reminder>` blocks at the next natural turn boundary.

TTLs: normal 30 minutes, urgent 2 hours. Expired nudges are silently discarded at drain time. Max queue depth: 50 nudges per session.

---

## PreCompact Re-Priming

**Location:** prime.go:187 (`runPrimeCompactResume`)

### What Triggers It

The `PreCompact` hook in `.claude/settings.json` fires `gt prime --hook` with stdin source `"compact"`. This runs BEFORE Claude Code performs compaction.

### How It Differs from Initial Prime

Full prime vs compact/resume:

| Section | Full Startup | Compact/Resume |
|---------|-------------|----------------|
| Session beacon `[session:...]` | Yes | Yes |
| Recovery line with role/identity | No | Yes: `> **Recovery**: Context compact complete. You are nux (polecat).` |
| Role template (full) | Yes | No |
| CONTEXT.md | Yes | No |
| Handoff content | Yes | No |
| Attachment status | Yes | No |
| Molecule context | Yes | Yes |
| Checkpoint context | Yes | No |
| bd prime | Yes | No |
| Mail injection | Yes | Yes |
| Escalation check | Yes (mayor only) | No |
| Autonomous directive (full) | Yes | No |
| Continuation directive (brief) | No | Yes (if hooked work) |
| Startup directive | Only if no hook | Only if no hook |

The rationale (prime.go:188–193): after compaction, the agent already has full role docs in compressed memory. The compact path just restores identity, hook/work status, and injects new mail. The key difference is using `outputContinuationDirective` instead of `outputAutonomousDirective` to avoid re-initialization on resumption.

`outputContinuationDirective` (prime_output.go:536):
```
## ▶ CONTINUE HOOKED WORK
Your context was compacted/resumed. **Continue working on your hooked bead.**
Do NOT re-announce, re-initialize, or re-read the bead from scratch.
Pick up where you left off.

  Hooked: gt-abc — Fix auth timeout
```

Special case for compaction-triggered handoff cycles (GH#1965): when `gt handoff --cycle --reason compaction` fires and the new session sees `handoff_marker` with reason `"compaction"`, the new session also routes through the compact/resume path rather than full prime.

---

## Role Templates: Key Sections

All templates are embedded in the binary at `/home/krystian/gt/gastown/crew/sherlock/internal/templates/roles/*.md.tmpl`.

### Common Structure Across All Templates

1. Recovery hint: `> **Recovery**: Run {{ cmd }} prime after compaction, clear, or new session`
2. Propulsion Principle section (role-specific metaphor)
3. Capability Ledger section
4. Role identity and architecture overview
5. Key commands
6. Startup Protocol
7. Hookable Mail instructions
8. Communication hygiene
9. Command Quick-Reference table

### Role-Specific Key Sections

**polecat.md.tmpl** (`~430 lines`):
- Completion Protocol: emphasizes `gt done` with no exceptions
- Directory Discipline: warns about editing in rig root (work lost)
- Two-level beads architecture with prefix-based routing table
- PR Workflow section (for repos requiring reviews)
- Pre-submission checklist
- Escalation patterns with code examples
- Formula checklist reference (mol-polecat-work)

**mayor.md.tmpl** (`~300 lines`):
- Work Philosophy: sling-liberally section
- Fix-merging community PRs (Co-Authored-By attribution)
- Directory Guidelines table (for git ops)
- Rig Wake/Sleep Protocol
- Escalation handling
- Where-to-file-beads table

**witness.md.tmpl** (`~320 lines`):
- Swim Lane Rule: may ONLY close wisps it created
- Context Management: hand off after 15 patrol loops or extraordinary action
- Mail Types table
- Patrol patrol context is shown by `outputWitnessPatrolContext` which auto-bonds `mol-witness-patrol`

**deacon.md.tmpl** (`~320 lines`):
- Step banner format (box drawing characters)
- End of Patrol Cycle options (loop vs exit)
- Timer callback handling
- Lifecycle request handling table (cycle/restart/shutdown)
- Session patterns table with `{{ .DeaconSession }}`

**refinery.md.tmpl** (`~350 lines`):
- Cardinal Rule: merge processor, NOT a developer
- Sequential Rebase Protocol diagram
- Patrol step table with emojis
- Target Resolution Rule
- Forbidden actions (e.g., landing integration branches via raw git)

**crew.md.tmpl** (`~430 lines`):
- Approval Fallacy section
- Cross-Rig Worktrees via `gt worktree`
- Landing the Plane (session end protocol, mandatory git push)
- Planning new features via `gt formula run mol-idea-to-plan`
- Nudge Delivery Modes table

**boot.md.tmpl** (~150 lines):
- Fresh-each-tick lifecycle diagram
- Decision matrix for triage (5x3 table)
- Degraded mode (GT_DEGRADED=true)

**dog.md.tmpl** (~115 lines):
- Minimal: check hook → run it → `gt dog done`
- Zero mail policy (results via event beads + nudge)

### Message Templates

Located at `internal/templates/messages/*.md.tmpl`:

- **spawn.md.tmpl**: Work assignment sent to newly spawned polecat
- **nudge.md.tmpl**: Check-in message sent by witness (`NudgeData` struct)
- **escalation.md.tmpl**: Escalation report (`EscalationData` struct)
- **handoff.md.tmpl**: Session handoff (`HandoffData` struct with git state)

---

## `.claude/settings.json`: Full Structure

Settings files are generated by `gt hooks sync` (via `hooks.DiscoverTargets` + `ComputeExpected`). The canonical file at `/home/krystian/gt/deacon/.claude/settings.json` represents the default base:

```json
{
  "enabledPlugins": {"beads@beads-marketplace": false},
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash(gh pr create*)", "hooks": [{"type": "command", "command": "... gt tap guard pr-workflow"}]},
      {"matcher": "Bash(git checkout -b*)", "hooks": [{"type": "command", "command": "... gt tap guard pr-workflow"}]},
      {"matcher": "Bash(git switch -c*)", "hooks": [{"type": "command", "command": "... gt tap guard pr-workflow"}]},
      {"matcher": "Bash(rm -rf /*)", "hooks": [{"type": "command", "command": "... gt tap guard dangerous-command"}]},
      {"matcher": "Bash(git push --force*)", "hooks": [{"type": "command", "command": "... gt tap guard dangerous-command"}]},
      {"matcher": "Bash(git push -f*)", "hooks": [{"type": "command", "command": "... gt tap guard dangerous-command"}]},
      {"matcher": "Bash(*bd mol pour*patrol*)", "hooks": [{"type": "command", "command": "echo '❌ BLOCKED...' && exit 2"}]},
      <more patrol formula guards for deacon/witness/refinery roles>
    ],
    "SessionStart": [
      {"matcher": "", "hooks": [{"type": "command", "command": "export PATH=... && gt prime --hook"}]}
    ],
    "Stop": [
      {"matcher": "", "hooks": [{"type": "command", "command": "export PATH=... && gt costs record"}]}
    ],
    "PreCompact": [
      {"matcher": "", "hooks": [{"type": "command", "command": "export PATH=... && gt prime --hook"}]}
    ],
    "UserPromptSubmit": [
      {"matcher": "", "hooks": [{"type": "command", "command": "export PATH=... && gt mail check --inject"}]}
    ]
  }
}
```

**Settings file locations** (from `hooks.DiscoverTargets`, `config.go:386`):
- `<townRoot>/mayor/.claude/settings.json` (key: "mayor")
- `<townRoot>/deacon/.claude/settings.json` (key: "deacon")
- `<townRoot>/<rig>/crew/.claude/settings.json` (key: "<rig>/crew")
- `<townRoot>/<rig>/polecats/.claude/settings.json` (key: "<rig>/polecats")
- `<townRoot>/<rig>/witness/.claude/settings.json` (key: "<rig>/witness")
- `<townRoot>/<rig>/refinery/.claude/settings.json` (key: "<rig>/refinery")

**Role-specific overrides** (`DefaultOverrides`, config.go:205):
- `"crew"`: PreCompact overrides to `gt handoff --cycle --reason compaction` instead of `gt prime --hook`
- `"witness"`, `"deacon"`, `"refinery"`: add patrol formula guards to PreToolUse

Claude Code discovers the correct settings file because `gt` launches agents with `--settings <path>` pointing to the role's parent directory settings file. Polecat sessions at `polecats/nux/` use `polecats/.claude/settings.json`. This is the mechanism that ensures all polecats in a rig share settings without per-polecat files.

---

## The Complete Assembly Order

For a fresh full prime (not compact/resume), output is emitted in this sequence:

1. **Session beacon** (hook mode only): `[session:uuid]`, `[source:startup]`
2. **Role template**: rendered `<role>.md.tmpl` with `RoleData` (identity, architecture, commands, propulsion principle, startup protocol)
3. **CONTEXT.md**: verbatim content of `<townRoot>/CONTEXT.md` if it exists
4. **Handoff content**: pinned handoff bead description if present (role-keyed lookup)
5. **Attachment status**: pinned bead with `attached_molecule` field if present
6. **Molecule context** (deacon/witness/refinery): patrol status — finds/creates `mol-<role>-patrol` wisp, shows formula steps inline
7. **Checkpoint context** (polecat/crew only): crash recovery data from `.runtime/checkpoint.json`
8. **bd prime**: `bd prime` output (beads workflow context)
9. **Mail injection**: `gt mail check --inject` output (mail + queued nudges as `<system-reminder>` blocks)
10. **Escalations** (mayor only): `bd list --status=open --tag=escalation --json` → prominent escalation list
11. **Autonomous work mode** (if hooked): `## 🚨 AUTONOMOUS WORK MODE 🚨` + bead details + formula checklist
    — OR —
    **Startup directive** (if no hooked work): role-specific instructions on what to do next

---

## Key Architectural Observations

1. **Templates are binary-embedded**: All role templates are compiled into the `gt` binary via `//go:embed`. No filesystem template reads at runtime. This means updating templates requires rebuilding and redeploying `gt`.

2. **gt prime stdout IS the agent's context**: The hook mechanism means `gt prime --hook`'s stdout becomes part of the Claude Code conversation. The agent literally reads its own role template on startup.

3. **Single point of assembly**: All context injection routes through `runPrime`. There is no separate "system prompt API" — everything is text output to stdout captured by the hook.

4. **Two injection mechanisms for mail**: Mail can arrive via (a) the `gt prime` call at startup via `runMailCheckInject`, and (b) the `UserPromptSubmit` hook calling `gt mail check --inject` on every turn. This ensures agents see mail both at startup and during ongoing work.

5. **Compact/resume path prevents re-initialization storms**: The lighter compact/resume output prevents agents from re-announcing and re-running startup protocol after compaction, which was causing behavioral issues (GH#1965).

6. **The CLAUDE.md hierarchy is deliberately minimal**: Role context is NOT stored in CLAUDE.md. CLAUDE.md files contain only recovery instructions pointing to `gt prime`. The full context is always regenerated fresh at session start from the template + runtime state. This ensures context is always current (mail, hook state, escalations) rather than stale.

7. **Timing race mitigation for polecats**: `findAgentWork` retries up to 3 times with 2-second delays for polecats/crew to handle the race between `bd slot set` (writing the hook bead) and `gt prime` querying it at session start.
