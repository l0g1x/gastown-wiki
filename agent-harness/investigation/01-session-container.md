# Session Container: tmux as the Universal Agent Process Container

> Reflects upstream commit: `ae11c53c`

Investigation of the Gas Town agent harness session container layer.

Source: `/home/krystian/gt/gastown/crew/sherlock/`

---

## Architecture

Every Gas Town AI agent runs as a persistent, detached tmux session. tmux is the universal container: it holds the process, owns the PTY, survives disconnects, and provides the keyboard-injection channel that makes agent communication possible. No other isolation mechanism (Docker, VMs, etc.) is used at the process level — each agent is simply a named tmux session running `claude --dangerously-skip-permissions` (or an equivalent agent binary) as its sole process.

### The Three-Layer Model

```
Role TOML config
    └─► start_command = "exec claude --dangerously-skip-permissions"
            │
            ▼
    config.BuildStartupCommand()
    (wraps with: exec env GT_ROLE=... GT_ROOT=... claude --dangerously-skip-permissions "beacon")
            │
            ▼
    tmux.NewSessionWithCommand(sessionID, workDir, command)
    (tmux new-session -d -s <id> -c <workDir>
     tmux respawn-pane -k -t <id> <command>)
            │
            ▼
    Running tmux session: hq-mayor, gt-witness, gt-crew-max, gt-furiosa, …
```

### Socket Model

The system uses a single named tmux socket for all Gas Town sessions. The socket name is initialized in `session.InitRegistry()` by calling `tmux.SetDefaultSocket("default")`. The constant `"default"` means Gas Town uses the standard default tmux server socket, not a private one. Multi-town isolation is achieved by running in separate containers/VMs rather than by per-town sockets, because town-level sessions (`hq-mayor`, `hq-deacon`) are globally unique names that would collide across towns on the same machine anyway.

The socket is stored as a package-level variable in `internal/tmux/tmux.go`:

```go
// internal/tmux/tmux.go:62
var defaultSocket string

// internal/tmux/tmux.go:66
func SetDefaultSocket(name string) { defaultSocket = name }
```

Every `Tmux` instance sends `-L <socketName>` with every tmux subprocess call. If `defaultSocket` is empty, the sentinel `"gt-no-town-socket"` is used to produce a clear error rather than silently hitting the wrong server.

```go
// internal/tmux/tmux.go:116
const noTownSocket = "gt-no-town-socket"
```

### Session Naming Convention

Session names are deterministic strings derived from the agent role and rig prefix. The rig prefix is the beads prefix (e.g., `"gt"` for gastown, `"bd"` for beads) read from `mayor/rigs.json`.

| Agent type | Session name pattern | Example |
|---|---|---|
| Mayor | `hq-mayor` | `hq-mayor` |
| Deacon | `hq-deacon` | `hq-deacon` |
| Boot watchdog | `hq-boot` | `hq-boot` |
| Overseer (human) | `hq-overseer` | `hq-overseer` |
| Witness | `{prefix}-witness` | `gt-witness` |
| Refinery | `{prefix}-refinery` | `gt-refinery` |
| Crew worker | `{prefix}-crew-{name}` | `gt-crew-max` |
| Polecat | `{prefix}-{name}` | `gt-furiosa` |

The `HQPrefix = "hq-"` constant marks town-level singleton agents. Rig-level agents use the rig's beads prefix. Session names are validated against `^[a-zA-Z0-9_-]+$` — no dots, colons, or spaces are allowed.

---

## Code Paths

### Session Creation Path

#### 1. Role TOML → `start_command`

Each role has a built-in TOML definition embedded in the binary:

```toml
# internal/config/roles/polecat.toml:13
[session]
pattern = "{prefix}-{name}"
work_dir = "{town}/{rig}/polecats/{name}"
start_command = "exec claude --dangerously-skip-permissions"
```

```toml
# internal/config/roles/crew.toml:9-13
[session]
pattern = "{prefix}-crew-{name}"
work_dir = "{town}/{rig}/crew/{name}"
start_command = "exec claude --dangerously-skip-permissions"
```

```toml
# internal/config/roles/mayor.toml:9-13
[session]
pattern = "hq-mayor"
work_dir = "{town}/mayor"
start_command = "exec claude --dangerously-skip-permissions"
```

All seven built-in roles (mayor, deacon, witness, refinery, crew, polecat, dog) use the same `start_command`. Role TOML is loaded via `config.LoadRoleDefinition()`:

```go
// internal/config/roles.go:136
func LoadRoleDefinition(townRoot, rigPath, roleName string) (*RoleDefinition, error)
```

Resolution order: built-in embedded TOML → town-level override (`<town>/roles/<role>.toml`) → rig-level override (`<rig>/roles/<role>.toml`). Only non-zero fields in overrides are applied.

The `start_command` field maps to:

```go
// internal/config/roles.go:60
type RoleSessionConfig struct {
    Pattern      string `toml:"pattern"`
    WorkDir      string `toml:"work_dir"`
    NeedsPreSync bool   `toml:"needs_pre_sync"`
    StartCommand string `toml:"start_command,omitempty"`
}
```

#### 2. `BuildAgentStartupCommand` assembles the full shell command

```go
// internal/config/loader.go:2107
func BuildAgentStartupCommand(role, rig, townRoot, rigPath, prompt string) string {
    envVars := AgentEnv(AgentEnvConfig{Role: role, Rig: rig, TownRoot: townRoot, Prompt: prompt})
    return BuildStartupCommand(envVars, rigPath, prompt)
}
```

`BuildStartupCommand` resolves the agent runtime config (`ResolveRoleAgentConfig`), builds the environment export map, and produces a command of this form:

```go
// internal/config/loader.go:1908
cmd = "exec env " + strings.Join(exports, " ") + " "
// then appends: claude --dangerously-skip-permissions "beacon"
```

The `exec env` prefix is critical: it replaces the shell with the agent process, making `pane_current_command` show `claude` (or `node`) directly rather than `bash`. This is what `WaitForCommand` uses to detect agent startup.

#### 3. `session.StartSession` — the central lifecycle function

```go
// internal/session/lifecycle.go:136
func StartSession(t *tmux.Tmux, cfg SessionConfig) (_ *StartResult, retErr error)
```

This is the universal session-start function used by all agent types. It performs 13 sequential steps:

1. Validate `SessionID`, `WorkDir`, `Role` are non-empty.
2. Resolve `RuntimeConfig` via `config.ResolveRoleAgentConfig(cfg.Role, cfg.TownRoot, cfg.RigPath)`.
3. Ensure settings/plugins exist: `runtime.EnsureSettingsForRole(...)`.
4. Build startup command (if `cfg.Command` is empty): calls `buildCommand()` → `config.BuildAgentStartupCommand()`.
5. Prepend `RuntimeConfigDir` env var and `ExtraEnv` into the command string.
6. Create tmux session: `t.NewSessionWithCommand(cfg.SessionID, cfg.WorkDir, command)`.
7. Optionally set `remain-on-exit = on`.
8. Set environment variables in the session table: `t.SetEnvironment(session, k, v)` for each key in `config.AgentEnv()` + `cfg.ExtraEnv`.
9. Apply theme: `t.ConfigureGasTownSession(...)`.
10. Optionally wait for agent: `t.WaitForCommand(session, shells, timeout)`.
11. Optionally set auto-respawn hook: `t.SetAutoRespawnHook(session)`.
12. Accept startup dialogs: `t.AcceptStartupDialogs(session)`.
13. Optionally wait for runtime ready: `t.WaitForRuntimeReady(session, runtimeConfig, timeout)`.
14. Optionally verify session survived: `t.HasSession(session)`.
15. Optionally track PID: `session.TrackSessionPID(townRoot, sessionID, t)`.

Reference: `internal/session/lifecycle.go:121-265`.

#### 4. `tmux.NewSessionWithCommand` — the two-step tmux invocation

```go
// internal/tmux/tmux.go:222
func (t *Tmux) NewSessionWithCommand(name, workDir, command string) error
```

Two-step creation to eliminate a race between command exit and `remain-on-exit` setup:

1. `tmux new-session -d -s <name> -c <workDir>` — create session with default shell.
2. `tmux set-option -wt <name> window-size latest` — allow auto-resize on client attach.
3. `tmux set-option -t <name> remain-on-exit on` — enable before command runs.
4. `tmux respawn-pane -k -t <name> <command>` — replace the shell with the actual command.
5. `checkSessionAfterCreate(name, command)` — brief health check (50ms delay, check `#{pane_dead}`).

The `respawn-pane -k` replaces the existing shell process with the agent command. This is why the session shows `claude` (or `node`) directly as `pane_current_command`.

#### 5. `NewSessionWithCommandAndEnv` — variant for environment isolation

```go
// internal/tmux/tmux.go:278
func (t *Tmux) NewSessionWithCommandAndEnv(name, workDir, command string, env map[string]string) error
```

Like `NewSessionWithCommand` but adds `-e KEY=VALUE` flags to the `new-session` call so the initial shell process (before `respawn-pane`) already has the correct environment. This prevents env leaks from parent mayor/polecat sessions.

---

### `gt crew start` / `gt sling` → Polecat Spawn Path

#### `gt sling` path:

```
gt sling <rig> <bead>
    │
    ▼
cmd/polecat_spawn.go:SpawnPolecatForSling()
    ├─ polecat.Manager.FindIdlePolecat() → reuse idle or AllocateName()
    ├─ polecat.Manager.AddWithOptions(name, addOpts) → creates git worktree
    └─ polecat.NewSessionManager(t, r).SessionName(name) → "gt-furiosa"

    [session start is deferred until after bead/hook attachment]

SpawnedPolecatInfo.StartSession()
    ├─ config.ResolveAccountConfigDir() → CLAUDE_CONFIG_DIR
    ├─ polecat.SessionManager.Start(name, opts)
    │       └─ session.StartSession(t, SessionConfig{...})  ← universal path
    └─ t.WaitForRuntimeReady(sessionName, runtimeConfig, 30s)
```

Reference: `internal/cmd/polecat_spawn.go:60-411`.

#### `gt crew start` path:

Goes through `cmd/crew_lifecycle.go` → `session.StartSession()` with `Role: "crew"`.

---

### `exec claude --dangerously-skip-permissions` Invocation

The final command sent to `tmux respawn-pane -k` looks like:

```
exec env GT_ROLE=gastown/polecats/Toast GT_ROOT=/home/user/gt GT_RIG=gastown GT_POLECAT=Toast BD_ACTOR=gastown/polecats/Toast GIT_AUTHOR_NAME=Toast GT_PROCESS_NAMES=node,claude CLAUDECODE= NODE_OPTIONS= ... claude --dangerously-skip-permissions "beacon text here"
```

The `exec` keyword replaces the shell with the `env` process, which in turn execs `claude`. The final process tree in the pane is simply `claude` (a Node.js process visible as `node` in process listings).

The `--dangerously-skip-permissions` flag suppresses Claude Code's interactive permission dialogs. The system also calls `AcceptStartupDialogs()` after startup to handle the workspace trust dialog and bypass permissions warning dialog that appear despite this flag.

Reference: `internal/config/roles/polecat.toml:13`, `internal/config/loader.go:1904-1915`.

---

## State

### What state is maintained and where

#### 1. tmux session state (in the tmux server)

- Session existence: queried via `tmux has-session -t =<name>`
- Session environment table: `tmux set-environment -t <session> KEY VALUE` / `tmux show-environment`
- Session metadata: creation timestamp (`session_created`), activity timestamp (`session_activity`), attached clients
- Pane state: `pane_current_command`, `pane_pid`, `pane_dead`, `pane_dead_status`, `pane_in_mode`
- Status bar configuration (theme, status-left, status-right, bindings)
- `remain-on-exit` setting
- `pane-died` hook (auto-respawn or crash logger)

#### 2. Environment variables stored in tmux session table

Set by `StartSession` via `t.SetEnvironment()`:

| Variable | Value | Purpose |
|---|---|---|
| `GT_ROLE` | `gastown/polecats/Toast` | Agent role/identity |
| `GT_RIG` | `gastown` | Rig name |
| `GT_POLECAT` | `Toast` | Polecat name |
| `GT_ROOT` | `/home/user/gt` | Town workspace root |
| `GT_AGENT` | `claude` | Agent binary name |
| `GT_PROCESS_NAMES` | `node,claude` | Process names for liveness detection |
| `GT_SESSION` | `gt-furiosa` | Session's own tmux name |
| `BD_ACTOR` | `gastown/polecats/Toast` | Beads actor identity |
| `GIT_AUTHOR_NAME` | `Toast` | Git commit author |
| `CLAUDE_CONFIG_DIR` | `/home/user/gt/.accounts/default` | Claude Code config dir |
| `CLAUDECODE` | `""` | Cleared to prevent nested-session errors |
| `NODE_OPTIONS` | `""` | Cleared to prevent debugger flag inheritance |
| `GIT_CEILING_DIRECTORIES` | `/home/user/gt` | Prevent git escaping town boundary |

`GT_PROCESS_NAMES` is the key variable for liveness detection. It is read by `t.resolveSessionProcessNames()` via `t.GetEnvironment(session, "GT_PROCESS_NAMES")` to determine which process names constitute a healthy agent.

Reference: `internal/session/lifecycle.go:194-208`, `internal/config/env.go:63-315`.

#### 3. PID tracking files

Stored at `<townRoot>/.runtime/pids/<sessionID>.pid`. Format: `<pid>|<start_time>`.

Written by `session.TrackSessionPID()` after session creation. Used by `KillTrackedPIDs()` during shutdown to catch orphaned processes that survived `KillSessionWithProcesses()`. The start time is stored to guard against PID reuse — if the PID has been recycled by a different process, the file is removed rather than killing the unrelated process.

Reference: `internal/session/pidtrack.go:44-76`.

#### 4. Prefix registry (in-process)

`session.PrefixRegistry` is a package-level `defaultRegistry` that maps rig names to their beads prefixes. Populated from `mayor/rigs.json` at startup via `InitRegistry()`. Used to parse session names back to `AgentIdentity` and to enumerate sessions by rig.

Reference: `internal/session/registry.go:92-202`.

#### 5. Session nudge locks (in-process)

```go
// internal/tmux/tmux.go:29
var sessionNudgeLocks sync.Map // map[string]chan struct{}
```

Per-session channel semaphores that serialize concurrent nudges to the same session. Prevents interleaving when multiple goroutines nudge the same agent simultaneously. Implemented as a `sync.Map` of buffered channels. Lock acquisition has a 30-second timeout to prevent permanent blockout if a nudge hangs.

Reference: `internal/tmux/tmux.go:24-35`.

---

## Interfaces

### How the session container connects to other harness layers

#### Input interface: `gt nudge` → `NudgeSession`

The primary inbound channel for sending messages to a running agent. Everything that needs to communicate with a Claude session goes through this:

```
gt nudge <target> <message>
    │
    ▼
cmd/nudge.go:deliverNudge()
    ├─ immediate mode → t.NudgeSession(sessionName, message)
    ├─ queue mode → nudge.Enqueue() (agent drains via hook)
    └─ wait-idle mode → t.WaitForIdle() then NudgeSession, else queue
```

#### Output interface: `gt peek` → `CapturePane`

```
gt peek <rig/agent> [n]
    │
    ▼
cmd/peek.go:runPeek()
    └─ t.CapturePane(sessionID, lines)
       → tmux capture-pane -p -t <session> -S -<lines>
```

#### Lifecycle interface: `session.StartSession`

All agent-launching code (sling, crew start, mayor start, deacon start, witness patrol) calls `session.StartSession()`. It is the single entry point for creating agent sessions.

#### Health interface: `tmux.IsAgentAlive`, `CheckSessionHealth`

Used by the daemon patrol loop, witness patrol, and `gt agents check`:

```go
// internal/tmux/tmux.go:2043
func (t *Tmux) IsAgentAlive(session string) bool
    → t.IsRuntimeRunning(session, t.resolveSessionProcessNames(session))
    → reads GT_PROCESS_NAMES from session table
    → checks pane_current_command + process tree

// internal/tmux/tmux.go:1678
func (t *Tmux) CheckSessionHealth(session string, maxInactivity time.Duration) ZombieStatus
    → SessionHealthy | SessionDead | AgentDead | AgentHung
```

#### Discovery interface: `ListSessions`, `GetSessionSet`

```go
// internal/tmux/tmux.go:854
func (t *Tmux) ListSessions() ([]string, error)
    → tmux list-sessions -F #{session_name}

// internal/tmux/tmux.go:893
func (t *Tmux) GetSessionSet() (*SessionSet, error)
    → bulk O(1) existence checks
```

Used by `gt agents` enumeration, stale session detection, and the daemon.

#### Stop interface: `KillSessionWithProcesses`, `StopSession`

```go
// internal/tmux/tmux.go:478
func (t *Tmux) KillSessionWithProcesses(name string) error

// internal/session/lifecycle.go:271
func StopSession(t *tmux.Tmux, sessionID string, graceful bool) error
```

---

## Control Flow

### 1. Session Creation: Step-by-step trace

Scenario: `gt sling gastown gt-abc12` allocates polecat "Toast" for rig "gastown".

```
1. cmd/sling.go:runSling()
   └─ polecat_spawn.go:SpawnPolecatForSling("gastown", opts)
      ├─ polecat.Manager.AllocateName()          → "Toast"
      ├─ polecat.Manager.AddWithOptions("Toast") → creates git worktree at
      │   gastown/polecats/Toast/
      └─ returns SpawnedPolecatInfo{SessionName: "gt-furiosa", Pane: ""}

2. cmd/sling.go attaches hook bead, then calls:
   SpawnedPolecatInfo.StartSession()
   │
   ├─ config.ResolveAccountConfigDir() → claudeConfigDir = "~/.gt/.accounts/default"
   ├─ polecat.SessionManager.Start("Toast", {RuntimeConfigDir: claudeConfigDir})
   │   └─ session.StartSession(t, SessionConfig{
   │          SessionID: "gt-furiosa",
   │          WorkDir:   "~/gt/gastown/polecats/Toast",
   │          Role:      "polecat",
   │          TownRoot:  "~/gt",
   │          RigPath:   "~/gt/gastown",
   │          RigName:   "gastown",
   │          AgentName: "Toast",
   │          WaitForAgent: true,
   │          AcceptBypass: true,
   │          ReadyDelay:   true,
   │          TrackPID:     true,
   │      })
   │
   │   Step 1: validate fields
   │   Step 2: runtimeConfig = config.ResolveRoleAgentConfig("polecat", "~/gt", "~/gt/gastown")
   │           → reads settings/agents.json, resolves agent binary = "claude"
   │   Step 3: runtime.EnsureSettingsForRole(settingsDir, workDir, "polecat", runtimeConfig)
   │   Step 4: command = config.BuildAgentStartupCommand("polecat", "gastown", "~/gt",
   │                          "~/gt/gastown", beacon)
   │           → "exec env GT_ROLE=gastown/polecats/Toast ... claude --dangerously-skip-permissions \"[GAS TOWN] ...\""
   │   Step 5: t.NewSessionWithCommand("gt-furiosa", "~/gt/gastown/polecats/Toast", command)
   │           a. tmux new-session -u -L default -d -s gt-furiosa -c ~/gt/gastown/polecats/Toast
   │           b. tmux set-option -wt gt-furiosa window-size latest
   │           c. tmux set-option -t gt-furiosa remain-on-exit on
   │           d. tmux respawn-pane -k -t gt-furiosa
   │                  "exec env GT_ROLE=... claude --dangerously-skip-permissions \"beacon\""
   │           e. sleep 50ms, check #{pane_dead} → if dead with nonzero exit, kill + error
   │           f. tmux set-option -t gt-furiosa remain-on-exit off  (if pane still alive)
   │   Step 6: t.SetEnvironment("gt-furiosa", "GT_ROLE", "gastown/polecats/Toast")
   │           ... (all vars from AgentEnv)
   │   Step 7: t.ConfigureGasTownSession("gt-furiosa", theme, "gastown", "Toast", "polecat")
   │           → ApplyTheme, SetStatusFormat, SetDynamicStatus, key bindings, mouse mode
   │   Step 8: t.WaitForCommand("gt-furiosa", ["bash","zsh","sh",...], 30s)
   │           → polls until pane_current_command != shell
   │   Step 9: (no auto-respawn for polecats)
   │   Step 10: t.AcceptStartupDialogs("gt-furiosa")
   │            → AcceptWorkspaceTrustDialog (checks for "trust this folder")
   │            → AcceptBypassPermissionsWarning (checks for "Bypass Permissions mode")
   │   Step 11: t.WaitForRuntimeReady("gt-furiosa", runtimeConfig, 30s)
   │            → polls CapturePaneLines for "❯ " prompt prefix
   │   Step 12: t.HasSession("gt-furiosa") → verify still alive
   │   Step 13: session.TrackSessionPID("~/gt", "gt-furiosa", t)
   │            → t.GetPanePID("gt-furiosa") → reads #{pane_pid}
   │            → writes ~/gt/.runtime/pids/gt-furiosa.pid
   │
   └─ polecat.Manager.SetAgentStateWithRetry("Toast", "working")
```

### 2. Nudge Injection: Step-by-step trace

Scenario: `gt nudge gastown/Toast "Check your hook"` from within another agent.

```
1. cmd/nudge.go:runNudge()
   ├─ validate --mode and --priority flags
   ├─ identify sender from GT_ROLE env var → "gastown/crew/max" (example)
   ├─ target = "gastown/Toast" (contains "/") → parseAddress()
   │   → rigName = "gastown", polecatName = "Toast"
   ├─ try crewSession = "gt-crew-Toast" → t.HasSession() → false
   ├─ polecatMgr.SessionName("Toast") → "gt-furiosa"
   └─ deliverNudge(t, "gt-furiosa", "Check your hook", "gastown/crew/max")
       └─ NudgeModeImmediate (default)
           └─ t.NudgeSession("gt-furiosa", "[from gastown/crew/max] Check your hook")

2. tmux.NudgeSession("gt-furiosa", message)
   ├─ acquireNudgeLock("gt-furiosa", 30s)  → serialize concurrent nudges
   ├─ t.FindAgentPane("gt-furiosa")        → find pane running agent (multi-pane guard)
   ├─ check pane_in_mode → if in copy mode: send-keys -X cancel
   ├─ sanitizeNudgeMessage(message)        → strip ESC, CR, DEL; TAB→space
   ├─ sendMessageToTarget(target, sanitized, NudgeReadyTimeout)
   │   └─ if len <= 512: sendKeysLiteralWithRetry()
   │       └─ tmux send-keys -u -L default -t gt-furiosa -l "<message>"
   │          (retries with 1.5x backoff on "not in a mode" error)
   ├─ time.Sleep(500ms)         ← wait for paste completion
   ├─ tmux send-keys -t gt-furiosa Escape  ← exit vim INSERT mode
   ├─ time.Sleep(600ms)         ← exceed bash keyseq-timeout so ESC is processed alone
   ├─ tmux send-keys -t gt-furiosa Enter   ← submit (3 retries)
   ├─ t.WakePaneIfDetached("gt-furiosa")
   │   → if not attached: resize-window ±1 (triggers SIGWINCH to wake Claude's event loop)
   └─ releaseNudgeLock("gt-furiosa")
```

The 500ms + 600ms total 1.1 second delay per nudge is required:
- 500ms: paste must complete before ESC is sent
- 600ms: must exceed bash readline's `keyseq-timeout` (default 500ms) so ESC+Enter is not interpreted as Meta-Enter

### 3. Session Discovery: Step-by-step trace

Scenario: `gt agents` lists all running agent sessions.

```
1. cmd/agents.go:runAgentsList()
   └─ getAgentSessions(includePolecats=false)
       ├─ t := tmux.NewTmux()
       ├─ sessions, _ := t.ListSessions()
       │   → tmux list-sessions -F #{session_name}
       │   → returns ["hq-mayor", "hq-deacon", "gt-witness", "gt-crew-max", "gt-furiosa"]
       └─ filterAndSortSessions(sessions, false)
           ├─ for each name: categorizeSession(name)
           │   └─ session.ParseSessionName(name)
           │       ├─ "hq-mayor" → {Role: RoleMayor}
           │       ├─ "hq-deacon" → {Role: RoleDeacon}
           │       ├─ "gt-witness" → matchPrefix("gt-witness") → prefix="gt"
           │       │   rest="witness" → {Role: RoleWitness, Rig: "gastown", Prefix: "gt"}
           │       ├─ "gt-crew-max" → rest="crew-max" → HasPrefix("crew-") → true
           │       │   → {Role: RoleCrew, Rig: "gastown", Name: "max"}
           │       └─ "gt-furiosa" → rest="furiosa" (not witness/refinery/crew-)
           │           → {Role: RolePolecat, Rig: "gastown", Name: "furiosa"}
           │           (excluded when includePolecats=false)
           └─ sort: mayor first, deacon second, then by rig, then by type order
```

#### `gt agents menu` additionally:

```
getAllSocketSessions(includePolecats)
├─ query town socket sessions (hq/gt agents)
├─ query "default" socket sessions (personal terminal sessions) if different from town socket
├─ scan /tmp/tmux-<uid>/ for gt-test-* sockets (integration test sessions)
└─ build tmux display-menu command with switch-client/cross-socket actions
   → invokes: tmux display-menu -T "..." -x C -y C -- <items>
```

### 4. Process Group Cleanup: What happens when Claude exits

#### Normal exit (Claude finishes a task and returns to the prompt):

The session continues running — the pane shows the Claude prompt again. The tmux session is still alive; only the agent process state changes. The witness patrol detects the idle state and may trigger re-assignment.

#### Crash exit (Claude process dies unexpectedly):

If `AutoRespawn: true` was set (used for deacon/boot), the `pane-died` hook fires:

```go
// internal/tmux/tmux.go:3068-3070
`run-shell -b "sleep 3 && tmux list-panes -t 'session' -F '##{pane_dead}' 2>/dev/null | grep -q 1 && tmux respawn-pane -k -t 'session' && tmux set-option -t 'session' remain-on-exit on || true"`
```

The hook:
1. Sleeps 3 seconds (debounce: lets the daemon restart it first if running)
2. Checks `#{pane_dead}` — if the daemon already restarted the session, the hook exits
3. If still dead: `respawn-pane -k` restarts the pane with its original command
4. Re-enables `remain-on-exit on` (respawn-pane resets it to off)

#### `KillSessionWithProcesses` — explicit termination:

```go
// internal/tmux/tmux.go:478
func (t *Tmux) KillSessionWithProcesses(name string) error
```

1. `t.GetPanePID(name)` → get pane's root PID
2. `getAllDescendants(pid)` → `pgrep -P <pid>` recursively (deepest-first)
3. `getProcessGroupID(pid)` → `ps -o pgid= -p <pid>`
4. `collectReparentedGroupMembers(pgid, knownPIDs)` → kill reparented processes only (PPID=1 filter)
5. `kill -TERM` all descendants → wait 2 seconds → `kill -KILL` any survivors
6. `kill -TERM <pid>` → wait 2 seconds → `kill -KILL <pid>`
7. `tmux kill-session -t <name>`

The 2-second grace period between SIGTERM and SIGKILL allows Claude Code's Node.js process to flush writes and clean up.

---

## Session Naming in Detail

### `session.InitRegistry`

```go
// internal/session/registry.go:111
func InitRegistry(townRoot string) error {
    tmux.SetDefaultSocket("default")
    r, err := BuildPrefixRegistryFromTown(townRoot)
    SetDefaultRegistry(r)
    config.LoadAgentRegistry(config.DefaultAgentRegistryPath(townRoot))
}
```

`BuildPrefixRegistryFromTown` reads `mayor/rigs.json`:

```json
{
  "rigs": {
    "gastown": {"beads": {"prefix": "gt"}},
    "beads":   {"beads": {"prefix": "bd"}}
  }
}
```

This populates `defaultRegistry` with prefix↔rig mappings. Every session name parse thereafter uses this registry to resolve `"gt-crew-max"` → `{Rig: "gastown", Role: RoleCrew, Name: "max"}`.

### `ParseSessionName` algorithm

```go
// internal/session/identity.go:99
func ParseSessionName(session string) (*AgentIdentity, error)
```

1. If starts with `"hq-"`: check suffix for `"mayor"`, `"deacon"`, `"boot"`, `"overseer"`.
2. Otherwise: `registry.matchPrefix(session)` — tries all registered prefixes longest-first, looking for `<prefix>-<rest>`.
3. With prefix and rest: check `rest == "witness"`, `rest == "refinery"`, `strings.HasPrefix(rest, "crew-")`, or else polecat.

### `AgentIdentity.SessionName()` — reverse mapping

```go
// internal/session/identity.go:164
func (a *AgentIdentity) SessionName() string
```

Produces the canonical session name from an `AgentIdentity`. Routes to the appropriate constructor:

```go
session.PolecatSessionName(prefix, name)  // → "gt-furiosa"
session.CrewSessionName(prefix, name)     // → "gt-crew-max"
session.WitnessSessionName(prefix)        // → "gt-witness"
session.MayorSessionName()               // → "hq-mayor"
```

---

## Theme and Visual Identification

The theme layer provides visual role identification via the tmux status bar.

### Theme assignment

```go
// internal/tmux/theme.go:62
func AssignTheme(rigName string) Theme {
    return AssignThemeFromPalette(rigName, DefaultPalette)
}

func AssignThemeFromPalette(rigName string, palette []Theme) Theme {
    h := fnv.New32a()
    h.Write([]byte(rigName))
    idx := int(h.Sum32()) % len(palette)
    return palette[idx]
}
```

FNV-32a hash of the rig name picks a theme from `DefaultPalette` (10 colors: ocean, forest, rust, plum, slate, ember, midnight, wine, teal, copper). Same rig always gets the same color. Town-level agents have fixed themes:

- Mayor: `{BG: "#3d3200", FG: "#ffd700"}` — gold on dark
- Deacon: `{BG: "#2d1f3d", FG: "#c0b0d0"}` — silver on purple

### `ConfigureGasTownSession` — full theming

```go
// internal/tmux/tmux.go:2408
func (t *Tmux) ConfigureGasTownSession(session string, theme Theme, rig, worker, role string) error
```

Sets:
- `status-style bg=<hex>,fg=<hex>` — background/foreground colors
- `status-left-length 25`, `status-left "<icon> <session>"` — role icon + session name
- `status-right` — dynamic: `#(gt status-line --session=<s> 2>/dev/null) %H:%M` (called every 5s)
- Key bindings: `C-b a` (feed), `C-b g` (agents menu), `C-b n/p` (cycle), mouse click on status-right (mail peek)
- Mouse mode and clipboard integration

All key bindings are conditional — they fire only when `session_name` matches the GT prefix pattern, preserving user bindings in personal sessions.

### Status-left identity format

```go
// internal/tmux/tmux.go:2365-2382
// Mayor: "🎩 Mayor "
// Polecat: "😺 gt-furiosa "  (shows tmux session name)
// Crew:   "👷 gt-crew-max "
```

Role icons: `🎩` mayor, `📯` deacon, `🔭` witness, `⚗️` refinery, `👷` crew, `😺` polecat.

---

## Additional Mechanisms

### `WaitForIdle` — idle detection for `--mode=wait-idle`

```go
// internal/tmux/tmux.go:2207
func (t *Tmux) WaitForIdle(session string, timeout time.Duration) error
```

Polls `CapturePaneLines(session, 5)` every 200ms looking for `"❯ "` (the Claude Code prompt character U+276F + space, with NBSP normalization). Returns `ErrIdleTimeout` if the agent is still busy after the timeout.

### `IsIdle` — busy detection via status bar

```go
// internal/tmux/tmux.go:2272
func (t *Tmux) IsIdle(session string) bool
```

Checks the Claude Code status bar (lines containing `⏵⏵`) for `"esc to interrupt"`. If present → busy. If absent → idle. This is a point-in-time snapshot, not a poll.

### `WakePaneIfDetached` — SIGWINCH injection

```go
// internal/tmux/tmux.go:1132
func (t *Tmux) WakePaneIfDetached(target string)
```

When Claude runs in a detached session, its TUI may not process stdin until a terminal resize event occurs. The wake sequence: `resize-window -x <w+1>`, sleep 50ms, `resize-window -x <w>`, then reset `window-size` to `"latest"`. This triggers SIGWINCH which wakes Claude's event loop. Called after every successful `NudgeSession`.

### Session staleness detection

```go
// internal/session/stale.go
func SessionCreatedAt(sessionName string) (time.Time, error)
func StaleReasonForTimes(messageTime, sessionCreated time.Time) (bool, string)
```

A message is stale if its timestamp is before the session's creation time. Used to suppress old messages when a session restarts (e.g., after compaction).

### `--if-fresh` nudge guard

```go
// internal/cmd/nudge.go:213-225
if nudgeIfFreshFlag {
    sessionName := tmux.CurrentSessionName()
    created, _ := t.GetSessionCreatedUnix(sessionName)
    age := time.Since(time.Unix(created, 0))
    if age > 60s { return nil }  // suppress: old session (compaction/clear)
}
```

Prevents `SessionStart` hooks in compacted/cleared sessions from spamming the deacon with stale "I'm alive" notifications.

---

## Summary: Key File/Line References

| Concern | File | Key Lines |
|---|---|---|
| tmux session creation | `internal/tmux/tmux.go` | 222-266 (NewSessionWithCommand), 278-331 (WithEnv) |
| Two-step create + respawn | `internal/tmux/tmux.go` | 239-265 |
| Socket model | `internal/tmux/tmux.go` | 60-135 |
| NudgeSession implementation | `internal/tmux/tmux.go` | 1279-1338 |
| Nudge serialization locks | `internal/tmux/tmux.go` | 24-35, 1053-1082 |
| CapturePane (peek) | `internal/tmux/tmux.go` | 1811-1814 |
| WaitForCommand | `internal/tmux/tmux.go` | 2069-2098 |
| WaitForRuntimeReady | `internal/tmux/tmux.go` | 2160-2194 |
| IsAgentAlive | `internal/tmux/tmux.go` | 2039-2058 |
| KillSessionWithProcesses | `internal/tmux/tmux.go` | 461-540 |
| SetAutoRespawnHook | `internal/tmux/tmux.go` | 2988-3034 |
| buildAutoRespawnHookCmd | `internal/tmux/tmux.go` | 3054-3071 |
| ConfigureGasTownSession | `internal/tmux/tmux.go` | 2407-2435 |
| Theme assignment | `internal/tmux/theme.go` | 62-75 |
| Theme palette | `internal/tmux/theme.go` | 18-29 |
| Process group (Unix) | `internal/tmux/process_group_unix.go` | 1-57 |
| StartSession (lifecycle) | `internal/session/lifecycle.go` | 136-265 |
| StopSession | `internal/session/lifecycle.go` | 267-290 |
| Session naming functions | `internal/session/names.go` | 1-62 |
| ParseSessionName | `internal/session/identity.go` | 99-161 |
| AgentIdentity.SessionName | `internal/session/identity.go` | 164-186 |
| InitRegistry | `internal/session/registry.go` | 111-135 |
| PrefixRegistry | `internal/session/registry.go` | 20-275 |
| PID tracking | `internal/session/pidtrack.go` | 44-189 |
| Stale detection | `internal/session/stale.go` | 1-46 |
| TownSessions shutdown order | `internal/session/town.go` | 22-28 |
| WaitForSessionExit | `internal/session/town.go` | 84-94 |
| ListSessions / GetSessionSet | `internal/tmux/tmux.go` | 853-946 |
| gt agents enumeration | `internal/cmd/agents.go` | 184-360 |
| gt peek implementation | `internal/cmd/peek.go` | 51-122 |
| gt nudge implementation | `internal/cmd/nudge.go` | 124-431 |
| deliverNudge routing | `internal/cmd/nudge.go` | 128-180 |
| SpawnPolecatForSling | `internal/cmd/polecat_spawn.go` | 60-302 |
| SpawnedPolecatInfo.StartSession | `internal/cmd/polecat_spawn.go` | 304-411 |
| BuildAgentStartupCommand | `internal/config/loader.go` | 2107-2115 |
| BuildStartupCommand | `internal/config/loader.go` | 1823-1919 |
| AgentEnv (env vars) | `internal/config/env.go` | 63-316 |
| LoadRoleDefinition | `internal/config/roles.go` | 128-171 |
| Role TOML (polecat) | `internal/config/roles/polecat.toml` | 1-22 |
| Role TOML (crew) | `internal/config/roles/crew.toml` | 1-23 |
| Role TOML (mayor) | `internal/config/roles/mayor.toml` | 1-23 |
