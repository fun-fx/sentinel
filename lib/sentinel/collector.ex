defmodule Sentinel.Collector do
  @moduledoc """
  Logger handler that captures errors and crash reports.

  Attaches to the Elixir Logger system and forwards errors to the Deduplicator.
  Also captures OTP crash reports and SASL reports.

  ## Setup

  The collector is automatically installed when Sentinel starts.
  Manual installation:

      Sentinel.Collector.install()
  """

  require Logger

  @handler_id :sentinel_collector

  @spec install() :: :ok | {:error, term()}
  def install do
    config = %{level: :error}

    case :logger.add_handler(@handler_id, __MODULE__, config) do
      :ok -> :ok
      {:error, {:already_exist, _}} -> :ok
      error -> error
    end
  end

  @spec uninstall() :: :ok | {:error, term()}
  def uninstall do
    :logger.remove_handler(@handler_id)
  end

  @doc false
  def log(%{level: level, msg: msg, meta: meta}, _config) when level in [:error, :critical, :alert, :emergency] do
    try do
      case extract_error(msg, meta) do
        {:ok, error, stacktrace, extra_meta} ->
          handle_error(error, stacktrace, extra_meta)

        :skip ->
          :ok
      end
    rescue
      _ -> :ok
    end
  end

  def log(_event, _config), do: :ok

  @spec handle_error(Exception.t() | term(), Exception.stacktrace(), map()) :: :ok
  def handle_error(error, stacktrace, metadata \\ %{}) do
    Sentinel.Deduplicator.record_error(error, stacktrace, metadata)
  end

  defp extract_error({:string, message}, meta) do
    if crash_report?(message) do
      extract_crash_report(message, meta)
    else
      error = %RuntimeError{message: to_string(message)}
      stacktrace = Map.get(meta, :stacktrace, [])
      {:ok, error, stacktrace, extract_meta(meta)}
    end
  end

  defp extract_error({:report, report}, meta) when is_map(report) do
    case report do
      %{reason: {error, stacktrace}} when is_list(stacktrace) ->
        {:ok, error, stacktrace, extract_meta(meta)}

      %{reason: error} ->
        {:ok, error, [], extract_meta(meta)}

      _ ->
        :skip
    end
  end

  defp extract_error({:report, report}, meta) when is_list(report) do
    case Keyword.get(report, :reason) do
      {error, stacktrace} when is_list(stacktrace) ->
        {:ok, error, stacktrace, extract_meta(meta)}

      _ ->
        :skip
    end
  end

  defp extract_error(_, _), do: :skip

  defp crash_report?(message) do
    msg = to_string(message)
    String.contains?(msg, "** (") or String.contains?(msg, "Process") or String.contains?(msg, "GenServer")
  end

  defp extract_crash_report(message, meta) do
    error = %RuntimeError{message: to_string(message)}
    stacktrace = Map.get(meta, :stacktrace, [])
    {:ok, error, stacktrace, extract_meta(meta)}
  end

  defp extract_meta(meta) do
    meta
    |> Map.take([:pid, :registered_name, :module, :function, :file, :line, :request_id, :domain])
    |> Map.new(fn {k, v} -> {k, inspect_safe(v)} end)
  end

  defp inspect_safe(v) when is_binary(v), do: v
  defp inspect_safe(v) when is_atom(v), do: Atom.to_string(v)
  defp inspect_safe(v) when is_integer(v), do: Integer.to_string(v)
  defp inspect_safe(v) when is_pid(v), do: inspect(v)
  defp inspect_safe(v), do: inspect(v, limit: 5)
end
