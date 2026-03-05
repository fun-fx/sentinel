defmodule Sentinel.ErrorBucket do
  @moduledoc """
  A deduplicated group of related errors.

  Error buckets are the unit of work in Sentinel. Each bucket represents
  a unique error signature with occurrence tracking and sample storage.
  """

  @type signature :: %{
          exception_type: String.t(),
          origin_module: String.t() | nil,
          origin_function: String.t() | nil,
          origin_line: non_neg_integer() | nil,
          message_pattern: String.t()
        }

  @type sample :: %{
          timestamp: DateTime.t(),
          stacktrace: Exception.stacktrace(),
          process_info: map(),
          metadata: map()
        }

  @type state :: :open | :investigating | :reported | :resolved

  @type t :: %__MODULE__{
          id: String.t(),
          signature: signature(),
          first_seen_at: DateTime.t(),
          last_seen_at: DateTime.t(),
          count: non_neg_integer(),
          samples: [sample()],
          state: state(),
          tracker_ref: String.t() | nil,
          provenance_ids: [String.t()]
        }

  @enforce_keys [:id, :signature, :first_seen_at, :last_seen_at, :count]
  defstruct [
    :id,
    :signature,
    :first_seen_at,
    :last_seen_at,
    :tracker_ref,
    count: 1,
    samples: [],
    state: :open,
    provenance_ids: []
  ]

  @max_samples 10

  @spec new(signature(), sample()) :: t()
  def new(signature, sample) do
    now = DateTime.utc_now()

    %__MODULE__{
      id: generate_id(signature),
      signature: signature,
      first_seen_at: now,
      last_seen_at: now,
      count: 1,
      samples: [sample],
      state: :open
    }
  end

  @spec add_occurrence(t(), sample()) :: t()
  def add_occurrence(%__MODULE__{} = bucket, sample) do
    samples =
      [sample | bucket.samples]
      |> Enum.take(@max_samples)

    %{bucket | count: bucket.count + 1, last_seen_at: DateTime.utc_now(), samples: samples}
  end

  @spec signature_key(Exception.t() | term(), Exception.stacktrace()) :: signature()
  def signature_key(error, stacktrace) do
    {mod, fun, line} = extract_origin(stacktrace)

    %{
      exception_type: exception_type(error),
      origin_module: mod,
      origin_function: fun,
      origin_line: line,
      message_pattern: message_pattern(error)
    }
  end

  @spec generate_id(signature()) :: String.t()
  def generate_id(signature) do
    hash =
      signature
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    "eb:#{hash}"
  end

  defp extract_origin([{mod, fun, arity_or_args, info} | _]) do
    line = Keyword.get(info, :line)

    arity =
      case arity_or_args do
        a when is_integer(a) -> a
        args when is_list(args) -> length(args)
        _ -> 0
      end

    {
      if(mod, do: "mod:#{inspect(mod)}"),
      if(mod && fun, do: "fn:#{inspect(mod)}.#{fun}/#{arity}"),
      line
    }
  end

  defp extract_origin(_), do: {nil, nil, nil}

  defp exception_type(%{__struct__: struct}), do: inspect(struct)
  defp exception_type(error) when is_atom(error), do: inspect(error)
  defp exception_type(_), do: "RuntimeError"

  defp message_pattern(%{message: msg}) when is_binary(msg) do
    msg |> String.slice(0, 200) |> String.replace(~r/\b[0-9a-f-]{8,}\b/, "<id>")
  end

  defp message_pattern(error), do: inspect(error) |> String.slice(0, 200)
end
