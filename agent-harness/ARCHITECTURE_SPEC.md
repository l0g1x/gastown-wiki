# Agent Harness Architecture Specification

A technology-agnostic specification of the functional requirements that an agent harness must satisfy. This document describes **what** the harness does, not **how** any particular implementation achieves it.

---

## 1. Purpose

The agent harness is the universal infrastructure that transforms a bare AI agent session into a controllable, addressable, work-capable participant in a multi-agent system. Every agent, regardless of its specialized role, sits inside the same harness. The harness provides the uniform scaffolding; roles provide the specialized intelligence.

The harness answers one question: **"What must we wrap around an AI session to make it a managed agent?"**

---

## 2. Layer Model

The harness is organized into 10 functional layers across 4 tiers.

### 2.1 Tiers

| Tier | Purpose | Layers |
|------|---------|--------|
| **Foundation** | Exists before the agent does anything | Session Container, Workspace Contract, Agent Identity |
| **Runtime** | Governs active behavior | Prompt Assembly, Behavioral Controls, Communication |
| **Work Flow** | How work moves through the agent | Work Binding → Execution Navigation → Work Delivery |
| **Envelope** | Wraps all other layers | Lifecycle Contract |

### 2.2 Surfaces

Each layer exposes functionality through one of two surfaces:

- **Outer surface** (system-facing): Mechanisms an operator or orchestrator uses to manage agents from outside. Invisible to the agent.
- **Inner surface** (agent-facing): Mechanisms the agent itself uses to navigate work, communicate, and deliver results.

Some layers bridge both surfaces.

| Surface | Layers |
|---------|--------|
| Outer | Session Container, Workspace Contract, Agent Identity, Behavioral Controls, Lifecycle Contract |
| Bridge | Prompt Assembly, Work Binding |
| Inner | Communication, Execution Navigation, Work Delivery |

---

## 3. Layer Specifications

### L1 — Session Container

The process environment in which the agent runs.

**Functional Requirements:**

| ID | Requirement |
|----|-------------|
| L1.1 | The agent MUST run in an isolated, named process container that can be addressed by a stable identifier. |
| L1.2 | The container MUST survive operator disconnection. The agent continues running whether or not a human is attached. |
| L1.3 | The container MUST support text injection — the ability to deliver arbitrary input to the agent's session from outside. |
| L1.4 | The container MUST support crash recovery. If the agent process dies, the container persists and can be restarted without losing its identity. |
| L1.5 | The container MUST support observation — the ability to read the agent's current output without affecting its execution. |
| L1.6 | The container MUST support graceful shutdown via signal delivery. |
| L1.7 | Each container MUST be assigned a deterministic, human-readable name derived from the agent's role and identity. |
| L1.8 | Concurrent input injection into the same container MUST be serialized to prevent interleaved messages. |

---

### L2 — Workspace Contract

The filesystem world every agent inhabits.

**Functional Requirements:**

| ID | Requirement |
|----|-------------|
| L2.1 | Every agent MUST operate within a designated working directory whose path encodes its role and identity within the system hierarchy. |
| L2.2 | The working directory path MUST be parseable to determine the agent's role (e.g., path segment patterns map to role types). |
| L2.3 | Agents of the same role class MUST share behavioral configuration (hooks, guards, settings) via a common ancestor directory. |
| L2.4 | Each workspace MUST provide access to the shared work-item database, either directly or via a redirection mechanism. |
| L2.5 | The workspace MUST contain fallback context that the agent can read if the normal startup protocol fails. |
| L2.6 | The workspace MUST enforce a boundary — the agent's tooling cannot traverse above the system root. |
| L2.7 | The workspace MUST support identity locking — only one agent process may claim a given workspace at a time. |
| L2.8 | Workspace types MUST support both persistent (full copy) and ephemeral (lightweight reference) modes. |

---

### L3 — Agent Identity

Who the agent is and how it is configured.

**Functional Requirements:**

| ID | Requirement |
|----|-------------|
| L3.1 | Every role MUST be defined by a structured configuration that specifies: session naming pattern, working directory template, startup command, health thresholds, environment variables, and prompt template. |
| L3.2 | Configuration MUST resolve through a cascade with clear priority order: ephemeral overrides > project-level > system-level > built-in defaults. |
| L3.3 | The system MUST support multiple AI runtimes (different agent binaries/providers). Agent selection MUST be configurable per-role and per-project. |
| L3.4 | A cost-tier mechanism MUST allow runtime remapping of role-to-agent assignments to balance capability against cost. |
| L3.5 | The agent's authoritative identity MUST be injected as an environment variable at session creation, not inferred at runtime. |
| L3.6 | New agent runtimes MUST be registerable by declaring their capabilities: binary name, autonomous-mode flags, process names for liveness detection, hook support, prompt delivery mode, and readiness detection method. |

---

### L4 — Prompt Assembly

What the agent knows at session start.

**Functional Requirements:**

| ID | Requirement |
|----|-------------|
| L4.1 | At session start, the harness MUST inject a complete role context into the agent containing: identity, available commands, behavioral protocols, and startup instructions. |
| L4.2 | If work is assigned, the prompt MUST include the work item details and an autonomous execution directive that causes the agent to begin working immediately without human input. |
| L4.3 | If a predecessor session existed (handoff or crash recovery), the prompt MUST include the predecessor's state summary. |
| L4.4 | The prompt MUST include any pending messages from the agent's inbox, prioritized by urgency. |
| L4.5 | Operators MUST be able to inject custom context (free-form instructions) that applies to all agents in the system. |
| L4.6 | On context compaction (memory pressure), the harness MUST re-inject a lighter version of the role context that preserves identity and current work state without repeating the full role template. |
| L4.7 | The prompt assembly pipeline MUST be a single entry point shared by all roles, with role-specific content provided via templates. |

---

### L5 — Behavioral Controls

What the agent can and cannot do.

**Functional Requirements:**

| ID | Requirement |
|----|-------------|
| L5.1 | The harness MUST intercept agent actions at defined lifecycle points: session start, each user/agent turn, before tool execution, and session stop. |
| L5.2 | Before tool execution, the harness MUST evaluate the proposed action against a set of guard rules. Guards MUST be able to block actions by returning an error code. |
| L5.3 | Guard rules MUST be composable: built-in defaults, user-level overrides, and role-specific overrides MUST merge via a deterministic algorithm (same matcher = replace, new matcher = append, empty = remove). |
| L5.4 | The harness MUST provide guards against destructive operations (e.g., force-push, recursive delete, hard reset) and workflow violations (e.g., creating pull requests outside the designated flow). |
| L5.5 | Autonomous agents MUST operate without interactive confirmation prompts. |
| L5.6 | The behavioral controls configuration MUST be regenerable from source (binary defaults + user overrides) to recover from drift or corruption. |

---

### L6 — Work Binding

How work attaches to an agent.

**Functional Requirements:**

| ID | Requirement |
|----|-------------|
| L6.1 | Work assignment MUST be durable — surviving agent restarts, crashes, and handoffs. The binding is stored in the work-item database, not in agent memory. |
| L6.2 | A work item MUST be exclusively assigned to at most one agent at a time. Double-assignment MUST be prevented. |
| L6.3 | Work binding MUST be atomic — the agent's "current work" reference and the work item's "assigned to" field MUST update together. |
| L6.4 | Binding MUST occur BEFORE the agent session starts, so that the startup prompt assembly sees the assignment immediately. |
| L6.5 | Work dispatch MUST support attaching a formula (execution plan) to the work item at binding time. |
| L6.6 | Concurrent dispatch of the same work item MUST be prevented via locking. |
| L6.7 | Work MUST be unbindable — clearing the assignment and returning the work item to an available state. |

---

### L7 — Communication

How the agent hears from and talks to the system.

**Functional Requirements:**

| ID | Requirement |
|----|-------------|
| L7.1 | The system MUST support two communication modes: **asynchronous messages** (durable, stored, delivered at turn boundaries) and **synchronous injection** (immediate, interrupts current work). |
| L7.2 | Asynchronous messages MUST be durable — stored in a database and surviving agent restarts. |
| L7.3 | Messages MUST support priority tiers (at minimum: urgent, high, normal, low) that affect delivery framing and injection order. |
| L7.4 | Message delivery MUST be trackable through at least two phases: sent (pending) and acknowledged (injected into agent context). |
| L7.5 | Agents MUST be addressable by a hierarchical path (e.g., project/role/name). Address resolution MUST validate against registered agents. |
| L7.6 | The system MUST support delivery patterns: direct (one-to-one), list (one-to-many), channel (pub/sub), queue (claim-based), and broadcast (all agents). |
| L7.7 | The system MUST support typed/structured messages (protocol messages) for machine-to-machine coordination. |
| L7.8 | Agents MUST be able to opt out of interruptions (do-not-disturb mode), with a force-override for critical messages. |
| L7.9 | The system MUST support read-only observation of an agent's current output without affecting its execution. |
| L7.10 | Severity-based escalation MUST route alerts to configurable targets based on urgency level. |

---

### L8 — Execution Navigation

How the agent tracks and advances through its work.

**Functional Requirements:**

| ID | Requirement |
|----|-------------|
| L8.1 | Work MUST be decomposable into a formula — a structured execution plan consisting of ordered steps. |
| L8.2 | Formulas MUST support step dependencies as a directed acyclic graph (DAG). Steps with satisfied dependencies are "ready"; steps with unsatisfied dependencies are "blocked." |
| L8.3 | The system MUST support both lightweight formulas (checklist in agent context only, no persistent step tracking) and persistent formulas (each step tracked as a discrete work item in the database). |
| L8.4 | Formulas MUST support template variables — parameterized values resolved at instantiation time. |
| L8.5 | Formulas MUST support typed execution patterns including at minimum: sequential workflow, parallel convoy (multi-leg with synthesis), and composition (formula inheritance and extension). |
| L8.6 | Step advancement MUST be explicit — the agent signals completion of a step, the system computes the next ready step(s), and the agent's context is updated. |
| L8.7 | The system MUST support idle-wait patterns — an agent suspending execution until a signal or event arrives, with configurable backoff. |
| L8.8 | Formula progress MUST be queryable: current step, percentage complete, blocked/ready counts. |

---

### L9 — Work Delivery

How completed work leaves the agent.

**Functional Requirements:**

| ID | Requirement |
|----|-------------|
| L9.1 | Work delivery MUST follow a defined protocol: validate completion → publish artifacts → create review request → notify stakeholders → close work item → release binding. |
| L9.2 | The delivery protocol MUST be checkpoint-based — each phase writes a durable checkpoint so that a crash mid-delivery can resume from the last completed phase rather than restarting. |
| L9.3 | Delivery MUST notify both the review system and the oversight system that work is complete. |
| L9.4 | For multi-part work (convoys), completion of a tracked sub-item MUST trigger an automatic check of whether the parent convoy is fully satisfied. |
| L9.5 | All work events (dispatch, completion, handoff, errors) MUST be recorded in a durable, append-only event feed. |
| L9.6 | The system MUST maintain a human-readable activity log alongside the structured event feed. |
| L9.7 | After delivery, the agent's workspace MUST be cleaned up — synced back to the base branch with the work branch removed. |

---

### L10 — Lifecycle Contract

How the agent is spawned, cycled, and stopped.

**Functional Requirements:**

| ID | Requirement |
|----|-------------|
| L10.1 | All agent roles MUST be startable through a single, unified startup function that accepts role-specific configuration. |
| L10.2 | The startup sequence MUST: create the process container, launch the agent binary with appropriate environment, wait for readiness, and verify the agent is responsive. |
| L10.3 | The harness MUST support in-place session replacement (handoff) — the agent saves its state, sends a summary to its successor, and the process is atomically replaced without destroying the container. |
| L10.4 | Handoff MUST preserve: the work binding, the execution plan attachment, and the version-control branch. The successor agent resumes from where the predecessor stopped. |
| L10.5 | The harness MUST support context cycling — triggered by memory pressure, the agent's context is compacted and the session is refreshed with a continuation directive. |
| L10.6 | Graceful shutdown MUST follow a defined sequence: signal → wait → force-terminate. |
| L10.7 | In a multi-agent system, shutdown MUST follow a defined order (supervisory roles last). |
| L10.8 | The harness MUST support crash recovery via checkpoint files. A successor session detects the checkpoint and resumes from the recorded state. |
| L10.9 | The harness MUST support predecessor session access — a new session can read the transcript of a previous session for context recovery. |
| L10.10 | The harness MUST detect stale messages — messages sent before the current session started MUST be identified and not re-processed. |
| L10.11 | Critical roles MUST support auto-respawn — if the agent process dies, the container automatically restarts it after a debounce period. |
| L10.12 | Agent liveness MUST be detectable via heartbeat files and process tracking, with guards against PID reuse. |

---

## 4. Propulsion Cycle

The canonical lifecycle of a work-executing agent, expressed as functional phases.

### Phase A — Birth

1. **Dispatch**: An operator or agent triggers work assignment, targeting a project.
2. **Identity allocation**: The system allocates an agent name (from a pool or by creation).
3. **Workspace creation**: A working directory is provisioned with access to the shared database, fallback context, and behavioral configuration.
4. **Work binding**: The execution plan is instantiated, the work item is atomically bound to the agent, and a formula is attached.
5. **Session creation**: The process container is created and the agent binary is launched with full environment.
6. **Prompt assembly**: The startup hook fires, injecting role context, work details, and an autonomous execution directive.

### Phase B — Activation

7. **Message check**: On each turn, the harness checks for inbound messages and injects them into the agent's context.
8. **Work recognition**: The agent sees its assigned work item and the attached formula checklist.
9. **Autonomous start**: The execution directive instructs the agent to begin immediately without waiting for human input.

### Phase C — Execution

10. **Step execution**: The agent works through formula steps in dependency order.
11. **Communication**: The agent sends and receives messages as needed during execution.
12. **Guard enforcement**: The harness intercepts and blocks any prohibited actions.

### Phase D — Submission

13. **Delivery protocol**: The agent validates, publishes, and submits its work through the checkpoint-based delivery sequence.
14. **Stakeholder notification**: Review and oversight systems are notified.
15. **Cleanup**: Work item is closed, binding is released, workspace is reset.

### Phase E — Cycling (alternative to Phase D)

16. **Context pressure**: If the agent's context fills before work is done, the compaction hook fires and re-injects a lighter context with a continuation directive.
17. **Manual handoff**: The agent saves state, sends a summary to its successor, and the session is atomically replaced. The successor picks up from the predecessor's last state.

---

## 5. Cross-Cutting Concerns

### 5.1 Determinism and Addressability

Every agent in the system MUST be deterministically addressable by a hierarchical path: `{project}/{role-class}/{name}`. This path is derivable from the agent's working directory, its process container name, and its entry in the work-item database.

### 5.2 Crash Safety

All state transitions that cross a failure boundary (work binding, delivery, handoff) MUST be checkpoint-based. The system MUST be able to resume from the last successful checkpoint rather than restarting the entire operation.

### 5.3 Configuration as Code

All behavioral configuration (guards, hooks, role definitions) MUST be regenerable from a deterministic merge of source layers. Runtime-modified configuration MUST be recoverable by re-running the merge algorithm.

### 5.4 Work-Item Database as Source of Truth

The durable work-item database — not agent memory or local files — is the authoritative record of: work assignments, agent state, message history, and completion status. Local file state (checkpoints, handoff markers, heartbeats) is ephemeral and subordinate.

### 5.5 Agent-Runtime Agnosticism

The harness MUST support pluggable agent runtimes. Adding a new AI provider requires registering its capabilities (binary, flags, readiness detection, hook support) without modifying the harness core. The harness communicates with all agent types through the same interfaces: text injection, environment variables, and CLI commands.

---

## 6. Invariants

Properties that MUST hold at all times across the system.

| ID | Invariant |
|----|-----------|
| INV-1 | A work item is assigned to at most one agent at any time. |
| INV-2 | An agent's authoritative identity is set at container creation and does not change for the lifetime of that container. |
| INV-3 | The work binding survives any number of handoffs and crash-recovery cycles. |
| INV-4 | Messages sent before the current session started are never re-processed as new. |
| INV-5 | Guard rules are evaluated on every tool invocation, with no bypass mechanism available to the agent. |
| INV-6 | The prompt assembly pipeline produces identical output for identical inputs, regardless of agent runtime. |
| INV-7 | All work events are recorded in the append-only event feed before the operation is considered complete. |
| INV-8 | An agent's workspace path uniquely identifies its role, project, and name. |
| INV-9 | Behavioral configuration is reproducible from source inputs alone. |
