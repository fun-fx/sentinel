defmodule Sentinel.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Sentinel.enabled?() do
        base_children() ++ optional_children()
      else
        []
      end

    opts = [strategy: :one_for_one, name: Sentinel.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp base_children do
    [
      Sentinel.Deduplicator,
      {Task.Supervisor, name: Sentinel.AgentSupervisor}
    ]
  end

  defp optional_children do
    tracker = if Sentinel.tracker_configured?(), do: [Sentinel.TrackerServer], else: []
    watcher = if Sentinel.board_watcher_enabled?(), do: [Sentinel.BoardWatcher], else: []
    tracker ++ watcher
  end
end
