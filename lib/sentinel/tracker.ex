defmodule Sentinel.Tracker do
  @moduledoc """
  Behaviour for issue tracker adapters.

  Covers both the write path (errors -> tickets) and the read path
  (board -> work items). Implementations include `Sentinel.Tracker.Linear`
  and `Sentinel.Tracker.GitHub`.
  """

  alias Sentinel.ErrorBucket

  @type issue_ref :: String.t()
  @type issue :: %{
          id: String.t(),
          identifier: String.t(),
          title: String.t(),
          description: String.t() | nil,
          state: String.t(),
          labels: [String.t()],
          url: String.t() | nil
        }
  @type filter_opts :: keyword()

  # Write path: errors -> tickets
  @callback create_issue(ErrorBucket.t()) :: {:ok, issue_ref()} | {:error, term()}
  @callback update_issue(issue_ref(), map()) :: :ok | {:error, term()}
  @callback find_existing(ErrorBucket.t()) :: {:ok, issue_ref()} | :not_found | {:error, term()}

  # Read path: board -> work items
  @callback fetch_available_issues(filter_opts()) :: {:ok, [issue()]} | {:error, term()}
  @callback assign_issue(String.t(), String.t()) :: :ok | {:error, term()}
  @callback transition_issue(String.t(), String.t()) :: :ok | {:error, term()}
  @callback add_comment(String.t(), String.t()) :: :ok | {:error, term()}

  @doc "Get the configured tracker adapter module and its options."
  @spec adapter() :: {module(), keyword()} | nil
  def adapter do
    case Application.get_env(:sentinel, :tracker) do
      {mod, opts} when is_atom(mod) -> {mod, opts}
      _ -> nil
    end
  end

  @doc "Call a tracker operation using the configured adapter."
  @spec call(atom(), [term()]) :: term()
  def call(operation, args) do
    case adapter() do
      {mod, _opts} -> apply(mod, operation, args)
      nil -> {:error, :no_tracker_configured}
    end
  end
end
