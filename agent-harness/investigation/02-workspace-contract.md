# Gas Town Workspace Contract

> Reflects upstream commit: `7a6c8189`

Investigation of the filesystem world every agent inhabits — the workspace contract.

---

## Architecture

The workspace is the foundational primitive of the Gas Town agent harness. Every piece
of agent identity, hook delivery, beads routing, mail addressing, and session lifecycle
derives from a single fact: **the agent's current working directory**.

A Gas Town workspace ("town") is a directory tree rooted at the directory that contains
`mayor/town.json`. Every agent runs with its cwd set to a subdirectory of that tree. The
path from the town root to the agent's cwd encodes its role, its rig affiliation, and its
individual name — without any external registry or environment variable being required.

The workspace is not a configuration file. It is a *directory layout*, and the layout
is the specification.

### Town Root Layout

```
{town}/                          # e.g. ~/gt/
  mayor/                         # town-level coordinator home
    town.json                    # PRIMARY workspace marker
    rigs.json                    # rig registry
    accounts.json                # account/API key config
    quota.json                   # cost quota state
    rig/                         # full git clone (mayor's working repo)
  deacon/                        # town-level daemon home
    dogs/                        # dog (cross-rig worker) kennel
      {name}/                    # individual dog workspace
        .dog.json                # dog state file
        {rigname}/               # per-rig git worktree
  .beads/                        # town-level beads database (hq-* prefixed)
    routes.jsonl                 # prefix-to-path routing table
  .runtime/                      # gitignored runtime state
  state.json                     # town-level operational state
  {rig}/                         # e.g. gastown/, beads/, shippercrm/
    config.json                  # rig identity (name, git_url, beads.prefix)
    mayor/
      rig/                       # canonical git repo clone (source of truth)
        .beads/                  # rig-level beads DB (or redirect to mayor/rig/.beads)
        CLAUDE.md                # project-level context (checked in)
    .repo.git/                   # bare repo (shared object pool for worktrees)
    polecats/
      {name}/                    # polecat home dir (persistent identity)
        {rigname}/               # git worktree (ephemeral, replaced each spawn)
          .beads/
            redirect             # points to ../../.beads or ../../mayor/rig/.beads
            PRIME.md             # fallback context if SessionStart hook fails
    crew/
      .claude/
        settings.json            # shared settings for all crew in rig
      {name}/                    # crew workspace (full git clone, persistent)
        .beads/
          redirect               # points to ../../mayor/rig/.beads
          PRIME.md               # fallback context
        mail/                    # crew member's mail directory
        state.json               # crew lifecycle state
    witness/                     # witness home (no git worktree, state only)
    refinery/
      rig/                       # refinery git worktree
        .beads/
          redirect               # points to ../../.beads
    settings/
      config.json                # rig-level settings (namepool, hooks, etc.)
    .runtime/
      locks/                     # per-polecat/crew file locks
      session_id                 # persisted Claude session ID
    .claude/                     # rig-level settings directory
      settings.json              # hooks for rig-level agents (witness, refinery)
```

---

## Code Paths

### Workspace Resolution

**File**: `/home/krystian/gt/gastown/crew/sherlock/internal/workspace/find.go`

The entry point for workspace discovery is `Find(startDir string) (string, error)` at
`find.go:33`. It walks up the directory tree from `startDir`, looking for two markers:

- **Primary**: `mayor/town.json` — authoritative, causes immediate return (unless in a
  worktree path, see below).
- **Secondary**: `mayor/` directory — weaker signal, keeps walking upward.

The key subtlety is **worktree path detection** (`find.go:70-73`):

```go
func isInWorktreePath(path string) bool {
    sep := string(filepath.Separator)
    return strings.Contains(path, sep+"polecats"+sep) ||
           strings.Contains(path, sep+"crew"+sep)
}
```

When the cwd is inside `polecats/` or `crew/`, `Find` does **not** stop at the first
`mayor/town.json` it encounters (which might be the rig's `mayor/rig/` within the
worktree). It continues walking upward to find the **outermost** workspace — the actual
town root.

The fallback `GT_TOWN_ROOT` environment variable is used when `os.Getwd()` fails (e.g.,
because a polecat's worktree was deleted while the agent was still running):
`find.go:97-111`, `FindFromCwdOrError`.

**Exported functions**:
- `Find(startDir)` — core walk, returns `""` if not found
- `FindOrError(startDir)` — wraps with `ErrNotFound` sentinel
- `FindFromCwd()` — uses `os.Getwd()`
- `FindFromCwdOrError()` — fails hard, GT_TOWN_ROOT fallback
- `FindFromCwdWithFallback()` — returns `(townRoot, cwd, err)` for commands like `gt done`

### Role Detection from Path

**File**: `/home/krystian/gt/gastown/crew/sherlock/internal/cmd/role.go`

The `detectRole(cwd, townRoot string) RoleInfo` function at `role.go:242` implements
the canonical path-to-role mapping. It computes `relPath = filepath.Rel(townRoot, cwd)`,
splits on `/`, and pattern-matches the segments:

```
relPath segments → Role
─────────────────────────────────────────────────────────────────
[mayor, ...]              → RoleMayor
[deacon, dogs, boot, ...] → RoleBoot
[deacon, dogs, {name}, …] → RoleDog  (ctx.Polecat = name)
[deacon, ...]             → RoleDeacon
[{rig}, mayor, ...]       → RoleMayor (per-rig mayor; rig stored in ctx.Rig)
[{rig}, witness, ...]     → RoleWitness
[{rig}, refinery, ...]    → RoleRefinery
[{rig}, polecats, {name}] → RolePolecat (ctx.Rig = rig, ctx.Polecat = name)
[{rig}, crew, {name}]     → RoleCrew   (ctx.Rig = rig, ctx.Polecat = name)
[.]                       → RoleUnknown (town root — neutral, no role)
```

`GetRoleWithContext(cwd, townRoot)` at `role.go:170` is the **authoritative** function.
It first checks `GT_ROLE` (and subsidiary `GT_RIG`, `GT_CREW`/`GT_POLECAT` env vars),
then fills gaps from cwd detection. If both sources agree, `Mismatch = false`. If they
disagree, `gt prime` emits a prominent warning (see `prime.go:303-318`).

Rig detection for shell integration uses `detectRigFromPath` in
`internal/cmd/rig_detect.go:84-108`. A directory is a rig if `{townRoot}/{candidate}/config.json`
exists and the candidate is not one of the reserved names: `mayor`, `deacon`, `.beads`,
`.claude`, `.git`, `plugins`.

### gt prime Path-Based Role Inference

**File**: `/home/krystian/gt/gastown/crew/sherlock/internal/cmd/prime.go`

`runPrime` at `prime.go:101` is the entry point for every agent startup. Its flow:

1. `resolvePrimeWorkspace()` (`prime.go:243`) calls `workspace.FindFromCwd()` to get
   `townRoot` and the current `cwd`.
2. `GetRoleWithContext(cwd, townRoot)` detects role from path and env.
3. `acquireIdentityLock(ctx)` (`prime.go:756-805`) — for crew and polecat only,
   acquires a file lock at `{workDir}/.runtime/agent.lock` to prevent two agents
   claiming the same identity.
4. `ensureBeadsRedirect(ctx)` (`prime.go:851-865`) — for crew, polecat, and refinery,
   checks that `.beads/redirect` exists; recreates it if missing.
5. `emitSessionEvent(ctx)` writes a session_start event to the events feed.
6. `outputRoleContext(ctx)` renders the role formula template as the startup context
   injected into the agent's context window.
7. `checkSlungWork(ctx)` looks up hooked/in-progress beads and emits AUTONOMOUS WORK MODE
   if work is found.
8. `runBdPrime(cwd)` runs `bd prime` in `cwd` to get beads workflow context.
9. `runMailCheckInject(cwd)` runs `gt mail check --inject` to inject pending mail.

The agent's identity string (used for bead assignee, hook lookup, and mail addressing)
is derived from path in `getAgentIdentity(ctx)` at `prime.go:734-754`:

```go
case RoleCrew:    return fmt.Sprintf("%s/crew/%s", ctx.Rig, ctx.Polecat)
case RolePolecat: return fmt.Sprintf("%s/polecats/%s", ctx.Rig, ctx.Polecat)
case RoleMayor:   return "mayor"
case RoleDeacon:  return "deacon"
case RoleWitness: return fmt.Sprintf("%s/witness", ctx.Rig)
case RoleRefinery:return fmt.Sprintf("%s/refinery", ctx.Rig)
```

### CLAUDE.md Hierarchy

Claude Code discovers `CLAUDE.md` files by walking from the cwd **upward** through the
directory tree. For a polecat at `{rig}/polecats/{name}/{rig}/`, Claude reads:

1. `{rig}/polecats/{name}/{rig}/CLAUDE.md` — project CLAUDE.md (checked into the repo)
2. `{rig}/polecats/{name}/CLAUDE.md` — does not exist (polecat home)
3. `{rig}/polecats/CLAUDE.md` — does not exist (not created)
4. `{rig}/CLAUDE.md` — does not exist for normal rigs
5. `{town}/CLAUDE.md` — town root identity anchor

The `CLAUDE.md` at `{town}/CLAUDE.md` (i.e. `/home/krystian/gt/CLAUDE.md`) is the
**town root identity anchor**. It tells agents to run `gt prime` for full context
rather than trying to infer identity from file contents.

**Note**: `crew/manager.go:296-298` explicitly states:
> We intentionally do NOT write to CLAUDE.md here. Gas Town context is injected
> ephemerally via SessionStart hook (gt prime). Writing to CLAUDE.md would overwrite
> project instructions and leak Gas Town internals into the project repo when workers
> commit/push.

The `PRIME.md` file in `.beads/` is a **fallback** context file, not a CLAUDE.md. It
provides GUPP (Gas Town Universal Propulsion Principle) if the SessionStart hook fails.

### Settings.json Merge Across Directory Levels

**File**: `/home/krystian/gt/gastown/crew/sherlock/internal/hooks/merge.go`
**File**: `/home/krystian/gt/gastown/crew/sherlock/internal/hooks/config.go`

Claude Code merges `.claude/settings.json` files hierarchically as it walks up the
directory tree. Gas Town exploits this to install settings at **container** directories
rather than inside individual worktrees.

Settings are installed at the following locations (discovered by `DiscoverTargets` at
`config.go:382`):

```
{town}/mayor/.claude/settings.json      → target key "mayor"
{town}/deacon/.claude/settings.json     → target key "deacon"
{rig}/crew/.claude/settings.json        → target key "{rig}/crew"
{rig}/polecats/.claude/settings.json    → target key "{rig}/polecats"
{rig}/witness/.claude/settings.json     → target key "{rig}/witness"
{rig}/refinery/.claude/settings.json    → target key "{rig}/refinery"
```

When Claude Code launches inside `{rig}/crew/{name}/` (a subdirectory of `crew/`), it
picks up `{rig}/crew/.claude/settings.json` by directory traversal — no per-worker copy
is required.

Hook computation uses `ComputeExpected(target)` at `config.go:345`:
1. Load base config from `~/.gt/hooks-base.json` (falls back to `DefaultBase()`)
2. Merge `DefaultBase()` under any on-disk base
3. For target `"gastown/crew"`, `GetApplicableOverrides` returns `["crew", "gastown/crew"]`
4. Apply built-in defaults for each key, then on-disk overrides layer on top

The merge rule (`merge.go:89-130`):
- Same matcher: override **replaces** base entirely
- Different matcher: both are **included**
- Override with empty hooks list: **removes** that hook (explicit disable)

The resulting merged config is written to the container's `.claude/settings.json`.

The standard hook set wired into every agent workspace includes:
- `SessionStart`: `gt prime --hook` (injects role context into context window)
- `PreCompact`: `gt prime --hook` (for polecats/crew) or `gt handoff --cycle` (for crew)
- `Stop`: `gt costs record`
- `UserPromptSubmit`: `gt mail check --inject`
- `PreToolUse`: `gt tap guard pr-workflow` (and optionally dangerous-command guards)

### Beads Database Access (Prefix Routing)

**File**: `/home/krystian/gt/gastown/crew/sherlock/internal/beads/routes.go`
**File**: `/home/krystian/gt/gastown/crew/sherlock/internal/beads/beads_redirect.go`

Beads routing is prefix-based. The town-level routing table lives at
`{town}/.beads/routes.jsonl`. Each line is a JSON object:

```json
{"prefix": "gt-", "path": "gastown/mayor/rig"}
{"prefix": "hq-", "path": "."}
```

The `path` field is relative to the town root. `path = "."` means town-level beads
(for `hq-*` prefixed issues like mayor/deacon agent beads).

`GetPrefixForRig(townRoot, rigName)` at `routes.go:176` resolves a rig name to its
beads prefix by scanning `routes.jsonl` for a route whose path starts with `rigName`.

`ResolveHookDir(townRoot, beadID, hookWorkDir)` at `routes.go:290` is the critical
function for locating the rig directory to run `bd update` in. It extracts the prefix
from the bead ID, then finds the path from routes.

Within a worktree, the **redirect** file at `{worktree}/.beads/redirect` points to the
actual beads database. `ResolveBeadsDir(workDir)` at `beads_redirect.go:25` reads this
file and resolves the relative path against the worktree root (not the `.beads` directory).

For `{rig}/crew/{name}/`:
```
.beads/redirect → "../../mayor/rig/.beads"
```

The redirect supports chains up to depth 3. Circular redirects are detected and the
errant file is removed.

`SetupRedirect(townRoot, worktreePath)` at `beads_redirect.go:268` is called during
workspace creation to establish this redirect. It uses `ComputeRedirectTarget` which
knows the depth of the worktree path and computes the correct `../` prefix.

### Mail Address Derivation from Path

**File**: `/home/krystian/gt/gastown/crew/sherlock/internal/mail/resolve.go`
**File**: `/home/krystian/gt/gastown/crew/sherlock/internal/session/identity.go`

Mail addresses are slash-separated path-like strings mirroring the filesystem layout:

```
mayor                        → mayor/
deacon                       → deacon/
{rig}/witness                → {rig}/witness
{rig}/refinery               → {rig}/refinery
{rig}/polecats/{name}        → {rig}/polecats/{name}
{rig}/crew/{name}            → {rig}/crew/{name}
deacon/dogs/{name}           → dog/{name}
```

`AgentIdentity.Address()` at `identity.go:237` produces the canonical address.
`ParseAddress(address)` at `identity.go:31` parses it back.

The `Resolver.validateAgentAddress(address)` at `resolve.go:130` validates a mail
address by checking:
1. Well-known singletons (mayor, deacon, overseer)
2. Well-known rig-level singletons (witness, refinery)
3. Agent beads in the beads database
4. **Workspace directory existence** at `{townRoot}/{rig}/{role}/{name}`

This last check means the mail system validates addresses against the filesystem layout —
the address `gastown/crew/sherlock` is valid if and only if the directory
`{town}/gastown/crew/sherlock/` exists.

### BD_ACTOR / Agent Identity

The beads `BD_ACTOR` identity (used for bead attribution) derives from the role path.
`RoleInfo.ActorString()` at `role.go:394-425` computes it:

```
mayor                → "mayor"
deacon               → "deacon"
{rig}/witness        → "{rig}/witness"
{rig}/refinery       → "{rig}/refinery"
{rig}/polecats/{name}→ "{rig}/polecats/{name}"
{rig}/crew/{name}    → "{rig}/crew/{name}"
boot                 → "deacon-boot"
```

The agent bead ID is a hyphen-separated variant: `{prefix}-{rig}-{role}-{name}`
(e.g., `gt-gastown-polecat-Toast`, `gt-gastown-crew-sherlock`). The prefix comes from
the rig's configured beads prefix in `config.json` (field `beads.prefix`).

---

## State

These are the files a harness-managed workspace may contain, grouped by lifecycle:

### Workspace Markers

| File | Location | Purpose |
|------|----------|---------|
| `mayor/town.json` | `{town}/` | Primary workspace marker. Contains `name`, `owner`, `public_name`. |
| `config.json` | `{rig}/` | Rig marker and identity. Contains `name`, `git_url`, `default_branch`, `beads.prefix`. |

### Runtime State (gitignored)

| File | Location | Purpose |
|------|----------|---------|
| `.runtime/agent.lock` | `{worktree}/` | Identity lock for crew/polecat. Holds PID and session ID. |
| `.runtime/session_id` | `{worktree}/` | Persisted Claude session ID, written by `gt prime --hook`. |
| `.runtime/handoff_to_successor` | `{worktree}/` | Handoff marker. Cleared by `gt prime` on next startup. |
| `.runtime/locks/polecat-{name}.lock` | `{rig}/` | Per-polecat file lock for spawn/remove races. |
| `.runtime/locks/crew-{name}.lock` | `{rig}/` | Per-crew file lock for add/remove races. |
| `.runtime/overlay/` | `{rig}/` | Files to copy into new worktrees (e.g., `.env`). |
| `.runtime/setup-hooks/` | `{rig}/` | Scripts run during polecat/crew creation. |

### Beads

| File | Location | Purpose |
|------|----------|---------|
| `.beads/redirect` | `{worktree}/` | Relative path to the actual beads database (e.g., `../../mayor/rig/.beads`). |
| `.beads/PRIME.md` | `{worktree}/` | Fallback context if SessionStart hook fails. Contains GUPP. |
| `.beads/config.yaml` | `{rig-beads}/` | Beads database configuration (prefix, custom types). |
| `.beads/routes.jsonl` | `{town}/.beads/` | Prefix-to-path routing table for bead ID dispatch. |
| `.beads/dolt/` | `{rig}/mayor/rig/.beads/` | Dolt database directory (actual issue storage). |

### Settings

| File | Location | Purpose |
|------|----------|---------|
| `.claude/settings.json` | `{rig}/crew/` | Shared hooks for all crew in this rig. Delivered via `--settings` flag. |
| `.claude/settings.json` | `{rig}/polecats/` | Shared hooks for all polecats in this rig. |
| `.claude/settings.json` | `{rig}/witness/` | Hooks for witness. |
| `.claude/settings.json` | `{rig}/refinery/` | Hooks for refinery. |
| `.claude/settings.json` | `{town}/mayor/` | Hooks for mayor. |
| `.claude/settings.json` | `{town}/deacon/` | Hooks for deacon. |

### Crew Lifecycle State

| File | Location | Purpose |
|------|----------|---------|
| `state.json` | `{rig}/crew/{name}/` | Crew worker state (Name, Rig, Branch, CreatedAt, UpdatedAt). |
| `mail/` | `{rig}/crew/{name}/` | Mail directory for message delivery. |

### Dog Lifecycle State

| File | Location | Purpose |
|------|----------|---------|
| `.dog.json` | `{town}/deacon/dogs/{name}/` | Dog state (State: idle/working, Worktrees map, Work). |

### Town-Level State

| File | Location | Purpose |
|------|----------|---------|
| `state.json` | `{town}/` | Operational state (patrol_count, last_patrol, extraordinary_action). |
| `mayor/rigs.json` | `{town}/` | Rig registry. |
| `mayor/quota.json` | `{town}/` | Cost quota enforcement state. |

---

## Interfaces

### How Workspace Drives Identity

The filesystem path is the **single source of truth** for agent identity. Every
downstream system derives from it:

**GT_ROLE environment variable** is set by the harness at session creation time (via
`tmux -e GT_ROLE=...` flags), encoding the full identity like `crew` or `polecat`. The
`GT_RIG` and `GT_CREW`/`GT_POLECAT` env vars carry the rig and worker name. These are
generated in `config.AgentEnv()` during `Manager.Start()` before creating the tmux session.

When `GT_ROLE` is absent, `detectRole(cwd, townRoot)` at `role.go:242` reads the role
from the directory path.

The env vars are considered **authoritative** but the filesystem path is the **fallback
and validation** source. A mismatch triggers a warning but the env var wins.

### How Workspace Drives Config

Role definitions are loaded from embedded TOML files at
`internal/config/roles/{role}.toml`. The `work_dir` field specifies the template
for session creation:

```toml
# crew.toml
work_dir = "{town}/{rig}/crew/{name}"

# polecat.toml
work_dir = "{town}/{rig}/polecats/{name}"

# dog.toml
work_dir = "{town}/deacon/dogs/{name}"

# mayor.toml
work_dir = "{town}/mayor"

# deacon.toml
work_dir = "{town}"

# witness.toml
work_dir = "{town}/{rig}/witness"

# refinery.toml
work_dir = "{town}/{rig}/refinery/rig"
```

Roles can be overridden at the town level (`{town}/roles/{role}.toml`) or rig level
(`{rig}/roles/{role}.toml`), layered on top of built-in defaults.

### How Workspace Drives Hooks

Hooks are computed by `ComputeExpected(target)` where `target` is a role specifier like
`"gastown/crew"`. The function merges:

1. `DefaultBase()` — universal hooks (SessionStart: `gt prime --hook`, Stop: `gt costs record`, etc.)
2. Built-in role overrides from `DefaultOverrides()` — role-specific additions
3. On-disk base at `~/.gt/hooks-base.json`
4. On-disk role override at `~/.gt/hooks-overrides/{role}.json`
5. On-disk rig+role override at `~/.gt/hooks-overrides/{rig}__{role}.json`

The resulting config is installed to the container `.claude/settings.json` at the role's
parent directory (e.g., `{rig}/crew/.claude/settings.json` for all crew in a rig).
Claude Code discovers this by directory traversal from the agent's cwd.

### How Workspace Drives Addressing

Mail addressing is validated against the workspace. `Resolver.validateAgentAddress` falls
back to checking `os.Stat({townRoot}/{rig}/{role}/{name})`. A directory must exist for
the address to be valid. This means creating a new agent workspace is a prerequisite
for being able to send it mail.

### How Workspace Drives Beads Access

`bd` CLI commands run with `cwd = {worktree}`. The `bd` CLI reads `.beads/redirect` from
the cwd to find the actual database. The redirect chain resolves to the shared rig-level
database at `{rig}/mayor/rig/.beads/dolt/`.

Town-level bead IDs (prefixed `hq-`) route to `{town}/.beads/` via the routes table.
Rig-level bead IDs route to `{rig}/mayor/rig/` via the routes table.

---

## Control Flow

### Workspace Creation: Crew

**File**: `/home/krystian/gt/gastown/crew/sherlock/internal/crew/manager.go`

`Manager.addLocked(name, createBranch)` at `crew/manager.go:193`:

```
1. Validate name (no hyphens, dots, slashes — breaks agent ID parsing)
2. MkdirAll {rig}/crew/        (base dir)
3. git.Clone(rig.GitURL, {rig}/crew/{name}/)
   - Uses --reference {rig}/.repo.git if available (object reuse)
4. syncRemotesFromRig(crewPath)
   - Copy remotes from {rig}/mayor/rig to match origin/upstream config
   - Sync push URLs from config.json (rig.PushURL)
5. Optionally: git checkout -b crew/{name}
6. MkdirAll {rig}/crew/{name}/mail/
7. beads.SetupRedirect(townRoot, crewPath)
   - Writes .beads/redirect → "../../mayor/rig/.beads"
8. beads.ProvisionPrimeMDForWorktree(crewPath)
   - Writes .beads/PRIME.md with GUPP and startup protocol
9. rig.CopyOverlay({rig}/.runtime/overlay/, crewPath)
10. rig.EnsureGitignorePatterns(crewPath)
11. runtime.EnsureSettingsForRole({rig}/crew/, crewPath, "crew", runtimeConfig)
    - Writes {rig}/crew/.claude/settings.json
12. Save state.json with {Name, Rig, Branch, ClonePath, CreatedAt}
```

Session start (`Manager.Start`) additionally:
- Builds `claudeCmd` including prompt beacon
- Injects env vars via `tmux -e GT_ROLE=crew GT_RIG={rig} GT_CREW={name} ...`
- Creates tmux session with `NewSessionWithCommandAndEnv(sessionID, crewPath, claudeCmd, envVars)`

### Workspace Creation: Polecat

**File**: `/home/krystian/gt/gastown/crew/sherlock/internal/polecat/manager.go`

`Manager.AddWithOptions(name, opts)` at `polecat/manager.go:606`:

```
1. Acquire per-polecat file lock (.runtime/locks/polecat-{name}.lock)
2. MkdirAll {rig}/polecats/{name}/    (polecat home dir)
3. Remove .pending reservation marker
4. Determine repo base:
   - Prefer {rig}/.repo.git (bare repo)
   - Fall back to {rig}/mayor/rig
5. git fetch origin (update bare repo)
6. Determine startPoint: opts.BaseBranch or "origin/{defaultBranch}"
7. Validate startPoint ref exists
8. Build branch name: polecat/{name}/{issue}@{timestamp} or configured template
9. git worktree add -b {branchName} {rig}/polecats/{name}/{rigname}/ {startPoint}
   (clonePath = polecats/<name>/<rigname>/ — new structure for LLM ergonomics)
10. beads.SetupRedirect(townRoot, clonePath)
    - Writes .beads/redirect
11. beads.ProvisionPrimeMDForWorktree(clonePath)
    - Writes .beads/PRIME.md
12. rig.CopyOverlay({rig}/.runtime/overlay/, clonePath)
13. rig.EnsureGitignorePatterns(clonePath)
14. runtime.EnsureSettingsForRole({rig}/polecats/, clonePath, "polecat", runtimeConfig)
    - Writes {rig}/polecats/.claude/settings.json
15. rig.RunSetupHooks({rig}/.runtime/setup-hooks/, clonePath)
16. beads.CreateOrReopenAgentBead(agentID, agentID, {RoleType:"polecat", AgentState:"spawning", HookBead:opts.HookBead})
    - Retries with exponential backoff — failure is hard (polecat without bead is untrackable)
```

Unlike crew, polecats use a **git worktree** (not a full clone). Each spawn creates a
fresh branch from `origin/{default}`. The previous branch is abandoned (never pushed).

No `state.json` is written for polecats — state is derived entirely from the beads
database (`assignee`, `hook_bead`, `agent_state` fields of the agent bead).

### Workspace Creation: Dog

**File**: `/home/krystian/gt/gastown/crew/sherlock/internal/dog/manager.go`

`Manager.Add(name)` at `dog/manager.go:95`:

```
1. MkdirAll {town}/deacon/dogs/         (kennel)
2. MkdirAll {town}/deacon/dogs/{name}/  (dog home)
3. For each rig in rigsConfig.Rigs:
   a. Determine repo base (findRepoBase):
      - Prefer {rig}/.repo.git (bare repo)
      - Fall back to {rig}/mayor/rig
   b. Determine defaultBranch from {rig}/config.json
   c. Generate branch: dog/{name}-{rig}-{timestamp}
   d. git worktree add -b {branch} {town}/deacon/dogs/{name}/{rigname}/ origin/{defaultBranch}
   e. Record worktrees[rigName] = worktreePath
4. Save .dog.json with {Name, State:idle, Worktrees, CreatedAt}
```

Dogs are **multi-rig**: one worktree per configured rig within a single dog workspace.
Dog state uses `StateIdle` / `StateWorking` and is tracked in `.dog.json` rather than beads.

Dog sessions are started from the dog home dir `{town}/deacon/dogs/{name}/` with the
agent cwd set to that directory. The individual rig worktrees inside are accessed by
path for cross-rig operations.

---

## Key Invariants

1. **Path is identity**: Every agent identity, mail address, beads prefix lookup, and
   hook target key derives from the cwd relative to the town root. No separate registry
   is required.

2. **Settings at the container**: Settings.json files are installed at the parent
   directory of a role class (`crew/`, `polecats/`, `witness/`), not inside individual
   worktrees. Claude Code inherits them by directory traversal.

3. **CLAUDE.md is project space**: No Gas Town context is written to CLAUDE.md inside
   worktrees. Context is injected ephemerally via the SessionStart hook (`gt prime --hook`).
   The `.beads/PRIME.md` is a fallback, not a permanent file.

4. **Beads via redirect**: Worktrees never carry their own beads database. The `.beads/redirect`
   file points to the rig's shared database. This makes `git clean` and worktree recreation
   safe — state persists in the shared database.

5. **Worktree vs clone by role**:
   - Polecat: git worktree from bare repo (`.repo.git`), ephemeral branch per spawn
   - Crew: full git clone, persistent branch, survives across sessions
   - Dog: git worktree per rig, persistent across assignments
   - Mayor/Refinery/Witness: single fixed clone at `{role}/rig/`, no per-agent copies

6. **Town root is neutral**: The cwd `{town}/` itself returns `RoleUnknown`. Only
   subdirectories have roles. The mayor's home is `{town}/mayor/`, not `{town}/`.
