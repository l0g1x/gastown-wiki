# 07 — Communication Layer

> Reflects upstream commit: `ae11c53c`

Investigation of how any agent talks to and hears from the rest of the system.

Source: `/home/krystian/gt/gastown/crew/sherlock/internal/`

---

## Architecture Overview

The Gas Town communication layer has three distinct transport channels:

1. **Mail** — durable, asynchronous, pull-based messages stored as beads in a Dolt database. The primary inter-agent coordination mechanism.
2. **Nudge** — a lightweight push channel for real-time session notifications. Two sub-modes: direct tmux injection and file-queue cooperative delivery.
3. **Protocol messages** — a thin typed layer on top of mail. Witness-Refinery merge pipeline uses structured subjects and key-value bodies parsed into typed payloads.

All mail storage is in a **town-level beads database** (`{townRoot}/.beads`) regardless of whether the sender or recipient is a town agent (mayor, deacon) or a rig agent (witness, refinery, polecat, crew). Rig-level beads databases exist only for project issues, not mail.

---

## Mail System

### Core Types (`internal/mail/types.go`)

The `Message` struct is the canonical in-memory representation:

```go
type Message struct {
    ID              string      // "msg-<8-byte-hex>"
    From            string      // address e.g., "gastown/Toast"
    To              string      // address (mutually exclusive with Queue and Channel)
    Queue           string      // queue name (mutually exclusive with To, Channel)
    Channel         string      // channel name (mutually exclusive with To, Queue)
    Subject         string
    Body            string
    Timestamp       time.Time
    Read            bool
    Priority        Priority    // "low", "normal", "high", "urgent"
    Type            MessageType // "task", "scavenge", "notification", "reply"
    Delivery        Delivery    // "queue" or "interrupt"
    ThreadID        string      // "thread-<6-byte-hex>"
    ReplyTo         string      // ID of parent message
    Pinned          bool
    Wisp            bool        // ephemeral, not synced to git
    CC              []string
    ClaimedBy       string
    ClaimedAt       *time.Time
    DeliveryState   string      // "pending" or "acked"
    DeliveryAckedBy string
    DeliveryAckedAt *time.Time
    SuppressNotify  bool        // in-memory only, not serialized
}
```

**Three mutually exclusive routing targets** — a message has exactly one of: `To` (direct), `Queue` (worker claiming), or `Channel` (broadcast). Validation enforces this at `Message.Validate()`.

**Priority mapping** — GGT uses strings (`"urgent"`, `"high"`, `"normal"`, `"low"`), beads uses integers (0, 1, 2, 3). Conversion at `PriorityToBeads()` and `PriorityFromInt()`.

**BeadsMessage** is the wire format returned by `bd list --json` / `bd show --json`. Metadata lives in the `labels` array using prefixed string keys:

```
"from:<sender>"
"thread:<id>"
"reply-to:<id>"
"msg-type:<type>"
"cc:<identity>"
"queue:<name>"
"channel:<name>"
"claimed-by:<identity>"
"claimed-at:<RFC3339>"
"delivery:pending"
"delivery:acked"
"delivery-acked-by:<identity>"
"delivery-acked-at:<RFC3339>"
"gt:message"
"read"
```

`BeadsMessage.ToMessage()` (types.go:382) converts wire format to the in-memory `Message` by calling `ParseLabels()` to extract all prefixed labels.

### Storage: Beads (Dolt) Primary, JSONL Legacy

**Primary mode (beads):** Messages are stored as beads issues in a Dolt database under `{townRoot}/.beads`. Each message is a `bd create` call. The assignee field encodes the recipient identity. Labels encode all message metadata. The Dolt database is the source of truth and can be synced to git.

**Legacy mode (JSONL):** A `Mailbox` created via `NewMailbox(path)` reads/writes `inbox.jsonl` files in a flat directory. One JSON object per line. Writes are protected by an `flock` on `inbox.jsonl.lock`. Rewrites use an atomic rename via a `.tmp` file. This mode is still used by some crew workers with local inboxes.

The `Mailbox` struct (mailbox.go:31) has a `legacy bool` field that gates all operations:

```go
type Mailbox struct {
    identity string  // beads identity
    workDir  string  // dir to run bd in
    beadsDir string  // explicit .beads dir (BEADS_DIR env)
    path     string  // legacy JSONL path
    legacy   bool
}
```

**Archive** — both modes append to an `archive.jsonl` file (in beads mode, at `{beadsDir}/archive.jsonl`). Beads mode archives by appending to JSONL then calling `bd close` on the bead.

### Mail Send: End-to-End (`internal/mail/router.go`)

The `Router` is the send-side entry point. All sends go through `Router.Send(msg)`.

**Router construction:**

```go
// internal/mail/router.go:53
func NewRouter(workDir string) *Router {
    townRoot := detectTownRoot(workDir)
    return &Router{
        workDir:  workDir,
        townRoot: townRoot,
        tmux:     tmux.NewTmux(),
    }
}
```

**Send dispatch** (router.go:~840):

```go
func (r *Router) Send(msg *Message) error {
    switch {
    case isListAddress(msg.To):     return r.sendToList(msg)
    case isQueueAddress(msg.To):    return r.sendToQueue(msg)
    case isAnnounceAddress(msg.To): return r.sendToAnnounce(msg)
    case isChannelAddress(msg.To):  return r.sendToChannel(msg)
    case isGroupAddress(msg.To):    return r.sendToGroup(msg)
    default:                        return r.sendToSingle(msg)
    }
}
```

**Direct message send** (`sendToSingle`, router.go:~1042):

1. Generate `msg.ID` if missing.
2. Validate via `msg.Validate()`.
3. Convert `msg.To` to beads identity via `AddressToIdentity()`.
4. Expand crew/polecats shorthand via `resolveCrewShorthand()`.
5. Validate recipient exists via `validateRecipient()` (checks agent beads + workspace directories).
6. Build label list: `gt:message`, `from:<sender>`, `delivery:pending`, `thread:<id>`, `reply-to:<id>`, `cc:<identity>` for each CC.
7. Determine `--ephemeral` flag via `shouldBeWisp()` (checks `msg.Wisp` or auto-detects from subject prefix like `POLECAT_DONE`, `NUDGE`, etc.).
8. Execute: `bd create --assignee <identity> -d <body> --priority <N> --labels <...> --actor <from> [--ephemeral] -- <subject>`
9. Spawn async goroutine for recipient notification via `notifyRecipient()`.

**All mail beads directory:** `{townRoot}/.beads` — resolved by `resolveBeadsDir()` which always returns the town-level path regardless of the sending agent's rig location.

**bd command execution** (bd.go:57): Every bd operation runs as a subprocess via `exec.CommandContext`. Environment variables set: `BEADS_DIR=<path>`, OTEL env for telemetry, plus any `extraEnv` passed by caller. Timeouts: 60s for reads, 60s for writes (increased from 30s due to contention under multi-agent load).

### Mail Receive: Reading the Inbox

**Mailbox.List()** (mailbox.go:101) → `listBeads()` → `listFromDir()`:

1. Run `bd list --label gt:message --assignee <identity> --json --limit 0` for each identity variant (e.g., `mayor/` and `mayor` for backward compat).
2. Run a second query with `--label cc:<identity>` to find CC'd messages.
3. Deduplicate by message ID.
4. Filter: only `status == "open"` or `status == "hooked"`.
5. `ToMessage()` on each `BeadsMessage`.
6. Sort by priority (higher first) then timestamp (newest first).

**Mark read:**
- `MarkRead(id)` → `bd close <id>` (closes the bead, status becomes "closed").
- `MarkReadOnly(id)` → `bd label add <id> read` (keeps bead open, adds "read" label).
- `MarkUnreadOnly(id)` → `bd label remove <id> read`.

**Delete** in beads mode is just `MarkRead` (closes the bead). There is no hard delete for beads messages.

### Mail Check and Inject (`internal/cmd/mail_check.go`)

`gt mail check --inject` is the agent's hook-called mail poll. It:

1. Detects the agent's address via `detectSender()`.
2. Gets the mailbox via `Router.GetMailbox(address)`.
3. Counts unread messages.
4. If `--inject` and unread > 0:
   - Lists unread via `mailbox.ListUnread()`.
   - Calls `formatInjectOutput(messages)` which writes to stdout as a `<system-reminder>` block (see below).
   - Calls `mailbox.AcknowledgeDeliveries(address, messages)` to write phase-2 ack labels concurrently (up to 8 concurrent bd processes).
5. Drains the nudge queue for the current tmux session via `nudge.Drain(workDir, sessionName)`.
6. If nudges found, prints them via `nudge.FormatForInjection(nudges)`.

**Inject output format** (mail_check.go:113) — three priority tiers produce different framing:

```
Urgent (priority=0):
<system-reminder>
URGENT: N urgent message(s) require immediate attention.
- <id> from <from>: <subject>
Run 'gt mail read <id>' to read urgent messages.
</system-reminder>

High (priority=1):
<system-reminder>
You have N high-priority message(s) in your inbox.
- <id> from <from>: <subject>
Continue your current task. When it completes, process these messages
before going idle: 'gt mail inbox'
</system-reminder>

Normal/Low:
<system-reminder>
You have N unread message(s) in your inbox.
- <id> from <from>: <subject>
Continue your current task. When it completes, check these messages
before going idle: 'gt mail inbox'
</system-reminder>
```

### Two-Phase Delivery Tracking (`internal/mail/delivery.go`)

Messages carry delivery state in their labels:

- **Phase 1 (send):** `delivery:pending` label written at send time by `DeliverySendLabels()`.
- **Phase 2 (ack):** Three labels written on `gt mail check --inject`:
  1. `delivery-acked-by:<recipientIdentity>`
  2. `delivery-acked-at:<RFC3339>`
  3. `delivery:acked`

The ordering is intentional for crash safety: state stays `pending` until the final `delivery:acked` label write succeeds. The ack sequence is idempotent — `DeliveryAckLabelSequenceIdempotent()` reuses an existing timestamp if the same recipient is the sole acker.

`AcknowledgeDeliveryBead()` (delivery.go:81) reads existing labels first (for idempotent retry), then applies ack labels sequentially via `bd label add`.

---

## Address Resolution (`internal/mail/resolve.go`)

The `Resolver` translates human-friendly addresses to one or more `Recipient` structs. Resolution is ordered:

1. **Explicit prefix** — `group:`, `queue:`, `channel:`, `list:`, `announce:` → bypass name lookup.
2. **@ prefix** — `@town`, `@witnesses`, `@rig/<name>`, `@crew/<name>` → group expansion. First checks beads-native groups, falls back to built-in patterns.
3. **Contains `/`** — agent address. Validates against agent beads and workspace directories. Wildcard patterns (`gastown/*`) expand to all matching agents.
4. **Name lookup** — checks for group, queue, and channel by name. If ambiguous (e.g., a group and a queue share the name), requires an explicit prefix. If not found in any, returns error.

**Recipient types:**

```go
const (
    RecipientAgent   RecipientType = "agent"   // direct to agent(s)
    RecipientQueue   RecipientType = "queue"   // single message, workers claim
    RecipientChannel RecipientType = "channel" // broadcast, retained
)
```

**Address → identity normalization** (`normalizeAddress`, types.go:548):

```
"overseer"           → "overseer"
"mayor" / "mayor/"  → "mayor/"
"deacon" / "deacon/" → "deacon/"
"gastown/polecats/Toast" → "gastown/Toast"   (crew/polecats normalized out)
"gastown/crew/max"   → "gastown/max"
"gastown/Toast"      → "gastown/Toast"
```

**Agent bead ID → address** (`AgentBeadIDToAddress`, resolve.go:464):

```
"gt-gastown-crew-max"  → "gastown/crew/max"
"gt-gastown-witness"   → "gastown/witness"
"hq-mayor"             → "mayor/"
"hq-deacon"            → "deacon/"
```

Agent bead ID format: `<prefix>-<rig>-<role>[-<name>]` where prefix is `gt` (rig), `hq` (town), or a rig-specific abbreviation.

**Validation** (`validateAgentAddress`, resolve.go:130): When a slash-containing address arrives, the resolver checks:
1. Well-known singletons (mayor, deacon, overseer, rig/witness, rig/refinery) — always valid.
2. Agent beads list (`beads.ListAgentBeads()`).
3. Workspace directory existence as fallback.

If neither beads nor `townRoot` is available, validation is skipped (graceful degradation).

**Group expansion** supports cycle detection via a `visited map[string]bool` threaded through recursive calls.

---

## Mail Routing (`internal/mail/router.go`)

The Router handles five delivery modes:

### 1. List fan-out (`list:name`)
Loads `config/messaging.json`, finds `lists[name]`, sends an individual copy to each member via recursive `Send()`. Each copy gets its own message ID.

### 2. Queue delivery (`queue:name`)
Creates a single bead with assignee `queue:<name>` and label `queue:<name>`. Workers claim by adding `claimed-by:` and `claimed-at:` labels. Race condition avoidance via post-claim verification (claim, re-read, verify `ClaimedBy == self`, else release and try next).

Queue messages are never ephemeral — they must persist until claimed.

### 3. Announce channel (`announce:name`)
Creates a single bead with assignee `announce:<name>`. No claiming. Retention pruning runs before each new message: if count >= `retain_count`, oldest messages are closed. Readers query by `announce:<name>` label. Does NOT fan-out to subscribers.

### 4. Beads-native channel (`channel:name`)
Creates a single origin bead with assignee `channel:<name>`. Retention enforced via `b.EnforceChannelRetention()`. **Also fans out** individual copies to each subscriber's inbox via `sendToSingle()`. Fan-out copies have `[channel:<name>]` prepended to the subject.

### 5. Group (`@group`)
Resolves group to individual addresses, then calls `sendToSingle()` for each. Each fan-out copy gets a new ID.

### Notification (`notifyRecipient`)

After a durable write completes, `sendToSingle()` spawns an async goroutine that calls `notifyRecipient()`. This is always enqueued into the nudge queue (via `nudge.Enqueue()`) rather than injected directly, to avoid TOCTOU races where a WaitForIdle check sees a brief idle flash and then NudgeSession disrupts an agent that has resumed work.

The overseer is special: gets a tmux banner via `tmux.SendNotificationBanner()` rather than a nudge.

DND check (`isRecipientMuted()`) happens before notification attempt. Fails open (allows notification) if agent bead not found.

Self-mail is silently skipped for notification (`isSelfMail()` comparison).

---

## Nudge System (`internal/nudge/queue.go`, `internal/cmd/nudge.go`)

Nudge is a thin real-time channel separate from mail. `gt nudge <target> <message>` is the entry point.

### Three Delivery Modes

**Mode 1: immediate** (default)

```go
// nudge.go:177
return t.NudgeSession(sessionName, prefixedMessage)
```

`NudgeSession` sends the message as text via `tmux send-keys`. The exact content sent is `[from <sender>] <message>` followed by Enter. This directly types into the agent's terminal — it interrupts any in-flight tool call. The text appears in the Claude Code input buffer and Enter submits it as a new user turn.

**Mode 2: queue**

```go
// nudge.go:141
return nudge.Enqueue(townRoot, sessionName, nudge.QueuedNudge{
    Sender:   sender,
    Message:  message,
    Priority: nudgePriorityFlag,
})
```

`Enqueue()` (queue.go:81):
1. Resolves queue dir: `{townRoot}/.runtime/nudge_queue/{session}/` (slashes in session name replaced with `_`).
2. Checks queue depth against `MaxQueueDepth = 50`.
3. Marshals `QueuedNudge` to JSON with indentation.
4. Writes to file named `{UnixNano}-{4-byte-random-hex}.json` for FIFO ordering and collision avoidance.
5. Sets TTL: 30 min for normal, 2 hours for urgent.

The file is picked up by `nudge.Drain()` at the next agent turn boundary (UserPromptSubmit hook).

**Mode 3: wait-idle**

```go
// nudge.go:154-175
err := t.WaitForIdle(sessionName, waitIdleTimeout) // 15s timeout
if err == nil {
    return t.NudgeSession(sessionName, prefixedMessage) // idle: deliver direct
}
// timeout: fall back to queue
nudge.Enqueue(townRoot, sessionName, QueuedNudge{...})
// queue full: last resort immediate
t.NudgeSession(sessionName, prefixedMessage)
```

`WaitForIdle` polls the tmux session to detect when the Claude prompt is visible (agent waiting for input). If idle within 15 seconds, delivers directly. If busy, falls back to queue. If queue fails (full or no workspace), falls back to immediate as last resort.

### Drain (Queue Pickup)

`Drain()` (queue.go:137) is called in `gt mail check --inject` after listing mail. It:

1. Reads queue directory entries.
2. Sweeps orphaned `.claimed.*` files older than 5 minutes (requeues them via rename back to `.json`).
3. Sorts entries by filename (timestamp-ordered) for FIFO.
4. For each `.json` file:
   - Atomically renames to `<original>.claimed.<random-suffix>` to prevent double-delivery.
   - Reads and unmarshals the claimed file.
   - Checks expiry (`ExpiresAt`), discards if past.
   - Appends to result.
   - Removes the claimed file.
5. Returns `[]QueuedNudge` in FIFO order.

### Inject Format for Nudges

`FormatForInjection()` (queue.go:271) produces a `<system-reminder>` block:

```
Urgent nudges:
<system-reminder>
QUEUED NUDGE (N urgent):

  [URGENT from <sender>] <message>

Plus M non-urgent nudge(s):
  [from <sender>] <message>

Handle urgent nudges before continuing current work.
</system-reminder>

Normal nudges:
<system-reminder>
QUEUED NUDGE (N message(s)):

  [from <sender>] <message>

This is a background notification. Continue current work unless the nudge is higher priority.
</system-reminder>
```

Note that the `Sender` field is stored separately from the `Message` — the `[from X]` prefix is added at injection time, not at enqueue time, preventing double-prefixing compared to immediate mode which prepends `[from <sender>]` before calling `NudgeSession`.

### Channel Nudge (`gt nudge channel:<name>`)

Looks up `nudge_channels[name]` in `config/messaging.json`. Each entry is a list of patterns (`"gastown/polecats/*"`, `"mayor"`, etc.). Patterns are matched against all running agent sessions. Each matched session gets a nudge delivered via `deliverNudge()` respecting the `--mode` flag. DND is checked per-target.

### Broadcast (`internal/cmd/broadcast.go`)

`gt broadcast <message>` enumerates all running agent sessions via `getAgentSessions()`. Filters: `--rig` for rig scoping, `--all` to include infrastructure agents (default: workers only). Skips self (by `BD_ACTOR` env var match). Checks DND per-target. Delivers via `t.NudgeSession()` directly (always immediate mode, no `--mode` support unlike `gt nudge`).

---

## Mail Hook (`internal/cmd/mail_hook.go`)

`gt mail hook <mail-id>` is an alias for `gt hook attach <mail-id>`. It delegates entirely to `runHook()`. The hook subsystem attaches a bead to the agent's durability hook — so the mail message becomes the agent's active work item. The mail bead's status becomes "hooked". When `Mailbox.listFromDir()` queries messages, it includes `status == "hooked"` so hooked mail still appears in the inbox.

---

## Escalation (`internal/cmd/escalate.go`, `internal/cmd/escalate_impl.go`)

`gt escalate <description>` creates a severity-routed alert. Flow:

1. Validates severity: `critical`, `high`, `medium` (default), `low`.
2. Finds workspace and loads `settings/escalation.json`.
3. Creates an escalation bead via `beads.CreateEscalationBead()` with label `gt:escalation`.
4. Looks up routing actions for the severity from config. Actions can be:
   - `mail:<target>` — sends a mail message via `Router.Send()`.
   - `email:<contact>` — stub (not implemented).
   - `sms:<contact>` — stub (not implemented).
   - `slack` — stub (not implemented).
   - `log` — stub.
5. Mail priority maps from severity: `critical → urgent`, `high → high`, `medium → normal`, `low → low`.
6. Each mail target gets a formatted body with the escalation ID and instructions for `gt escalate ack` / `gt escalate close`.

**Stale re-escalation** (`gt escalate stale`): Finds escalations older than `stale_threshold` (default 4h) that haven't been acked. Bumps severity: `low → medium → high → critical`. Respects `max_reescalations` limit (default 2). Sends new mail to the routing targets for the new severity. The escalation bead tracks `reescalation_count` to prevent infinite cycling.

**Severity routing config** (`settings/escalation.json`): A map of severity to action list. Example: `"critical": ["mail:mayor/", "mail:overseer", "email:human"]`.

---

## Protocol Messages (`internal/protocol/`)

The protocol package defines typed, structured inter-agent messages that travel over the mail system. They are not a separate transport — they are ordinary mail messages with recognizable subject patterns and key-value bodies.

### Message Types (`types.go`)

```go
const (
    TypeMergeReady         = "MERGE_READY"          // Witness → Refinery
    TypeMerged             = "MERGED"                // Refinery → Witness
    TypeMergeFailed        = "MERGE_FAILED"          // Refinery → Witness
    TypeReworkRequest      = "REWORK_REQUEST"         // Refinery → Witness
    TypeConvoyNeedsFeeding = "CONVOY_NEEDS_FEEDING"  // Refinery → Deacon
)
```

Subject format: `"<TYPE> <qualifier>"` e.g., `"MERGE_READY Toast"`, `"CONVOY_NEEDS_FEEDING convoy-abc"`.

Body format: plain key-value lines parsed by `parseField(body, "Key")`:
```
Branch: polecat/Toast/gt-abc123
Issue: gt-abc123
Polecat: Toast
Rig: gastown
Verified: clean git state, issue closed
```

### Payload Structs (`types.go`)

Each message type has a typed payload struct:

- `MergeReadyPayload` — Branch, Issue, Polecat, Rig, Verified, Timestamp
- `MergedPayload` — Branch, Issue, Polecat, Rig, MergedAt, MergeCommit, TargetBranch
- `MergeFailedPayload` — Branch, Issue, Polecat, Rig, FailedAt, FailureType, Error, TargetBranch
- `ReworkRequestPayload` — Branch, Issue, Polecat, Rig, RequestedAt, TargetBranch, ConflictFiles, Instructions
- `ConvoyNeedsFeedingPayload` — ConvoyID, SourceIssue, Rig, MergedAt
- `PolecatDonePayload` — Polecat, ExitType, Issue, Branch, MR, ConvoyID, ConvoyOwned, MergeStrategy, Errors

`PolecatDonePayload` is a mail convention (not a formal protocol message) — the polecat sends `POLECAT_DONE` mail to its witness, parsed by `ParsePolecatDonePayload()`.

### Handler Registry (`handlers.go`)

The registry pattern allows agents to register typed handlers:

```go
registry := protocol.NewHandlerRegistry()
registry.Register(protocol.TypeMerged, func(msg *mail.Message) error {
    payload, err := protocol.ParseMergedPayload(msg.Body)
    ...
    return h.HandleMerged(payload)
})
```

`ProcessProtocolMessage(msg)` returns `(isProtocol bool, err error)`:
- `(false, nil)` — not a protocol message (subject unrecognized)
- `(true, nil)` — handled successfully
- `(true, ErrNoHandler)` — recognized type but no handler registered
- `(true, err)` — handling failed

### Merge Pipeline Flow

```
Polecat → Witness: "POLECAT_DONE Toast"     (mail convention)
Witness → Refinery: "MERGE_READY Toast"      (TypeMergeReady)
Refinery → Witness: "MERGED Toast"           (TypeMerged)
    OR              "MERGE_FAILED Toast"      (TypeMergeFailed)
    OR              "REWORK_REQUEST Toast"    (TypeReworkRequest)
Refinery → Deacon: "CONVOY_NEEDS_FEEDING <id>" (TypeConvoyNeedsFeeding)
```

The Witness handler (`witness_handlers.go`) on `MERGED` calls `witness.AutoNukeIfClean()` to clean up the polecat's worktree after confirming the merge succeeded.

---

## `gt peek` — Reading Agent Output (`internal/cmd/peek.go`)

`gt peek <address> [N]` captures terminal output from an agent's tmux session. It is the read-side complement to `gt nudge` (the write side).

Address parsing:
- Town agents: `mayor`, `hq/mayor`, `deacon`, `hq/deacon`, `boot` → hardcoded session names (`hq-mayor`, `hq-deacon`, `hq-boot`).
- Rig agents: `<rig>/<polecat>` or `<rig>/crew/<name>` → resolved via `getSessionManager(rigName)` and `mgr.Capture(polecatName, lines)`.

For crew workers (`crew/` prefix in address), uses `session.CrewSessionName(rigPrefix, crewName)` directly.

Implementation calls `tmux.CapturePane(sessionName, lines)` which runs `tmux capture-pane -p -S -<N>`. Returns raw terminal output including ANSI codes.

---

## State

### Mailbox Storage

| Location | Format | Content |
|----------|--------|---------|
| `{townRoot}/.beads/` | Dolt (SQLite/MySQL-compatible) | All mail messages as issues with labels |
| `{townRoot}/.beads/archive.jsonl` | JSONL, one message per line | Archived mail (beads mode) |
| `{agentDir}/inbox.jsonl` | JSONL, one message per line | Legacy JSONL mode inbox |
| `{agentDir}/inbox.jsonl.archive` | JSONL | Legacy JSONL mode archive |

### Nudge Queue Storage

Location: `{townRoot}/.runtime/nudge_queue/{session-name}/`

Where `{session-name}` is the tmux session name with `/` replaced by `_`.

Each file: `{UnixNano}-{8-hex-chars}.json`

```json
{
  "sender": "mayor/",
  "message": "Check your mail",
  "priority": "normal",
  "timestamp": "2026-02-28T12:00:00Z",
  "expires_at": "2026-02-28T12:30:00Z"
}
```

Claim files during drain: `{original}.json.claimed.{4-hex-chars}` — ephemeral, removed after successful processing.

### Protocol State

Protocol messages are ordinary mail messages in the beads database. There is no separate protocol state store. The subject line is the discriminator. The Witness and Refinery read their inboxes and dispatch protocol messages through handler registries registered at startup.

---

## Interfaces to Other Systems

### Prompt Assembly (Mail Injection)

`gt mail check --inject` is called from the Claude Code `UserPromptSubmit` hook. Its stdout is injected directly into the agent's prompt context as a `<system-reminder>` block. The hook output is concatenated with any other hook output and prepended to the user's actual message. This is how mail delivery becomes part of the agent's context.

### Work Binding (Mail-to-Hook)

`gt mail hook <mail-id>` delegates to `gt hook attach <mail-id>`, which sets the mail bead as the agent's active work on its durability hook. The hook mechanism changes the bead's status to "hooked" in beads. This makes the mail message the agent's primary work assignment.

### Lifecycle (Handoff Mail)

Agents send mail to themselves (`gt mail send --self -s "Handoff" -m "<context>"`) to pass context across session boundaries. The `shouldBeWisp()` check auto-classifies messages with subjects matching `POLECAT_DONE`, `LIFECYCLE:`, `NUDGE`, etc. as ephemeral wisps that are not synced to git and are cleaned up on patrol squash.

---

## Control Flow Traces

### Full Mail Send → Deliver → Inject

```
1. Agent calls: gt mail send gastown/Toast -s "Fix this" -m "Body"

2. runMailSend() [mail_send.go:20]
   a. Detect sender via detectSender() (reads GT_ROLE, BD_ACTOR, or cwd)
   b. Create Message with NewMessage(from, to, subject, body)
   c. Set Priority, Type, Wisp, CC from flags
   d. Create Resolver with beads+townRoot; call resolver.Resolve("gastown/Toast")
      → resolveAgentAddress("gastown/Toast")
      → validateAgentAddress: checks agent beads, workspace dir
      → returns [Recipient{Address:"gastown/Toast", Type:RecipientAgent}]
   e. Create Router with NewRouter(workDir)
   f. Call router.Send(msg) for each recipient

3. Router.Send(msg) [router.go]
   → sendToSingle(msg)
   a. Generate msg.ID = "msg-<8-byte-hex>"
   b. msg.Validate() — check From, Subject, routing exclusivity
   c. toIdentity = AddressToIdentity("gastown/Toast") → "gastown/Toast"
   d. toIdentity = resolveCrewShorthand(toIdentity) — no-op for polecat
   e. validateRecipient(toIdentity) — queries agent beads + workspace
   f. labels = ["gt:message", "from:gastown/sender", "delivery:pending",
                "thread:thread-<6-byte-hex>"]
   g. shouldBeWisp(msg) → false (normal notification)
   h. bd create --assignee gastown/Toast -d "Body"
              --priority 2 --labels gt:message,from:...,delivery:pending,...
              --actor gastown/sender -- "Fix this"
              (BEADS_DIR={townRoot}/.beads set in env)
   i. Spawn goroutine: notifyRecipient(msg)
      → Check DND: isRecipientMuted("gastown/Toast") → false
      → AddressToSessionIDs("gastown/Toast") → ["gt-crew-Toast", "gt-Toast"]
      → Try each session via tmux.HasSession()
      → nudge.Enqueue(townRoot, "gt-gastown-Toast", QueuedNudge{
            Sender: "gastown/sender",
            Message: "📬 You have new mail from gastown/sender. Subject: Fix this. Run 'gt mail inbox' to read.",
        })
        → writes {townRoot}/.runtime/nudge_queue/gt-gastown-Toast/{nano}-{rand}.json

4. Message now in Dolt DB at {townRoot}/.beads
   Status: open
   Assignee: gastown/Toast
   Labels: gt:message, from:gastown/sender, delivery:pending, thread:..., ...

5. On recipient's next hook call:
   gt mail check --inject [called from UserPromptSubmit hook]

6. runMailCheck() [mail_check.go:16]
   a. address = detectSender() → "gastown/Toast"
   b. workDir = findMailWorkDir()
   c. router = NewRouter(workDir); mailbox = router.GetMailbox(address)
   d. mailbox.Count() → (1, 1, nil) — 1 total, 1 unread
   e. mailbox.ListUnread()
      → bd list --label gt:message --assignee gastown/Toast --json --limit 0
      → returns [BeadsMessage{...}]
      → ToMessage() → [Message{ID:"msg-abc", From:"gastown/sender", ...}]
   f. formatInjectOutput(messages) → prints to stdout:
      <system-reminder>
      You have 1 unread message(s) in your inbox.
      - msg-abc from gastown/sender: Fix this
      Continue your current task. When it completes, check these messages
      before going idle: 'gt mail inbox'
      </system-reminder>
   g. mailbox.AcknowledgeDeliveries("gastown/Toast", messages)
      → (concurrent, up to 8 goroutines)
      → bd show msg-abc --json → get existing labels
      → bd label add msg-abc delivery-acked-by:gastown/Toast
      → bd label add msg-abc delivery-acked-at:2026-02-28T12:00:01Z
      → bd label add msg-abc delivery:acked
   h. sessionName = tmux.CurrentSessionName() → "gt-gastown-Toast"
   i. nudge.Drain(workDir, "gt-gastown-Toast")
      → reads {townRoot}/.runtime/nudge_queue/gt-gastown-Toast/
      → atomically claims each .json file by rename to .claimed.<rand>
      → returns [QueuedNudge{Sender:"gastown/sender", Message:"📬 You have new mail..."}]
   j. nudge.FormatForInjection(nudges) → prints to stdout:
      <system-reminder>
      QUEUED NUDGE (1 message(s)):
        [from gastown/sender] 📬 You have new mail from gastown/sender...
      This is a background notification...
      </system-reminder>

7. Both <system-reminder> blocks are now in Claude's prompt context.
```

### Full Nudge Trace — All Three Modes

**Immediate mode (default):**

```
1. gt nudge gastown/Toast "Check your status" [--mode=immediate]

2. runNudge() [nudge.go:195]
   a. Validate mode, priority
   b. Parse "gastown/Toast" → rig="gastown", polecat="Toast"
   c. sender = detectSender() from GT_ROLE
   d. Check DND: shouldNudgeTarget(townRoot, "gastown/Toast", false)
      → GetAgentNotificationLevel(agentBeadID) → not muted
   e. crewSession = crewSessionName("gastown", "Toast") → "gt-crew-Toast"
   f. t.HasSession("gt-crew-Toast") → false (polecat, not crew)
   g. mgr.SessionName("Toast") → "gt-gastown-Toast"
   h. deliverNudge(t, "gt-gastown-Toast", "Check your status", "mayor/")
      switch immediate:
      → t.NudgeSession("gt-gastown-Toast", "[from mayor/] Check your status")
      → tmux send-keys -t gt-gastown-Toast "[from mayor/] Check your status" Enter
```

**Queue mode:**

```
1. gt nudge gastown/Toast "Check status" --mode=queue

2. runNudge()
   ... (same address resolution as above) ...
   h. deliverNudge(t, "gt-gastown-Toast", "Check status", "mayor/")
      switch queue:
      townRoot = workspace.FindFromCwd()
      nudge.Enqueue(townRoot, "gt-gastown-Toast", QueuedNudge{
          Sender:   "mayor/",
          Message:  "Check status",
          Priority: "normal",
      })
      → creates: {townRoot}/.runtime/nudge_queue/gt-gastown-Toast/
                 {UnixNano}-{rand}.json
      → file contents:
        {
          "sender": "mayor/",
          "message": "Check status",
          "priority": "normal",
          "timestamp": "2026-02-28T12:00:00Z",
          "expires_at": "2026-02-28T12:30:00Z"
        }

3. At next gt mail check --inject call:
   nudge.Drain("gt-gastown-Toast")
   → reads directory, renames .json to .claimed.<rand>
   → unmarshals QueuedNudge
   → checks ExpiresAt (30min TTL not exceeded)
   → returns [QueuedNudge{Sender:"mayor/", Message:"Check status"}]
   nudge.FormatForInjection(nudges) → prints <system-reminder> block
```

**Wait-idle mode:**

```
1. gt nudge gastown/Toast "Check status" --mode=wait-idle

2. runNudge()
   ... (address resolution) ...
   h. deliverNudge(t, "gt-gastown-Toast", "Check status", "mayor/")
      switch wait-idle:
      err = t.WaitForIdle("gt-gastown-Toast", 15s)
      IF err == nil (agent became idle within 15s):
          t.NudgeSession("gt-gastown-Toast", "[from mayor/] Check status")
          → tmux send-keys immediately
      IF err == ErrSessionNotFound or ErrNoServer:
          return error (session gone, no point queuing)
      IF err == timeout (agent still busy after 15s):
          nudge.Enqueue(townRoot, "gt-gastown-Toast", QueuedNudge{...})
          IF enqueue fails (queue full):
              print warning to stderr
              t.NudgeSession("gt-gastown-Toast", "[from mayor/] Check status")
              → immediate fallback
```

---

## Key File:Line References

| Concept | File | Lines |
|---------|------|-------|
| Message struct | `internal/mail/types.go` | 59–137 |
| BeadsMessage labels | `internal/mail/types.go` | 292–320 |
| Priority mapping | `internal/mail/types.go` | 486–524 |
| Address normalization | `internal/mail/types.go` | 548–607 |
| Mailbox (both modes) | `internal/mail/mailbox.go` | 31–77 |
| listFromDir (inbox query) | `internal/mail/mailbox.go` | 135–223 |
| AcknowledgeDeliveries | `internal/mail/mailbox.go` | 874–925 |
| bd subprocess wrapper | `internal/mail/bd.go` | 57–105 |
| Two-phase delivery | `internal/mail/delivery.go` | 1–161 |
| Address resolver | `internal/mail/resolve.go` | 62–100 |
| validateAgentAddress | `internal/mail/resolve.go` | 130–196 |
| Router.Send dispatch | `internal/mail/router.go` | ~840–870 |
| sendToSingle | `internal/mail/router.go` | ~1042–1120 |
| sendToQueue | `internal/mail/router.go` | ~1135–1190 |
| sendToChannel (fan-out) | `internal/mail/router.go` | ~1290–1370 |
| notifyRecipient | `internal/mail/router.go` | ~1522–1600 |
| AddressToSessionIDs | `internal/mail/router.go` | ~1650–1700 |
| Nudge queue Enqueue | `internal/nudge/queue.go` | 81–126 |
| Nudge queue Drain | `internal/nudge/queue.go` | 137–244 |
| FormatForInjection | `internal/nudge/queue.go` | 271–311 |
| deliverNudge (3 modes) | `internal/cmd/nudge.go` | 128–180 |
| mail check inject format | `internal/cmd/mail_check.go` | 113–174 |
| mail send flow | `internal/cmd/mail_send.go` | 20–226 |
| escalate routing | `internal/cmd/escalate_impl.go` | 98–130 |
| protocol type constants | `internal/protocol/types.go` | 22–47 |
| ParseMessageType | `internal/protocol/types.go` | 50–71 |
| HandlerRegistry | `internal/protocol/handlers.go` | 19–50 |
| WrapWitnessHandlers | `internal/protocol/handlers.go` | 84–112 |
| peek CapturePane | `internal/cmd/peek.go` | 51–122 |
| broadcast immediate | `internal/cmd/broadcast.go` | 104–137 |
| queue claim/release | `internal/cmd/mail_queue.go` | 23–445 |
