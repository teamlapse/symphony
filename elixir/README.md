# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls Linear for candidate work
2. Creates a workspace per issue
3. Launches the configured agent profile inside the workspace
4. Sends a workflow prompt to the agent
5. Keeps the executor and optional reviewer agents working on the issue until the work is done

During Codex app-server sessions, Symphony also serves a client-side `linear_graphql` tool so that
repo skills can make raw Linear GraphQL calls.

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Get a new personal token in Linear via Settings → Security & access → Personal API keys, and
   set it as the `LINEAR_API_KEY` environment variable.
3. Copy this directory's `WORKFLOW.md` to your repo.
4. Optionally copy the `commit`, `push`, `pull`, `land`, and `linear` skills to your repo.
   - The `linear` skill expects Symphony's `linear_graphql` app-server tool for raw Linear GraphQL
     operations such as comment editing or upload flows.
5. Customize the copied `WORKFLOW.md` file for your project.
   - To get your project's slug, right-click the project and copy its URL. The slug is part of the
     URL.
   - When creating a workflow based on this repo, note that it depends on non-standard Linear
     issue statuses: "Rework", "Human Review", and "Merging". You can customize them in
     Team Settings → Workflow in Linear.
6. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run On A Mac

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony ./WORKFLOW.md
```

For high-trust local runs where agents need normal macOS filesystem, network, Bazel, and repo-cache
access, configure the agent profile explicitly instead of relying on safer defaults. Example Codex
profile:

```yaml
agents:
  default:
    kind: codex_app_server
    command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=xhigh app-server
    approval_policy: never
    thread_sandbox: danger-full-access
    turn_sandbox_policy:
      type: dangerFullAccess
```

Example Claude CLI profile:

```yaml
agent:
  executor: claude
agents:
  claude:
    kind: exec
    command: claude --print --dangerously-skip-permissions
    prompt_mode: stdin
    turn_timeout_ms: 3600000
```

These settings are intentionally permissive. Use them only in a trusted repo/workspace with
credentials and filesystem access you are comfortable giving to the selected agent.

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
mise exec -- ./bin/symphony /path/to/custom/WORKFLOW.md --port 4000
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
agent session prompt.

Minimal example:

```md
---
tracker:
  kind: linear
  project_slug: "..."
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  executor: default
  max_concurrent_agents: 10
  max_turns: 20
agents:
  default:
    kind: codex_app_server
    command: codex app-server
codex:
  command: codex app-server
---

You are working on a Linear issue {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Notes:

- If a value is missing, defaults are used.
- `agent.executor` names the profile in `agents` used for implementation turns.
- `agents.<name>.kind` can be `codex_app_server` for Codex app-server or `exec` for a generic CLI
  command that receives the prompt by stdin or prompt file.
- `exec` commands receive `SYMPHONY_PROMPT_FILE`, `SYMPHONY_AGENT_PROFILE`,
  `SYMPHONY_AGENT_SESSION_ID`, `SYMPHONY_AGENT_TURN_ID`, and
  `SYMPHONY_AGENT_TURN_SESSION_ID`. CLI wrappers can use the stable
  `SYMPHONY_AGENT_SESSION_ID` to resume provider sessions across continuation and review-feedback
  turns when the provider supports it.
- If `agents.default` is omitted, the legacy `codex` block is used as the default Codex app-server
  profile.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- When `codex.turn_sandbox_policy` is set explicitly, Symphony passes the map through to Codex
  unchanged. Compatibility then depends on the targeted Codex app-server version rather than local
  Symphony validation.
- `agent.max_turns` caps how many back-to-back executor turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- `review.enabled` starts a separate reviewer profile in the same workspace after executor work.
  The reviewer compares the branch to `review.target_branch`, writes
  `.symphony/review/latest.md`, and any findings are fed back to the original executor session
  until the reviewer reports `status: pass` or configured limits are reached.
- While the automated reviewer or review-feedback turn is running, the terminal and web dashboards
  show a runtime stage such as `Agent Review` or `Address Feedback` for that active issue.
- `review.target_branch` defaults to `origin/main`. It can be set to `$SYMPHONY_TARGET_BRANCH`;
  when that env var is unset Symphony falls back to `origin/main`, and bare branch names such as
  `release/2026` are normalized to `origin/release/2026`. Workspace hooks receive the resolved
  target as `SYMPHONY_TARGET_BRANCH`.
- `review.prompt_file` can point at a prompt file next to `WORKFLOW.md` when the review prompt is
  too large to keep in YAML front matter. If both `review.prompt_file` and `review.prompt` are set,
  the file wins.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- For an existing repo with its own worktree lifecycle scripts, call the setup script from
  `hooks.after_create` and the teardown script from `hooks.before_remove`. Symphony runs
  `after_create` with `$PWD` set to the empty per-issue workspace directory and runs
  `before_remove` before deleting the workspace for a terminal issue.
- `hooks.env_passthrough` forwards selected host environment variables, such as
  `BUILDBUDDY_API_KEY`, into hook scripts. Hooks also receive `SYMPHONY_WORKSPACE`,
  `SYMPHONY_HOOK_NAME`, `SYMPHONY_ISSUE_ID`, `SYMPHONY_ISSUE_IDENTIFIER`, and
  `SYMPHONY_TARGET_BRANCH`.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- `tracker.api_key` reads from `LINEAR_API_KEY` when unset or when value is `$LINEAR_API_KEY`.
- `tracker.project_slug` can also be set to `$LINEAR_PROJECT_SLUG` or another explicit env var
  reference.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.

```yaml
tracker:
  api_key: $LINEAR_API_KEY
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
codex:
  command: "$CODEX_BIN --config 'model=\"gpt-5.5\"' app-server"
```

Existing repository worktree example:

```yaml
workspace:
  root: ~/code/acme-workspaces
hooks:
  env_passthrough: [BUILDBUDDY_API_KEY]
  after_create: |
    /Users/me/code/acme/scripts/setup-agent-worktree "$PWD" "{{ issue.identifier }}"
  before_remove: |
    /Users/me/code/acme/scripts/teardown-agent-worktree "$PWD" "{{ issue.identifier }}"
```

The setup script should be idempotent enough to tolerate a partially prepared workspace after a
failed run. The teardown script should tolerate missing build artifacts and already-removed
worktrees.

- If `WORKFLOW.md` is missing or has invalid YAML at startup, Symphony does not boot.
- If a later reload fails, Symphony keeps running with the last known good workflow and logs the
  reload error until the file is fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

Run the real external end-to-end test only when you want Symphony to create disposable Linear
resources and launch a real `codex app-server` session:

```bash
cd elixir
export LINEAR_API_KEY=...
make e2e
```

Optional environment variables:

- `SYMPHONY_LIVE_LINEAR_TEAM_KEY` defaults to `SYME2E`
- `SYMPHONY_LIVE_SSH_WORKER_HOSTS` uses those SSH hosts when set, as a comma-separated list

`make e2e` runs two live scenarios:
- one with a local worker
- one with SSH workers

If `SYMPHONY_LIVE_SSH_WORKER_HOSTS` is unset, the SSH scenario uses `docker compose` to start two
disposable SSH workers on `localhost:<port>`. The live test generates a temporary SSH keypair,
mounts the host `~/.codex/auth.json` into each worker, verifies that Symphony can talk to them
over real SSH, then runs the same orchestration flow against those worker addresses. This keeps
the transport representative without depending on long-lived external machines.

Set `SYMPHONY_LIVE_SSH_WORKER_HOSTS` if you want `make e2e` to target real SSH hosts instead.

The live test creates a temporary Linear project and issue, writes a temporary `WORKFLOW.md`, runs
a real agent turn, verifies the workspace side effect, requires Codex to comment on and close the
Linear issue, then marks the project completed so the run remains visible in Linear.

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Symphony repo, and ask it to set things up for
you.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
