defmodule Sentinel do
  @moduledoc """
  In-process autonomous dev agent for Elixir.

  Sentinel captures runtime errors, deduplicates them, creates tracker issues,
  and optionally invokes Codex to investigate and fix. It also polls the tracker
  board, self-assigns eligible work, and starts executing it.

  ## Quick start (error collection)

      # mix.exs
      {:sentinel, "~> 0.1.0"}

      # config/dev.exs
      config :sentinel, enabled: true

  ## With ticket creation

      config :sentinel,
        tracker: {Sentinel.Tracker.Linear, api_key: System.get_env("LINEAR_API_KEY")},
        tracker_project: "MY-PROJECT"

  ## With autonomous agent

      config :sentinel,
        agent: [enabled: true, command: "codex app-server", approval_policy: "never"],
        board_watcher: [enabled: true, pickup_states: ["Todo"], labels: ["sentinel"]]
  """

  alias Sentinel.{Collector, Deduplicator, ErrorBucket}

  @doc "Manually report an error to Sentinel."
  @spec report(Exception.t() | term(), keyword()) :: :ok
  def report(error, opts \\ []) do
    stacktrace = Keyword.get(opts, :stacktrace, [])
    metadata = Keyword.get(opts, :metadata, %{})
    Collector.handle_error(error, stacktrace, metadata)
  end

  @doc "Get all current error buckets."
  @spec error_buckets() :: [ErrorBucket.t()]
  def error_buckets do
    Deduplicator.list_buckets()
  end

  @doc "Get Sentinel's current status."
  @spec status() :: map()
  def status do
    %{
      enabled: enabled?(),
      environment: environment(),
      error_bucket_count: length(error_buckets()),
      tracker_configured: tracker_configured?(),
      agent_enabled: agent_enabled?(),
      board_watcher_enabled: board_watcher_enabled?()
    }
  end

  @doc "Check if Sentinel is enabled."
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:sentinel, :enabled, false)
  end

  @doc false
  @spec environment() :: atom()
  def environment do
    Application.get_env(:sentinel, :environment, Mix.env())
  rescue
    _ -> :prod
  end

  @doc false
  @spec tracker_configured?() :: boolean()
  def tracker_configured? do
    Application.get_env(:sentinel, :tracker) != nil
  end

  @doc false
  @spec agent_enabled?() :: boolean()
  def agent_enabled? do
    get_in(Application.get_env(:sentinel, :agent, []), [:enabled]) == true
  end

  @doc false
  @spec board_watcher_enabled?() :: boolean()
  def board_watcher_enabled? do
    get_in(Application.get_env(:sentinel, :board_watcher, []), [:enabled]) == true
  end
end
