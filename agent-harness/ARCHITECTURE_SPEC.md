# Agent Harness Architecture Specification

A universal specification for the infrastructure that transforms a bare AI agent session into a controllable, addressable, work-capable participant in a managed system. This document describes **principles and capabilities**, not mechanisms or technologies. It is intended as a foundation reference that any implementation can build upon.

---

## 1. Purpose

An AI agent session — left unmanaged — is a stateless, unaddressable, unsupervised process. It cannot receive work, coordinate with peers, survive failures, or be held accountable for its actions.

The **agent harness** is the universal scaffolding that solves this. It wraps every agent — regardless of role, AI provider, or specialization — in a common control infrastructure. The harness provides the uniform envelope; roles provide the specialized intelligence.

The harness answers one question: **"What must surround an AI session to make it a managed agent?"**

---

## 2. Layer Model

The harness is organized into 10 functional layers across 4 tiers.

### 2.1 Tiers

| Tier | Purpose | Layers |
|------|---------|--------|
| **Foundation** | Exists before the agent does anything | Session Container, Workspace, Agent Identity |
| **Runtime** | Governs active behavior | Prompt Assembly, Behavioral Controls, Communication |
| **Work Flow** | How work moves through the agent | Work Binding → Execution Navigation → Work Delivery |
| **Envelope** | Wraps all other layers | Lifecycle Contract |

### 2.2 Surfaces

Each layer exposes functionality through one of two surfaces:

- **Outer surface** (system-facing): How operators and orchestrators manage agents from outside. Invisible to the agent itself.
- **Inner surface** (agent-facing): How the agent navigates work, communicates, and delivers results.

Some layers bridge both surfaces.

| Surface | Layers |
|---------|--------|
| Outer | Session Container, Workspace, Agent Identity, Behavioral Controls, Lifecycle Contract |
| Bridge | Prompt Assembly, Work Binding |
| Inner | Communication, Execution Navigation, Work Delivery |

---

## 3. Principles and Capabilities

Each layer is specified as a **principle** (the fundamental truth) followed by **capabilities** (what an implementation must be able to do).

---

### L1 — Session Container

*The execution environment in which the agent runs.*

**Principle:** An agent must exist within a durable, addressable execution boundary that is independent of any human operator's presence and controllable from outside.

**Capabilities:**

| ID | Capability |
|----|------------|
| L1.1 | The agent runs within an isolated execution boundary that is uniquely addressable by a stable identifier. |
| L1.2 | The execution boundary persists independently of operator connections. The agent continues running whether or not a human is observing it. |
| L1.3 | The system can deliver instructions to a running agent from outside the agent's own process. |
| L1.4 | If the agent process fails, the execution boundary persists and can host a replacement agent without losing its identity. |
| L1.5 | The system can observe the agent's current state and output without affecting its execution. |
| L1.6 | The system can request graceful termination of the agent process. |
| L1.7 | Concurrent instruction delivery to the same agent is serialized to prevent corruption. |

---

### L2 — Workspace

*The isolated environment an agent operates within.*

**Principle:** Every agent must have a bounded, provisioned environment that provides access to shared resources while enforcing isolation. The agent's identity within the system must be discoverable from its workspace.

**Capabilities:**

| ID | Capability |
|----|------------|
| L2.1 | Every agent operates within a designated, isolated workspace from which its role and identity within the system hierarchy are discoverable. |
| L2.2 | Agents of the same role class share behavioral configuration through a mechanism determined by the implementation. |
| L2.3 | Each workspace provides access to the shared work-item store. |
| L2.4 | The workspace contains fallback context that the agent can access if the normal startup protocol fails. |
| L2.5 | The workspace enforces a boundary — the agent cannot access resources outside the system's managed scope. |
| L2.6 | Only one agent process may claim a given workspace at a time. |
| L2.7 | Workspaces can be provisioned at varying cost levels — from full independent copies to lightweight references — depending on the agent's persistence requirements. |

---

### L3 — Agent Identity

*Who the agent is and how it is configured.*

**Principle:** Every agent must have an authoritative identity that is assigned at creation and immutable for the lifetime of its session. Configuration must resolve through a deterministic cascade from multiple sources.

**Capabilities:**

| ID | Capability |
|----|------------|
| L3.1 | Every role is defined by a structured configuration specifying its behavioral parameters: naming, workspace layout, startup procedure, health criteria, and context template. |
| L3.2 | Configuration resolves through a cascade with a clear, deterministic priority order — from ephemeral overrides down through project, system, and built-in defaults. |
| L3.3 | The system supports multiple AI runtimes. Agent runtime selection is configurable per role and per project. |
| L3.4 | The system supports capability-cost tradeoffs — remapping which AI runtime serves a given role to balance capability against resource consumption. |
| L3.5 | The agent's authoritative identity is established at session creation and is not self-discovered or mutable by the agent. |
| L3.6 | New AI runtimes are integrable by declaring their capabilities (startup procedure, readiness detection, hook support, prompt delivery mode) without modifying the harness core. |

---

### L4 — Prompt Assembly

*What the agent knows at session start.*

**Principle:** The harness must construct and deliver a complete operational context to the agent at session start, and must be able to reconstruct a lighter version of that context when the agent's memory is constrained.

**Capabilities:**

| ID | Capability |
|----|------------|
| L4.1 | At session start, the harness delivers a complete role context to the agent: identity, available operations, behavioral protocols, and startup instructions. |
| L4.2 | If work is assigned, the context includes work item details and a directive that causes the agent to begin autonomously. |
| L4.3 | If a predecessor session existed (handoff or recovery), the context includes the predecessor's state summary. |
| L4.4 | The context includes any pending inbound messages, ordered by priority. |
| L4.5 | Operators can inject custom instructions that apply to all agents across the system. |
| L4.6 | Under memory pressure, the harness reconstructs a minimal context that preserves identity and current work state without repeating the full role template. |
| L4.7 | Context assembly follows a uniform pipeline across all roles, with role-specific content supplied via pluggable templates. |

---

### L5 — Behavioral Controls

*What the agent can and cannot do.*

**Principle:** The harness must be able to intercept, evaluate, and block agent actions at defined points in the agent's execution cycle. The agent must have no mechanism to bypass these controls.

**Capabilities:**

| ID | Capability |
|----|------------|
| L5.1 | The harness intercepts agent actions at defined lifecycle points: session start, each interaction turn, before action execution, and session stop. |
| L5.2 | Before action execution, the harness evaluates the proposed action against a rule set and can block it. |
| L5.3 | Rules are composable from multiple layers (built-in, operator, role-specific) through a deterministic merge algorithm. |
| L5.4 | The harness prevents destructive operations and workflow violations as defined by the operator. |
| L5.5 | Autonomous agents operate without interactive confirmation — controls are enforced programmatically, not by prompting a human. |
| L5.6 | The full set of active rules is reproducible from its source inputs, recovering from any runtime drift. |

---

### L6 — Work Binding

*How work attaches to an agent.*

**Principle:** Work assignment must be durable, exclusive, and atomic. The binding lives in the system's persistent store — not in agent memory — and survives any number of agent restarts, failures, and replacements.

**Capabilities:**

| ID | Capability |
|----|------------|
| L6.1 | Work assignment is durable — it survives agent restarts, crashes, and handoffs. |
| L6.2 | A work item is exclusively assigned to at most one agent at a time. |
| L6.3 | Binding is atomic — the agent's current-work reference and the work item's assigned-agent field update together. |
| L6.4 | Binding occurs before the agent session starts, so that the initial context assembly sees the assignment immediately. |
| L6.5 | An execution plan (formula) can be attached to the work item at binding time. |
| L6.6 | Concurrent binding attempts on the same work item are prevented. |
| L6.7 | Bindings are reversible — the assignment can be cleared, returning the work item to an available state. |

---

### L7 — Communication

*How the agent hears from and talks to the system.*

**Principle:** Agents must be addressable participants in a messaging system that supports both durable asynchronous messages and low-latency synchronous delivery. Communication must work across agent restarts and support priority-based ordering.

**Capabilities:**

| ID | Capability |
|----|------------|
| L7.1 | The system supports both asynchronous messages (durable, delivered at turn boundaries) and synchronous delivery (immediate, may interrupt current work). |
| L7.2 | Asynchronous messages are durable — they survive agent restarts and are not lost if the agent is unavailable at send time. |
| L7.3 | Messages carry priority levels that affect delivery order and framing. |
| L7.4 | Message delivery is trackable through at least two states: sent and acknowledged. |
| L7.5 | Agents are addressable by a structured identifier. Address resolution validates against registered agents. |
| L7.6 | The system supports multiple delivery patterns: direct (one-to-one), group (one-to-many), subscription-based (pub/sub), claim-based (queue), and broadcast (all agents). |
| L7.7 | The system supports structured/typed messages for machine-to-machine coordination alongside free-form messages. |
| L7.8 | Agents can suppress non-critical interruptions, with an override for urgent messages. |
| L7.9 | Alerts can be routed to configurable targets based on severity. |

---

### L8 — Execution Navigation

*How the agent tracks and advances through its work.*

**Principle:** Work must be decomposable into structured execution plans with dependency ordering. The system — not the agent's memory — tracks execution state, ensuring progress survives agent replacement.

**Capabilities:**

| ID | Capability |
|----|------------|
| L8.1 | Work is decomposable into a structured execution plan (formula) consisting of discrete steps. |
| L8.2 | Steps support dependency ordering as a directed acyclic graph. The system determines which steps are ready based on completed dependencies. |
| L8.3 | Execution plans exist at multiple fidelity levels — from lightweight checklists held only in agent context to fully persistent plans where each step is independently tracked in the system store. |
| L8.4 | Execution plans support parameterization — template variables resolved at instantiation time. |
| L8.5 | Execution plans support multiple topologies: sequential, parallel with join, and compositional (plan inheritance and extension). |
| L8.6 | Step advancement is explicit — the agent signals completion, the system computes the next ready steps, and the agent's context is updated. |
| L8.7 | Agents can suspend execution to wait for an external signal or event, with configurable backoff behavior. |
| L8.8 | Execution progress is queryable: current step, completion percentage, and blocked/ready counts. |

---

### L9 — Work Delivery

*How completed work leaves the agent.*

**Principle:** Work delivery must follow a defined, resumable protocol. Each phase of delivery is checkpointed so that failures mid-delivery result in resumption, not repetition. All work events are durably recorded.

**Capabilities:**

| ID | Capability |
|----|------------|
| L9.1 | Delivery follows a defined protocol of ordered phases: validate → publish → submit for review → notify stakeholders → close work item → release binding. |
| L9.2 | Each delivery phase is checkpointed. A failure mid-delivery resumes from the last completed checkpoint. |
| L9.3 | Delivery notifies the appropriate review and oversight participants. |
| L9.4 | For compound work items, completion of a sub-item triggers evaluation of whether the parent item is fully satisfied. |
| L9.5 | All work lifecycle events are recorded in a durable, append-only event store. |
| L9.6 | The system maintains a human-readable activity log alongside the structured event store. |
| L9.7 | After delivery, the agent's workspace is returned to a clean baseline state. |

---

### L10 — Lifecycle Contract

*How the agent is spawned, cycled, and stopped.*

**Principle:** All agents — regardless of role — follow the same lifecycle: create → start → run → replace-or-stop. Session continuity is maintained across agent replacements through durable state, not agent memory. The harness owns the lifecycle; the agent is a tenant.

**Capabilities:**

| ID | Capability |
|----|------------|
| L10.1 | All agent roles are startable through a unified startup path that accepts role-specific configuration. |
| L10.2 | Startup provisions the execution boundary, launches the agent with appropriate context, waits for readiness, and verifies responsiveness. |
| L10.3 | The harness supports session continuity — an agent can be replaced within its execution boundary while preserving identity, work binding, and execution state. |
| L10.4 | On replacement, the outgoing agent's state summary is delivered to its successor. The successor resumes from where the predecessor stopped. |
| L10.5 | Under memory pressure, the harness can refresh the agent's context without full replacement. |
| L10.6 | Shutdown follows a defined escalation: request → grace period → forced termination. |
| L10.7 | Multi-agent shutdown follows a defined order — supervised agents stop before their supervisors. |
| L10.8 | The harness supports crash recovery — a successor session can detect and resume from a checkpointed state. |
| L10.9 | The harness provides access to predecessor session history for context recovery. |
| L10.10 | The harness distinguishes messages from the current session versus prior sessions, preventing re-processing of stale messages. |
| L10.11 | Critical roles support automatic restart after process failure, with a dampening delay to prevent restart loops. |
| L10.12 | Agent liveness is detectable through periodic health signals, with safeguards against false-positive detection from recycled process identifiers. |

---

## 4. Agent Lifecycle

The canonical lifecycle of a work-executing agent, expressed as abstract phases.

### Phase A — Provisioning

1. **Dispatch**: Work assignment is triggered, targeting a project.
2. **Identity allocation**: The system allocates or creates an agent identity.
3. **Workspace provisioning**: An isolated workspace is provisioned with access to shared resources and behavioral configuration.
4. **Work binding**: The work item is atomically bound to the agent with an execution plan attached.

### Phase B — Activation

5. **Session creation**: The execution boundary is created and the agent is launched with appropriate environment and context.
6. **Context assembly**: The harness delivers the full role context, work details, and autonomous execution directive.
7. **Autonomous start**: The agent begins executing its assigned work without waiting for human input.

### Phase C — Execution

8. **Plan execution**: The agent works through execution plan steps in dependency order.
9. **Communication**: The agent sends and receives messages as needed. Inbound messages are delivered at turn boundaries or injected immediately depending on urgency.
10. **Control enforcement**: The harness evaluates and blocks prohibited actions.

### Phase D — Delivery

11. **Completion protocol**: The agent validates and publishes its work through the checkpointed delivery sequence.
12. **Notification**: Review and oversight participants are notified.
13. **Cleanup**: Work item is closed, binding is released, workspace is reset to baseline.

### Phase E — Continuity (alternative to Phase D)

14. **Memory pressure**: The harness refreshes the agent's context with a minimal continuation directive, preserving work state.
15. **Session replacement**: The agent saves state and is replaced. The successor receives the predecessor's summary and resumes execution. Work binding, execution plan, and all durable state persist across the boundary.

---

## 5. Cross-Cutting Principles

### 5.1 Addressability

Every agent is uniquely and deterministically addressable. The addressing scheme is consistent across all system interfaces: messaging, work assignment, observation, and lifecycle management.

### 5.2 Crash Safety

All state transitions that cross a failure boundary (work binding, delivery, handoff) are checkpointed. The system resumes from the last successful checkpoint rather than restarting the operation.

### 5.3 Reproducible Configuration

All behavioral configuration — controls, role definitions, agent selection — is reproducible from its source inputs through a deterministic resolution process. Runtime configuration can always be regenerated from source.

### 5.4 External State as Source of Truth

The system's persistent store — not agent memory or local ephemeral state — is the authoritative record of work assignments, agent state, message history, and completion status. Ephemeral local state (checkpoints, markers, heartbeats) exists only to bridge failure gaps.

### 5.5 Runtime Agnosticism

The harness is independent of any specific AI provider. New agent runtimes are integrable by declaring their capabilities without modifying the harness core. The harness communicates with all agent types through the same abstract interfaces.

### 5.6 Separation of Harness and Role

The harness provides infrastructure; roles provide intelligence. Role-specific behaviors (scheduling algorithms, review procedures, monitoring strategies) are consumers of the harness, not part of it. The harness is the same for every role.

---

## 6. Invariants

Properties that hold at all times across any conforming implementation.

| ID | Invariant |
|----|-----------|
| INV-1 | A work item is assigned to at most one agent at any time. |
| INV-2 | An agent's authoritative identity is immutable for the lifetime of its session. |
| INV-3 | Work binding survives any number of agent replacements and crash-recovery cycles. |
| INV-4 | Messages from prior sessions are distinguishable from current-session messages and are not re-processed. |
| INV-5 | Behavioral controls are evaluated on every agent action, with no bypass available to the agent. |
| INV-6 | Context assembly produces equivalent output for equivalent inputs, regardless of agent runtime. |
| INV-7 | Work lifecycle events are durably recorded before the triggering operation is considered complete. |
| INV-8 | An agent's identity is derivable from its workspace, and its workspace is derivable from its identity. |
| INV-9 | Behavioral configuration is reproducible from source inputs alone. |
