defmodule Sentinel.Tracker.Linear do
  @moduledoc """
  Linear issue tracker adapter for Sentinel.

  Uses the `linear_client` package for all API operations.

  ## Configuration

      config :sentinel,
        tracker: {Sentinel.Tracker.Linear,
          api_key: System.get_env("LINEAR_API_KEY"),
          team_id: "TEAM-UUID",
          project_slug: "MY-PROJECT"
        }
  """

  @behaviour Sentinel.Tracker

  alias Sentinel.ErrorBucket

  @impl true
  def create_issue(%ErrorBucket{} = bucket) do
    with {:ok, client} <- client(),
         {:ok, team_id} <- team_id() do
      attrs = %{
        "teamId" => team_id,
        "title" => "[Sentinel] #{bucket.signature.exception_type}: #{bucket.signature.message_pattern}",
        "description" => format_issue_body(bucket),
        "labelIds" => resolve_label_ids(client)
      }

      case Linear.create_issue(client, attrs) do
        {:ok, issue} -> {:ok, issue["id"]}
        error -> error
      end
    end
  end

  @impl true
  def update_issue(issue_id, update) do
    with {:ok, client} <- client() do
      body = Map.get(update, :comment, "Sentinel: occurrence count updated to #{Map.get(update, :count, "?")}")
      Linear.create_comment(client, issue_id, body)
      :ok
    end
  end

  @impl true
  def find_existing(%ErrorBucket{} = bucket) do
    with {:ok, client} <- client(),
         {:ok, issues} <-
           Linear.list_issues(client,
             state_names: open_states(),
             first: 10
           ) do
      title_prefix = "[Sentinel] #{bucket.signature.exception_type}"

      case Enum.find(issues, fn i -> String.starts_with?(i["title"] || "", title_prefix) end) do
        nil -> :not_found
        issue -> {:ok, issue["id"]}
      end
    end
  end

  @impl true
  def fetch_available_issues(opts) do
    with {:ok, client} <- client() do
      filter_opts =
        []
        |> maybe_add(:state_names, Keyword.get(opts, :pickup_states))
        |> maybe_add(:team_id, Keyword.get(opts, :team_id, team_id_value()))

      case Linear.list_issues(client, filter_opts) do
        {:ok, issues} ->
          labels_filter = Keyword.get(opts, :labels, [])
          filtered = filter_by_labels(issues, labels_filter)
          {:ok, normalize_issues(filtered)}

        error ->
          error
      end
    end
  end

  @impl true
  def assign_issue(issue_id, assignee_id) do
    with {:ok, client} <- client() do
      case Linear.update_issue(client, issue_id, %{"assigneeId" => assignee_id}) do
        {:ok, _} -> :ok
        error -> error
      end
    end
  end

  @impl true
  def transition_issue(issue_id, state_name) do
    with {:ok, client} <- client() do
      case Linear.transition_issue(client, issue_id, state_name) do
        {:ok, _} -> :ok
        error -> error
      end
    end
  end

  @impl true
  def add_comment(issue_id, body) do
    with {:ok, client} <- client() do
      case Linear.create_comment(client, issue_id, body) do
        {:ok, _} -> :ok
        error -> error
      end
    end
  end

  defp client do
    case tracker_opts() do
      opts when is_list(opts) ->
        api_key = Keyword.get(opts, :api_key)

        if api_key do
          {:ok, Linear.client(api_key: api_key)}
        else
          {:error, :missing_linear_api_key}
        end

      _ ->
        {:error, :tracker_not_configured}
    end
  end

  defp team_id do
    case team_id_value() do
      nil -> {:error, :missing_team_id}
      id -> {:ok, id}
    end
  end

  defp team_id_value, do: Keyword.get(tracker_opts() || [], :team_id)

  defp tracker_opts do
    case Application.get_env(:sentinel, :tracker) do
      {__MODULE__, opts} -> opts
      _ -> nil
    end
  end

  defp open_states, do: ["Backlog", "Todo", "In Progress", "Triage"]

  defp format_issue_body(%ErrorBucket{} = bucket) do
    sample = List.first(bucket.samples)

    """
    ## Error Details

    **Type**: `#{bucket.signature.exception_type}`
    **Origin**: `#{bucket.signature.origin_function || bucket.signature.origin_module || "unknown"}`
    **Line**: #{bucket.signature.origin_line || "unknown"}
    **Occurrences**: #{bucket.count}
    **First seen**: #{bucket.first_seen_at}
    **Last seen**: #{bucket.last_seen_at}

    ## Message

    ```
    #{bucket.signature.message_pattern}
    ```

    #{if sample, do: format_sample_stacktrace(sample), else: ""}

    ---
    *Created by [Sentinel](https://github.com/fun-fx/sentinel)*
    """
  end

  defp format_sample_stacktrace(%{stacktrace: stacktrace}) when is_list(stacktrace) and stacktrace != [] do
    formatted =
      stacktrace
      |> Enum.take(10)
      |> Enum.map_join("\n", &Exception.format_stacktrace_entry/1)

    """
    ## Stacktrace

    ```
    #{formatted}
    ```
    """
  end

  defp format_sample_stacktrace(_), do: ""

  defp resolve_label_ids(_client), do: []

  defp filter_by_labels(issues, []), do: issues

  defp filter_by_labels(issues, required_labels) do
    required_set = MapSet.new(required_labels |> Enum.map(&String.downcase/1))

    Enum.filter(issues, fn issue ->
      issue_labels =
        (issue["labels"] || get_in(issue, ["labels", "nodes"]) || [])
        |> Enum.map(fn
          %{"name" => name} -> String.downcase(name)
          name when is_binary(name) -> String.downcase(name)
          _ -> ""
        end)
        |> MapSet.new()

      MapSet.subset?(required_set, issue_labels)
    end)
  end

  defp normalize_issues(issues) do
    Enum.map(issues, fn issue ->
      %{
        id: issue["id"],
        identifier: issue["identifier"],
        title: issue["title"],
        description: issue["description"],
        state: get_in(issue, ["state", "name"]) || issue["state"],
        labels: extract_label_names(issue),
        url: issue["url"]
      }
    end)
  end

  defp extract_label_names(issue) do
    case issue do
      %{"labels" => %{"nodes" => nodes}} when is_list(nodes) ->
        Enum.map(nodes, & &1["name"])

      %{"labels" => labels} when is_list(labels) ->
        Enum.map(labels, fn
          %{"name" => n} -> n
          n when is_binary(n) -> n
          _ -> nil
        end)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)
end
