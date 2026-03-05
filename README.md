# Sentinel

An in-process autonomous dev agent for Elixir. Captures runtime errors, creates
tracker issues, picks up board work, and runs Codex to investigate and fix.

Built in four layers that can be adopted incrementally -- use just error collection,
add tracker integration, or go full autonomous with the board watcher and agent.

## Installation

Add to your `mix.exs`:

```elixir
def deps do
  [
    {:sentinel, "~> 0.1"},
    {:plug, "~> 1.15", optional: true},       # for Sentinel.Plug
    {:provenance, "~> 0.1", optional: true}    # enriches agent context
  ]
end
```

Sentinel depends on [`codex_app_server`](https://github.com/fun-fx/codex_app_server)
and [`linear_client`](https://github.com/fun-fx/linear_client) (both pulled
automatically).

## Architecture

```
                     +------------------+
                     | Your Application |
                     +--------+---------+
                              |
               Logger errors / Sentinel.report/2
                              |
+-----------------------------v-----------------------------+
|  Layer 1: Error Intelligence                              |
|                                                           |
|  Collector ---------> Deduplicator ---------> ErrorBucket |
|  (Logger handler)     (GenServer)             (signature, |
|                                                samples)   |
+-----------------------------+-----------------------------+
                              |
               threshold reached / manual
                              |
+-----------------------------v-----------------------------+
|  Layer 2: Tracker Integration                             |
|                                                           |
|  TrackerServer -----> Tracker behaviour                   |
|  (create/update)      |                                   |
|                       +-> Tracker.Linear (Linear API)     |
|                       +-> (your custom adapter)           |
+-----------------------------+-----------------------------+
                              |
               issues on board labeled "sentinel"
                              |
+-----------------------------v-----------------------------+
|  Layer 3: Board Watcher                                   |
|                                                           |
|  BoardWatcher (GenServer, polls on interval)              |
|  - Fetches issues in pickup states                        |
|  - Self-assigns, transitions to "In Progress"             |
|  - Dispatches to Agent                                    |
+-----------------------------+-----------------------------+
                              |
                              v
+-----------------------------------------------------------+
|  Layer 4: Agent                                           |
|                                                           |
|  Agent ---------> CodexAppServer.run/3                    |
|  (dispatch)       (JSON-RPC to codex app-server)          |
|                                                           |
|  Prompt ---------> builds investigation/task prompts      |
|  (optional)        enriched with Provenance data          |
+-----------------------------------------------------------+
```

## Configuration

### Layer 1 -- Error Collection

Captures Logger errors and groups them by signature. No external dependencies.

```elixir
# config/config.exs
config :sentinel,
  enabled: true,
  workspace: File.cwd!()
```

Install the Logger handler in your application startup:

```elixir
# lib/my_app/application.ex
def start(_type, _args) do
  Sentinel.Collector.install()
  # ...
end
```

Or report errors manually:

```elixir
Sentinel.report(error,
  stacktrace: __STACKTRACE__,
  metadata: %{request_id: conn.assigns[:request_id]}
)
```

Optional Plug integration for Phoenix/Plug apps:

```elixir
# lib/my_app_web/endpoint.ex
plug Sentinel.Plug
```

Query collected errors:

```elixir
Sentinel.error_buckets()
# => [%Sentinel.ErrorBucket{id: "eb:a1b2c3d4", signature: %{...}, count: 7, ...}]

Sentinel.status()
# => %{enabled: true, bucket_count: 3, tracker: :configured, agent: :disabled, ...}
```

### Layer 2 -- Tracker Integration

Creates and updates issues in Linear (or any tracker implementing the
`Sentinel.Tracker` behaviour).

```elixir
# config/config.exs
config :sentinel,
  tracker: {Sentinel.Tracker.Linear,
    api_key: System.get_env("LINEAR_API_KEY"),
    team_id: "YOUR-TEAM-UUID",
    project_slug: "MY-PROJECT"
  }
```

Issues are created automatically when error buckets are dispatched. You can also
create them manually:

```elixir
bucket = Sentinel.Deduplicator.get_bucket("eb:a1b2c3d4")
Sentinel.TrackerServer.create_or_update(bucket)
```

#### Custom Tracker Adapter

Implement the `Sentinel.Tracker` behaviour:

```elixir
defmodule MyApp.Tracker.GitHub do
  @behaviour Sentinel.Tracker

  @impl true
  def create_issue(bucket), do: ...

  @impl true
  def update_issue(ref, attrs), do: ...

  @impl true
  def find_existing(bucket), do: ...

  @impl true
  def fetch_available_issues(opts), do: ...

  @impl true
  def assign_issue(id, assignee), do: ...

  @impl true
  def transition_issue(id, state), do: ...

  @impl true
  def add_comment(id, body), do: ...
end
```

```elixir
config :sentinel,
  tracker: {MyApp.Tracker.GitHub, repo: "org/repo", token: "..."}
```

### Layer 3 -- Board Watcher

Polls the tracker board for issues labeled "sentinel", self-assigns them, and
dispatches to the agent.

```elixir
# config/config.exs
config :sentinel,
  board_watcher: [
    enabled: true,
    poll_interval_ms: 60_000,
    pickup_states: ["Todo", "Ready"],
    in_progress_state: "In Progress",
    done_state: "Done",
    labels: ["sentinel"],
    max_concurrent: 2,
    assignee: "me"                    # "me" resolves to the API key's user
  ]
```

The watcher runs as a supervised GenServer. For each eligible issue it:

1. Assigns the issue to the configured assignee
2. Transitions it to the in-progress state
3. Dispatches to `Sentinel.Agent.dispatch_board_issue/1`
4. Posts a comment with the result and transitions to done

### Layer 4 -- Agent

Runs Codex via `codex_app_server` to investigate errors or execute board tasks.

```elixir
# config/config.exs
config :sentinel,
  agent: [
    enabled: true,
    command: "codex app-server",
    approval_policy: "never",
    max_concurrent: 2,
    investigate_threshold: 1           # dispatch after N error occurrences
  ]
```

The agent builds a prompt from the error bucket or board issue, optionally enriched
with provenance data (related modules, tables, dependency graph), and sends it to
Codex for investigation.

```elixir
# Dispatched automatically by Deduplicator when threshold is reached.
# Can also be triggered manually:
Sentinel.Agent.dispatch_error(bucket)
Sentinel.Agent.dispatch_board_issue(issue)
```

## Provenance Integration

When [`provenance`](https://github.com/fun-fx/provenance) is installed, Sentinel
enriches agent prompts with lineage data:

- Related modules and their architectural layers
- Database tables touched by the failing code
- Module dependency graph excerpt
- Process context at the time of the error

This gives the agent significantly more context for investigation. No additional
configuration is needed -- Sentinel detects provenance automatically.

## Full Configuration Example

```elixir
# config/dev.exs
config :sentinel,
  enabled: true,
  workspace: File.cwd!(),

  tracker: {Sentinel.Tracker.Linear,
    api_key: System.get_env("LINEAR_API_KEY"),
    team_id: "YOUR-TEAM-UUID",
    project_slug: "MY-PROJECT"
  },

  board_watcher: [
    enabled: true,
    poll_interval_ms: 60_000,
    pickup_states: ["Todo", "Ready"],
    in_progress_state: "In Progress",
    done_state: "Done",
    labels: ["sentinel"],
    max_concurrent: 2,
    assignee: "me"
  ],

  agent: [
    enabled: true,
    command: "codex app-server",
    approval_policy: "never",
    max_concurrent: 2,
    investigate_threshold: 1
  ]
```

```elixir
# config/prod.exs -- conservative defaults
config :sentinel,
  enabled: true,
  workspace: File.cwd!(),

  tracker: {Sentinel.Tracker.Linear,
    api_key: System.get_env("LINEAR_API_KEY"),
    team_id: "YOUR-TEAM-UUID",
    project_slug: "MY-PROJECT"
  },

  board_watcher: [enabled: false],
  agent: [enabled: false]
```

## Environment Behavior

| Capability | dev | staging | prod |
|------------|-----|---------|------|
| Error collection | yes | yes | yes |
| Deduplication | yes | yes | yes |
| Ticket creation | yes | yes | yes |
| Board watching | yes | yes | no (default) |
| Agent investigation | yes | yes | no |
| Code changes / PRs | yes | configurable | no |

## Supervision Tree

Sentinel starts the following processes under its application supervisor:

- `Sentinel.Deduplicator` -- always started
- `Sentinel.AgentSupervisor` (`Task.Supervisor`) -- always started
- `Sentinel.TrackerServer` -- started when tracker is configured
- `Sentinel.BoardWatcher` -- started when board_watcher is enabled

`Sentinel.Collector` is not auto-started. Call `Sentinel.Collector.install/0`
in your application's `start/2` to attach the Logger handler.

## Specification

Sentinel implements the [Sentinel Specification](https://github.com/fun-fx/sentinel_spec)
(Draft v1), a language-agnostic contract for provenance IDs, error buckets, tracker
adapters, and agent dispatch.

## License

MIT -- see [LICENSE](LICENSE).
