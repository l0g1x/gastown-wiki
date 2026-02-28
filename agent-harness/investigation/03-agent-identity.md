# 03 — Agent Identity Layer

> Reflects upstream commit: `7a6c8189`

Deep architectural investigation of how every Gas Town agent gets its identity,
model, and behavioral settings. Source code is in
`/home/krystian/gt/gastown/crew/sherlock/`.

---

## Architecture: Identity Resolution End-to-End

Every agent session in Gas Town is fully described before the first process
is launched. Identity resolution proceeds through four distinct layers:

```
1. Role assignment  (what type of agent are you?)
   ↓ GT_ROLE env var  OR  path-based cwd inference (gt prime)
2. Config cascade   (what agent binary / model / flags?)
   ↓ rig/settings/config.json → town/settings/config.json → built-in presets
3. Env assembly     (what variables does the session inherit?)
   ↓ AgentEnv() — single source of truth for all GT_*, BD_*, GIT_*, OTEL_* vars
4. Hook provisioning (what lifecycle hooks are installed?)
   ↓ runtime.EnsureSettingsForRole → provider-specific installer
```

The result is a fully-assembled `RuntimeConfig` struct and an environment-
variable map that are passed to tmux when the session is created.

---

## State: Config Files and Their Schemas

### Town level — `settings/config.json`

Path function: `TownSettingsPath(townRoot)` → `<townRoot>/settings/config.json`

Type: `TownSettings` (`internal/config/types.go:41`)

| Field | Type | Purpose |
|---|---|---|
| `type` | string | Schema discriminator: `"town-settings"` |
| `version` | int | Schema version (current: 1) |
| `default_agent` | string | Fallback agent name when no role or rig override exists (e.g. `"claude"`) |
| `agents` | `map[string]*RuntimeConfig` | Named agent definitions; can override built-in presets or define entirely new agents |
| `role_agents` | `map[string]string` | Per-role agent name overrides: `"witness" → "claude-haiku"` etc. |
| `cost_tier` | string | Informational: `"standard"`, `"economy"`, `"budget"`, or empty |
| `agent_email_domain` | string | Domain for agent git identity emails (default: `"gastown.local"`) |
| `scheduler` | `*capacity.SchedulerConfig` | Polecat scheduler settings |

Live example (`/home/krystian/gt/settings/config.json`):
```json
{
  "type": "town-settings",
  "default_agent": "claude",
  "agents": {
    "claude":        {"command": "claude", "args": ["--dangerously-skip-permissions", "--model", "claude-opus-4-6"]},
    "claude-haiku":  {"command": "claude", "args": ["--dangerously-skip-permissions", "--model", "haiku"]},
    "claude-sonnet": {"command": "claude", "args": ["--dangerously-skip-permissions", "--model", "sonnet"]}
  },
  "role_agents": {
    "crew":     "claude",
    "deacon":   "claude-haiku",
    "mayor":    "claude-sonnet",
    "polecat":  "claude",
    "refinery": "claude-sonnet",
    "witness":  "claude-sonnet"
  }
}
```

### Rig level — `<rig>/settings/config.json`

Path function: `RigSettingsPath(rigPath)` → `<rig>/settings/config.json`

Type: `RigSettings` (`internal/config/types.go:332`)

| Field | Type | Purpose |
|---|---|---|
| `type` | string | `"rig-settings"` |
| `version` | int | Schema version |
| `agent` | string | Agent override for this rig (all roles unless `role_agents` narrows it) |
| `agents` | `map[string]*RuntimeConfig` | Rig-local agent definitions |
| `role_agents` | `map[string]string` | Per-role agent overrides for this rig only |
| `runtime` | `*RuntimeConfig` | Legacy direct runtime config (deprecated, use `agent`) |
| `merge_queue` | `*MergeQueueConfig` | Merge queue behavior |
| `crew` | `*CrewConfig` | Crew auto-start policy |
| `theme` | `*ThemeConfig` | Tmux visual theme |

### Agent agent registry — `settings/agents.json`

Optional. Loaded by `LoadAgentRegistry` / `LoadRigAgentRegistry`. Adds or
overrides entries in the global `AgentRegistry`. Format mirrors `AgentPresetInfo`
embedded in `agents.go`. Rig-level: `<rig>/settings/agents.json`.

### Role TOML definitions — embedded in binary

Path: `internal/config/roles/<role>.toml`
Loaded via `//go:embed roles/*.toml` (`roles.go:16`).
Type: `RoleDefinition` (`roles.go:18`)

**All fields in a role TOML:**

| Field | Type | Purpose |
|---|---|---|
| `role` | string | Role identifier: `"mayor"`, `"deacon"`, `"dog"`, `"witness"`, `"refinery"`, `"polecat"`, `"crew"` |
| `scope` | string | `"town"` or `"rig"` — determines where the agent runs |
| `nudge` | string | Initial prompt text sent when starting the agent |
| `prompt_template` | string | Name of the Markdown prompt template file |
| `[session].pattern` | string | Tmux session name pattern; placeholders: `{rig}`, `{name}`, `{role}`, `{prefix}` |
| `[session].work_dir` | string | Working directory pattern; placeholders: `{town}`, `{rig}`, `{name}`, `{role}` |
| `[session].needs_pre_sync` | bool | Whether the workspace needs git sync before starting |
| `[session].start_command` | string | Command run after tmux session creation (default: `exec claude --dangerously-skip-permissions`) |
| `[env]` | `map[string]string` | Static env vars to set in the session (merged, not replaced, on override) |
| `[health].ping_timeout` | duration | How long to wait for a health-check response |
| `[health].consecutive_failures` | int | Failed checks before force-kill |
| `[health].kill_cooldown` | duration | Minimum time between force-kills |
| `[health].stuck_threshold` | duration | How long in_progress before the agent is declared stuck |

Role TOML example (witness):
```toml
role = "witness"
scope = "rig"
nudge = "Run 'gt prime' to check worker status and begin patrol cycle."
prompt_template = "witness.md.tmpl"

[session]
pattern = "{prefix}-witness"
work_dir = "{town}/{rig}/witness"
needs_pre_sync = false
start_command = "exec claude --dangerously-skip-permissions"

[env]
GT_ROLE = "witness"
GT_SCOPE = "rig"

[health]
ping_timeout = "30s"
consecutive_failures = 3
kill_cooldown = "5m"
stuck_threshold = "1h"
```

**Role/scope matrix:**

| Role | Scope | Per-rig? | Notes |
|---|---|---|---|
| mayor | town | No | Global coordinator |
| deacon | town | No | Daemon beacon / heartbeat |
| dog | town | No | Cross-rig task worker |
| witness | rig | Yes | Polecat lifecycle monitor |
| refinery | rig | Yes | Merge queue processor |
| polecat | rig | Yes, multiple | Ephemeral worker |
| crew | rig | Yes, multiple | Persistent workspace |

### Claude settings templates — embedded in binary

Path: `internal/claude/config/settings-autonomous.json` and
`settings-interactive.json`.
Selected by `RoleTypeFor(role)` (`claude/settings.go:28`):

- **Autonomous** (polecat, witness, refinery, deacon, boot): `SessionStart`
  hook runs `gt prime --hook && gt mail check --inject` — both context and work
  assignment happen automatically.
- **Interactive** (mayor, crew, others): `SessionStart` hook runs
  `gt prime --hook` only — mail injection is done on `UserPromptSubmit`.

Both templates configure the same five hook events:
`PreToolUse`, `SessionStart`, `PreCompact`, `UserPromptSubmit`, `Stop`.

---

## Code Paths: Key Functions with File:Line References

| Function | File | Line | Purpose |
|---|---|---|---|
| `ResolveRoleAgentConfig` | `internal/config/loader.go` | 1205 | Public entry point: resolves RuntimeConfig for a role |
| `resolveRoleAgentConfigCore` | `internal/config/loader.go` | 1345 | Lock-free inner implementation |
| `resolveAgentConfigInternal` | `internal/config/loader.go` | 1027 | Resolves rig/town default agent (no role specificity) |
| `lookupAgentConfig` | `internal/config/loader.go` | 1493 | Name → RuntimeConfig: checks rig, town, then built-in presets |
| `lookupCustomAgentConfig` | `internal/config/loader.go` | 1520 | Same but only custom agents (skips built-ins) |
| `fillRuntimeDefaults` | `internal/config/loader.go` | 1546 | Deep-copies config and fills missing fields from preset |
| `normalizeRuntimeConfig` | `internal/config/types.go` | 540 | Apply all provider-specific defaults; called by `BuildCommand()` |
| `AgentEnv` | `internal/config/env.go` | 65 | Single source of truth for all agent session env vars |
| `LoadRoleDefinition` | `internal/config/roles.go` | 136 | Load TOML with 3-layer override cascade |
| `mergeRoleDefinition` | `internal/config/roles.go` | 209 | Non-zero-override merge of TOML layers |
| `GetRoleWithContext` | `internal/cmd/role.go` | 170 | GT_ROLE env → cwd path detection fallback |
| `detectRole` | `internal/cmd/role.go` | 242 | Path-based role inference from cwd |
| `EnsureSettingsForRole` | `internal/runtime/runtime.go` | 55 | Provision provider-specific hooks and slash commands |
| `tryResolveFromEphemeralTier` | `internal/config/loader.go` | 1287 | Ephemeral GT_COST_TIER override check |
| `withRoleSettingsFlag` | `internal/config/loader.go` | 1232 | Appends `--settings` arg for Claude agents |
| `initRegistryLocked` | `internal/config/agents.go` | 381 | Initializes global AgentRegistry from built-ins |
| `loadAgentRegistryFromPathLocked` | `internal/config/agents.go` | 398 | Merges user JSON into global registry |

---

## Control Flow: Full Trace of `ResolveRoleAgentConfig()`

`ResolveRoleAgentConfig(role, townRoot, rigPath string) *RuntimeConfig`
(`loader.go:1205`)

```
ResolveRoleAgentConfig(role, townRoot, rigPath)
│
├─ Acquire resolveConfigMu (serializes concurrent rig loads)
│
└─ resolveRoleAgentConfigCore(role, townRoot, rigPath)
   │
   ├─ 1. Load rig settings:  LoadRigSettings(<rig>/settings/config.json)
   │     → nil if file absent (town-level roles)
   │
   ├─ 2. Load town settings: LoadOrCreateTownSettings(<town>/settings/config.json)
   │     → NewTownSettings() if file absent (safe defaults)
   │
   ├─ 3. Load agent registries:
   │     LoadAgentRegistry(<town>/settings/agents.json)      (cached after first load)
   │     LoadRigAgentRegistry(<rig>/settings/agents.json)    (if rigPath != "")
   │
   ├─ 4. Dog shortcut: if role == "dog"
   │     → unless explicit non-Claude override in RoleAgents, return claudeHaikuPreset()
   │
   ├─ 5. Ephemeral cost tier: tryResolveFromEphemeralTier(role)
   │     checks GT_COST_TIER env var; returns (rc, handled)
   │     ├─ handled=true, rc != nil → use tier's Claude model (unless non-Claude override)
   │     └─ handled=true, rc == nil → skip persisted RoleAgents, jump to resolveAgentConfigInternal
   │
   ├─ 6. Rig RoleAgents: rigSettings.RoleAgents[role]
   │     → lookupCustomAgentConfig(agentName) OR lookupAgentConfig(agentName)
   │     → on binary-not-found: warn + fall through
   │
   ├─ 7. Town RoleAgents: townSettings.RoleAgents[role]
   │     → same lookup chain as #6
   │
   └─ 8. Fallback: resolveAgentConfigInternal(townRoot, rigPath)
         ├─ if rigSettings.Runtime != nil → use it directly (legacy compat)
         ├─ agentName = rigSettings.Agent || townSettings.DefaultAgent || "claude"
         └─ lookupAgentConfig(agentName, townSettings, rigSettings)
               ├─ rigSettings.Agents[name]   → fillRuntimeDefaults()
               ├─ townSettings.Agents[name]  → fillRuntimeDefaults()
               ├─ GetAgentPresetByName(name) → RuntimeConfigFromPreset()
               └─ DefaultRuntimeConfig()     (ultimate fallback: claude)

After resolveRoleAgentConfigCore returns:
└─ withRoleSettingsFlag(rc, role, rigPath)
      → for Claude agents with a shared settings dir (witness/refinery/crew/polecat),
        appends "--settings <path>/.claude/settings.json" to rc.Args
```

**lookupAgentConfig priority (innermost resolution):**
1. `rigSettings.Agents[name]` — rig-local custom agent
2. `townSettings.Agents[name]` — town-level custom agent
3. `GetAgentPresetByName(name)` → global `AgentRegistry` (built-ins + loaded JSON)
4. `DefaultRuntimeConfig()` — Claude defaults

---

## Control Flow: Full Trace of `AgentEnv()`

`AgentEnv(cfg AgentEnvConfig) map[string]string`
(`env.go:65`)

The `AgentEnvConfig` struct is the input contract:

| Field | Effect |
|---|---|
| `Role` | Drives the role-specific block (switch on "mayor", "deacon", etc.) |
| `Rig` | Sets `GT_RIG`; included in `GT_ROLE` compound format |
| `AgentName` | Sets `GT_POLECAT` / `GT_CREW`; included in `BD_ACTOR` |
| `TownRoot` | Sets `GT_ROOT` and `GIT_CEILING_DIRECTORIES` |
| `RuntimeConfigDir` | Sets `CLAUDE_CONFIG_DIR` |
| `SessionIDEnv` | Sets `GT_SESSION_ID_ENV` (tells runtime where to look for session ID) |
| `Agent` | Sets `GT_AGENT` (agent override name, visible via tmux show-environment) |
| `Prompt` | Included as `gt.prompt` in `OTEL_RESOURCE_ATTRIBUTES` |
| `Issue` | Included as `gt.issue` in `OTEL_RESOURCE_ATTRIBUTES` |
| `Topic` | Included as `gt.topic` in `OTEL_RESOURCE_ATTRIBUTES` |
| `SessionName` | Sets `GT_SESSION`; included as `gt.session` in OTEL |

**All environment variables produced:**

Phase 1 — Role-specific identity vars:

| Role | Variables Set |
|---|---|
| mayor | `GT_ROLE=mayor`, `BD_ACTOR=mayor`, `GIT_AUTHOR_NAME=mayor` |
| deacon | `GT_ROLE=deacon`, `BD_ACTOR=deacon`, `GIT_AUTHOR_NAME=deacon` |
| boot | `GT_ROLE=deacon/boot`, `BD_ACTOR=deacon-boot`, `GIT_AUTHOR_NAME=boot` |
| witness | `GT_ROLE=<rig>/witness`, `GT_RIG=<rig>`, `BD_ACTOR=<rig>/witness`, `GIT_AUTHOR_NAME=<rig>/witness` |
| refinery | `GT_ROLE=<rig>/refinery`, `GT_RIG=<rig>`, `BD_ACTOR=<rig>/refinery`, `GIT_AUTHOR_NAME=<rig>/refinery` |
| polecat | `GT_ROLE=<rig>/polecats/<name>`, `GT_RIG=<rig>`, `GT_POLECAT=<name>`, `BD_ACTOR=<rig>/polecats/<name>`, `GIT_AUTHOR_NAME=<name>`, `BD_DOLT_AUTO_COMMIT=off` |
| crew | `GT_ROLE=<rig>/crew/<name>`, `GT_RIG=<rig>`, `GT_CREW=<name>`, `BD_ACTOR=<rig>/crew/<name>`, `GIT_AUTHOR_NAME=<name>` |
| dog | `GT_ROLE=dog`, `BD_ACTOR=dog/<name>` or `dog`, `GIT_AUTHOR_NAME=<name>` or `dog` |

Phase 2 — Additional contextual vars:

| Variable | Condition |
|---|---|
| `GT_ROOT` | TownRoot != "" |
| `GIT_CEILING_DIRECTORIES` | TownRoot != "" (same value as GT_ROOT) |
| `BEADS_AGENT_NAME` | role is polecat or crew (format: `<rig>/<name>`) |
| `CLAUDE_CONFIG_DIR` | RuntimeConfigDir != "" |
| `GT_SESSION_ID_ENV` | SessionIDEnv != "" |
| `GT_SESSION` | SessionName != "" |
| `GT_AGENT` | Agent != "" |
| `NODE_OPTIONS` | Always set to `""` (clears debugger flags from parent shell) |
| `CLAUDECODE` | Always set to `""` (prevents nested-session error in Claude v2) |

Phase 3 — OTEL telemetry (only when `GT_OTEL_METRICS_URL` is set):

`CLAUDE_CODE_ENABLE_TELEMETRY`, `OTEL_METRICS_EXPORTER`, `OTEL_METRIC_EXPORT_INTERVAL`,
`OTEL_EXPORTER_OTLP_METRICS_ENDPOINT`, `OTEL_EXPORTER_OTLP_METRICS_PROTOCOL`,
`BD_OTEL_METRICS_URL`. If `GT_OTEL_LOGS_URL` also set:
`BD_OTEL_LOGS_URL`, `OTEL_LOGS_EXPORTER`, `OTEL_EXPORTER_OTLP_LOGS_ENDPOINT`,
`OTEL_EXPORTER_OTLP_LOGS_PROTOCOL`, `OTEL_LOG_TOOL_DETAILS`, `OTEL_LOG_TOOL_CONTENT`,
`OTEL_LOG_USER_PROMPTS`. All these receive `OTEL_RESOURCE_ATTRIBUTES` containing
`gt.role`, `gt.rig`, `gt.actor`, `gt.agent`, `gt.town`, `gt.prompt`, `gt.issue`,
`gt.topic`, `gt.session` as sanitized comma-separated key=value pairs.

Phase 4 — Cloud/API credential pass-through (only values already set in parent process):

Anthropic direct: `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL`,
`ANTHROPIC_CUSTOM_HEADERS`, `ANTHROPIC_MODEL`, `ANTHROPIC_DEFAULT_HAIKU_MODEL`,
`ANTHROPIC_DEFAULT_SONNET_MODEL`, `ANTHROPIC_DEFAULT_OPUS_MODEL`,
`CLAUDE_CODE_SUBAGENT_MODEL`.

AWS Bedrock: `CLAUDE_CODE_USE_BEDROCK`, `CLAUDE_CODE_SKIP_BEDROCK_AUTH`,
`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, `AWS_REGION`,
`AWS_PROFILE`, `AWS_BEARER_TOKEN_BEDROCK`, `ANTHROPIC_SMALL_FAST_MODEL_AWS_REGION`.

Microsoft Foundry: `CLAUDE_CODE_USE_FOUNDRY`, `CLAUDE_CODE_SKIP_FOUNDRY_AUTH`,
`ANTHROPIC_FOUNDRY_API_KEY`, `ANTHROPIC_FOUNDRY_BASE_URL`, `ANTHROPIC_FOUNDRY_RESOURCE`.

Google Vertex AI: `CLAUDE_CODE_USE_VERTEX`, `CLAUDE_CODE_SKIP_VERTEX_AUTH`,
`GOOGLE_APPLICATION_CREDENTIALS`, `GOOGLE_CLOUD_PROJECT`, `VERTEX_PROJECT`,
`VERTEX_LOCATION`, `VERTEX_REGION_CLAUDE_3_5_HAIKU`, `VERTEX_REGION_CLAUDE_3_7_SONNET`,
`VERTEX_REGION_CLAUDE_4_0_OPUS`, `VERTEX_REGION_CLAUDE_4_0_SONNET`,
`VERTEX_REGION_CLAUDE_4_1_OPUS`.

Network/proxy: `HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY`.

mTLS: `CLAUDE_CODE_CLIENT_CERT`, `CLAUDE_CODE_CLIENT_KEY`,
`CLAUDE_CODE_CLIENT_KEY_PASSPHRASE`.

---

## Interfaces: How Identity Feeds Into the System

### Into prompt assembly

`gt prime` calls `GetRoleWithContext(cwd, townRoot)` → `RoleInfo` → selects the
role-specific Markdown template (e.g. `witness.md.tmpl`). The template receives
`RoleInfo.Role`, `RoleInfo.Rig`, `RoleInfo.Polecat`, and other context.

The Claude hook `SessionStart` fires automatically on agent startup and runs
`gt prime --hook`, which reads session JSON from stdin to persist the session
ID, then emits the full role context to Claude's context window.

### Into session creation

Lifecycle managers (e.g. `witness/manager.go`, `polecat/session_manager.go`) call:
1. `ResolveRoleAgentConfig(role, townRoot, rigPath)` → `RuntimeConfig`
2. `AgentEnv(AgentEnvConfig{...})` → `map[string]string`
3. `runtime.EnsureSettingsForRole(settingsDir, workDir, role, rc)` to install hooks
4. tmux session creation with the assembled command and env

### Into hook provisioning

`runtime.EnsureSettingsForRole` (`runtime/runtime.go:55`) dispatches to the
provider-registered installer:

```go
// runtime/runtime.go:20-47 (init function)
config.RegisterHookInstaller("claude",    claude.EnsureSettingsForRoleAt)
config.RegisterHookInstaller("gemini",    gemini.EnsureSettingsForRoleAt)
config.RegisterHookInstaller("opencode",  opencode.EnsurePluginAt)
config.RegisterHookInstaller("copilot",   copilot.EnsureSettingsAt)
config.RegisterHookInstaller("omp",       omp.EnsureHookAt)
config.RegisterHookInstaller("pi",        pi.EnsureHookAt)
```

Hook installer selection: `rc.Hooks.Provider` (e.g. `"claude"`) determines
which registered function runs. The `HookInstallerFunc` signature is:
`func(settingsDir, workDir, role, hooksDir, hooksFile string) error`.

After hook install, `commands.ProvisionFor(workDir, provider)` installs
agent-specific slash commands.

---

## The Agent Preset Registry

`AgentPresetInfo` (`agents.go:45`) is the single source of truth for every
supported agent runtime. Fields and their roles:

| Field | Purpose |
|---|---|
| `Name` | Preset identifier (`AgentPreset` constant) |
| `Command` | CLI binary (e.g. `"claude"`, `"gemini"`, `"codex"`) |
| `Args` | Default autonomous-mode flags (e.g. `["--dangerously-skip-permissions"]`) |
| `Env` | Preset-level env vars merged into AgentEnv (e.g. `OPENCODE_PERMISSION`) |
| `ProcessNames` | Process names for tmux liveness detection |
| `SessionIDEnv` | Env var that holds the agent's session ID |
| `ResumeFlag` | Flag or subcommand for session resume |
| `ContinueFlag` | Flag for auto-resuming most recent session |
| `ResumeStyle` | `"flag"` or `"subcommand"` |
| `SupportsHooks` | Whether the agent has real executable lifecycle hooks |
| `SupportsForkSession` | Whether `--fork-session` is available |
| `NonInteractive` | Config for non-interactive (scripted) invocation |
| `PromptMode` | `"arg"` or `"none"` — how initial prompt is delivered |
| `ConfigDirEnv` | Env var for agent config directory (e.g. `"CLAUDE_CONFIG_DIR"`) |
| `ConfigDir` | Directory containing agent config (e.g. `".claude"`) |
| `HooksProvider` | Hook framework name (`"claude"`, `"opencode"`, `"gemini"`, etc.) |
| `HooksDir` | Directory for hooks/settings |
| `HooksSettingsFile` | Settings/plugin filename |
| `HooksInformational` | True when hooks install instructions only, not executable hooks |
| `ReadyPromptPrefix` | tmux prompt prefix for readiness detection (e.g. `"❯ "`) |
| `ReadyDelayMs` | Fallback delay-based readiness wait |
| `InstructionsFile` | Agent's instructions filename (`"CLAUDE.md"`, `"AGENTS.md"`) |
| `EmitsPermissionWarning` | Agent shows permission bypass warning that needs tmux acknowledgment |

**Built-in presets summary:**

| Name | Binary | YOLO flag | Hooks | InstructionsFile |
|---|---|---|---|---|
| `claude` | `claude` | `--dangerously-skip-permissions` | claude | `CLAUDE.md` |
| `gemini` | `gemini` | `--approval-mode yolo` | gemini | `AGENTS.md` |
| `codex` | `codex` | `--dangerously-bypass-approvals-and-sandbox` | none | `AGENTS.md` |
| `cursor` | `cursor-agent` | `-f` | none | `AGENTS.md` |
| `auggie` | `auggie` | `--allow-indexing` | none | `AGENTS.md` |
| `amp` | `amp` | `--dangerously-allow-all --no-ide` | none | `AGENTS.md` |
| `opencode` | `opencode` | *(OPENCODE_PERMISSION env)* | opencode | `AGENTS.md` |
| `copilot` | `copilot` | `--yolo` | copilot (informational) | `AGENTS.md` |
| `pi` | `pi` | `-e .pi/extensions/gastown-hooks.js` | pi | *(none)* |
| `omp` | `omp` | `--hook .omp/hooks/gastown-hook.ts` | omp | *(none)* |

For Claude specifically, `resolveClaudePath()` (`types.go:663`) checks `PATH`
first, then falls back to `~/.claude/local/claude` (the standard non-alias
installation path that works in non-interactive tmux shells).

---

## Model Selection: From `settings/config.json` to the Model String

The model is not a first-class config field — it is encoded in the `args` array
of a named agent entry. The full trace:

1. `ResolveRoleAgentConfig("witness", townRoot, rigPath)` is called.
2. `townSettings.RoleAgents["witness"]` → `"claude-sonnet"`.
3. `lookupAgentConfig("claude-sonnet", townSettings, nil)` checks
   `townSettings.Agents["claude-sonnet"]`.
4. Finds: `{"command": "claude", "args": ["--dangerously-skip-permissions", "--model", "sonnet"]}`.
5. `fillRuntimeDefaults()` deep-copies and returns that `RuntimeConfig`.
6. `withRoleSettingsFlag()` appends `--settings <path>/.claude/settings.json`.
7. Final `rc.BuildCommand()` → `"claude --dangerously-skip-permissions --model sonnet --settings ..."`.

The `--model` flag value is passed directly to the Claude CLI, which resolves
aliases (`"sonnet"`, `"haiku"`, `"opus"`) to the current model ID internally.
Town-level agents can pin a full model ID (as in the live config above:
`"claude-opus-4-6"`), or use an alias.

---

## Cost Tiers

`internal/config/cost_tier.go`

Three named tiers control the `role_agents` mapping at write-time (via
`gt cost tier set`). At read-time, `tryResolveFromEphemeralTier` reads
`GT_COST_TIER` to apply a tier without persisting config.

| Tier | mayor | deacon | witness | refinery | polecat | crew |
|---|---|---|---|---|---|---|
| `standard` | *(default/opus)* | *(default/opus)* | *(default/opus)* | *(default/opus)* | *(default/opus)* | *(default/opus)* |
| `economy` | claude-sonnet | claude-haiku | claude-sonnet | claude-sonnet | *(default/opus)* | *(default/opus)* |
| `budget` | claude-sonnet | claude-haiku | claude-haiku | claude-haiku | claude-sonnet | claude-sonnet |

Dogs are always Haiku (hardcoded in `resolveRoleAgentConfigCore` as the
first branch — they are cheap infrastructure workers). Tiers do not manage
the `"dog"` or `"boot"` roles.

An explicit non-Claude `role_agents` entry (e.g. `"witness": "gemini"`)
is always respected and overrides any tier setting, because cost tiers only
manage Claude model selection, not agent platform choice.

---

## Role Detection: Path-Based Inference in `gt prime`

`detectRole(cwd, townRoot string) RoleInfo` (`cmd/role.go:242`)

Computes `relPath = filepath.Rel(townRoot, cwd)` and matches path segments:

```
relPath == "."                      → unknown (town root is neutral)
parts[0] == "mayor"                 → mayor
parts[0] == "deacon" && parts[1] == "dogs" && parts[2] == "boot" → boot
parts[0] == "deacon" && parts[1] == "dogs"                        → dog (parts[2] = name)
parts[0] == "deacon"                → deacon
parts[1] == "mayor"                 → mayor
parts[1] == "witness"               → witness (parts[0] = rig)
parts[1] == "refinery"              → refinery
parts[1] == "polecats"              → polecat (parts[2] = name)
parts[1] == "crew"                  → crew (parts[2] = name)
```

`GetRoleWithContext` (`cmd/role.go:170`) first checks `$GT_ROLE`. If set, it
is authoritative. The env value is parsed by `parseRoleString()` which handles:
- Simple: `"mayor"`, `"deacon"`, `"boot"`, `"dog"`
- Compound rig/role: `"gastown/witness"`, `"gastown/refinery"`
- Compound with name: `"gastown/polecats/Alpha"`, `"gastown/crew/max"`

If `GT_ROLE` is set but incomplete (e.g. bare `"crew"` without rig), the gaps
are filled from `GT_RIG`, `GT_CREW`, `GT_POLECAT` env vars, then from cwd
detection. A mismatch between `GT_ROLE` and cwd detection triggers a warning
but `GT_ROLE` wins.

---

## Plugin System

`internal/plugin/` — plugins are automation tasks run by the Deacon during
patrol cycles. They are **not** about agent identity; they are work dispatch
units.

Discovery via `plugin.Scanner`:
- Town-level: `<townRoot>/plugins/<name>/plugin.md`
- Rig-level: `<rig>/plugins/<name>/plugin.md`

Rig-level plugins override town-level plugins with the same name.

Each `plugin.md` has TOML `+++` frontmatter declaring:
- `name`, `description`, `version`
- `[gate]`: type (`cooldown`, `cron`, `condition`, `event`, `manual`), schedule, etc.
- `[tracking]`: labels, digest inclusion
- `[execution]`: timeout, failure notification

Plugin runs are recorded as ephemeral beads (`plugin/recording.go`) via
`bd create --ephemeral`, enabling cooldown gate evaluation across sessions.

The plugin system does not affect agent identity. It is invoked by the Deacon
agent (role `deacon`) after it receives its own identity through the normal
`ResolveRoleAgentConfig` path.

---

## `internal/runtime/runtime.go` — Provider Abstraction Layer

This file serves as the **registration hub** that bridges the config system
with provider-specific implementations. Its `init()` function registers one
`HookInstallerFunc` per agent provider into the global `hookInstallers` map
in `config/agents.go`.

Beyond registration, it provides:

- `EnsureSettingsForRole(settingsDir, workDir, role, rc)` — dispatches to the
  registered installer for `rc.Hooks.Provider`, then provisions slash commands.
- `SessionIDFromEnv()` — multi-source session ID lookup:
  `GT_SESSION_ID_ENV` → `GT_AGENT` preset lookup → `CLAUDE_SESSION_ID` fallback.
- `StartupFallbackCommands(role, rc)` — for agents without hooks: returns
  `["gt prime && gt mail check --inject"]` (or just `gt prime` for interactive roles).
- `GetStartupFallbackInfo(rc)` — computes whether beacon/nudge need special
  handling based on `hasHooks` and `hasPrompt` flags from the RuntimeConfig.
- `RuntimeConfigWithMinDelay(rc, minMs)` — produces a copy with `ReadyDelayMs`
  floored at `minMs`, used during the `gt prime` wait to guarantee wall-clock
  delay rather than prompt-detection short-circuit.

The pattern: config knows about providers through string names; runtime knows
about concrete implementations through imported packages and registers them at
startup without config needing to import them. This avoids circular imports and
keeps provider implementations isolated.

---

## Alternate Providers: Claude vs. Gemini vs. OpenCode vs. Pi

Each provider package registers with `config.RegisterHookInstaller` and
implements a provider-specific settings file:

| Provider | Package | Settings file | Hook style |
|---|---|---|---|
| `claude` | `internal/claude` | `.claude/settings.json` | Executable JSON hooks |
| `gemini` | `internal/gemini` | `.gemini/settings.json` | Executable hooks (installed in workDir) |
| `opencode` | `internal/opencode` | `.opencode/plugins/gastown.js` | JS plugin (no --settings flag) |
| `copilot` | `internal/copilot` | `.copilot/copilot-instructions.md` | Instructions only (informational) |
| `pi` | `internal/pi` | `.pi/extensions/gastown-hooks.js` | JS extension via `-e` flag |
| `omp` | `internal/omp` | `.omp/hooks/gastown-hook.ts` | TS hook via `--hook` flag |

Informational providers (copilot) have `HooksInformational: true`, so
`GetStartupFallbackInfo` knows to send `gt prime` via tmux nudge rather than
relying on an automatic hook.

For codex (no hooks at all), `SupportsHooks: false` and `PromptMode: "none"`,
so the startup flow: sends beacon as nudge, waits `DefaultPrimeWaitMs=2000ms`,
then sends work instructions as a second nudge.

---

## Summary: The Cascade

```
                ┌─────────────────────────────┐
                │    resolveRoleAgentConfigCore │
                └─────────────┬───────────────┘
                              │ priority order
          ┌───────────────────▼──────────────────────┐
          │ 1. GT_COST_TIER env var (ephemeral tier)  │
          │    → CostTierRoleAgents + CostTierAgents  │
          └───────────────────┬──────────────────────┘
                              │ if not handled
          ┌───────────────────▼──────────────────────┐
          │ 2. rigSettings.RoleAgents[role]           │
          │    → rig/settings/config.json             │
          └───────────────────┬──────────────────────┘
                              │ if not set
          ┌───────────────────▼──────────────────────┐
          │ 3. townSettings.RoleAgents[role]          │
          │    → town/settings/config.json            │
          └───────────────────┬──────────────────────┘
                              │ if not set
          ┌───────────────────▼──────────────────────┐
          │ 4. resolveAgentConfigInternal             │
          │    a. rigSettings.Runtime (legacy)        │
          │    b. rigSettings.Agent                   │
          │    c. townSettings.DefaultAgent           │
          │    d. "claude" (hard-coded fallback)      │
          └───────────────────┬──────────────────────┘
                              │ agent name resolved
          ┌───────────────────▼──────────────────────┐
          │ lookupAgentConfig(name)                   │
          │    a. rig/settings/agents.json            │
          │    b. town/settings/agents.json           │
          │    c. built-in AgentPresetInfo registry   │
          │    d. DefaultRuntimeConfig() (claude)     │
          └───────────────────┬──────────────────────┘
                              │
          ┌───────────────────▼──────────────────────┐
          │ withRoleSettingsFlag                      │
          │   append --settings <path> for Claude     │
          └───────────────────────────────────────────┘
```
