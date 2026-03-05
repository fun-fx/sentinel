if Code.ensure_loaded?(Phoenix.LiveDashboard.PageBuilder) do
  defmodule Sentinel.Dashboard do
    @moduledoc """
    Phoenix LiveDashboard page for Sentinel.

    Shows error buckets, agent status, and board watcher state.

    ## Setup

    Add to your LiveDashboard router:

        live_dashboard "/dashboard",
          additional_pages: [
            sentinel: Sentinel.Dashboard
          ]

    Requires `phoenix_live_dashboard ~> 0.8` as a dependency.
    """

    use Phoenix.LiveDashboard.PageBuilder

    @impl true
    def menu_link(_, _) do
      {:ok, "Sentinel"}
    end

    @impl true
    def render(assigns) do
      status = Sentinel.status()
      buckets = Sentinel.error_buckets()

      assigns =
        assigns
        |> Map.put(:status, status)
        |> Map.put(:buckets, sort_buckets(buckets))

      ~H"""
      <h5>Sentinel Agent</h5>
      <div class="row">
        <div class="col-sm-6">
          <div class="card mb-4">
            <div class="card-body">
              <dl>
                <dt>Enabled</dt><dd><%= @status.enabled %></dd>
                <dt>Environment</dt><dd><%= @status.environment %></dd>
                <dt>Error Buckets</dt><dd><%= @status.error_bucket_count %></dd>
                <dt>Tracker</dt><dd><%= @status.tracker_configured %></dd>
                <dt>Agent</dt><dd><%= @status.agent_enabled %></dd>
                <dt>Board Watcher</dt><dd><%= @status.board_watcher_enabled %></dd>
              </dl>
            </div>
          </div>
        </div>
      </div>

      <h5>Error Buckets (<%= length(@buckets) %>)</h5>
      <div class="card">
        <div class="card-body">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Exception</th>
                <th>Message</th>
                <th>Origin</th>
                <th>Count</th>
                <th>State</th>
                <th>Last Seen</th>
              </tr>
            </thead>
            <tbody>
              <%= for b <- @buckets do %>
              <tr>
                <td><code><%= b.signature.exception_type %></code></td>
                <td><%= String.slice(b.signature.message_pattern, 0, 60) %></td>
                <td><code><%= b.signature.origin_function || b.signature.origin_module || "-" %></code></td>
                <td><%= b.count %></td>
                <td><%= b.state %></td>
                <td><%= format_time(b.last_seen_at) %></td>
              </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </div>
      """
    end

    defp sort_buckets(buckets) do
      Enum.sort_by(buckets, & &1.last_seen_at, {:desc, DateTime})
    end

    defp format_time(nil), do: "-"

    defp format_time(%DateTime{} = dt) do
      Calendar.strftime(dt, "%H:%M:%S UTC")
    end
  end
end
