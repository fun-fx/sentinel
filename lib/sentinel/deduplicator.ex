defmodule Sentinel.Deduplicator do
  @moduledoc """
  Groups errors by signature, tracks frequency, and stores bounded samples.

  Each unique error signature maps to an `ErrorBucket`. When an error is
  recorded, the deduplicator either creates a new bucket or adds to an existing one.
  When a bucket crosses a configured threshold, it dispatches to the agent.
  """

  use GenServer

  alias Sentinel.ErrorBucket

  @type state :: %{
          buckets: %{String.t() => ErrorBucket.t()},
          signature_index: %{term() => String.t()}
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec record_error(Exception.t() | term(), Exception.stacktrace(), map()) :: :ok
  def record_error(error, stacktrace, metadata \\ %{}) do
    GenServer.cast(__MODULE__, {:record_error, error, stacktrace, metadata})
  end

  @spec list_buckets() :: [ErrorBucket.t()]
  def list_buckets do
    GenServer.call(__MODULE__, :list_buckets)
  end

  @spec get_bucket(String.t()) :: {:ok, ErrorBucket.t()} | :not_found
  def get_bucket(bucket_id) do
    GenServer.call(__MODULE__, {:get_bucket, bucket_id})
  end

  @spec update_bucket_state(String.t(), ErrorBucket.state()) :: :ok | :not_found
  def update_bucket_state(bucket_id, new_state) do
    GenServer.call(__MODULE__, {:update_bucket_state, bucket_id, new_state})
  end

  @impl true
  def init(_opts) do
    {:ok, %{buckets: %{}, signature_index: %{}}}
  end

  @impl true
  def handle_cast({:record_error, error, stacktrace, metadata}, state) do
    signature = ErrorBucket.signature_key(error, stacktrace)
    bucket_id = ErrorBucket.generate_id(signature)

    sample = %{
      timestamp: DateTime.utc_now(),
      stacktrace: stacktrace,
      process_info: Map.take(metadata, [:pid, :registered_name]),
      metadata: metadata
    }

    {bucket, is_new} =
      case Map.get(state.buckets, bucket_id) do
        nil ->
          {ErrorBucket.new(signature, sample), true}

        existing ->
          {ErrorBucket.add_occurrence(existing, sample), false}
      end

    new_state = %{
      state
      | buckets: Map.put(state.buckets, bucket_id, bucket),
        signature_index: Map.put(state.signature_index, signature, bucket_id)
    }

    maybe_dispatch(bucket, is_new)

    {:noreply, new_state}
  end

  @impl true
  def handle_call(:list_buckets, _from, state) do
    buckets = Map.values(state.buckets)
    {:reply, buckets, state}
  end

  def handle_call({:get_bucket, bucket_id}, _from, state) do
    case Map.get(state.buckets, bucket_id) do
      nil -> {:reply, :not_found, state}
      bucket -> {:reply, {:ok, bucket}, state}
    end
  end

  def handle_call({:update_bucket_state, bucket_id, new_bucket_state}, _from, state) do
    case Map.get(state.buckets, bucket_id) do
      nil ->
        {:reply, :not_found, state}

      bucket ->
        updated = %{bucket | state: new_bucket_state}
        new_state = %{state | buckets: Map.put(state.buckets, bucket_id, updated)}
        {:reply, :ok, new_state}
    end
  end

  defp maybe_dispatch(bucket, is_new) do
    threshold = investigate_threshold()

    if Sentinel.agent_enabled?() and should_dispatch?(bucket, is_new, threshold) do
      Sentinel.Agent.dispatch_error(bucket)
    end
  end

  defp should_dispatch?(bucket, true, 1), do: bucket.state == :open
  defp should_dispatch?(bucket, _is_new, threshold), do: bucket.count == threshold and bucket.state == :open

  defp investigate_threshold do
    :sentinel
    |> Application.get_env(:agent, [])
    |> Keyword.get(:investigate_threshold, 1)
  end
end
