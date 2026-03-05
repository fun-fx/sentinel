defmodule Sentinel.BoardWatcher do
  @moduledoc """
  Polls the tracker board on a cadence, self-assigns eligible issues,
  and dispatches them to the Codex agent for execution.

  ## Configuration

      config :sentinel,
        board_watcher: [
          enabled: true,
          poll_interval_ms: 60_000,
          pickup_states: ["Todo", "Ready"],
          in_progress_state: "In Progress",
          done_state: "Done",
          labels: ["sentinel"],
          max_concurrent: 2,
          assignee: "me"
        ]
  """

  use GenServer

  require Logger

  alias Sentinel.Tracker

  @default_poll_interval 60_000
  @default_pickup_states ["Todo"]
  @default_in_progress "In Progress"
  @default_done "Done"
  @default_max_concurrent 2

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    config = board_config()
    poll_interval = Keyword.get(config, :poll_interval_ms, @default_poll_interval)

    state = %{
      config: config,
      active_issues: MapSet.new(),
      assignee_id: nil
    }

    Process.send_after(self(), :poll, poll_interval)
    send(self(), :resolve_identity)

    {:ok, state}
  end

  @impl true
  def handle_info(:resolve_identity, state) do
    assignee_id = resolve_assignee_id(state.config)
    {:noreply, %{state | assignee_id: assignee_id}}
  end

  def handle_info(:poll, state) do
    config = state.config
    poll_interval = Keyword.get(config, :poll_interval_ms, @default_poll_interval)

    state = do_poll(state)

    Process.send_after(self(), :poll, poll_interval)
    {:noreply, state}
  end

  def handle_info({:agent_completed, issue_id, result}, state) do
    config = state.config
    done_state = Keyword.get(config, :done_state, @default_done)

    case result do
      {:ok, agent_result} ->
        comment = Map.get(agent_result, :comment_body, "Sentinel completed this task.")
        Tracker.call(:add_comment, [issue_id, comment])
        Tracker.call(:transition_issue, [issue_id, done_state])
        Logger.info("Sentinel completed board issue=#{issue_id}")

      {:error, reason} ->
        Tracker.call(:add_comment, [issue_id, "Sentinel encountered an error: #{inspect(reason)}"])
        Logger.warning("Sentinel failed on board issue=#{issue_id}: #{inspect(reason)}")
    end

    {:noreply, %{state | active_issues: MapSet.delete(state.active_issues, issue_id)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp do_poll(state) do
    config = state.config
    max_concurrent = Keyword.get(config, :max_concurrent, @default_max_concurrent)
    available_slots = max_concurrent - MapSet.size(state.active_issues)

    if available_slots <= 0 do
      state
    else
      filter_opts = [
        pickup_states: Keyword.get(config, :pickup_states, @default_pickup_states),
        labels: Keyword.get(config, :labels, [])
      ]

      case Tracker.call(:fetch_available_issues, [filter_opts]) do
        {:ok, issues} ->
          issues
          |> Enum.reject(fn i -> MapSet.member?(state.active_issues, i.id) end)
          |> Enum.take(available_slots)
          |> Enum.reduce(state, &pickup_issue(&1, &2))

        {:error, reason} ->
          Logger.warning("Sentinel board poll failed: #{inspect(reason)}")
          state
      end
    end
  end

  defp pickup_issue(issue, state) do
    in_progress = Keyword.get(state.config, :in_progress_state, @default_in_progress)

    if state.assignee_id do
      Tracker.call(:assign_issue, [issue.id, state.assignee_id])
    end

    Tracker.call(:transition_issue, [issue.id, in_progress])

    Logger.info("Sentinel picked up board issue=#{issue.identifier} title=#{issue.title}")

    watcher_pid = self()

    Task.Supervisor.start_child(Sentinel.AgentSupervisor, fn ->
      result = Sentinel.Agent.dispatch_board_issue(issue)
      send(watcher_pid, {:agent_completed, issue.id, result})
    end)

    %{state | active_issues: MapSet.put(state.active_issues, issue.id)}
  end

  defp resolve_assignee_id(config) do
    case Keyword.get(config, :assignee) do
      "me" ->
        case Tracker.call(:fetch_available_issues, [[]]) do
          _ ->
            with {_mod, opts} <- Tracker.adapter(),
                 api_key when is_binary(api_key) <- Keyword.get(opts, :api_key),
                 client <- Linear.client(api_key: api_key),
                 {:ok, viewer} <- Linear.viewer(client) do
              viewer["id"]
            else
              _ -> nil
            end
        end

      id when is_binary(id) ->
        id

      _ ->
        nil
    end
  end

  defp board_config do
    Application.get_env(:sentinel, :board_watcher, [])
  end
end
