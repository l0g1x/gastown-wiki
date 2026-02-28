# Agent Harness Architecture Investigation Plan

> **Goal**: Map the universal "agent harness" — the common control infrastructure
> that every Gas Town agent (Mayor, Deacon, Witness, Refinery, Polecat, Crew, Dog)
> sits inside of. This is the scaffolding that makes an LLM session into a
> controlled, addressable, work-capable agent. Not the role-specific behaviors
> that run *inside* the harness — the harness itself.

## Defining the Harness

The harness answers: **"What does Gas Town wrap around a Claude session to make
it a controllable agent?"**

Every agent, regardless of role, needs:

| # | Layer | Harness Question | View |
|---|-------|------------------|------|
| 1 | Session Container | Where does the agent process run? | Outer |
| 2 | Workspace Contract | What is the agent's filesystem world? | Outer |
| 3 | Agent Identity | Who is this agent and how is it configured? | Outer |
| 4 | Prompt Assembly | What does the agent know at session start? | Outer → Inner |
| 5 | Behavioral Controls | What can the agent do and not do? | Outer |
| 6 | Work Binding | How does work attach to the agent? | Outer → Inner |
| 7 | Communication | How does the agent hear from / talk to the system? | Bidirectional |
| 8 | Execution Navigation | How does the agent track and advance through its work? | Inner |
| 9 | Work Delivery | How does completed work leave the agent? | Inner → Outer |
| 10 | Lifecycle Contract | How is the agent spawned, cycled, and stopped? | Outer |

### Layer Tiers

**Foundation** (exists before the agent does anything):
- Session Container, Workspace Contract, Agent Identity

**Runtime** (governs active behavior):
- Prompt Assembly, Behavioral Controls, Communication

**Work Flow** (how work moves through the agent):
- Work Binding → Execution Navigation → Work Delivery

**Envelope** (wraps everything):
- Lifecycle Contract

### Perspective

This investigation is scoped to a **single agent in isolation**. Multi-agent
concerns (concurrency, scheduling, contention, coordination) are out of scope.
The harness is the thing wrapped around *one* agent.

### Exclusions

Out of scope: daemon internals, patrol loop specifics, scheduler/capacity,
health checks/doctor, Dolt storage internals, convoy orchestration logic.
Those are consumers of the harness, not the harness itself.

## Output Structure

```
/home/krystian/gt/docs/investigation/
├── 01-session-container.md          # tmux as process container
├── 02-workspace-contract.md         # The agent's filesystem world
├── 03-agent-identity.md             # Role system, config cascade, model selection
├── 04-prompt-assembly.md            # gt prime, templates, CLAUDE.md, prompt construction
├── 05-behavioral-controls.md        # Claude Code hooks, guards, constraints
├── 06-work-binding.md               # sling, hook attachment, propulsion trigger
├── 07-communication.md              # mail, nudge, broadcast — inter-agent communication
├── 08-execution-navigation.md       # Molecule steps, progress tracking, step advancement
├── 09-work-delivery.md              # gt done, bead state, MQ submission, evidence trail
├── 10-lifecycle-contract.md         # Common spawn/start/handoff/stop across all roles

/home/krystian/gt/docs/
└── AGENT-HARNESS-ARCHITECTURE.md    # Wave 3 final synthesis
```

---

## Wave 1: Broad Codebase Cartography

**Objective**: Identify every package, config file, state file, and template
that participates in the universal agent harness. Build a complete inventory
focused on what's *common* across all roles. Inventory, not analysis.

### Task 1.1 — Harness Package Map
- Identify which `internal/` packages are used by ALL agent types (not role-specific)
- Trace the common paths: session creation, config loading, hook setup, mail routing
- Key shared packages likely include: `session`, `tmux`, `config`, `hooks`, `mail`,
  `nudge`, `templates`, `claude`, `runtime`, `agent`, `beads` (hook/sling parts)
- **Key files**: `internal/cmd/` imports, `internal/session/`, `internal/tmux/`,
  `internal/config/`, `internal/hooks/`

### Task 1.2 — Agent Role Inventory (Harness Perspective)
- For each role (Mayor, Deacon, Witness, Refinery, Polecat, Crew, Dog):
  - What's the same? (tmux session, hooks, mail, prime, sling)
  - What's different? (work dir pattern, session name, stuck threshold, model)
- Document the *uniform interface* that every role implements
- **Key files**: `internal/config/roles/*.toml`, role manager packages

### Task 1.3 — Harness Config Inventory
- Map every config file that affects the harness (not role-specific behavior)
- Town config: `settings/config.json` (agents, role→agent mapping)
- Rig config: `gastown/config.json`, `gastown/settings/config.json`
- Claude config: `.claude/settings.json` at each directory level
- Role definitions: `internal/config/roles/*.toml`
- **Key files**: `internal/config/loader.go`, `internal/claude/settings.go`

### Task 1.4 — Template and Prompt Inventory
- Catalog all `.md.tmpl` role templates and message templates
- Catalog all `CLAUDE.md` files and their directory hierarchy
- Map the `gt prime` assembly pipeline — what gets concatenated, in what order
- **Key dirs**: `internal/templates/roles/`, `internal/templates/messages/`, `templates/`

---

## Wave 2: Deep Investigation (one document per harness layer)

Each task produces a standalone investigation document with:
- **Architecture**: How the subsystem works end-to-end
- **Code paths**: Key functions with `file_path:line_number` references
- **State**: What state is maintained and where
- **Interfaces**: How this layer connects to adjacent layers
- **Control flow**: Step-by-step traces of key operations

---

### Task 2.1 — Session Container (`01-session-container.md`)
**Scope**: tmux as the universal process container for all agents

**Questions to answer:**
- How is a tmux session created for a new agent? What's the code path from
  `gt crew start` / `gt sling` / polecat spawn → tmux session?
- What is the session naming scheme and how is it derived from role config?
- What is `start_command` and how does it get from the role TOML into tmux?
- How does `exec claude --dangerously-skip-permissions` get invoked?
- How does the system discover existing agent sessions? (session registry)
- How does `gt agents` enumerate sessions? How does `gt peek` read output?
- How does `gt nudge` inject text into a running session?
- What is the process group model? What happens when Claude exits?
- What is the respawn hook? Does the session auto-restart?
- What is the tmux socket model? Per-rig? Global?
- What role does tmux theme play (visual identification)?

**Source packages:**
- `internal/tmux/` — all files (process_group.go, respawn_hook.go, socket.go, themes.go)
- `internal/session/` — identity.go, lifecycle.go, names.go, pid.go, registry.go, startup.go
- `internal/cmd/agents.go` — session enumeration
- `internal/cmd/nudge.go` — tmux send-keys
- Role TOMLs for `start_command` and `session_pattern`

---

### Task 2.2 — Workspace Contract (`02-workspace-contract.md`)
**Scope**: The filesystem world every agent inhabits — the directory path as the
foundational harness primitive that drives identity, config, hooks, and addressing

**Questions to answer:**
- What is the directory layout convention for each role type?
  (`{town}/{rig}/crew/{name}`, `{town}/{rig}/polecats/{name}`, etc.)
- How does the directory path determine role detection? (trace `gt prime`'s
  path-based role inference)
- How does the CLAUDE.md hierarchy map to directory depth? Which directories
  have CLAUDE.md files and what does each level contribute?
- How does `.claude/settings.json` merge across directory levels? What's the
  merge order? (town → rig → role-group → agent)
- What git repo does the agent work in? Is it a full clone or a worktree?
  How does this differ by role?
- How does the directory path determine the agent's beads database access?
  (prefix routing from `routes.jsonl`)
- How does the directory path determine the agent's mail address?
  (`gastown/crew/sherlock` derived from path)
- How does BD_ACTOR identity derive from the workspace path?
- What files does the harness expect to find in an agent's workspace?
  (`state.json`, `.claude/`, `.beads/`, etc.)
- How are workspaces created for each role? (crew: git clone, polecat: worktree,
  patrol agents: shared rig clone?)
- What is `internal/workspace/` and how does it resolve workspace paths?

**Source packages:**
- `internal/workspace/` — workspace resolution
- `internal/config/roles/*.toml` — `work_dir` patterns
- `internal/cmd/prime*.go` — path-based role detection
- `internal/hooks/merge.go` — directory-level hook merging
- `internal/session/identity.go` — identity from path
- `internal/beads/routes.go` (or similar) — prefix routing
- `internal/mail/resolve.go` — address from path
- CLAUDE.md files at each directory level
- `.claude/settings.json` files at each directory level

---

### Task 2.3 — Agent Identity (`03-agent-identity.md`)
**Scope**: How every agent gets its identity, model, and behavioral settings —
configuration as a consequence of identity

**Questions to answer:**
- What are the fields in a role TOML and what does each control?
- How does `internal/config/loader.go` assemble config? What's the load order?
- How does the config cascade work? (town → rig → role → agent-specific overrides)
- How is the model selected? (`settings/config.json` defines agents like `claude`
  with `model: opus-4-6`, roles map to agents — trace this)
- What is `internal/runtime/runtime.go`? How does it abstract Claude vs Codex vs Gemini?
- What is the plugin system? How do alternate providers register?
- How does `GT_ROLE`, `BD_ACTOR`, and other env vars get set?
- How does role detection work? (path-based: `mayor/` → Mayor, `polecats/<name>` → Polecat)
- What is `internal/config/agents.go`? Cost tiers?
- What is `internal/config/env.go`? What environment variables are used?

**Source packages:**
- `internal/config/` — loader.go, agents.go, env.go, hooks.go, types.go, `roles/*.toml`
- `internal/runtime/runtime.go`
- `internal/plugin/plugin.go`
- `internal/claude/settings.go`, `config/` (settings-autonomous.json, settings-interactive.json)
- `internal/pi/`, `internal/gemini/`, `internal/copilot/`, `internal/opencode/`
- `settings/config.json` (town-level agent/model definitions)

---

### Task 2.4 — Prompt Assembly (`04-prompt-assembly.md`)
**Scope**: How context gets constructed and injected into a Claude session —
the pipeline that turns a generic Claude into a Gas Town agent with role
knowledge, instructions, and live state

**Questions to answer:**
- What does `gt prime` do step-by-step? Trace the full code path.
- How does `gt prime --hook` work as a SessionStart hook? What's the hook contract?
- How does role detection work? (directory-based → which template to render)
- What template variables are available? How are they resolved?
- What does each role template (`internal/templates/roles/*.md.tmpl`) contain?
- How does the CLAUDE.md hierarchy work? (Claude Code loads these natively —
  what does gastown put in each level?)
- What's in `.claude/settings.json` beyond hooks? (permissions, model overrides?)
- How does mail injection work? (`gt mail check --inject` on UserPromptSubmit)
  What format? How does it appear to the agent?
- How do nudges appear to the agent? (immediate: raw tmux send-keys into prompt;
  queue: injected via hook as `<system-reminder>`)
- What is `gt prime --state`? What runtime state gets injected?
- How does PreCompact re-priming work?

**Source packages:**
- `internal/cmd/prime*.go` — all prime command files
- `internal/templates/roles/*.md.tmpl` — role templates
- `internal/templates/messages/*.md.tmpl` — message templates
- `internal/hooks/` — hook execution during prime
- `internal/cmd/mail_check.go` (or similar) — mail injection
- `.claude/` directories at each level — what they contain and why

---

### Task 2.5 — Behavioral Controls (`05-behavioral-controls.md`)
**Scope**: How Gas Town constrains what an agent can and cannot do — the
enforcement layer that prevents harmful or unauthorized actions

**Questions to answer:**
- What hook event types does Gas Town use? (SessionStart, UserPromptSubmit,
  Stop, PreCompact, PreToolUse — are there others?)
- For each hook type: what command does it invoke, and what does that command do?
- How are hooks defined in `.claude/settings.json`? What's the schema?
- How does hook merging work across directory levels? (`internal/hooks/merge.go`)
  If town-level and rig-level both define SessionStart, what happens?
- What is `gt tap guard`? What guards exist (pr-workflow, dangerous-command)?
  How do they block tool use?
- What is `gt signal`? What Claude Code events does it handle?
- How do role-specific guards work? (Deacon blocks patrol formula misuse via
  PreToolUse matchers — is this common pattern or special case?)
- How does `gt hooks sync` propagate hook configs across agents?
- What is the relationship between `.claude/settings.json` hooks and
  `internal/hooks/config.go`?
- How does the `gt costs record` Stop hook work?

**Source packages:**
- `internal/hooks/` — config.go, merge.go, sync.go
- `internal/cmd/hooks*.go` — hooks management commands
- `internal/cmd/signal*.go` — signal handlers
- `internal/cmd/tap*.go` — tap/guard system
- `.claude/settings.json` files at each workspace level
- `internal/claude/config/settings-autonomous.json`, `settings-interactive.json`

---

### Task 2.6 — Work Binding (`06-work-binding.md`)
**Scope**: How work gets attached to an agent and how the agent knows
to execute it — the input side of the work flow

**Questions to answer:**
- What is a "hook" in the work-dispatch sense? (distinct from Claude Code hooks)
  What data structure represents "work is hooked to this agent"?
- How does `gt sling <bead> <target>` work end-to-end? Trace the code path.
- How does `gt hook` show/attach/detach/clear work?
- What is `gt mol attach`? How does a molecule get bound to an agent?
- What is `gt mol attach-from-mail`? How does mail become hooked work?
- How does `gt hook` persist across sessions? (The hook survives restarts —
  where is it stored?)
- What triggers propulsion? When an agent starts and finds work on its hook,
  what's the mechanism? (gt prime reads hook state → injects it into prompt?)
- How does auto-spawning work during sling? (sling creates a polecat if needed)
- How does `gt unsling` / `gt release` remove work?
- What is the relationship between hook state and molecule state?

**Source packages:**
- `internal/cmd/sling*.go` — all sling files
- `internal/cmd/hook*.go` — hook command (not Claude hooks)
- `internal/cmd/molecule*.go` — molecule attachment
- `internal/beads/` — hook/sling-related functions
- `internal/agent/state.go` — agent state tracking

---

### Task 2.7 — Communication (`07-communication.md`)
**Scope**: How any agent talks to and hears from the rest of the system —
all communication channels available within the harness

**Questions to answer:**
- How does the mail system work end-to-end? (send → store → deliver → read)
- Where are mailboxes stored? What's the format? (JSONL files? Dolt tables?)
- How does address resolution work? (`<rig>/<role>`, `--human`, `--self`, shortcuts)
- What is `internal/mail/router.go`? How does routing work?
- What is `internal/mail/delivery.go`? Push vs pull delivery?
- How does `gt nudge` work? Three modes: immediate, queue, wait-idle.
  - Immediate: tmux send-keys — what exactly is sent?
  - Queue: writes to file — where? How is it picked up?
  - Wait-idle: how does it detect idle?
- How does `gt broadcast` work? Does it enumerate all agents?
- How does mail injection work at the hook level? (`gt mail check --inject` on
  UserPromptSubmit — what format does the injected mail take?)
- What is `gt mail hook`? (hooking a mail bead as work assignment)
- What is `gt escalate`? How does severity routing work?
- What is `internal/protocol/`? (message handlers between agents)

**Source packages:**
- `internal/mail/` — bd.go, delivery.go, mailbox.go, resolve.go, router.go, types.go
- `internal/nudge/` — queue.go
- `internal/cmd/mail*.go` — all mail commands
- `internal/cmd/nudge.go` — nudge command
- `internal/cmd/broadcast.go` (if exists)
- `internal/cmd/escalate.go` (if exists)
- `internal/protocol/` — types.go, handlers

---

### Task 2.8 — Execution Navigation (`08-execution-navigation.md`)
**Scope**: The agent-facing interface for tracking and advancing through
assigned work — how the agent navigates from "work attached" to "work done"

**Questions to answer:**
- What is a molecule from the agent's perspective? How does the agent interact with it?
- How does the agent know what step it's on? (`gt mol status`, `gt mol current`)
- How does the agent advance to the next step? (`gt mol step`? Or is it automatic?)
- How does the agent know it's on the last step? What signals "you're done"?
- What is the formula TOML schema from the agent's perspective? What fields
  matter to the agent vs. to the system?
- How do molecule steps differ from bead status updates? (`gt mol step` vs
  `bd update --status=...`) When does the agent use which?
- What is wisp vs persistent molecule? How does the agent experience each?
- How does step tracking persist? Where is current-step state stored?
- What happens if the agent fails a step? Retry? Skip? Escalate?
- How does the agent report progress? (`gt mol progress`?)
- How does the formula DAG determine step ordering? Does the agent see the DAG
  or just the next step?
- What is the relationship between molecule progression and the prompt?
  (Does the formula inject step-specific instructions?)
- How do patrol loops use molecules differently from work molecules?
  (loop-or-exit step, cycle counting — is this harness or role-specific?)

**Source packages:**
- `internal/formula/` — parser.go, embed.go, variable validation
- `internal/formula/formulas/` — TOML formula files (examine schema)
- `internal/cmd/molecule*.go` — mol commands (status, step, progress, current)
- `internal/beads/` — molecule-related state functions
- `internal/wisp/` — wisp types, config, promotion

---

### Task 2.9 — Work Delivery (`09-work-delivery.md`)
**Scope**: How completed work leaves the agent and gets accepted by the
system — the output side of the work flow

**Questions to answer:**
- What does `gt done` do end-to-end? Trace the code path.
  - What state transitions happen? (bead status, hook cleared, branch submitted?)
  - How does the work get to the refinery merge queue?
  - What metadata is attached? (actor, timestamps, commit refs)
- How do crew workers submit work differently? (direct push to main vs MQ)
- How do patrol agents (witness/refinery/deacon) record completion?
  (patrol digests, cycle counts, state.json updates)
- What is the bead state machine for work evidence?
  (pending → in_progress → done/closed — who transitions each?)
- How does `bd close` work? What evidence does it capture?
- What is `bd update --status=...`? How do status transitions get recorded?
- What git artifacts constitute "evidence"? Commits on a branch? Pushed to main?
- What is the merge queue submission format? What does refinery expect to receive?
- What is the "landing the plane" protocol in code? (Is it just convention
  in the prompt, or is there actual harness enforcement?)
- How does `gt audit` query work history by actor? What's the evidence trail?
- What is `internal/beads/recording.go`? Is there an audit log of agent actions?
- How does activity tracking (`internal/activity/`) relate to work evidence?

**Source packages:**
- `internal/cmd/done.go` (or wherever `gt done` lives)
- `internal/cmd/close.go` — bead closing
- `internal/mq/` — merge queue submission
- `internal/beads/recording.go` — action recording
- `internal/activity/` — activity tracking
- `internal/cmd/audit.go` (if exists) — work history queries
- `internal/cmd/trail.go` (if exists) — agent activity trail
- `internal/events/` — event emission on completion

---

### Task 2.10 — Lifecycle Contract (`10-lifecycle-contract.md`)
**Scope**: The universal spawn → start → run → handoff → stop contract
that every agent type implements — the external management of agent birth,
cycling, and death

**Questions to answer:**
- What is the common lifecycle all agents share? Map the state machine.
- How does agent spawning work? Trace from request → tmux session → Claude running.
  - `gt crew start <name>` path
  - `gt sling <bead> <rig>` → polecat spawn path
  - Witness/refinery start path (rig start)
- What is the startup protocol? (`gt prime --hook` fires → role context injected →
  hook check → work found → execute)
- What is `gt handoff`? How does it work for each role type?
  - What state does it persist? (hook, mail-to-self, molecule state)
  - How does the successor session pick up where the predecessor left off?
- What is `internal/session/lifecycle.go`? Common lifecycle functions?
- What is `internal/session/startup.go`? Common startup logic?
- How does context cycling work? (agent fills context → handoff → fresh session
  → re-prime → hook still attached → continues work)
- What is `gt seance`? (talking to predecessor sessions — implies session history)
- What is `internal/checkpoint/`? Crash recovery checkpoints.
- What is the "landing the plane" protocol? (git push, bead close, handoff)
- What is `gt krc` (keep-running command)? Auto-restart mechanism?

**Source packages:**
- `internal/session/` — lifecycle.go, startup.go, identity.go, stale.go
- `internal/cmd/handoff.go` — handoff command
- `internal/cmd/crew*.go` — crew start/stop
- `internal/cmd/seance.go` — predecessor access
- `internal/checkpoint/` — crash recovery
- `internal/krc/` — keep-running command
- `internal/keepalive/` — keepalive mechanism

---

## Wave 3: Synthesis and Validation

### Task 3.1 — Propulsion Cycle Trace and Cross-Reference Validation

Trace one complete propulsion cycle end-to-end across all 10 layers to validate
that the individual investigations connect correctly. Pick a concrete scenario
(polecat spawned via sling with a bead) and follow the full cycle:

**Phase A — Birth (Container → Workspace → Identity → Prompt Assembly)**
1. `gt sling <bead> <rig>` invoked — who calls what?
2. Polecat identity allocated (namepool) — where does identity come from?
3. Workspace created (worktree) — what directory, what files?
4. tmux session created — exact command, working directory, session name
5. `exec claude --dangerously-skip-permissions` — how does this land in tmux?
6. Claude boots → SessionStart hook fires → `gt prime --hook` runs
7. `gt prime` detects role from directory, renders template, outputs context

**Phase B — Activation (Behavioral Controls → Work Binding → Prompt Assembly)**
8. UserPromptSubmit hook fires → `gt mail check --inject` runs
9. Mail injected (if any) — what format? Where does it appear?
10. Agent reads injected context, sees hooked work from prime output
11. Propulsion triggers — agent begins executing without human input

**Phase C — Execution (Execution Navigation → Communication → Behavioral Controls)**
12. Agent works on the bead — molecule step tracking
13. Agent advances through formula steps — how?
14. Agent sends mail (status update, question) — what's the code path?
15. Agent receives a nudge mid-work — how does it arrive?
16. Guards fire on a blocked action — trace the block

**Phase D — Submission (Work Delivery → Lifecycle)**
17. Work complete → `gt done` → what happens to the hook? The bead? The MQ?
18. What evidence is captured? (commits, bead status, activity events)

**Phase E — Cycling (Lifecycle → back to Phase A)**
19. OR: context fills → `gt handoff` → what state persists?
20. Handoff mail sent to self — where stored?
21. tmux session killed or respawned — what triggers the new session?
22. New session starts → back to Phase A — what's different the second time?
    (Hook still attached, handoff mail waiting, molecule at step N)

**Cross-reference validation:**
- For each claimed interface between layers, verify bidirectionally
- Every connection must have actual `file:line` code references
- Flag any gaps, inconsistencies, or undocumented interfaces

### Task 3.2 — Produce AGENT-HARNESS-ARCHITECTURE.md
Synthesize all findings into a single architecture document. Structure:

1. **Harness Definition** — What it is, what it's not, the 10 layers
2. **Layer Model** (ASCII diagram) — Foundation → Runtime → Work Flow → Envelope,
   with inner/outer surface distinction
3. **Control Surface Catalog** — Every mechanism by which an agent's behavior
   is influenced, organized by layer
4. **Propulsion Cycle** — End-to-end trace: the canonical scenario walkthrough
   proving all layers connect
5. **Communication Map** — Every path a message can take between
   system components and the agent
6. **Configuration Flow** — How config cascades from town → rig → role →
   agent, with every config file and its purpose
7. **State Ownership** — What state each layer owns, where it lives, format
8. **Harness Interfaces** — The minimal set of abstractions/contracts that
   constitute the harness (the "API" that a new agent type would need to implement)

---

## Execution Notes

- **Investigation docs** → `/home/krystian/gt/docs/investigation/`
- **Final doc** → `/home/krystian/gt/docs/AGENT-HARNESS-ARCHITECTURE.md`
- Wave 1 tasks inform Wave 2 — findings may adjust scope
- Wave 2 tasks are independent and can run in parallel
- Wave 3 depends on all Wave 2 outputs
- All code references use `file_path:line_number` format

## Source Code Root

All source code references are relative to:
`/home/krystian/gt/gastown/crew/sherlock/`

This is the `github.com/steveyegge/gastown` Go module containing the `gt` CLI.
