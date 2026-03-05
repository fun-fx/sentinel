defmodule Sentinel.Tracker.GitHub do
  @moduledoc """
  GitHub Issues tracker adapter for Sentinel.

  Uses the GitHub REST API via `Req` to create issues, add comments,
  and manage labels.

  ## Configuration

      config :sentinel,
        tracker: {Sentinel.Tracker.GitHub,
          token: System.get_env("GITHUB_TOKEN"),
          owner: "my-org",
          repo: "my-repo"
        }
  """

  @behaviour Sentinel.Tracker

  alias Sentinel.ErrorBucket

  @api_base "https://api.github.com"

  @impl true
  def create_issue(%ErrorBucket{} = bucket) do
    with {:ok, config} <- validate_config() do
      body = %{
        "title" => "[Sentinel] #{bucket.signature.exception_type}: #{bucket.signature.message_pattern}",
        "body" => format_issue_body(bucket),
        "labels" => ["sentinel", "bug"]
      }

      case github_post(config, "/repos/#{config.owner}/#{config.repo}/issues", body) do
        {:ok, %{status: 201, body: resp}} ->
          {:ok, to_string(resp["number"])}

        {:ok, %{status: status}} ->
          {:error, {:github_api_status, status}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def update_issue(issue_number, update) do
    with {:ok, _config} <- validate_config() do
      body = Map.get(update, :comment, "Sentinel: updated (count: #{Map.get(update, :count, "?")})")
      add_comment(issue_number, body)
      :ok
    end
  end

  @impl true
  def find_existing(%ErrorBucket{} = bucket) do
    with {:ok, config} <- validate_config() do
      title_prefix = "[Sentinel] #{bucket.signature.exception_type}"

      query =
        URI.encode_query(%{
          "q" => "repo:#{config.owner}/#{config.repo} is:issue is:open in:title \"#{title_prefix}\""
        })

      case github_get(config, "/search/issues?#{query}") do
        {:ok, %{status: 200, body: %{"items" => items}}} when is_list(items) ->
          case items do
            [first | _] -> {:ok, to_string(first["number"])}
            [] -> :not_found
          end

        _ ->
          :not_found
      end
    end
  end

  @impl true
  def fetch_available_issues(opts) do
    with {:ok, config} <- validate_config() do
      labels = Keyword.get(opts, :labels, ["sentinel"]) |> Enum.join(",")

      case github_get(config, "/repos/#{config.owner}/#{config.repo}/issues?labels=#{labels}&state=open&per_page=50") do
        {:ok, %{status: 200, body: issues}} when is_list(issues) ->
          {:ok, normalize_issues(issues)}

        {:ok, %{status: status}} ->
          {:error, {:github_api_status, status}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def assign_issue(issue_number, assignee) do
    with {:ok, config} <- validate_config() do
      body = %{"assignees" => [assignee]}

      case github_post(config, "/repos/#{config.owner}/#{config.repo}/issues/#{issue_number}", body, :patch) do
        {:ok, %{status: 200}} -> :ok
        {:ok, %{status: status}} -> {:error, {:github_api_status, status}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def transition_issue(issue_number, state_name) do
    with {:ok, config} <- validate_config() do
      github_state = if state_name in ["Done", "Closed", "Resolved"], do: "closed", else: "open"
      body = %{"state" => github_state}

      case github_post(config, "/repos/#{config.owner}/#{config.repo}/issues/#{issue_number}", body, :patch) do
        {:ok, %{status: 200}} -> :ok
        {:ok, %{status: status}} -> {:error, {:github_api_status, status}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def add_comment(issue_number, body) do
    with {:ok, config} <- validate_config() do
      payload = %{"body" => body}

      case github_post(config, "/repos/#{config.owner}/#{config.repo}/issues/#{issue_number}/comments", payload) do
        {:ok, %{status: 201}} -> :ok
        {:ok, %{status: status}} -> {:error, {:github_api_status, status}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp github_get(config, path) do
    Req.get("#{@api_base}#{path}", headers: auth_headers(config))
  end

  defp github_post(config, path, body, method \\ :post) do
    opts = [headers: auth_headers(config), json: body]

    case method do
      :post -> Req.post("#{@api_base}#{path}", opts)
      :patch -> Req.patch("#{@api_base}#{path}", opts)
    end
  end

  defp auth_headers(config) do
    [
      {"Authorization", "Bearer #{config.token}"},
      {"Accept", "application/vnd.github+json"},
      {"X-GitHub-Api-Version", "2022-11-28"}
    ]
  end

  defp validate_config do
    case tracker_opts() do
      opts when is_list(opts) ->
        token = Keyword.get(opts, :token)
        owner = Keyword.get(opts, :owner)
        repo = Keyword.get(opts, :repo)

        cond do
          is_nil(token) -> {:error, :missing_github_token}
          is_nil(owner) -> {:error, :missing_github_owner}
          is_nil(repo) -> {:error, :missing_github_repo}
          true -> {:ok, %{token: token, owner: owner, repo: repo}}
        end

      _ ->
        {:error, :tracker_not_configured}
    end
  end

  defp tracker_opts do
    case Application.get_env(:sentinel, :tracker) do
      {__MODULE__, opts} -> opts
      _ -> nil
    end
  end

  defp format_issue_body(%ErrorBucket{} = bucket) do
    sample = List.first(bucket.samples)

    stacktrace_section =
      if sample && is_list(sample.stacktrace) && sample.stacktrace != [] do
        formatted = Enum.map_join(Enum.take(sample.stacktrace, 10), "\n", &Exception.format_stacktrace_entry/1)
        "\n## Stacktrace\n\n```\n#{formatted}\n```\n"
      else
        ""
      end

    """
    ## Error Details

    | Field | Value |
    |-------|-------|
    | **Type** | `#{bucket.signature.exception_type}` |
    | **Origin** | `#{bucket.signature.origin_function || bucket.signature.origin_module || "unknown"}` |
    | **Line** | #{bucket.signature.origin_line || "unknown"} |
    | **Occurrences** | #{bucket.count} |
    | **First seen** | #{bucket.first_seen_at} |
    | **Last seen** | #{bucket.last_seen_at} |

    ## Message

    ```
    #{bucket.signature.message_pattern}
    ```
    #{stacktrace_section}
    ---
    *Created by [Sentinel](https://github.com/fun-fx/sentinel)*
    """
  end

  defp normalize_issues(issues) do
    Enum.map(issues, fn issue ->
      %{
        id: to_string(issue["number"]),
        identifier: "##{issue["number"]}",
        title: issue["title"],
        description: issue["body"],
        state: issue["state"],
        labels: Enum.map(issue["labels"] || [], & &1["name"]),
        url: issue["html_url"]
      }
    end)
  end
end
