defmodule Sentinel.TrackerServer do
  @moduledoc """
  Manages tracker operations: creating issues from error buckets,
  deduplicating against existing issues, and updating occurrence counts.
  """

  use GenServer

  require Logger

  alias Sentinel.{ErrorBucket, Tracker}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec create_or_update(ErrorBucket.t()) :: :ok
  def create_or_update(%ErrorBucket{} = bucket) do
    GenServer.cast(__MODULE__, {:create_or_update, bucket})
  end

  @impl true
  def init(_opts) do
    {:ok, %{known_refs: %{}}}
  end

  @impl true
  def handle_cast({:create_or_update, bucket}, state) do
    case Map.get(state.known_refs, bucket.id) do
      nil ->
        case Tracker.call(:find_existing, [bucket]) do
          {:ok, ref} ->
            Tracker.call(:update_issue, [ref, %{count: bucket.count}])
            {:noreply, %{state | known_refs: Map.put(state.known_refs, bucket.id, ref)}}

          :not_found ->
            case Tracker.call(:create_issue, [bucket]) do
              {:ok, ref} ->
                Logger.info("Sentinel created tracker issue ref=#{ref} for bucket=#{bucket.id}")
                {:noreply, %{state | known_refs: Map.put(state.known_refs, bucket.id, ref)}}

              {:error, reason} ->
                Logger.warning("Sentinel failed to create issue: #{inspect(reason)}")
                {:noreply, state}
            end

          {:error, reason} ->
            Logger.warning("Sentinel failed to check existing issues: #{inspect(reason)}")
            {:noreply, state}
        end

      ref ->
        Tracker.call(:update_issue, [ref, %{count: bucket.count}])
        {:noreply, state}
    end
  end
end
