defmodule Sentinel.Plug do
  @moduledoc """
  Optional Phoenix/Plug middleware that captures request context for errors.

  Adds request metadata (method, path, request_id) to Logger metadata so
  that when errors occur during request processing, the Collector captures
  the full request context.

  ## Usage

      # In your endpoint.ex
      plug Sentinel.Plug
  """

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    request_id =
      Plug.Conn.get_resp_header(conn, "x-request-id")
      |> List.first()
      |> Kernel.||(generate_request_id())

    Logger.metadata(
      sentinel_request_id: request_id,
      sentinel_method: conn.method,
      sentinel_path: conn.request_path
    )

    if Code.ensure_loaded?(Provenance) do
      Provenance.put_context(
        request_id: request_id,
        method: conn.method,
        path: conn.request_path
      )
    end

    conn
  end

  defp generate_request_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
