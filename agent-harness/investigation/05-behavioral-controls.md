# Gas Town Behavioral Controls

> Reflects upstream commit: `ae11c53c`

## Overview

The Gas Town behavioral controls layer intercepts Claude Code's execution at well-defined
hook points and either constrains what the agent may do (guards, blocking on exit 2) or
enriches what the agent sees (context injection, mail delivery). The system is centrally
managed through a three-tier merge hierarchy: binary-compiled defaults, user-editable base
config, and per-role/per-rig overrides. All configuration lands in `.claude/settings.json`
files that Claude Code reads via the `--settings` flag at startup.

---

## 1. Hook Event Types

Gas Town uses eight Claude Code hook event types. They are declared as the canonical ordered
list in `EventTypes` at:

```
internal/hooks/config.go:483
var EventTypes = []string{"PreToolUse", "PostToolUse", "SessionStart", "Stop", "PreCompact", "UserPromptSubmit", "WorktreeCreate", "WorktreeRemove"}
```

### 1.1 PreToolUse

Fires **before** any tool call. The hook command receives a JSON payload on stdin:

```json
{"tool_name": "Bash", "tool_input": {"command": "..."}}
```

Exit code 2 blocks the tool entirely. Exit 0 allows it.

Gas Town uses this event exclusively for guards — commands that check the intent of the
upcoming tool call and either allow or block it. The matcher pattern (`Bash(gh pr create*)`)
controls which tool invocations trigger each hook.

### 1.2 PostToolUse

Fires **after** a tool call completes. Gas Town defines this event type in the schema but
no built-in hooks use it. The `gt tap` docs describe it as a future "audit" or "check" slot.

### 1.3 SessionStart

Fires once when a Claude Code session begins. Gas Town uses it to:

1. Inject session identity (`gt prime --hook`) — reads session UUID from stdin JSON, persists
   it to disk, and outputs the full role-context prompt that becomes the agent's system
   context for the session.

Autonomous roles (polecat, witness, refinery, deacon, boot) additionally inject mail in the
same `SessionStart` hook because they may be triggered externally without a user prompt:

```
settings-autonomous.json SessionStart command:
  export PATH="$HOME/go/bin:$HOME/bin:$PATH" && gt prime --hook && gt mail check --inject
```

Interactive roles (mayor, crew) split `SessionStart` and mail delivery: `SessionStart` runs
`gt prime --hook` only, and `UserPromptSubmit` handles mail injection on each user turn.

### 1.4 Stop

Fires at every **turn boundary** — when the agent would go idle. Gas Town installs two
different Stop hooks depending on configuration:

- **All roles (DefaultBase)**: `gt costs record` — reads the session's token usage from
  `~/.claude/projects/` transcript files, calculates cost, and appends a record to
  `~/.gt/costs.jsonl`.
- **Planned extension**: `gt signal stop` — a more sophisticated Stop handler that checks
  for unread mail and slung work, blocking the turn with `{"decision":"block","reason":"..."}``
  to prevent idle when work is queued. (This handler exists and is documented, but is not
  wired as a default in `DefaultBase()`; it appears in the `gt signal` command docs.)

The Stop hook **never** blocks the agent by default. It records cost silently.

### 1.5 PreCompact

Fires before Claude Code compacts the context window. Gas Town diverges sharply here between
roles:

- **Base/all roles**: `gt prime --hook` — re-injects role context after compaction so the
  agent retains identity in the compacted memory.
- **Crew workers** (override): `gt handoff --cycle --reason compaction` — instead of
  compacting (which degrades quality), replaces the entire session with a fresh Claude
  instance. The new session inherits work state via the handoff mail mechanism. This is the
  auto-session-cycling design from `gt-op78`.

### 1.6 UserPromptSubmit

Fires before each user prompt is submitted to the model. Used by Gas Town to deliver mail:

```
gt mail check --inject
```

When unread messages exist, `--inject` emits `<system-reminder>` blocks that Claude Code
prepends to the context. Priority tiering controls urgency framing:

- **urgent**: Agent is instructed to stop and read immediately.
- **high**: Agent is instructed to process at the next task boundary.
- **normal/low**: Informational; process before going idle.

Queued nudges (from `gt nudge --mode=queue`) are also drained and injected here.

### 1.7 WorktreeCreate / WorktreeRemove

Declared in the schema and in `EventTypes` but **no default commands are installed** for
either. They are reserved for future worktree-level lifecycle management. The `gt tap`
documentation lists "inject" and "check" as planned categories that would use these events.

---

## 2. Commands Invoked by Each Hook

| Event | Matcher | Command | Purpose |
|---|---|---|---|
| PreToolUse | `Bash(gh pr create*)` | `gt tap guard pr-workflow` | Block PR creation |
| PreToolUse | `Bash(git checkout -b*)` | `gt tap guard pr-workflow` | Block feature branches |
| PreToolUse | `Bash(git switch -c*)` | `gt tap guard pr-workflow` | Block feature branches |
| PreToolUse | `Bash(rm -rf /*)` | `gt tap guard dangerous-command` | Block destructive rm |
| PreToolUse | `Bash(git push --force*)` | `gt tap guard dangerous-command` | Block force push |
| PreToolUse | `Bash(git push -f*)` | `gt tap guard dangerous-command` | Block force push |
| PreToolUse | `Bash(*bd mol pour*patrol*)` | inline echo + exit 2 | Block patrol mol pour |
| PreToolUse | `Bash(*bd mol pour *mol-witness*)` | inline echo + exit 2 | Block witness mol pour |
| PreToolUse | `Bash(*bd mol pour *mol-deacon*)` | inline echo + exit 2 | Block deacon mol pour |
| PreToolUse | `Bash(*bd mol pour *mol-refinery*)` | inline echo + exit 2 | Block refinery mol pour |
| SessionStart | `""` (all) | `gt prime --hook` | Role context injection |
| Stop | `""` (all) | `gt costs record` | Record session cost |
| PreCompact | `""` (all) | `gt prime --hook` (base) OR `gt handoff --cycle --reason compaction` (crew) | Context re-injection or session cycling |
| UserPromptSubmit | `""` (all) | `gt mail check --inject` | Mail delivery |

All commands are prefixed with `export PATH="$HOME/go/bin:$HOME/.local/bin:$PATH" &&` to
ensure `gt` and `bd` binaries are on PATH regardless of the shell environment that Claude
Code inherits.

---

## 3. Hook Definition Schema in `.claude/settings.json`

The settings file schema is defined in `internal/hooks/config.go`. The structure is:

```json
{
  "editorMode": "normal",
  "enabledPlugins": {
    "beads@beads-marketplace": false
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash(gh pr create*)",
        "hooks": [
          {
            "type": "command",
            "command": "export PATH=\"$HOME/go/bin:$HOME/.local/bin:$PATH\" && gt tap guard pr-workflow"
          }
        ]
      }
    ],
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "export PATH=\"$HOME/go/bin:$HOME/.local/bin:$PATH\" && gt prime --hook"
          }
        ]
      }
    ]
  }
}
```

Key schema invariants enforced by Gas Town:
- `enabledPlugins["beads@beads-marketplace"]` is always set to `false` — the beads MCP
  plugin is disabled at the settings level in every managed settings file.
- The `hooks` key is always written (even if empty) — it is the "managed section".
- All other top-level fields (`editorMode`, `skipDangerousModePermissionPrompt`, unknown
  future keys) are preserved verbatim via the `Extra map[string]json.RawMessage` roundtrip
  mechanism (`UnmarshalSettings` / `MarshalSettings` at `config.go:73-134`).
- Matchers within each event type must be unique — `validateUniqueMatchers` enforces this
  at `config.go:844`.

Go types mapping to the schema:

```go
// config.go:17-38
type HookEntry struct {
    Matcher string `json:"matcher"`
    Hooks   []Hook `json:"hooks"`
}

type Hook struct {
    Type    string `json:"type"`    // always "command"
    Command string `json:"command"`
}

type HooksConfig struct {
    PreToolUse       []HookEntry `json:"PreToolUse,omitempty"`
    PostToolUse      []HookEntry `json:"PostToolUse,omitempty"`
    SessionStart     []HookEntry `json:"SessionStart,omitempty"`
    Stop             []HookEntry `json:"Stop,omitempty"`
    PreCompact       []HookEntry `json:"PreCompact,omitempty"`
    UserPromptSubmit []HookEntry `json:"UserPromptSubmit,omitempty"`
    WorktreeCreate   []HookEntry `json:"WorktreeCreate,omitempty"`
    WorktreeRemove   []HookEntry `json:"WorktreeRemove,omitempty"`
}
```

---

## 4. Hook Merge Algorithm: `ComputeExpected()`

### 4.1 Config File Locations

Three tiers of config exist:

| Tier | Path | Managed by |
|---|---|---|
| Binary defaults | Compiled into `gt` binary | `DefaultBase()`, `DefaultOverrides()` |
| Base config | `~/.gt/hooks-base.json` | `gt hooks base` |
| Role overrides | `~/.gt/hooks-overrides/<target>.json` | `gt hooks override <target>` |

The `GT_HOME` environment variable redirects the primary config dir: when set,
`$GT_HOME/.gt/` is used instead of `~/.gt/`. Both dirs are searched in priority order
(GT_HOME first) when loading; writes always go to the primary dir. See `gtConfigDirs()` at
`config.go:579-595`.

### 4.2 `ComputeExpected()` Trace

`config.go:345-380`:

```go
func ComputeExpected(target string) (*HooksConfig, error) {
    // Step 1: Load on-disk base, or fall back to DefaultBase() if absent
    base, err := LoadBase()
    if err != nil {
        if os.IsNotExist(err) {
            base = DefaultBase()
        } else {
            return nil, fmt.Errorf("loading base config: %w", err)
        }
    } else {
        // Step 2: Backfill — merge DefaultBase() UNDER on-disk base.
        // New hook types added to DefaultBase() appear automatically
        // without overwriting user customizations.
        base = Merge(DefaultBase(), base)
    }

    defaults := DefaultOverrides()
    result := base

    // Step 3: For each applicable override key (ordered least to most specific):
    for _, overrideKey := range GetApplicableOverrides(target) {
        // 3a: Apply compiled-in role default first
        if def, ok := defaults[overrideKey]; ok {
            result = Merge(result, def)
        }
        // 3b: Apply on-disk override on top (wins over compiled defaults)
        override, err := LoadOverride(overrideKey)
        if err != nil {
            if os.IsNotExist(err) { continue }
            return nil, fmt.Errorf("loading override %q: %w", overrideKey, err)
        }
        result = Merge(result, override)
    }

    return result, nil
}
```

### 4.3 Override Key Expansion

`GetApplicableOverrides()` at `config.go:816-824`:

```go
// "gastown/crew"  → ["crew", "gastown/crew"]
// "mayor"         → ["mayor"]
// "beads/witness" → ["witness", "beads/witness"]
```

Role-level overrides apply first; rig+role overrides apply last and therefore win on same-
matcher collisions.

### 4.4 `mergeEntries()` Logic

`merge.go:93-130`:

```
For each event type:
  Build a map: override_matcher → override_entry

  Walk base entries:
    If base_entry.matcher is in override map:
      If override_entry.Hooks is non-empty  → replace base entry with override entry
      If override_entry.Hooks is empty      → drop entry entirely (explicit disable)
    Else:
      Keep base entry unchanged

  Walk override entries:
    If matcher is NOT already in base → append override entry (new matcher)
    If matcher WAS in base            → already handled above, skip
```

This means:
- **Same matcher**: override replaces base entirely.
- **New matcher**: override entry is appended after all base entries.
- **Empty hooks list**: explicit disable — removes that matcher from the result.

The merge is non-mutating: `cloneConfig()` deep-copies the base before any modification.

### 4.5 Example: Full Merge for `gastown/crew`

Given `target = "gastown/crew"`:

1. Load `~/.gt/hooks-base.json` (or `DefaultBase()` if absent).
2. Merge `DefaultBase()` underneath on-disk base (backfill).
3. `GetApplicableOverrides("gastown/crew")` returns `["crew", "gastown/crew"]`.
4. Apply compiled `DefaultOverrides()["crew"]` → adds crew-specific `PreCompact` (session
   cycling instead of priming).
5. Apply `~/.gt/hooks-overrides/crew.json` if it exists.
6. Apply compiled `DefaultOverrides()["gastown/crew"]` → (none defined by default).
7. Apply `~/.gt/hooks-overrides/gastown__crew.json` if it exists.

Note: filesystem safety — `/` is replaced with `__` in filenames:
`"gastown/crew"` → `~/.gt/hooks-overrides/gastown__crew.json`.

---

## 5. `DefaultBase()` and `DefaultOverrides()`

Both are compiled into the `gt` binary at `config.go:199-330` and `config.go:713-806`.
They act as the implicit floor that is always present even if no on-disk config exists.

### 5.1 `DefaultBase()` — Applies to All Roles

```
PreToolUse guards:
  Bash(gh pr create*)          → gt tap guard pr-workflow
  Bash(git checkout -b*)       → gt tap guard pr-workflow
  Bash(git switch -c*)         → gt tap guard pr-workflow
  Bash(rm -rf /*)              → gt tap guard dangerous-command
  Bash(git push --force*)      → gt tap guard dangerous-command
  Bash(git push -f*)           → gt tap guard dangerous-command

SessionStart (matcher=""):     gt prime --hook
PreCompact   (matcher=""):     gt prime --hook
UserPromptSubmit (matcher=""): gt mail check --inject
Stop         (matcher=""):     gt costs record
```

### 5.2 `DefaultOverrides()` — Role-Specific

**crew**: Overrides `PreCompact` to trigger session cycling instead of context re-injection:

```
PreCompact (matcher=""): gt handoff --cycle --reason compaction
```

**witness**, **deacon**, **refinery**: All receive the same four patrol-formula guards
appended to `PreToolUse`:

```
Bash(*bd mol pour*patrol*)      → echo BLOCKED && exit 2
Bash(*bd mol pour *mol-witness*) → echo BLOCKED && exit 2
Bash(*bd mol pour *mol-deacon*)  → echo BLOCKED && exit 2
Bash(*bd mol pour *mol-refinery*) → echo BLOCKED && exit 2
```

**mayor**, **polecats**: No compiled overrides. They receive only `DefaultBase()`.

---

## 6. `gt tap guard` — The Guard System

### 6.1 Command Structure

`gt tap guard` is a PreToolUse hook handler. It is registered under `gt tap` in
`cmd/tap.go` and `cmd/tap_guard.go`. Two guards are implemented:

#### `gt tap guard pr-workflow`

Source: `internal/cmd/tap_guard.go:34-101`

Blocks PR creation and feature branch operations. Exits 2 in two scenarios:

1. Running as a Gas Town agent: detected via environment variables `GT_POLECAT`,
   `GT_CREW`, `GT_WITNESS`, `GT_REFINERY`, `GT_MAYOR`, `GT_DEACON` (any non-empty), or
   by CWD containing `/crew/` or `/polecats/`.
2. Origin remote is `steveyegge/gastown`: detected by `git remote get-url origin`.

If neither condition holds (e.g., a human working on a personal fork), the guard exits 0
and the operation is allowed.

Error output is a formatted box on stderr:
```
╔══════════════════════════════════════════════════════════════════╗
║  ❌ PR WORKFLOW BLOCKED                                          ║
╠══════════════════════════════════════════════════════════════════╣
║  Gas Town workers push directly to main. PRs are forbidden.     ║
...
╚══════════════════════════════════════════════════════════════════╝
```

#### `gt tap guard dangerous-command`

Source: `internal/cmd/tap_guard_dangerous.go:66-100`

Reads the tool input JSON from stdin, extracts `tool_input.command`, and tests it against
five dangerous patterns (all substrings must match, case-insensitive):

```go
var dangerousPatterns = []dangerousPattern{
    {contains: []string{"rm", "-rf", "/"}, reason: "rm -rf with absolute path..."},
    {contains: []string{"git", "push", "--force"}, reason: "Force push..."},
    {contains: []string{"git", "push", "-f"}, reason: "Force push..."},
    {contains: []string{"git", "reset", "--hard"}, reason: "Hard reset..."},
    {contains: []string{"git", "clean", "-f"}, reason: "git clean -f..."},
}
```

On match, exits 2. On non-match or parse failure, exits 0 (fail-open for non-hook usage).

### 6.2 Inline Guards (Patrol-Formula Guards)

The witness, deacon, and refinery role overrides install guards as inline shell commands
rather than calling `gt tap guard`. These do not need to read stdin:

```bash
echo '❌ BLOCKED: Patrol formulas must use wisps, not persistent molecules.' && \
echo 'Use: bd mol wisp mol-*-patrol' && \
echo 'Not:  bd mol pour mol-*-patrol' && \
exit 2
```

These block `bd mol pour` when the molecule name contains `patrol`, `mol-witness`,
`mol-deacon`, or `mol-refinery`. The rationale (from comments in `DefaultOverrides()`):
patrol agents must use ephemeral wisps, not persistent molecules, to avoid unbounded
accumulation.

### 6.3 Control Flow: PreToolUse Guard Blocking

When an agent tries `git push --force origin main`:

1. Claude Code matches the command against hook matchers.
2. `Bash(git push --force*)` matches.
3. Claude Code invokes: `export PATH="..." && gt tap guard dangerous-command`
4. `gt tap guard dangerous-command` reads stdin JSON:
   `{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}`
5. `extractCommand()` extracts `"git push --force origin main"`.
6. `matchesDangerous()` finds the `{"git","push","--force"}` pattern matches.
7. Command prints the error box to stderr.
8. `return NewSilentExit(2)` — exits with code 2.
9. Claude Code sees exit 2 → **tool call is blocked**, error output is shown to agent.
10. Agent receives the error message and must choose a different approach.

---

## 7. `gt signal` — Turn Boundary Handler

Source: `internal/cmd/signal.go`, `internal/cmd/signal_stop.go`

`gt signal stop` is a Stop hook implementation designed for active agents (witnesses,
polecats) that must not go idle while work is queued. It outputs JSON consumed by Claude
Code:

```json
{"decision": "block", "reason": "<message to inject>"}
// or
{"decision": "approve"}
```

### 7.1 What It Checks

Both checks run in parallel (goroutines) with a 500ms total budget:

1. **Unread mail** (`checkUnreadMail`): Queries the agent's mailbox. If unread messages
   exist (excluding self-handoff mail), returns a block reason:
   ```
   [gt signal stop] You have N unread message(s). Most recent from <sender>: "<subject>"
   Run `gt mail inbox` to read your messages, then continue working.
   ```

2. **Slung work** (`checkStopSlungWork`): Checks the agent bead for a `hook_bead` field,
   then checks if that bead has `status=hooked`. Falls back to querying for any
   `status=hooked` beads assigned to the agent. Returns a block reason:
   ```
   [gt signal stop] Work slung to you: <bead-id> — "<title>"
   Run `gt hook` to see details, then execute the work.
   ```

### 7.2 Loop Prevention

The stop state file at `/tmp/gt-signal-stop-<agent>.json` records `last_reason`. If the
same block reason fires on consecutive turns (because the agent hasn't processed the mail
yet), the handler approves instead of blocking a second time. When conditions clear, the
state file is deleted so future conditions trigger fresh notifications.

### 7.3 Not in DefaultBase

`gt signal stop` is **not** installed in `DefaultBase()`. The default Stop hook is
`gt costs record` only. `gt signal stop` is documented and available but must be
manually added via `gt hooks override` or `gt hooks install` if desired.

---

## 8. Role-Specific Guard Differences

| Role | PR Guard | Dangerous Guard | Patrol Guard | PreCompact |
|---|---|---|---|---|
| mayor | yes | yes | no | `gt prime --hook` |
| deacon | yes | yes | yes (4 matchers) | `gt prime --hook` |
| crew | yes | yes | no | `gt handoff --cycle` |
| witness | yes | yes | yes (4 matchers) | `gt prime --hook` |
| refinery | yes | yes | yes (4 matchers) | `gt prime --hook` |
| polecats | yes | yes | no | `gt prime --hook` |

Key differences:
- **Crew** is the only role that does session cycling on PreCompact rather than re-priming.
- **Witness, deacon, refinery** have the patrol-formula guard. Mayor, crew, and polecats
  do not.
- All roles share the same PR workflow and dangerous-command guards from `DefaultBase()`.

Autonomous roles (polecat, witness, refinery, deacon) also use the `settings-autonomous.json`
template which merges mail delivery into `SessionStart` rather than relying solely on
`UserPromptSubmit`. This matters because autonomous agents may wake up to incoming work
without a user prompt being submitted.

---

## 9. `gt hooks sync` — Propagation Across the Workspace

Source: `internal/cmd/hooks_sync.go`

`gt hooks sync` regenerates all `.claude/settings.json` files in the workspace by:

1. **Discovering targets**: `hooks.DiscoverTargets(townRoot)` at `config.go:386-469`
   walks the workspace directory structure, finding:
   - `<townRoot>/mayor/.claude/settings.json` (key: `"mayor"`)
   - `<townRoot>/deacon/.claude/settings.json` (key: `"deacon"`)
   - `<townRoot>/<rig>/crew/.claude/settings.json` (key: `"<rig>/crew"`)
   - `<townRoot>/<rig>/polecats/.claude/settings.json` (key: `"<rig>/polecats"`)
   - `<townRoot>/<rig>/witness/.claude/settings.json` (key: `"<rig>/witness"`)
   - `<townRoot>/<rig>/refinery/.claude/settings.json` (key: `"<rig>/refinery"`)

2. **Computing expected config**: For each target, calls `ComputeExpected(target.Key)`.

3. **Comparing to current**: Loads existing settings via `LoadSettings()` which preserves
   all unknown fields. If the hooks section is already equal (`HooksEqual()`), skips write.

4. **Writing**: Updates only the `hooks` key in the settings map. Also sets
   `enabledPlugins["beads@beads-marketplace"] = false`. Preserves all other fields
   (e.g., `editorMode`, `skipDangerousModePermissionPrompt`) via the `Extra` map roundtrip.

5. **Integrity errors**: If `LoadSettings()` encounters a malformed JSON file, it returns
   a `SettingsIntegrityError`. Sync **fails closed** (refuses to write) on integrity
   violations, preventing corrupt state from propagating.

`--dry-run` shows what would change without writing.

### 9.1 Target Discovery: `isRig()`

A directory is treated as a rig only if it contains at least one of `crew/`, `witness/`,
`polecats/`, or `refinery/` subdirectories (`config.go:472-480`). Directories like
`mayor/`, `deacon/`, `.beads/`, and dotfiles are explicitly excluded.

### 9.2 Shared Settings Model

All workers within a role directory share **one** settings file. For example, all crew
workers in the `gastown` rig share `/home/krystian/gt/gastown/crew/.claude/settings.json`.
Individual crew worktrees under `/home/krystian/gt/gastown/crew/<name>/` all receive this
file via Claude Code's `--settings` flag at startup.

---

## 10. `gt costs record` — The Stop Hook

Source: `internal/cmd/costs.go:956-1000+`

`gt costs record` is invoked on every Stop event. It:

1. Resolves the session name from: `--session` flag → `GT_SESSION` env → `deriveSessionName()`
   (from `GT_*` role envs) → `detectCurrentTmuxSession()`.
2. If no session is found (e.g., Claude Code launched outside Gas Town), exits silently.
3. Locates the work directory from `GT_CWD` or from the tmux session.
4. Reads token usage from the Claude Code transcript file at `~/.claude/projects/`.
5. Calculates cost using model-specific pricing.
6. Appends a `CostLogEntry` (JSON) to `~/.gt/costs.jsonl`.

The log is a simple append-only file. It is never a database operation, so it cannot fail
due to network or service unavailability. Daily aggregation is performed separately by
`gt costs digest` (run by the Deacon patrol), which creates permanent "Cost Report
YYYY-MM-DD" beads.

---

## 11. Autonomous vs Interactive Settings Templates

Source: `internal/claude/settings.go`, `internal/claude/config/`

The binary embeds two template files via `go:embed`:

```go
//go:embed config/*.json
var configFS embed.FS
```

### 11.1 `settings-interactive.json`

Used for mayor and crew roles. These agents wait for user input, so mail injection
through `UserPromptSubmit` is sufficient.

```
SessionStart:      gt prime --hook
PreCompact:        gt prime --hook
UserPromptSubmit:  gt mail check --inject
Stop:              gt costs record
PreToolUse:        pr-workflow guard (3 matchers)
```

No `skipDangerousModePermissionPrompt` or `editorMode` in the interactive template.

### 11.2 `settings-autonomous.json`

Used for polecat, witness, refinery, deacon, and boot roles. These agents may be
triggered externally (e.g., via sling/hook) without a user prompt, so mail injection must
also happen at `SessionStart`:

```
SessionStart:      gt prime --hook && gt mail check --inject
PreCompact:        gt prime --hook
UserPromptSubmit:  gt mail check --inject
Stop:              gt costs record
PreToolUse:        pr-workflow guard (3 matchers)
skipDangerousModePermissionPrompt: true
editorMode: normal
```

The autonomous template sets `skipDangerousModePermissionPrompt: true`, meaning the agent
operates in dangerous mode without confirmation prompts. This is appropriate because
autonomous agents are supervised by the Gas Town harness, not directly by a human.

### 11.3 Template vs Managed Settings

The templates are used only by `EnsureSettingsForRole()` as a bootstrap mechanism — they
create the settings file if it does not exist. Once created, the file is managed by
`gt hooks sync` which overwrites only the `hooks` section. The two-phase design means:

1. **Bootstrap**: Template is copied verbatim if no settings file exists.
2. **Ongoing management**: `gt hooks sync` keeps the hooks section current while preserving
   all other fields written by the template or by Claude Code itself.

---

## 12. Architecture Summary

### 12.1 End-to-End Data Flow

```
Binary (DefaultBase + DefaultOverrides)
         ↓
~/.gt/hooks-base.json         ← edited by: gt hooks base
~/.gt/hooks-overrides/*.json  ← edited by: gt hooks override <target>
         ↓
  ComputeExpected(target)      ← merge algorithm
         ↓
  .claude/settings.json        ← written by: gt hooks sync
         ↓
  Claude Code --settings flag  ← passed at agent startup
         ↓
  Hook events fire             ← PreToolUse / SessionStart / Stop / etc.
         ↓
  gt tap guard / gt prime / gt costs record / gt mail check
```

### 12.2 Key Invariants

- **Fail closed on integrity**: Malformed `settings.json` causes `sync` to refuse to write
  that target rather than overwrite with potentially wrong data.
- **No mutation of base**: `cloneConfig()` ensures `Merge()` never modifies its inputs.
- **Backfill guarantee**: New hook types added to `DefaultBase()` automatically appear in
  all managed settings files on the next `gt hooks sync`, even if an on-disk base predates
  the addition.
- **Unique matchers enforced**: Duplicate matcher strings within an event type are rejected
  at load time by `validateUniqueMatchers()`.
- **Fail open for non-hook usage**: The dangerous-command guard exits 0 (allows) if it
  cannot parse stdin, so it does not break non-hook invocations of `gt tap guard`.
- **PATH setup prefix**: Every hook command prefixes `export PATH="$HOME/go/bin:$HOME/.local/bin:$PATH" &&`
  to ensure `gt` and `bd` are found regardless of Claude Code's inherited shell environment.

### 12.3 Key File Locations

| File | Role |
|---|---|
| `/home/krystian/gt/gastown/crew/sherlock/internal/hooks/config.go` | Schema types, DefaultBase, DefaultOverrides, ComputeExpected, DiscoverTargets |
| `/home/krystian/gt/gastown/crew/sherlock/internal/hooks/merge.go` | MergeHooks, mergeEntries, applyOverride, cloneConfig |
| `/home/krystian/gt/gastown/crew/sherlock/internal/cmd/tap_guard.go` | pr-workflow guard |
| `/home/krystian/gt/gastown/crew/sherlock/internal/cmd/tap_guard_dangerous.go` | dangerous-command guard |
| `/home/krystian/gt/gastown/crew/sherlock/internal/cmd/signal_stop.go` | gt signal stop handler |
| `/home/krystian/gt/gastown/crew/sherlock/internal/cmd/hooks_sync.go` | gt hooks sync |
| `/home/krystian/gt/gastown/crew/sherlock/internal/cmd/costs.go` | gt costs record |
| `/home/krystian/gt/gastown/crew/sherlock/internal/cmd/mail_check.go` | gt mail check --inject |
| `/home/krystian/gt/gastown/crew/sherlock/internal/claude/settings.go` | EnsureSettingsForRole, template dispatch |
| `/home/krystian/gt/gastown/crew/sherlock/internal/claude/config/settings-autonomous.json` | Autonomous role template |
| `/home/krystian/gt/gastown/crew/sherlock/internal/claude/config/settings-interactive.json` | Interactive role template |
| `/home/krystian/gt/mayor/.claude/settings.json` | Mayor managed settings |
| `/home/krystian/gt/deacon/.claude/settings.json` | Deacon managed settings |
| `/home/krystian/gt/gastown/crew/.claude/settings.json` | Crew managed settings (gastown rig) |
| `/home/krystian/gt/gastown/polecats/.claude/settings.json` | Polecats managed settings (gastown rig) |
| `/home/krystian/gt/gastown/witness/.claude/settings.json` | Witness managed settings (gastown rig) |
| `/home/krystian/gt/gastown/refinery/.claude/settings.json` | Refinery managed settings (gastown rig) |
