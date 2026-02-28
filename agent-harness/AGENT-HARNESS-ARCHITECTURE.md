# Gas Town Agent Harness Architecture

> Reflects upstream commit: `ae11c53c`

The definitive reference for the universal control infrastructure that wraps
every Gas Town AI agent. Synthesized from 10 deep investigation documents
covering every harness layer.

**Source investigations**: `/home/krystian/gt/docs/investigation/01-..10-*.md`
**Source code root**: `/home/krystian/gt/gastown/crew/sherlock/` (Go module `github.com/steveyegge/gastown`)

---

## 1. Harness Definition

### What the harness is

The harness is the common scaffolding that turns a bare LLM session (Claude,
Gemini, Codex, or any supported agent runtime) into a controllable,
addressable, work-capable Gas Town agent. It is the answer to: *"What does Gas
Town wrap around a Claude session to make it an agent?"*

Every agent — Mayor, Deacon, Witness, Refinery, Polecat, Crew, Dog, Boot —
sits inside the same harness. The harness provides:

- A **process container** (tmux session) that survives disconnects and enables
  keyboard injection
- A **filesystem identity** derived from the agent's working directory
- A **configuration cascade** that resolves which binary, model, and flags to use
- A **prompt pipeline** that injects role context, work state, and mail at
  session start
- **Behavioral guards** that block dangerous or unauthorized tool calls
- A **work binding mechanism** that durably attaches beads to agents
- **Communication channels** (mail, nudge, protocol messages)
- **Execution navigation** (formulas, molecules, step tracking)
- A **work delivery protocol** (gt done, MR submission, convoy completion)
- A **lifecycle contract** (spawn, start, handoff, stop) shared by all roles

### What the harness is not

The harness is not the role-specific behaviors that run *inside* it. Patrol
loop logic, witness survey algorithms, refinery merge procedures, mayor
scheduling heuristics, and deacon health-check routines are consumers of the
harness, not the harness itself. The harness provides the uniform
infrastructure; roles provide the specialized intelligence.

### The 10 layers

| # | Layer | Question it answers |
|---|-------|---------------------|
| 1 | Session Container | Where does the agent process run? |
| 2 | Workspace Contract | What is the agent's filesystem world? |
| 3 | Agent Identity | Who is this agent and how is it configured? |
| 4 | Prompt Assembly | What does the agent know at session start? |
| 5 | Behavioral Controls | What can the agent do and not do? |
| 6 | Work Binding | How does work attach to the agent? |
| 7 | Communication | How does the agent hear from / talk to the system? |
| 8 | Execution Navigation | How does the agent track and advance through work? |
| 9 | Work Delivery | How does completed work leave the agent? |
| 10 | Lifecycle Contract | How is the agent spawned, cycled, and stopped? |

### Inner vs outer surface

The harness has two surfaces:

- **Outer surface** (system-facing): The mechanisms an operator or orchestrator
  uses to manage agents from outside. These layers are invisible to the agent.
- **Inner surface** (agent-facing): The mechanisms the agent itself uses to
  navigate work, communicate, and deliver results.

Some layers bridge both surfaces.

| Surface | Layers |
|---------|--------|
| Outer (system-facing) | Session Container, Workspace Contract, Agent Identity, Behavioral Controls, Lifecycle Contract |
| Bridge (both surfaces) | Prompt Assembly, Work Binding |
| Inner (agent-facing) | Execution Navigation, Work Delivery, Communication |

---

## 2. Layer Model

```
                          ┌─────────────────────────────────────────────┐
                          │          LIFECYCLE CONTRACT (L10)           │
                          │  spawn → start → run → handoff → stop      │
                          │  (envelope: wraps all other layers)        │
                          └─────────────┬───────────────────────────────┘
                                        │
         ┌──────────────────────────────┼──────────────────────────────┐
         │                              │                              │
    ┌────▼─────────────┐  ┌─────────────▼──────────────┐  ┌──────────▼────────┐
    │   FOUNDATION     │  │        RUNTIME             │  │    WORK FLOW      │
    │                  │  │                            │  │                   │
    │  L1 Session      │  │  L4 Prompt Assembly    ◄───┼──┤  L6 Work Binding  │
    │     Container    │  │     (bridge: outer→inner)  │  │     (bridge)      │
    │                  │  │                            │  │        │          │
    │  L2 Workspace    │  │  L5 Behavioral Controls   │  │        ▼          │
    │     Contract     │  │     (outer surface)        │  │  L8 Execution    │
    │                  │  │                            │  │     Navigation   │
    │  L3 Agent        │  │  L7 Communication          │  │     (inner)      │
    │     Identity     │  │     (bidirectional)        │  │        │          │
    │                  │  │                            │  │        ▼          │
    │  (outer surface) │  │                            │  │  L9 Work         │
    └──────────────────┘  └────────────────────────────┘  │     Delivery     │
                                                          │     (inner→outer)│
                                                          └──────────────────┘

    OUTER SURFACE (system-facing)              INNER SURFACE (agent-facing)
    ─────────────────────────                  ──────────────────────────
    L1  Session Container                      L7  Communication
    L2  Workspace Contract                     L8  Execution Navigation
    L3  Agent Identity                         L9  Work Delivery
    L5  Behavioral Controls
    L10 Lifecycle Contract
                                BRIDGES
                                ───────
                            L4  Prompt Assembly
                            L6  Work Binding
```

### Tier organization

```
FOUNDATION (exists before the agent does anything):
  ├── L1 Session Container   — tmux session, process group, socket
  ├── L2 Workspace Contract  — directory layout, worktree, beads redirect
  └── L3 Agent Identity      — role TOML, config cascade, model selection

RUNTIME (governs active behavior):
  ├── L4 Prompt Assembly     — gt prime, templates, CLAUDE.md, mail injection
  ├── L5 Behavioral Controls — hooks, guards, settings.json merge
  └── L7 Communication       — mail, nudge, protocol messages, broadcast

WORK FLOW (how work moves through the agent):
  ├── L6 Work Binding        — sling, hook, formula attachment
  ├── L8 Execution Navigation — molecules, steps, patrol loops, await-signal
  └── L9 Work Delivery       — gt done, MR submission, convoy completion

ENVELOPE (wraps everything):
  └── L10 Lifecycle Contract — spawn, start, handoff, stop, crash recovery
```

---

## 3. Control Surface Catalog

Every mechanism by which an agent's behavior is influenced, organized by layer.

### L1 — Session Container

| Mechanism | Location | Controls |
|-----------|----------|----------|
| tmux session creation | `internal/tmux/tmux.go:222` (`NewSessionWithCommand`) | Process isolation; the agent runs in a named, detached tmux session |
| `exec env ... claude` | `internal/config/loader.go:1908` (`BuildStartupCommand`) | The agent binary is launched via `exec` which replaces the shell, making `pane_current_command` show the agent process directly |
| Session naming | `internal/session/names.go`, role TOML `pattern` field | Deterministic session name from rig prefix + role + name (e.g., `gt-crew-max`) |
| `remain-on-exit` | `internal/tmux/tmux.go:239-265` | Pane survives process death; enables respawn without losing the session |
| `GT_PROCESS_NAMES` env var | `internal/config/env.go:147` | Liveness detection: which process names constitute a healthy agent |
| Auto-respawn hook | `internal/tmux/tmux.go:3054-3071` (`buildAutoRespawnHookCmd`) | Session survives crashes for deacon/boot; 3-second debounce before respawn |
| Nudge serialization locks | `internal/tmux/tmux.go:24-35` (`sessionNudgeLocks`) | Per-session channel semaphores prevent interleaved tmux send-keys |
| SIGWINCH wake | `internal/tmux/tmux.go:1132` (`WakePaneIfDetached`) | Resize-window trick triggers SIGWINCH to wake detached Claude's event loop |
| Theme assignment | `internal/tmux/theme.go:62` (`AssignTheme`) | FNV-32a hash of rig name selects a color from 10-color palette for visual identification |

### L2 — Workspace Contract

| Mechanism | Location | Controls |
|-----------|----------|----------|
| Town root marker | `mayor/town.json` | Primary workspace discovery; `workspace.Find()` walks up looking for this file |
| `work_dir` template | Role TOML `[session].work_dir` | Directory pattern determines agent's cwd (e.g., `{town}/{rig}/polecats/{name}`) |
| Path-based role detection | `internal/cmd/role.go:242` (`detectRole`) | `relPath` segments map to role: `polecats/{name}` = Polecat, `crew/{name}` = Crew, etc. |
| `.beads/redirect` | `internal/beads/beads_redirect.go:25` | Worktree points to shared rig-level beads DB via relative path |
| `.beads/routes.jsonl` | `internal/beads/routes.go:176` | Prefix-to-path routing table for bead ID dispatch across rigs |
| `.beads/PRIME.md` | Provisioned at worktree creation | Fallback GUPP context if SessionStart hook fails |
| Settings at container dir | `{rig}/crew/.claude/settings.json` (not per-worker) | All workers in a role class share one settings file via Claude Code's directory traversal |
| `GIT_CEILING_DIRECTORIES` | `internal/config/env.go` (set to `GT_ROOT`) | Prevents git from escaping the town boundary |
| Identity lock | `{workDir}/.runtime/agent.lock` | File lock prevents two agents from claiming the same workspace |

### L3 — Agent Identity

| Mechanism | Location | Controls |
|-----------|----------|----------|
| Role TOML definitions | `internal/config/roles/*.toml` (embedded via `//go:embed`) | Defines session pattern, work_dir, start_command, health thresholds, env vars, prompt_template |
| `ResolveRoleAgentConfig()` | `internal/config/loader.go:1205` | Config cascade: ephemeral tier -> rig RoleAgents -> town RoleAgents -> rig default -> town default -> built-in preset |
| `AgentEnv()` | `internal/config/env.go:65` | Single source of truth for all GT_*, BD_*, GIT_*, OTEL_* session environment variables |
| `GT_ROLE` env var | Set at session creation | Authoritative role identity (e.g., `gastown/polecats/Toast`) |
| `BD_ACTOR` env var | Set at session creation | Beads attribution identity |
| Agent preset registry | `internal/config/agents.go:45` (`AgentPresetInfo`) | Defines command, args, process names, hook provider, instructions file for each agent type (claude, gemini, codex, etc.) |
| Cost tiers | `internal/config/cost_tier.go` | Economy/budget tiers remap role->agent assignments to cheaper models; `GT_COST_TIER` env var for ephemeral override |
| `EnsureSettingsForRole()` | `internal/runtime/runtime.go:55` | Dispatches to provider-registered hook installer (claude, gemini, opencode, copilot, pi, omp) |
| Town settings | `{town}/settings/config.json` | `default_agent`, named `agents` map, `role_agents` per-role overrides, `cost_tier`, `agent_email_domain` |
| Rig settings | `{rig}/settings/config.json` | Rig-level `agent` override, rig-local `agents`, `role_agents`, merge queue config |

### L4 — Prompt Assembly

| Mechanism | Location | Controls |
|-----------|----------|----------|
| `gt prime --hook` | `internal/cmd/prime.go:101` (`runPrime`) | SessionStart hook entry point; reads stdin JSON, persists session ID, renders full role context to stdout |
| Role templates | `internal/templates/roles/*.md.tmpl` (embedded) | Binary-embedded Go templates: ~100-430 lines per role defining identity, commands, propulsion, startup protocol |
| `CONTEXT.md` injection | `internal/cmd/prime_output.go:344` | Operator-written file at `{townRoot}/CONTEXT.md`; injected verbatim for all agents |
| Handoff content | `internal/cmd/prime_output.go:358` | Pinned handoff bead description injected to provide predecessor context |
| Molecule context | `internal/cmd/prime_molecule.go:183` | Formula checklist rendered inline from embedded TOML for patrol agents; `bd mol current` for child-bead molecules |
| Checkpoint context | `internal/cmd/prime_output.go:607` | Crash recovery: `.runtime/checkpoint.json` content shown to successor |
| `bd prime` | External `bd` CLI | Beads workflow context injection |
| Mail injection | `internal/cmd/mail_check.go` via `gt mail check --inject` | `<system-reminder>` blocks with priority-tiered framing; called on SessionStart (autonomous) and UserPromptSubmit (all) |
| Autonomous directive | `internal/cmd/prime.go:542` (`outputAutonomousDirective`) | `## AUTONOMOUS WORK MODE` block: mandatory execution trigger when hooked work is found |
| Compact/resume path | `internal/cmd/prime.go:187` (`runPrimeCompactResume`) | Lighter re-prime after compaction: identity + hook check + mail, skip full role template |

### L5 — Behavioral Controls

| Mechanism | Location | Controls |
|-----------|----------|----------|
| PR workflow guard | `internal/cmd/tap_guard.go:34-101` | PreToolUse hook; blocks `gh pr create`, `git checkout -b`, `git switch -c` for GT agents |
| Dangerous command guard | `internal/cmd/tap_guard_dangerous.go:66-100` | PreToolUse hook; blocks `rm -rf /`, `git push --force`, `git reset --hard`, `git clean -f` |
| Patrol formula guards | Inline in `DefaultOverrides()` (`internal/hooks/config.go`) | Blocks `bd mol pour` for patrol molecules (must use wisps); witness/deacon/refinery only |
| `DefaultBase()` | `internal/hooks/config.go:199-330` | Universal hooks: SessionStart (`gt prime --hook`), Stop (`gt costs record`), PreCompact (`gt prime --hook`), UserPromptSubmit (`gt mail check --inject`) |
| `DefaultOverrides()` | `internal/hooks/config.go:713-806` | Role-specific: crew PreCompact → `gt handoff --cycle`; patrol agents get formula guards |
| Hook merge algorithm | `internal/hooks/merge.go:93-130` | Same matcher = replace; new matcher = append; empty hooks = remove (explicit disable) |
| `ComputeExpected()` | `internal/hooks/config.go:345` | Three-tier merge: binary defaults -> on-disk base (`~/.gt/hooks-base.json`) -> role/rig overrides |
| `gt hooks sync` | `internal/cmd/hooks_sync.go` | Regenerates all `.claude/settings.json` files; preserves non-hook fields via `Extra` map roundtrip |
| `--settings` flag | `internal/config/loader.go:1232` (`withRoleSettingsFlag`) | Points Claude Code to the shared settings file for the role class |
| `gt signal stop` | `internal/cmd/signal_stop.go` | Optional Stop hook: blocks idle when unread mail or slung work exists; loop prevention via state file |
| `skipDangerousModePermissionPrompt` | `settings-autonomous.json` | Autonomous roles operate without confirmation prompts |

### L6 — Work Binding

| Mechanism | Location | Controls |
|-----------|----------|----------|
| Bead `status=hooked` | Dolt beads DB via `bd update` | Durable work assignment; prevents double-assignment |
| Agent bead `hook_bead` slot | `bd slot set <agent-bead> hook <work-bead>` | Cross-reference from agent to its current work |
| `gt sling` dispatch | `internal/cmd/sling.go:161` (`runSling`) | Full dispatch: lock bead -> guard checks -> resolve/spawn target -> convoy -> formula -> hook -> start session -> nudge |
| `gt hook attach` | `internal/cmd/hook.go:207` (`runHook`) | Pure attach: bd update + slot set + event log; no session start, no formula |
| Formula instantiation | `internal/cmd/sling_formula.go:76` | `bd cook` + `bd mol wisp` creates wisp root; `storeFieldsInBead` writes `attached_formula` |
| Deferred session start | `internal/cmd/polecat_spawn.go:304` | Session starts AFTER hook is set, ensuring `gt prime` sees the work immediately |
| Per-bead flock lock | `internal/cmd/sling.go:510` (`tryAcquireSlingBeadLock`) | Prevents concurrent sling of the same bead |
| `SlingContext` (deferred) | `internal/scheduler/capacity/pipeline.go:18` | Ephemeral bead storing dispatch parameters for capacity-controlled queue mode |
| `gt unsling` / `gt hook clear` | `internal/cmd/unsling.go:57` | Clears hook_bead slot, resets bead to `status=open` |

### L7 — Communication

| Mechanism | Location | Controls |
|-----------|----------|----------|
| Mail (beads-backed) | `internal/mail/router.go:~840` (`Router.Send`) | Durable async messages stored as beads in town-level Dolt DB; five delivery modes (direct, list, queue, channel, announce) |
| Nudge (immediate) | `internal/tmux/tmux.go:1279` (`NudgeSession`) | tmux send-keys: types message + Enter directly into agent's terminal; interrupts current work |
| Nudge (queue) | `internal/nudge/queue.go:81` (`Enqueue`) | Writes JSON file to `.runtime/nudge_queue/{session}/`; drained on next UserPromptSubmit hook |
| Nudge (wait-idle) | `internal/cmd/nudge.go:154-175` | Polls for idle (15s timeout); if idle, deliver immediate; if busy, fall back to queue |
| Mail injection | `internal/cmd/mail_check.go:113` (`formatInjectOutput`) | Three priority tiers: urgent (interrupt), high (task boundary), normal (before idle); output as `<system-reminder>` blocks |
| Two-phase delivery tracking | `internal/mail/delivery.go` | Phase 1: `delivery:pending` at send; Phase 2: `delivery:acked` labels at inject time |
| Protocol messages | `internal/protocol/types.go` | Typed structured mail: MERGE_READY, MERGED, MERGE_FAILED, REWORK_REQUEST, CONVOY_NEEDS_FEEDING |
| Escalation routing | `internal/cmd/escalate_impl.go:98-130` | Severity-routed alerts: critical/high/medium/low -> mail targets from `settings/escalation.json` |
| Broadcast | `internal/cmd/broadcast.go:104-137` | Enumerate all running sessions; immediate nudge to each; DND check per-target |
| `gt peek` | `internal/cmd/peek.go:51-122` | Read-side: `tmux capture-pane` returns raw terminal output from agent session |
| Address resolution | `internal/mail/resolve.go:62-100` | Slash-separated paths validated against agent beads + workspace directories |

### L8 — Execution Navigation

| Mechanism | Location | Controls |
|-----------|----------|----------|
| Formula TOML | `internal/formula/types.go`, `formulas/*.formula.toml` | Step DAGs with `needs` dependencies, template variables, type (workflow/convoy/expansion/aspect) |
| Wisp molecule (root-only) | `bd mol wisp <formula> --root-only` | Ephemeral: single bead, no child steps; checklist lives in agent context; used for patrol loops and polecat work |
| Persistent molecule | `bd mol wisp <formula>` (without --root-only) | Full: root bead + child step beads; state tracked in DB; survives crashes |
| `gt mol step done` | `internal/cmd/molecule_step.go:67` | Closes step bead, computes next ready step via `findAllReadySteps`, pins it, respawns pane |
| `gt mol current` | `internal/cmd/molecule_status.go:920` | Follows breadcrumb trail: handoff bead -> attached_molecule -> children -> identify current/next step |
| `gt mol status` / `gt hook` | `internal/cmd/molecule_status.go:316` | Shows hook, attached molecule, progress (% complete, ready/blocked counts) |
| Formula injection into prime | `internal/cmd/prime_molecule.go:111` (`showFormulaSteps`) | Reads embedded formula, renders step list into gt prime output |
| `await-signal` | `internal/cmd/molecule_await_signal.go` | Patrol idle: tails `.events.jsonl`; exponential backoff (base * mult^cycles, capped); crash-safe via `backoff-until:` label |
| `await-event` | `internal/cmd/molecule_await_event.go` | Named channel wait: polls `events/<channel>/` for `.event` files |
| Topological sort | `internal/formula/parser.go:270` | Kahn's algorithm; `ReadySteps(completed)` returns all steps with deps satisfied |

### L9 — Work Delivery

| Mechanism | Location | Controls |
|-----------|----------|----------|
| `gt done` | `internal/cmd/done.go:81` (`runDone`) | Full polecat delivery: push branch, create MR bead, nudge refinery, nudge witness, close work bead, clear hook, sync worktree |
| Done checkpoints | Agent bead labels `done-cp:*` | Resume points (pushed, mr-created, witness-notified) for crash-safe `gt done` |
| Done intent label | `done-intent:<type>:<ts>` on agent bead | Early signal for Witness zombie detection |
| MR bead creation | `internal/cmd/done.go:767` | Ephemeral wisp with `branch:`, `target:`, `source_issue:`, `rig:`, `worker:`, `agent_bead:` fields |
| Convoy completion check | `internal/convoy/operations.go:37` (`CheckConvoysForIssue`) | Event-driven: on `bd close`, checks all tracking convoys; auto-closes when all tracked issues are closed |
| `gt mq submit` | `internal/cmd/mq_submit.go:78` | Manual MR submission without polecat lifecycle machinery |
| `gt close` | `internal/cmd/close.go:44` | Thin wrapper: `bd close` + convoy completion check |
| Events feed | `internal/events/events.go` (`LogFeed`) | JSONL append to `.events.jsonl` with flock; types: done, sling, hook, unhook, handoff, spawn, etc. |
| TownLog | `internal/townlog/logger.go` | Human-readable `logs/town.log` entries |
| Telemetry | `internal/telemetry/recorder.go:413` (`RecordDone`) | OTel metrics + logs to VictoriaLogs |
| Molecule audit | `internal/beads/audit.go` | JSONL audit log at `.beads/audit.log` for molecule detach/burn/squash operations |

### L10 — Lifecycle Contract

| Mechanism | Location | Controls |
|-----------|----------|----------|
| `session.StartSession()` | `internal/session/lifecycle.go:136` | Universal 13-step session creation used by all role managers |
| `session.StopSession()` | `internal/session/lifecycle.go:267` | Ctrl-C -> wait -> KillSessionWithProcesses (SIGTERM -> 2s -> SIGKILL) |
| `gt handoff` | `internal/cmd/handoff.go:89` | State-save + pane respawn: sends handoff mail to self, writes marker, `tmux respawn-pane -k` |
| `gt handoff --cycle` | `internal/cmd/handoff.go:402` | Full session replacement for PreCompact: `--continue` flag resumes conversation thread |
| `gt handoff --auto` | `internal/cmd/handoff.go:338` | State-save only (no respawn): for PreCompact auto-save before LLM compaction |
| Handoff mail | `internal/cmd/handoff.go:1154` (`sendHandoffMail`) | Ephemeral bead, auto-hooked to self, priority=high; carries git state + inbox summary |
| Handoff marker | `{workDir}/.runtime/handoff` | Anti-loop: tells successor "handoff is done"; cleared by `gt prime` on next startup |
| Checkpoint | `internal/checkpoint/checkpoint.go` | `.polecat-checkpoint.json`: molecule, step, git state, hook bead; stale after 24h |
| `gt seance` | `internal/cmd/seance.go` | Predecessor session access via `--fork-session`; sessions discovered from `.events.jsonl` |
| Keepalive | `internal/keepalive/keepalive.go:53` (`Touch`) | Best-effort heartbeat: `.runtime/keepalive.json` with last command + timestamp |
| PID tracking | `internal/session/pidtrack.go:44` | Defense-in-depth: `.runtime/pids/<session>.pid` with start time guard against PID reuse |
| KRC event pruning | `internal/krc/krc.go` | TTL-based lifecycle for `.events.jsonl`: rapid decay for heartbeats, slow decay for work events |
| Town shutdown order | `internal/session/town.go:22` | Boot -> Deacon -> Mayor (Boot first to stop the watchdog) |
| Stale detection | `internal/session/stale.go:32` | Message timestamp < session creation time = stale; prevents re-processing predecessor mail |

---

## 4. Propulsion Cycle

A complete end-to-end trace of a polecat spawned via `gt sling` with a work bead.

### Phase A — Birth

**Step 1: Sling invoked**

An operator or agent runs `gt sling gt-abc gastown`.

```
runSling()                              internal/cmd/sling.go:161
  shouldDeferDispatch() -> false        (max_polecats <= 0, immediate mode)
  tryAcquireSlingBeadLock("gt-abc")     flock on bead ID
  getBeadInfo("gt-abc")                 verify status=open, not closed/tombstone
```

**Step 2: Identity allocated**

```
resolveTarget("gastown", opts)          internal/cmd/sling_target.go:127
  IsRigName("gastown") -> true
  spawnPolecatForSling("gastown", {HookBead:"gt-abc"})
    polecatMgr.FindIdlePolecat() -> nil (no idle polecats)
    polecatMgr.AllocateName() -> "Toast" (from namepool)
```

**Step 3: Workspace created**

```
polecatMgr.AddWithOptions("Toast", {HookBead:"gt-abc"})
  MkdirAll gastown/polecats/Toast/
  git worktree add -b polecat/Toast/gt-abc@<ts> gastown/polecats/Toast/gastown/ origin/main
  beads.SetupRedirect(townRoot, clonePath)   -> .beads/redirect -> ../../mayor/rig/.beads
  beads.ProvisionPrimeMDForWorktree()        -> .beads/PRIME.md
  rig.CopyOverlay()                          -> copy .env etc from .runtime/overlay/
  runtime.EnsureSettingsForRole()             -> gastown/polecats/.claude/settings.json
  beads.CreateOrReopenAgentBead("gt-gastown-polecat-Toast", {HookBead:"gt-abc"})
    -> bd slot set gt-gastown-polecat-Toast hook gt-abc  (ATOMIC at spawn)
```

**Step 4: Formula applied, bead hooked**

```
formulaName = "mol-polecat-work"         (auto-applied for polecat targets)
InstantiateFormulaOnBead("mol-polecat-work", "gt-abc", ...)
  bd cook mol-polecat-work
  bd mol wisp mol-polecat-work --json    -> creates wisp root "gt-abc.1"
  bd mol bond gt-abc.1 gt-abc
hookBeadWithRetry("gt-abc", "gastown/polecats/Toast", hookDir)
  bd update gt-abc --status=hooked --assignee=gastown/polecats/Toast
storeFieldsInBead("gt-abc", {AttachedMolecule:"gt-abc.1", AttachedFormula:"mol-polecat-work"})
```

**Step 5: tmux session created**

```
SpawnedPolecatInfo.StartSession()        internal/cmd/polecat_spawn.go:304
  session.StartSession(t, SessionConfig{
    SessionID: "gt-Toast",
    WorkDir:   "~/gt/gastown/polecats/Toast",
    Role:      "polecat",
    ...
  })
    ResolveRoleAgentConfig("polecat", townRoot, rigPath)
      -> RuntimeConfig{Command:"claude", Args:["--dangerously-skip-permissions","--model","claude-opus-4-6"]}
    EnsureSettingsForRole(...)
    command = "exec env GT_ROLE=gastown/polecats/Toast GT_ROOT=~/gt ... claude --dangerously-skip-permissions \"beacon\""
    tmux new-session -d -s gt-Toast -c ~/gt/gastown/polecats/Toast
    tmux respawn-pane -k -t gt-Toast <command>
    SetEnvironment(gt-Toast, GT_ROLE, GT_RIG, GT_POLECAT, BD_ACTOR, ...)
    ConfigureGasTownSession(gt-Toast, theme, "gastown", "Toast", "polecat")
    WaitForCommand(gt-Toast, ["bash","zsh","sh"], 30s)
    AcceptStartupDialogs(gt-Toast)
    WaitForRuntimeReady(gt-Toast, runtimeConfig, 30s)  -> polls for ">" prompt
    TrackSessionPID(townRoot, "gt-Toast", t)
```

**Step 6: SessionStart hook fires**

Claude boots inside the tmux session. Claude Code reads `polecats/.claude/settings.json`
and fires the SessionStart hook:

```
export PATH="$HOME/go/bin:$HOME/.local/bin:$PATH" && gt prime --hook
```

Claude Code pipes to stdin: `{"session_id":"abc-123","source":"startup"}`

**Step 7: gt prime injects context**

```
runPrime()                               internal/cmd/prime.go:101
  handlePrimeHookMode()                  reads session_id, persists to .runtime/session_id
  GetRoleWithContext(cwd, townRoot)       -> RolePolecat, rig=gastown, name=Toast
  outputRoleContext(ctx)
    outputSessionMetadata()              [GAS TOWN] role:gastown/polecats/Toast pid:... session:abc-123
    outputPrimeContext()                 renders polecat.md.tmpl (~430 lines of role instructions)
    outputContextFile()                  CONTEXT.md if present
    outputHandoffContent()               pinned handoff bead if present
  runPrimeExternalTools()
    runBdPrime()                         beads workflow context
    runMailCheckInject()                 mail + queued nudges as <system-reminder>
  checkSlungWork(ctx)
    findAgentWork(ctx)
      ab.Show("gt-gastown-polecat-Toast") -> HookBead = "gt-abc"
      hb.Show("gt-abc") -> status=hooked  -> FOUND
    outputAutonomousDirective()          ## AUTONOMOUS WORK MODE
    outputHookedBeadDetails()            Bead: gt-abc, Title: ...
    outputMoleculeWorkflow()             showFormulaStepsFull("mol-polecat-work")
      -> renders all 9 steps as ### Step N: Title + full description
```

### Phase B — Activation

**Step 8: UserPromptSubmit hook fires**

On every turn, Claude Code fires:
```
gt mail check --inject
```

This checks for unread mail and queued nudges, outputting `<system-reminder>` blocks
if any exist.

**Step 9: Agent sees hooked work**

The agent's context now contains:
- Full polecat role template (commands, protocols, behaviors)
- `## AUTONOMOUS WORK MODE` block with hooked bead details
- Formula checklist: 9 steps (load-context, branch-setup, ..., submit-and-exit)

**Step 10: Propulsion triggers**

The autonomous directive instructs:
```
1. Announce: "Rig Polecat Toast, checking in." (ONE line)
2. This bead has an ATTACHED FORMULA (workflow checklist)
3. Work through formula steps in order
4. When all steps complete, run `gt done`

DO NOT: wait for user, ask questions, describe what you're going to do
```

The agent begins executing immediately without human input.

### Phase C — Execution

**Step 11: Agent works through formula steps**

The agent follows the formula checklist:
1. `load-context`: `bd show gt-abc` to read the work bead
2. `branch-setup`: verify branch, run setup commands
3. `preflight-tests`: run test suite
4. `implement`: write code changes
5. `self-review`: review own changes
6. `run-tests`: run tests again
7. `commit-changes`: `git add && git commit`
8. `cleanup-workspace`: clean build artifacts
9. `prepare-for-review` + `submit-and-exit`: run `gt done`

**Step 12: Agent sends mail (if needed)**

```
gt mail send gastown/witness -s "HELP" -m "Tests failing on auth module"
  Router.Send(msg)
    sendToSingle(msg)
      bd create --assignee gastown/witness -d "..." --labels gt:message,...
      notifyRecipient() -> nudge.Enqueue(townRoot, "gt-witness", ...)
```

**Step 13: Agent receives a nudge mid-work**

Witness sends a check: `gt nudge gastown/Toast "Status check"`
```
NudgeSession("gt-Toast", "[from gastown/witness] Status check")
  acquireNudgeLock("gt-Toast", 30s)
  tmux send-keys -t gt-Toast -l "[from gastown/witness] Status check"
  sleep 500ms                          (wait for paste completion)
  tmux send-keys -t gt-Toast Escape    (exit vim mode)
  sleep 600ms                          (exceed keyseq-timeout)
  tmux send-keys -t gt-Toast Enter     (submit as new user turn)
  WakePaneIfDetached("gt-Toast")
```

**Step 14: Guard fires**

Agent attempts `git push --force origin main`:
```
Claude Code matches: Bash(git push --force*)
  gt tap guard dangerous-command
    reads stdin: {"tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}
    matchesDangerous(): {"git","push","--force"} -> MATCH
    prints error box to stderr
    exit 2   -> BLOCKED
```

### Phase D — Submission

**Step 15: gt done**

```
runDone()                                internal/cmd/done.go:81
  g.CheckUncommittedWork()               verify clean git state
  g.CommitsAhead("origin/main", "HEAD")  verify work exists
  g.Push("origin", branch+":"+branch)    push to remote
  g.RemoteBranchExists("origin", branch) verify push landed
  writeDoneCheckpoint(CheckpointPushed)
  bd.Create({type:"merge-request", ephemeral:true, ...})  -> mrID
  bd.Show(mrID)                          verify MR readable
  writeDoneCheckpoint(CheckpointMRCreated)
  nudgeRefinery("gastown", "MERGE_READY ...")
  bd.UpdateAgentCompletion(agentBeadID, {ExitType:"COMPLETED", MRID:mrID, ...})
  nudgeWitness("gastown", "POLECAT_DONE Toast exit=COMPLETED")
  writeDoneCheckpoint(CheckpointWitnessNotified)
  events.LogFeed(TypeDone, ...)
  updateAgentStateOnDone()
    closeDescendants(molecule)           close formula step children
    bd.ForceCloseWithReason("done", molecule)
    bd.Close("gt-abc")                   close work bead
    bd.ClearHookBead(agentBeadID)        clear hook
    bd.Run("agent", "state", agentBeadID, "done")
  g.Checkout("main")                     sync worktree to main
  g.Pull("origin", "main")
  g.DeleteBranch(oldBranch, true)
```

### Phase E — Cycling (alternative to Phase D)

If the agent's context fills before work is done:

**Step 16: PreCompact hook fires**

```
gt prime --hook                          (PreCompact for polecats, base behavior)
  source = "compact"
  isCompactResume() -> true
  runPrimeCompactResume()
    outputContinuationDirective()
      "## CONTINUE HOOKED WORK"
      "Context was compacted. Continue working on your hooked bead."
      "Hooked: gt-abc -- Fix auth timeout"
```

**Step 17: Or, manual handoff**

Agent decides context is high and runs `gt handoff`:

```
runHandoff()                             internal/cmd/handoff.go:89
  cleanupMoleculeOnHandoff()
  sendHandoffMail(subject, message)
    bd create --assignee gastown/polecats/Toast --ephemeral --priority 1 ...
    bd update <mail-bead> --status=hooked --assignee=gastown/polecats/Toast
  write .runtime/handoff marker
  t.SetRemainOnExit(pane, true)
  t.ClearHistory(pane)
  t.RespawnPane(pane, restartCmd)        ATOMIC: kills old, starts new
```

**Step 18: Successor picks up**

New agent instance starts in the same tmux session (gt-Toast):

```
SessionStart hook fires -> gt prime --hook
  reads handoff marker -> prints warning -> removes marker
  detectSessionState() -> "autonomous" (hook_bead still set)
  outputContinuationDirective() or outputAutonomousDirective()
  agent reads hook -> sees hooked work -> continues execution
```

The hook (`status=hooked` bead), the molecule attachment, and the git branch
all persist across the handoff. The agent resumes from where the predecessor
left off.

---

## 5. Communication Map

Every path a message can take between the system and the agent.

```
                            ┌─────────────────────────┐
                            │     AGENT SESSION        │
                            │  (tmux pane running      │
                            │   claude/gemini/etc.)    │
                            └─────┬───────────┬────────┘
                                  │           │
                     ┌────────────┤           ├──────────────┐
                     │            │           │              │
              ┌──────▼──────┐ ┌──▼────────┐ ┌▼────────┐ ┌──▼──────────┐
              │ SessionStart│ │UserPrompt │ │PreTool  │ │   Stop      │
              │   Hook      │ │Submit Hook│ │Use Hook │ │   Hook      │
              └──────┬──────┘ └──┬────────┘ └┬────────┘ └──┬──────────┘
                     │           │           │              │
              gt prime --hook  gt mail     gt tap          gt costs
                     │        check        guard           record
                     │        --inject       │
              ┌──────▼──────────▼────┐  ┌───▼───┐      ┌──▼──────┐
              │  Context injection   │  │ BLOCK │      │ Cost    │
              │  (stdout -> context) │  │ exit 2│      │ log     │
              └──────────────────────┘  └───────┘      └─────────┘

    INBOUND TO AGENT                          OUTBOUND FROM AGENT
    ────────────────                          ──────────────────
    1. SessionStart hook                      1. gt mail send <target>
       -> gt prime output (role context,         -> Router.Send() -> bd create
          handoff, molecule, mail)                -> notifyRecipient() -> nudge queue

    2. UserPromptSubmit hook                  2. gt nudge <target> <msg>
       -> gt mail check --inject                 -> immediate: tmux send-keys
       -> <system-reminder> blocks               -> queue: file-based
                                                 -> wait-idle: poll then decide
    3. Immediate nudge
       -> tmux send-keys into terminal        3. gt escalate <description>
       -> interrupts agent's current work        -> severity-routed mail

    4. Queued nudge                           4. gt broadcast <msg>
       -> drained at UserPromptSubmit            -> nudge to all running agents
       -> <system-reminder> block

    5. Protocol message (typed mail)          5. gt done (completion notification)
       -> MERGE_READY, MERGED, etc.              -> nudge witness + refinery
       -> delivered via mail system               -> write to events feed

    6. gt peek (read-only observation)        6. gt handoff (state to successor)
       -> tmux capture-pane                      -> ephemeral mail to self
       -> no effect on agent                     -> handoff marker file
```

### Detailed channel specifications

| Channel | Direction | Transport | Latency | Persistence | Priority |
|---------|-----------|-----------|---------|-------------|----------|
| SessionStart hook | System -> Agent | Hook stdout -> context | Sync | Session-scoped | N/A |
| UserPromptSubmit hook | System -> Agent | Hook stdout -> `<system-reminder>` | Sync per turn | Turn-scoped | urgent/high/normal/low |
| Immediate nudge | Agent/System -> Agent | tmux send-keys | <2s (500ms+600ms delay) | None (ephemeral) | Interrupts current work |
| Queued nudge | Agent/System -> Agent | File -> drained at turn boundary | Next turn | 30min (normal) / 2hr (urgent) TTL | Background notification |
| Mail (direct) | Agent -> Agent | Dolt bead + nudge notification | Async | Durable (until closed) | urgent(0)/high(1)/normal(2)/low(3) |
| Mail (queue) | Agent -> Queue | Dolt bead; workers claim | Async | Durable until claimed | Inherits |
| Mail (channel) | Agent -> Channel + subscribers | Dolt bead + fan-out copies | Async | Retained (pruned by count) | Inherits |
| Protocol message | Agent -> Agent | Mail with typed subject/body | Async | Durable | Inherits from mail |
| Broadcast | Agent -> All agents | Immediate nudge to each | <2s per target | None | Interrupts |
| Peek | System -> (read only) | tmux capture-pane | Sync | None | N/A |

---

## 6. Configuration Flow

### Config cascade (resolution order)

```
                    HIGHEST PRIORITY
                         │
    ┌────────────────────▼────────────────────┐
    │  GT_COST_TIER env var (ephemeral tier)   │
    │  → CostTierRoleAgents + CostTierAgents  │
    └────────────────────┬────────────────────┘
                         │ if not handled
    ┌────────────────────▼────────────────────┐
    │  rigSettings.RoleAgents[role]            │
    │  → <rig>/settings/config.json           │
    └────────────────────┬────────────────────┘
                         │ if not set
    ┌────────────────────▼────────────────────┐
    │  townSettings.RoleAgents[role]           │
    │  → <town>/settings/config.json          │
    └────────────────────┬────────────────────┘
                         │ if not set
    ┌────────────────────▼────────────────────┐
    │  resolveAgentConfigInternal             │
    │  a. rigSettings.Runtime (legacy)        │
    │  b. rigSettings.Agent                   │
    │  c. townSettings.DefaultAgent           │
    │  d. "claude" (hard-coded fallback)      │
    └────────────────────┬────────────────────┘
                         │ agent name resolved
    ┌────────────────────▼────────────────────┐
    │  lookupAgentConfig(name)                │
    │  a. rigSettings.Agents[name]            │
    │  b. townSettings.Agents[name]           │
    │  c. built-in AgentPresetInfo registry   │
    │  d. DefaultRuntimeConfig() (claude)     │
    └────────────────────┬────────────────────┘
                         │
    ┌────────────────────▼────────────────────┐
    │  withRoleSettingsFlag                   │
    │  → append --settings <path> for Claude  │
    └─────────────────────────────────────────┘
                    LOWEST PRIORITY
```

### Every config file and its purpose

| File | Scope | Type | Purpose |
|------|-------|------|---------|
| `internal/config/roles/*.toml` | Built-in | Embedded TOML | Role definitions: session pattern, work_dir, start_command, health thresholds, env vars, nudge text, prompt_template |
| `{town}/roles/{role}.toml` | Town override | TOML | Town-level role overrides (non-zero fields replace built-in) |
| `{rig}/roles/{role}.toml` | Rig override | TOML | Rig-level role overrides (non-zero fields replace built-in + town) |
| `{town}/settings/config.json` | Town | JSON (`TownSettings`) | `default_agent`, named `agents` map, `role_agents` per-role overrides, `cost_tier`, `agent_email_domain`, `scheduler` |
| `{rig}/settings/config.json` | Rig | JSON (`RigSettings`) | Rig-level `agent` override, `agents`, `role_agents`, `merge_queue`, `crew`, `theme` |
| `{town}/settings/agents.json` | Town | JSON | Additional agent preset definitions (merged into global AgentRegistry) |
| `{rig}/settings/agents.json` | Rig | JSON | Rig-local agent preset definitions |
| `mayor/town.json` | Town | JSON | Primary workspace marker: `name`, `owner`, `public_name` |
| `mayor/rigs.json` | Town | JSON | Rig registry: maps rig names to beads prefixes (e.g., `gastown` -> `gt`) |
| `mayor/accounts.json` | Town | JSON | Account/API key configuration |
| `mayor/quota.json` | Town | JSON | Cost quota enforcement state |
| `{rig}/config.json` | Rig | JSON | Rig identity: `name`, `git_url`, `default_branch`, `beads.prefix` |
| `{town}/CONTEXT.md` | Town | Markdown | Operator-written custom instructions injected by `gt prime` for all agents |
| `{town}/CLAUDE.md` | Town | Markdown | Town root identity anchor; tells agents to run `gt prime` |
| `{rig}/mayor/rig/CLAUDE.md` | Project | Markdown | Project-level context (checked into the repo); minimal Gas Town content |
| `{role-group}/.claude/settings.json` | Role class | JSON | Claude Code hooks and settings; shared by all agents in the role class |
| `~/.gt/hooks-base.json` | User | JSON | User-editable base hook config (merged under DefaultBase) |
| `~/.gt/hooks-overrides/{target}.json` | User | JSON | Per-role/rig hook overrides (merged after built-in overrides) |
| `settings/escalation.json` | Town | JSON | Escalation routing: severity -> action list |
| `config/messaging.json` | Town | JSON | Mail lists, nudge channels, group definitions |

### Hook config cascade

```
Binary (DefaultBase + DefaultOverrides)     <- compiled into gt binary
         ↓
~/.gt/hooks-base.json                       <- edited by: gt hooks base
~/.gt/hooks-overrides/*.json                <- edited by: gt hooks override <target>
         ↓
  ComputeExpected(target)                   <- three-tier merge algorithm
         ↓
  .claude/settings.json                     <- written by: gt hooks sync
         ↓
  Claude Code --settings flag               <- passed at agent startup
         ↓
  Hook events fire                          <- PreToolUse / SessionStart / etc.
```

---

## 7. State Ownership

### Dolt database state

| Owner | Database location | Content |
|-------|-------------------|---------|
| Work beads | `{rig}/mayor/rig/.beads/dolt/` | Project issues, MR beads, convoy beads; prefix-routed via `routes.jsonl` |
| Agent beads | Same rig DB (per agent bead ID prefix) | Agent state: `hook_bead` slot, `agent_state`, `completion_metadata`, `idle:N` label |
| Mail | `{town}/.beads/` | All mail messages as beads with `gt:message` label; all rigs share town-level mail DB |
| Town beads | `{town}/.beads/` | Town-level issues (`hq-*` prefix), sling context beads, plugin run records |

### File-based state

| File | Owner layer | Format | Purpose |
|------|-------------|--------|---------|
| `.runtime/session_id` | L4 Prompt Assembly | Plain text (UUID) | Persisted Claude session ID for seance |
| `.runtime/handoff` | L10 Lifecycle | `<session_name>\n[reason]` | Anti-loop marker; cleared on next prime |
| `.runtime/agent.lock` | L2 Workspace | flock PID file | Prevents two agents claiming same workspace |
| `.runtime/pids/<session>.pid` | L1 Session Container | `<pid>\|<start_time>` | Orphan process tracking |
| `.runtime/keepalive.json` | L10 Lifecycle | JSON (`{last_command, timestamp}`) | Agent activity heartbeat |
| `.runtime/checkpoint.json` | L10 Lifecycle | JSON (Checkpoint struct) | Crash recovery: molecule, step, git state |
| `.runtime/nudge_queue/<session>/*.json` | L7 Communication | JSON (QueuedNudge) | Queued nudges awaiting drain |
| `.runtime/scheduler-state.json` | L6 Work Binding | JSON | Scheduler pause/resume state |
| `.beads/redirect` | L2 Workspace | Relative path string | Points worktree to shared rig beads DB |
| `.beads/PRIME.md` | L2 Workspace | Markdown | Fallback context if SessionStart hook fails |
| `.beads/routes.jsonl` | L2 Workspace | JSONL | Prefix-to-path routing for bead ID dispatch |
| `.beads/audit.log` | L9 Work Delivery | JSONL | Molecule detach audit trail |
| `.events.jsonl` | L9/L10 | JSONL (flock-protected) | Town-wide event feed; used by await-signal, seance, krc |
| `logs/town.log` | L9 Work Delivery | Human-readable text | TownLog entries |
| `state.json` (town) | L2 Workspace | JSON | patrol_count, last_patrol, extraordinary_action |
| `state.json` (crew) | L2 Workspace | JSON | Name, Rig, Branch, CreatedAt, UpdatedAt |
| `.dog.json` | L2 Workspace | JSON | Dog state: idle/working, worktrees map |
| `~/.gt/costs.jsonl` | L5 Behavioral Controls | JSONL | Cost log from `gt costs record` Stop hook |

### tmux state

| State | Owner layer | Access method |
|-------|-------------|---------------|
| Session existence | L1 | `tmux has-session -t =<name>` |
| Session environment | L1/L3 | `tmux set-environment` / `tmux show-environment` |
| Pane current command | L1 | `tmux display-message -p '#{pane_current_command}'` |
| Pane PID | L1 | `tmux display-message -p '#{pane_pid}'` |
| Pane dead status | L1 | `tmux display-message -p '#{pane_dead}'` |
| Session activity | L1 | `tmux display-message -p '#{session_activity}'` |
| Session created | L1 | `tmux display-message -p '#{session_created}'` |
| Status bar | L1 | Configured by `ConfigureGasTownSession()` |
| pane-died hook | L1 | Auto-respawn for deacon/boot |

### Environment variables (set per session)

| Variable | Set by | Purpose |
|----------|--------|---------|
| `GT_ROLE` | L3 `AgentEnv()` | Authoritative role identity |
| `GT_RIG` | L3 | Rig name |
| `GT_POLECAT` / `GT_CREW` | L3 | Agent name within rig |
| `GT_ROOT` | L3 | Town workspace root |
| `GT_SESSION` | L3 | tmux session name |
| `GT_AGENT` | L3 | Agent binary name override |
| `GT_PROCESS_NAMES` | L3 | Process names for liveness detection |
| `BD_ACTOR` | L3 | Beads attribution identity |
| `GIT_AUTHOR_NAME` | L3 | Git commit author |
| `GIT_CEILING_DIRECTORIES` | L3 | Prevents git escaping town root |
| `CLAUDE_CONFIG_DIR` | L3 | Claude Code config directory |
| `CLAUDECODE` | L3 | Cleared (prevents nested-session error) |
| `NODE_OPTIONS` | L3 | Cleared (prevents debugger flag inheritance) |
| `BEADS_AGENT_NAME` | L3 | Agent name for beads operations |
| `OTEL_*` | L3 | OpenTelemetry metrics/logs configuration |
| `ANTHROPIC_API_KEY`, `AWS_*`, etc. | L3 | Cloud/API credential pass-through |

---

## 8. Harness Interfaces

The minimal set of abstractions a new agent type would need to implement to
join the harness. This is the "API" of the harness.

### Interface 1: Agent Preset (`AgentPresetInfo`)

Register the agent binary's capabilities in the agent registry.

```
Required fields:
  Name            string    — preset identifier (e.g., "myagent")
  Command         string    — CLI binary name (e.g., "myagent")
  Args            []string  — autonomous-mode flags
  ProcessNames    []string  — for tmux liveness detection (what shows in pane_current_command)

Important optional fields:
  PromptMode      string    — "arg" (prompt as CLI arg) or "none" (prompt via nudge)
  ReadyPromptPrefix string  — prompt string for readiness detection (e.g., "> ")
  ReadyDelayMs    int       — fallback delay-based readiness if no prompt detection
  SupportsHooks   bool      — whether the agent has executable lifecycle hooks
  HooksProvider   string    — hook framework name; triggers hook installer registration
  HooksDir        string    — directory for hooks/settings files
  HooksSettingsFile string  — settings filename
  ConfigDirEnv    string    — env var for agent config directory
  InstructionsFile string   — agent's instructions file name ("CLAUDE.md", "AGENTS.md")
  ResumeFlag      string    — flag for session resume
  SupportsForkSession bool  — whether --fork-session is available (for gt seance)
```

Registration: add to `internal/config/agents.go` built-in presets or to
`settings/agents.json` at runtime.

### Interface 2: Hook Installer (`HookInstallerFunc`)

Provide a function that installs lifecycle hooks into the agent's settings.

```go
func(settingsDir, workDir, role, hooksDir, hooksFile string) error
```

Register via `config.RegisterHookInstaller("myagent", installer)` in
`internal/runtime/runtime.go`'s `init()` function.

The installer must create whatever settings/config file the agent runtime
reads to discover lifecycle hooks. For Claude Code, this is
`.claude/settings.json`. For other agents, it may be a JS plugin, a TS hook
file, or a markdown instructions file.

### Interface 3: SessionStart Hook Contract

The agent must execute `gt prime --hook` at session start (or equivalent).
The hook:

1. Reads session metadata from stdin (JSON: `{session_id, transcript_path, source}`)
2. Outputs role context to stdout (captured by the agent runtime as initial context)
3. Detects hooked work and injects autonomous execution directives

If the agent has no executable hooks (`SupportsHooks: false`), the harness
falls back to sending `gt prime` via tmux nudge after startup.

### Interface 4: UserPromptSubmit Hook Contract

The agent must execute `gt mail check --inject` on each user turn (or
equivalent). This:

1. Checks the agent's mailbox for unread messages
2. Outputs `<system-reminder>` blocks to stdout for injection into context
3. Drains queued nudges

If the agent has no hooks, mail delivery relies on periodic nudges or
immediate tmux injection.

### Interface 5: Work Commands

The agent must be able to execute these Gas Town CLI commands:

| Command | Purpose | Required for |
|---------|---------|-------------|
| `gt prime` | Load role context, detect work state | All agents |
| `gt hook` / `gt mol status` | Check current work assignment | Agents with work |
| `gt done` | Signal work completion | Polecats |
| `gt handoff` | Save state and cycle session | All agents |
| `gt mail inbox` / `gt mail read` | Read messages | All agents |
| `gt mail send` | Send messages | All agents |
| `gt mol step done` | Advance to next formula step | Agents with child-bead molecules |
| `gt patrol report` | Close patrol cycle | Patrol agents |
| `gt escalate` | Route alerts by severity | All agents |

### Interface 6: Environment Contract

The agent must run in an environment with these variables set:

- `GT_ROLE` — full role identity string
- `GT_ROOT` — town workspace root
- `BD_ACTOR` — beads attribution identity
- `PATH` — must include `gt` and `bd` binaries

### Interface 7: Workspace Contract

The agent's working directory must:

- Be a subdirectory of the town root whose path encodes its role
- Contain (or inherit via directory traversal) a `.claude/settings.json` (or
  equivalent) with lifecycle hooks
- Have a `.beads/redirect` file pointing to the shared beads database
- Have a `.beads/PRIME.md` file as fallback context

### Interface 8: tmux Session Contract

The agent process must:

- Run as the sole process in a named tmux session
- Accept text input via `tmux send-keys` (the nudge channel)
- Show a detectable prompt prefix when idle (for readiness/idle detection)
- Exit cleanly on Ctrl-C (SIGINT) for graceful shutdown

---

*For deeper dives into any layer, see the individual investigation documents
in `/home/krystian/gt/docs/investigation/`.*
