# 08 — Execution Navigation

> Reflects upstream commit: `ae11c53c`

**Scope:** The agent-facing interface for tracking and advancing through assigned work.

**Primary sources:**
- `/home/krystian/gt/gastown/crew/sherlock/internal/formula/` — parser, types, embed, variable_validation
- `/home/krystian/gt/gastown/crew/sherlock/internal/formula/formulas/` — TOML formula definitions
- `/home/krystian/gt/gastown/crew/sherlock/internal/cmd/molecule*.go` — all molecule commands
- `/home/krystian/gt/gastown/crew/sherlock/internal/beads/molecule.go` — molecule state in beads
- `/home/krystian/gt/gastown/crew/sherlock/internal/wisp/` — wisp types, config, promotion
- `/home/krystian/gt/gastown/crew/sherlock/internal/cmd/prime_molecule.go` — formula injection into prime output

---

## Architecture

Execution navigation is the subsystem that answers, for any running agent: *"What am I supposed to do next?"* It spans three interconnected layers:

1. **Formula layer** — TOML files defining step graphs (the recipe)
2. **Molecule layer** — live instantiations of formulas as bead issues (the work in flight)
3. **Navigation commands** — `gt mol *` commands that agents call to orient themselves and advance

The design follows the **Propulsion Principle**: work placed on an agent's hook triggers autonomous execution. The agent never polls for work; it reads its hook at `gt prime` time, sees the current step, and begins executing immediately.

### How it fits together

```
Formula TOML
    │ (embedded in binary + provisioned to .beads/formulas/)
    │
    ▼
bd mol wisp <formula> --root-only --json
    │ (creates a wisp root issue in beads DB; formula steps embedded as description)
    │
    ▼
gt sling <formula> <target>
    │ (cooks formula, creates wisp, sets status=hooked on target agent's hook_bead)
    │
    ▼
Target agent session starts → gt prime
    │ (reads hook_bead, finds attached_formula, renders step checklist)
    │
    ▼
Agent works each step in sequence
    │ (for wisp/patrol molecules: checklist is inline, no child beads)
    │ (for persistent molecules: child step beads track state)
    │
    ▼
Step completion signaling:
    │ gt mol step done <step-id>   — closes step bead, advances to next
    │ gt patrol report              — closes patrol wisp, creates new one (loop)
    │ gt done                       — submits work, nukes sandbox (polecat exit)
    │
    ▼
Molecule complete → molecule burned/squashed, hook cleared
```

---

## Formula Schema (TOML)

Source: `/home/krystian/gt/gastown/crew/sherlock/internal/formula/types.go`

A formula file (`.formula.toml`) maps to the `Formula` struct:

```go
type Formula struct {
    Name        string            `toml:"formula"`      // required, e.g. "mol-polecat-work"
    Description string            `toml:"description"`  // long doc string
    Type        FormulaType       `toml:"type"`         // convoy|workflow|expansion|aspect
    Version     int               `toml:"version"`

    // workflow-specific
    Steps []Step                  `toml:"steps"`
    Vars  map[string]Var          `toml:"vars"`

    // convoy-specific
    Inputs    map[string]Input    `toml:"inputs"`
    Prompts   map[string]string   `toml:"prompts"`
    Output    *Output             `toml:"output"`
    Legs      []Leg               `toml:"legs"`
    Synthesis *Synthesis          `toml:"synthesis"`

    // expansion-specific
    Template []Template           `toml:"template"`

    // aspect-specific
    Aspects []Aspect              `toml:"aspects"`
}
```

**Step (workflow type):**
```go
type Step struct {
    ID          string   `toml:"id"`           // unique within formula
    Title       string   `toml:"title"`
    Description string   `toml:"description"`  // full prose instructions, may contain {{vars}}
    Needs       []string `toml:"needs"`         // step IDs this depends on (DAG edges)
    Parallel    bool     `toml:"parallel"`      // can run concurrently with sibling parallel steps
    Acceptance  string   `toml:"acceptance"`   // exit criteria (for Ralph loop mode)
}
```

**Var (template variable definition):**
```go
type Var struct {
    Description string `toml:"description"`
    Required    bool   `toml:"required"`
    Default     string `toml:"default"`
}
```

Vars support shorthand syntax: `[vars.base_branch]` with `default = "main"`, or inline string syntax `base_branch = "main"` (parsed by `UnmarshalTOML`).

**Template variables** in step descriptions use `{{variable_name}}` syntax. The `ValidateTemplateVariables()` function (`variable_validation.go:63`) checks at parse time that every `{{var}}` found in all text fields resolves to either a `[vars]` definition or an `[inputs]` definition.

### Formula types

| Type | Execution model | Steps field |
|------|----------------|-------------|
| `workflow` | Sequential with DAG dependencies | `[[steps]]` with `needs` |
| `convoy` | Parallel legs then synthesis | `[[legs]]` + `[synthesis]` |
| `expansion` | Template-based step generation | `[[template]]` with `needs` |
| `aspect` | Parallel multi-aspect analysis | `[[aspects]]` (no dependencies) |

### Real formula examples

**mol-polecat-work** (workflow, version 6):
- 9 steps: `load-context`, `branch-setup`, `preflight-tests`, `implement`, `self-review`, `run-tests`, `commit-changes`, `cleanup-workspace`, `prepare-for-review`, `submit-and-exit`
- Linear chain: each step `needs` the previous one
- Variables: `issue` (required), `base_branch` (default: `main`), `setup_command`, `typecheck_command`, `test_command`, `lint_command`, `build_command`
- Step descriptions contain `{{issue}}`, `{{base_branch}}`, etc. expanded at instantiation

**mol-deacon-patrol** (workflow, version 12):
- 20+ steps with a complex DAG: inbox-check fans out to orphan-process-cleanup, test-pollution-cleanup, gate-evaluation, check-convoy-completion in parallel; these gather at heartbeat-mid; then continues linearly
- Final step: `loop-or-exit` — calls `gt mol step await-signal` with exponential backoff, then `gt patrol report` to loop
- Var: `wisp_type = "patrol"` (default)

**mol-witness-patrol** (workflow, version 9):
- 8 steps: `inbox-check`, `process-cleanups`, `check-refinery`, `survey-workers`, `check-timer-gates`, `check-swarm-completion`, `patrol-cleanup`, `context-check`, `loop-or-exit`
- Linear shape (no fan-out)
- Same loop-or-exit pattern as deacon

---

## Code Paths

### Formula parsing

```
formula.ParseFile(path)                               parser.go:12
  └─ formula.Parse(data)                             parser.go:21
       ├─ toml.Decode(string(data), &f)
       ├─ f.inferType()                              parser.go:38 — infers type from content if unset
       └─ f.Validate()                               parser.go:56
            ├─ validateWorkflow()                    parser.go:119 — unique IDs, valid needs refs, cycle check
            └─ checkCycles()                         parser.go:208 — DFS cycle detection
```

**Topological sort** (`parser.go:270`): Kahn's algorithm over the `needs` graph. Returns steps in dependency order. Used by molecule step-tracking to determine what is ready.

**ReadySteps** (`parser.go:360`): Given a `completed map[string]bool`, returns all steps with all needs satisfied. This is the core scheduler primitive.

**ParallelReadySteps** (`parser.go:430`): Splits ready steps into `parallel []string` (steps marked `parallel=true`) and `sequential string` (first non-parallel ready step).

### Molecule state in beads

Source: `/home/krystian/gt/gastown/crew/sherlock/internal/beads/molecule.go`

**MoleculeStep** (parsed from old-format markdown):
```go
type MoleculeStep struct {
    Ref          string         // Step reference (from "## Step: <ref>")
    Title        string
    Instructions string
    Needs        []string       // Step deps
    WaitsFor     []string       // Dynamic wait conditions (e.g. "all-children")
    Tier         string         // haiku|sonnet|opus
    Type         string         // "task" (default), "wait"
    Backoff      *BackoffConfig // for wait-type steps
}
```

**InstantiateMolecule** (`molecule.go:267`): Creates child issues from a molecule template. Supports two formats:
- **New format**: molecule has child issues already — uses those as templates (`instantiateFromChildren`, `molecule.go:296`)
- **Old format**: parses markdown from description via `ParseMoleculeSteps` (`molecule.go:362`)

For each step it creates a child issue with `instantiated_from: <mol-id>` in the description (provenance metadata), then wires `AddDependency` calls to implement `needs` relationships.

### gt mol step done

Source: `/home/krystian/gt/gastown/crew/sherlock/internal/cmd/molecule_step.go:67`

This is the canonical step completion command:

```
runMoleculeStepDone(stepID)
  1. b.Show(stepID)                                  — verify step exists
  2. extractMoleculeIDFromStep(stepID)               — gt-abc.1 → gt-abc  (molecule_step.go:187)
     └─ fallback: step.Parent field
  3. b.Close(stepID)                                 — mark step closed in beads
  4. findAllReadySteps(b, moleculeID)                — molecule_step.go:217
     ├─ b.List(children of moleculeID, status=all)  — check all-closed completion
     ├─ b.ReadyForMol(moleculeID)                   — beads canonical ready-work logic
     └─ sortStepsBySequence(readySteps)             — molecule_dep.go:25 — numeric suffix sort
  5. Dispatch by action:
     - "done"       → handleMoleculeComplete()      — molecule_step.go:429
     - "continue"   → handleStepContinue()          — molecule_step.go:262
     - "parallel"   → handleParallelSteps()         — molecule_step.go:351
     - "no_more_ready" → print blocked message
```

**handleStepContinue** (`molecule_step.go:262`):
1. Detects agent identity via `GetRoleWithContext` + `buildAgentIdentity`
2. Pins the next step: `bd update <next-step-id> --status=pinned --assignee=<agent>`
3. If in tmux: kills pane processes, clears history, respawns pane with restart command

**handleMoleculeComplete** (`molecule_step.go:429`):
- For polecats: calls `gt done --status DEFERRED` (self-cleaning model)
- For other roles: unpins the work bead, prints completion message

### gt mol status (alias: gt hook)

Source: `/home/krystian/gt/gastown/crew/sherlock/internal/cmd/molecule_status.go:316`

Primary lookup path:
1. Resolve `agentBeadID` from identity
2. `agentB.Show(agentBeadID)` — read agent bead
3. Read `agentBead.HookBead` field (the `hook_bead` column, set by `bd slot set`)
4. `hookB.Show(agentBead.HookBead)` — read the hooked bead (may be in different DB)
5. `beads.ParseAttachmentFields(hookBead)` — extract `attached_molecule`, `attached_at`, `attached_args`
6. If attached molecule: `getMoleculeProgressInfo(b, attachment.AttachedMolecule)` — compute progress

Fallback path (no agent bead): queries for `status=hooked` or `status=in_progress` beads assigned to the agent, searching town-level and all-rig databases.

**MoleculeStatusInfo** output:
```go
type MoleculeStatusInfo struct {
    Target           string
    Role             string
    AgentBeadID      string
    HasWork          bool
    PinnedBead       *beads.Issue
    AttachedMolecule string
    AttachedAt       string
    AttachedArgs     string
    IsWisp           bool
    Progress         *MoleculeProgressInfo  // nil if no attached molecule
    NextAction       string
}
```

### gt mol current

Source: `/home/krystian/gt/gastown/crew/sherlock/internal/cmd/molecule_status.go:920`

Follows the breadcrumb trail:
1. Find handoff bead via `b.FindHandoffBead(role)`
2. Parse `attached_molecule` from handoff bead description
3. List all children of the molecule root
4. Build closed/in_progress/ready sets using `Dependencies` field (from `bd show`, not `bd list`)
5. Classify: `in_progress steps` → current; first `ready step` → next; all closed → complete; no ready/in_progress → blocked

Output statuses: `"working"`, `"naked"`, `"complete"`, `"blocked"`

### gt mol progress

Source: `/home/krystian/gt/gastown/crew/sherlock/internal/cmd/molecule_status.go:150`

Lists all children of a molecule root, categorizes by status, checks dependency satisfaction for open steps, produces a `MoleculeProgressInfo`:
```go
type MoleculeProgressInfo struct {
    RootID       string
    RootTitle    string
    MoleculeID   string
    TotalSteps   int
    DoneSteps    int
    InProgress   int
    ReadySteps   []string   // step IDs with all deps met, sorted by sequence number
    BlockedSteps []string
    Percent      int
    Complete     bool
}
```

### await-signal (patrol loop wait)

Source: `/home/krystian/gt/gastown/crew/sherlock/internal/cmd/molecule_await_signal.go`

The patrol idle mechanism. Tails `<townRoot>/.events.jsonl` and returns when a new line appears:

```
gt mol step await-signal --agent-bead <bead-id> --backoff-base 30s --backoff-mult 2 --backoff-max 5m

runMoleculeAwaitSignal()
  1. getAgentLabels(agentBead)       — read idle:N and backoff-until:TIMESTAMP from bead labels
  2. calculateEffectiveTimeout()     — base * mult^idleCycles, capped at max
  3. Resume logic: if backoff-until is stored and in the future, use remaining time
  4. persist backoff-until label     — setAgentBackoffUntil() — crash-safe resume
  5. waitForActivitySignal(ctx)
     └─ waitForEventsFile(ctx, townRoot+"/.events.jsonl")
          └─ seeks to EOF, polls every 200ms for new lines (bufio.Reader)
  6. On timeout: increment idle:N label, clear backoff-until
  7. On signal: clear backoff-until, report idle:N to caller
```

The caller (patrol agent) must reset `idle:0` on its agent bead after receiving a signal.

### await-event (named channel wait)

Source: `/home/krystian/gt/gastown/crew/sherlock/internal/cmd/molecule_await_event.go`

Watches `<townRoot>/events/<channel>/` for `.event` JSON files. Used by Refinery to wake on MERGE_READY:

```
gt mol step await-event --channel refinery --timeout 10m
  1. Check for already-pending .event files (return immediately if found)
  2. Poll directory every 500ms until event or timeout
  3. With --cleanup: delete processed event files
  4. Same backoff + idle-cycle tracking as await-signal
```

---

## State Storage

### Where current-step state lives

Step state is entirely in the **beads database**. There is no separate step-cursor or checkpoint file. The state model is:

| Step status | Meaning |
|-------------|---------|
| `open` | Not yet started; may be blocked |
| `in_progress` | Agent is working on it (pinned to agent) |
| `closed` | Step complete |

`findAllReadySteps` computes what is ready by querying all children of the molecule root, checking which are not closed, then delegating to `b.ReadyForMol(moleculeID)` (beads' canonical `bd ready --mol` logic) which consults the `blocked_issues_cache` for transitive dependency resolution.

**Current step identification**: The agent knows it is on a step because:
1. For child-bead molecules: the step bead has `status=pinned` (or `in_progress`) and the agent is its assignee
2. For wisp/formula molecules (patrol): the formula steps are rendered inline in `gt prime` output; the agent tracks progress in its own context window

### Agent bead fields for navigation

The agent bead (`hq-deacon`, `gt-gastown-witness`, etc.) carries:
- `hook_bead`: ID of the currently hooked work bead (set by `bd slot set` during sling)
- `idle:N` label: idle cycle counter for exponential backoff in `await-signal`
- `backoff-until:TIMESTAMP` label: Unix timestamp for crash-safe backoff resume
- `last_activity`: heartbeat timestamp updated by `bd agent heartbeat`

These are updated by `gt mol step await-signal` and read back at the start of the next invocation.

### Attachment fields in the hooked bead

The hooked bead (the wisp root or issue on the hook) stores:
- `attached_molecule`: molecule ID
- `attached_at`: RFC3339 timestamp of attachment
- `attached_args`: pass-through args from `gt sling --args`
- `attached_formula`: formula name (for wisp-based formulas without child molecules)
- `dispatcher`: who slung it

These are parsed by `beads.ParseAttachmentFields()` and read by `gt mol status` and `gt prime`.

---

## Interfaces

### Connection to work binding (molecule attachment)

**gt sling <formula> <target>** (`sling_formula.go:76`):
1. `bd cook <formula>` — ensures formula proto exists
2. `bd mol wisp <formula> --root-only --json` — creates a wisp root bead
3. `hookBeadWithRetry(wispRootID, targetAgent)` — sets `status=hooked` on the wisp
4. `updateAgentHookBead(targetAgent, wispRootID)` — writes `hook_bead` column on agent bead
5. `storeFieldsInBead(wispRootID, ...)` — writes `attached_formula` field in wisp description
6. `t.NudgePane(targetPane, prompt)` — wakes target agent's tmux pane

**gt mol attach <mol-id>** (`molecule_attach.go:15`):
- Explicit: `gt mol attach <pinned-bead-id> <molecule-id>`
- Auto-detect: `gt mol attach <molecule-id>` — finds handoff bead from cwd/role
- Calls `b.AttachMolecule(pinnedBeadID, moleculeID)` — writes attachment fields

**gt mol attach-from-mail <mail-id>** (`molecule_attach_from_mail.go`):
- Reads mail body for `attached_molecule:` field
- Finds agent's pinned bead (status=pinned + assignee=agent)
- Calls `b.AttachMolecule(hookBead.ID, moleculeID)`

### Connection to prompt assembly (formula injection into prime)

Source: `/home/krystian/gt/gastown/crew/sherlock/internal/cmd/prime_molecule.go`

`outputMoleculeContext(ctx RoleContext)` is called during `gt prime` to inject molecule state:

- **Deacon**: `outputDeaconPatrolContext()` → `outputPatrolContext()` + `showFormulaSteps("mol-deacon-patrol", "Patrol Steps")`
- **Witness**: `outputWitnessPatrolContext()` → same pattern with `mol-witness-patrol`
- **Refinery**: `outputRefineryPatrolContext()` with extra vars from rig MQ settings
- **Polecats**: formula steps shown via `showFormulaStepsFull(formulaName)` from `attached_formula`

`showFormulaSteps(formulaName, label)` (`prime_molecule.go:111`):
- Reads formula from embedded FS via `formula.GetEmbeddedFormulaContent(formulaName)`
- Parses it
- Renders numbered step list: `1. **Title** — <first line of description>`

`showFormulaStepsFull(formulaName)` (`prime_molecule.go:138`):
- Same but renders `### Step N: Title` + full description — used for polecat work

`showMoleculeExecutionPrompt(workDir, moleculeID)` (`prime_molecule.go:36`):
- Calls `bd mol current <moleculeID> --json` for child-bead molecules
- Renders the current step's full description + "EXECUTE THIS STEP NOW" directive

The critical principle: **for patrol loops, there are no step beads**. The formula checklist is rendered inline from the embedded TOML at every `gt prime`. The agent works through the steps in its own context, then calls `gt patrol report` to close the cycle and loop.

### Connection to work delivery (completion signaling)

**Polecat completion**: `gt done` (not `gt mol step done`) is the canonical polecat exit:
- Pushes branch, creates MR bead, nukes sandbox, exits session
- `handleMoleculeComplete()` calls `gt done --status DEFERRED` for polecats (`molecule_step.go:485`)

**Patrol completion** (deacon/witness/refinery): `gt patrol report --summary "..."`:
- Closes the current patrol wisp
- Creates a new patrol wisp for the next cycle
- Agents then immediately continue from step 1

**Molecule burn**: `gt mol burn` (`molecule_lifecycle.go:18`):
- `closeDescendants(b, moleculeID)` — recursively closes all step children
- `b.DetachMoleculeWithAudit(handoff.ID, DetachOptions{Operation:"burn"})` — clears attachment
- `b.ForceCloseWithReason("burned", moleculeID)` — closes root

**Molecule squash**: `gt mol squash` (`molecule_lifecycle.go:131`):
- `closeDescendants(b, moleculeID)` — same as burn
- Creates a digest issue (ephemeral, P4) with execution summary — unless `--no-digest`
- `b.DetachMoleculeWithAudit(handoff.ID, DetachOptions{Operation:"squash"})`
- Closes root — prevents hooked-status leak (issue #1828)
- `--jitter <duration>` flag adds random pre-sleep to avoid concurrent Dolt lock contention

---

## Control Flow: Full Trace

### Formula creation and sling

```
User/agent calls: gt sling mol-polecat-work gastown/polecats/nux

sling.go → runSlingFormula(["mol-polecat-work", "gastown/polecats/nux"])
  resolveTarget("gastown/polecats/nux") → resolves pane, workDir, agent identity

  bd cook mol-polecat-work
    └─ creates/updates formula proto in .beads/formulas/

  bd mol wisp mol-polecat-work --root-only --json
    └─ reads mol-polecat-work.formula.toml
    └─ creates a single wisp root bead (no child step beads for --root-only)
    └─ returns {"root_id": "gt-wisp-xyz"}

  hookBeadWithRetry("gt-wisp-xyz", "gastown/polecats/nux")
    └─ bd update gt-wisp-xyz --status=hooked --assignee=gastown/polecats/nux

  updateAgentHookBead("gastown/polecats/nux", "gt-wisp-xyz")
    └─ bd slot set gt-gastown-polecat-nux hook_bead gt-wisp-xyz

  storeFieldsInBead("gt-wisp-xyz", {AttachedFormula: "mol-polecat-work"})
    └─ appends "attached_formula: mol-polecat-work" to wisp description

  t.NudgePane(pane, "Formula mol-polecat-work slung. Run `gt hook`...")
```

### Agent wakes up and primes

```
gt prime (called by SessionStart hook or manually)
  runPrime()
    detectRole(cwd, townRoot) → RolePolecat, rig=gastown, name=nux
    outputMoleculeContext(ctx)
      └─ (polecat branch — reads hook_bead from agent bead)
         agentBead.HookBead = "gt-wisp-xyz"
         hookBead = b.Show("gt-wisp-xyz")
         attachment = ParseAttachmentFields(hookBead)
         → attached_formula = "mol-polecat-work"
         showFormulaStepsFull("mol-polecat-work")
           └─ formula.GetEmbeddedFormulaContent("mol-polecat-work")
           └─ formula.Parse(content)
           └─ renders:
              "### Step 1: Load context and verify assignment"
              <full description with {{issue}} still as template — needs var expansion>
              "### Step 2: Set up working branch"
              ... (9 steps total)
```

### Agent advances through steps (polecat with child beads)

When child beads have been instantiated (full molecule, not root-only):

```
Agent completes Step 1 work. Runs:

gt mol step done gt-mol-instance.1

runMoleculeStepDone("gt-mol-instance.1")
  step = b.Show("gt-mol-instance.1")           — verify exists
  moleculeID = "gt-mol-instance"               — strip .1 suffix
  b.Close("gt-mol-instance.1")                 — mark step closed
  readySteps, allComplete = findAllReadySteps(b, "gt-mol-instance")
    children = b.List({Parent: "gt-mol-instance", Status: "all"})
    → not all closed, so:
    readySteps = b.ReadyForMol("gt-mol-instance")  — beads ready logic
    sortStepsBySequence(readySteps)
    → returns [gt-mol-instance.2]              — Step 2: branch-setup

  action = "continue"
  handleStepContinue(cwd, townRoot, readyStep[0], false)
    agentID = "gastown/polecats/nux"
    exec "bd update gt-mol-instance.2 --status=pinned --assignee=gastown/polecats/nux"
    t.KillPaneProcesses(pane)
    t.ClearHistory(pane)
    t.RespawnPane(pane, restartCmd)
    → new tmux pane starts, gt prime runs, sees gt-mol-instance.2 as pinned step
```

### Patrol loop (witness)

```
gt prime (witness session start)
  outputWitnessPatrolContext(ctx)
    outputPatrolContext(cfg)
      → checks for existing open patrol wisp
      → if none: auto-creates one ("bd mol wisp mol-witness-patrol --json")
    showFormulaSteps("mol-witness-patrol", "Patrol Steps")
      → renders numbered list of 9 patrol steps

Agent works through all 9 steps in sequence in its context.
Arrives at final step: loop-or-exit.

gt mol step await-signal --agent-bead gt-gastown-witness \
  --backoff-base 30s --backoff-mult 2 --backoff-max 5m

  idleCycles = read from "idle:N" label on gt-gastown-witness bead
  timeout = min(30s * 2^idleCycles, 5m)
  persist "backoff-until:<unix>" on agent bead
  tail ~/.gt/.events.jsonl
    → if event within timeout: return "signal"
    → if timeout: return "timeout", increment idle:N

After await-signal returns:

gt patrol report --summary "brief observations"
  → closes current patrol wisp
  → creates new patrol wisp
  → prints "New cycle started"

Agent immediately executes from step 1 of new cycle (in same context).
```

### Context high — handoff and respawn

```
At loop-or-exit, agent detects context > 80%:

gt handoff -s "Witness patrol handoff" -m "observations..."
  → creates handoff mail to successor
  → sets handoff marker

Agent exits cleanly. Daemon detects dead session.
Daemon respawns fresh witness session.

New session: gt prime
  → reads handoff mail from inbox-check step
  → auto-bonds new patrol wisp
  → continues from step 1
```

---

## Questions Answered

### 1. What is a molecule from the agent's perspective?

A molecule is a structured work assignment. The agent sees it as:
- A **hook bead** (the pinned work issue on its hook)
- An **attached formula** (formula name stored in the hook bead's description) — for root-only/patrol molecules, the checklist is shown inline at `gt prime` time
- Or an **attached molecule** (molecule root ID) — for persistent molecules with child step beads, each step is a separate issue in beads

The agent interacts with it primarily through `gt hook` (= `gt mol status`), which shows what is on the hook and the next action. For patrol agents, the formula checklist is always rendered inline in `gt prime`. For polecats, the full formula steps are printed as a checklist at session start.

### 2. What is the formula TOML schema?

See [Formula Schema](#formula-schema-toml) above. Key fields:
- `formula` (required), `description`, `type` (workflow/convoy/expansion/aspect), `version`
- `[[steps]]` with `id`, `title`, `description`, `needs`, `parallel`, `acceptance`
- `[vars.<name>]` with `description`, `required`, `default`
- `[[legs]]`/`[synthesis]` for convoy type
- Type is inferred from content if not explicit

### 3. How does the agent know what step it's on?

Two mechanisms depending on molecule format:

**Root-only/patrol (no child beads)**: The agent reads the formula checklist from `gt prime` output. It tracks its position in its own context window. The formula steps are rendered as a numbered list; the agent works through them sequentially, recognizing where it is by reading the step descriptions.

**Full molecule (child beads)**: The agent calls `gt mol current` or `gt mol status`, which queries the beads DB for child issues with `in_progress` or `open` (with all deps satisfied) status. The agent sees the current step ID and title, and may `bd show <step-id>` for the full description.

### 4. How does the agent advance to the next step?

**For child-bead molecules**: `gt mol step done <step-id>`. This closes the current step in beads, computes the next ready step, pins it to the agent, and respawns the tmux pane. The agent starts fresh in the new pane and sees the next step at prime time.

**For patrol/root-only molecules**: The agent works through all formula steps in sequence within one context window. After `loop-or-exit`, it calls `gt patrol report` which closes the current wisp and creates a new one. The agent then loops back to step 1. There is no per-step bead advancement — the progression is entirely in the agent's reasoning.

**Not automatic**: Step advancement requires explicit agent action. The system does not automatically advance when it detects the agent has "done" work on a step. The agent must explicitly close the step.

### 5. How does the agent know it's on the last step?

**Child-bead molecules**: `gt mol step done <last-step-id>` returns `action = "done"` when `findAllReadySteps` finds all children closed. This triggers `handleMoleculeComplete()`.

**Patrol/root-only**: The agent recognizes `loop-or-exit` as the final step from the formula checklist (it's always the last listed step). The formula's description for this step instructs the agent to either loop or exit based on context level.

**Signal from beads**: `findAllReadySteps` at `molecule_step.go:217` first checks if all children are `status=closed` → returns `allComplete=true`.

### 6. How do molecule steps differ from bead status updates?

**Molecule steps** are discrete work phases defined by the formula DAG. Each step is either a separate child bead (persistent molecules) or a named checklist item (patrol molecules). Completing a step closes the step bead and advances the molecule.

**Bead status updates** (`bd update <issue-id> --status=in_progress`, `--notes`, `--design`) are metadata updates on the work issue itself (e.g., the assigned bug or feature). The agent is expected to persist findings to the work bead (`bd update {{issue}} --notes "..."`) *before* closing a step, so findings survive session crashes.

Rule of thumb: bead status updates track the work; molecule step closes track the workflow.

### 7. What is wisp vs persistent molecule?

**Wisp (root-only)**: Created with `bd mol wisp <formula> --root-only`. A single ephemeral bead with no child step beads. The formula steps live only in the agent's context (injected at prime time). Used for patrol loops (deacon, witness, refinery), dog tasks, and polecat work where the checklist-in-context model suffices. Wisps have TTLs; expired closed wisps are deleted by compaction; expired open wisps are promoted (flagged for attention).

**Persistent molecule (full)**: Created without `--root-only`. Has a root bead plus child bead for each step. The full DAG is materialized in the beads DB. Steps can be tracked individually, parallel steps can fan out, and progress survives session crashes. Used when the work is too complex for context-only tracking, or when multiple agents need to collaborate on different steps.

**Agent experience**:
- Wisp: agent sees the checklist at prime; no step beads to query; no `gt mol step done` flow; uses `gt patrol report` to close the cycle
- Persistent: agent sees `gt mol current` output; closes steps with `gt mol step done`; tmux pane respawns between steps

### 8. How does step tracking persist?

For child-bead molecules: in the beads database. Each step is a bead issue; its `status` field persists across session crashes. On respawn, `gt mol current` reads the DB and identifies the in-progress/ready step.

For patrol molecules: not persisted across crashes. The patrol wisp tracks that a patrol is in flight (it exists as an open bead), but not which step was in progress. After a crash respawn, the agent starts from step 1 of a new patrol cycle. This is intentional — each patrol cycle is idempotent by design.

### 9. What happens if the agent fails a step?

**No automatic retry mechanism** at the molecule layer. The system does not detect step failure. The agent is responsible for failure handling as described in the step's own instructions.

Typical patterns from the formulas:
- Tests fail → fix them (step instructions say "do not proceed with failures")
- Blocked externally → mail Witness with HELP, mark self stuck
- Context filling → `gt handoff` to cycle to fresh session; successor picks up from same step
- Unsure → mail Witness, don't guess

For patrol agents: if a step is difficult, the agent documents the situation in its patrol digest and loops. There is no escalation gate per step; the Deacon's health-scan step has a decision matrix based on the agent's own judgment.

### 10. How does the agent report progress?

Commands available:
- `gt hook` / `gt mol status` — show hook, attached molecule, progress bar (% complete, ready/blocked step counts)
- `gt mol current` — detailed current step identification (identity, handoff, molecule, steps N/M, current step ID and title)
- `gt mol progress <root-id>` — full progress breakdown (done/in-progress/ready/blocked step IDs, progress bar)
- `gt mol dag <molecule-id>` — visualize the full dependency DAG with tier groupings and critical path
- `bd show <step-id>` — read step description (the actual instructions)
- `gt patrol report --summary "..."` — close patrol cycle with summary; creates ephemeral digest bead

### 11. How does the formula DAG determine step ordering? Does the agent see the full DAG or just the next step?

The DAG is defined by `needs` arrays in the formula steps. `TopologicalSort()` (Kahn's algorithm) produces a full execution order; `ReadySteps(completed)` produces just the currently-executable set.

At runtime for child-bead molecules, `findAllReadySteps` computes readiness based on beads' `blocked_issues_cache` (which handles transitive deps, conditional-blocks, and waits-for). The agent is shown only the next step(s) via `gt mol current` — it does not need to reason about the full DAG.

The agent can see the full DAG via `gt mol dag <molecule-id>` if it needs it, but this is primarily a diagnostic tool for humans and Witness agents monitoring work.

For patrol molecules, the agent sees all steps at once (the full checklist is rendered inline). It works through them in order, but can skip or abbreviate steps based on its own judgment (e.g., "no orphans detected, skip dispatch").

### 12. Does the formula inject step-specific instructions into the prime output?

Yes, but the mechanism differs by molecule type:

**Patrol/wisp molecules** (deacon, witness, refinery): `showFormulaSteps()` renders the full step list from the embedded formula at every `gt prime`. The agent sees all steps but works through them sequentially. The instructions live in the formula TOML (in `step.Description`) and are rendered inline.

**Persistent/child-bead molecules**: `showMoleculeExecutionPrompt()` calls `bd mol current <moleculeID> --json`, gets the next step's description from the beads DB, and renders it with a "EXECUTE THIS STEP NOW" directive. Only the current step's description is shown.

**Polecat work formula (root-only)**: `showFormulaStepsFull()` renders all steps with full descriptions as a numbered checklist (the "formula checklist" pattern). The agent reads the complete checklist and works through it within one session.

### 13. How do patrol loops use molecules?

**The patrol loop pattern** (shared by Deacon, Witness, Refinery):

1. A patrol wisp (root-only, `wisp_type = "patrol"`) is created on session start if none exists
2. The formula is rendered as a checklist in `gt prime` output
3. The agent works through all steps in sequence in its context window
4. The final step (`loop-or-exit`) calls `gt mol step await-signal` with exponential backoff
5. `await-signal` tails `~/.gt/.events.jsonl`, returning immediately on any Gas Town activity
6. Whether signal or timeout, the agent calls `gt patrol report --summary "..."`:
   - Creates ephemeral digest bead (captures patrol observations; aggregated daily)
   - Closes the current patrol wisp
   - Creates a new patrol wisp for the next cycle
7. Agent immediately begins executing from step 1 again

**Backoff mechanism**: `await-signal` tracks idle cycles via `idle:N` label on the agent bead:
- First idle: 30s wait (witness) / 60s (deacon)
- Second idle: 60s / 120s
- Third idle: 120s / 240s
- Capped at 5 minutes

When activity arrives, the caller resets `idle:0` via `gt agent state <bead> --set idle=0`.

**Crash-safe backoff**: `backoff-until:TIMESTAMP` label is written before the wait begins. If the process is killed and restarted (nudge, SIGTERM), the new `await-signal` reads the stored timestamp and sleeps only the remaining time — prevents premature patrol cycles after interruption.

**Context high path**: At `loop-or-exit`, if context > 80%, the agent calls `gt handoff` and exits instead of looping. The daemon detects the dead session and respawns a fresh agent, which starts a new patrol cycle from scratch. The handoff mail in the inbox provides continuity context for the successor at its `inbox-check` step.

---

## Summary

The execution navigation system is a lean, state-in-beads architecture:

- **Formulas** are TOML DAG definitions embedded in the binary and provisioned to `.beads/formulas/`. They carry all step instructions and variable schemas.
- **Molecules** are live instantiations: either root-only wisps (checklist lives in agent context) or full child-bead graphs (state in beads DB).
- **Step state** is a bead status field (`open` → `in_progress` → `closed`). There is no separate cursor.
- **Advancement** is explicit: `gt mol step done` closes a step, computes the next ready step, pins it, and respawns the agent pane. For patrol molecules, `gt patrol report` closes the cycle and creates a new one.
- **Patrol loops** use `await-signal` with exponential backoff on the events feed — the agent is event-driven, not polling on a fixed interval.
- **The formula is injected into `gt prime`** output at every session start, giving the agent its instructions without requiring it to fetch them from beads.
- **Failure handling is agent-side** — there is no automatic retry or escalation gate built into the molecule step machinery. Each step's description contains the failure mode instructions.
