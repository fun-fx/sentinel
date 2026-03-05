defmodule Sentinel.Agent do
  @moduledoc """
  Codex agent runner for both error investigation and board task execution.

  Uses `codex_app_server` to spawn Codex sessions and run turns with
  context-rich prompts built from error data, board issues, and provenance.
  """

  require Logger

  alias Sentinel.{ErrorBucket, Deduplicator}
  alias Sentinel.Agent.Prompt

  @doc "Dispatch an error investigation asynchronously."
  @spec dispatch_error(ErrorBucket.t()) :: :ok
  def dispatch_error(%ErrorBucket{} = bucket) do
    if allowed_environment?() do
      Deduplicator.update_bucket_state(bucket.id, :investigating)

      Task.Supervisor.start_child(Sentinel.AgentSupervisor, fn ->
        run_error_investigation(bucket)
      end)

      :ok
    else
      :ok
    end
  end

  @doc "Execute a board issue synchronously (called from BoardWatcher task)."
  @spec dispatch_board_issue(map()) :: {:ok, map()} | {:error, term()}
  def dispatch_board_issue(issue) do
    if allowed_environment?() do
      run_board_task(issue)
    else
      {:error, :agent_not_allowed_in_environment}
    end
  end

  defp run_error_investigation(bucket) do
    workspace = workspace_path()
    prompt = Prompt.error_investigation(bucket, provenance_context(bucket))
    config = agent_config()

    Logger.info("Sentinel investigating error bucket=#{bucket.id}")

    case CodexAppServer.run(workspace, prompt,
           command: Keyword.get(config, :command, "codex app-server"),
           title: "Sentinel: #{bucket.signature.exception_type}",
           approval_policy: Keyword.get(config, :approval_policy, "never"),
           sandbox: "workspace-write",
           sandbox_policy: %{"type" => "workspaceWrite"},
           on_message: &log_agent_message/1
         ) do
      {:ok, result} ->
        Deduplicator.update_bucket_state(bucket.id, :reported)

        if Sentinel.tracker_configured?() do
          Sentinel.TrackerServer.create_or_update(bucket)
        end

        Logger.info("Sentinel error investigation completed bucket=#{bucket.id} session=#{result.session_id}")

      {:error, reason} ->
        Deduplicator.update_bucket_state(bucket.id, :open)
        Logger.warning("Sentinel error investigation failed bucket=#{bucket.id}: #{inspect(reason)}")
    end
  end

  defp run_board_task(issue) do
    workspace = workspace_path()
    prompt = Prompt.board_task(issue, provenance_context_for_issue(issue))
    config = agent_config()

    Logger.info("Sentinel executing board issue=#{issue.identifier}")

    case CodexAppServer.run(workspace, prompt,
           command: Keyword.get(config, :command, "codex app-server"),
           title: "Sentinel: #{issue.identifier} #{issue.title}",
           approval_policy: Keyword.get(config, :approval_policy, "never"),
           sandbox: "workspace-write",
           sandbox_policy: %{"type" => "workspaceWrite"},
           on_message: &log_agent_message/1
         ) do
      {:ok, result} ->
        {:ok,
         %{session_id: result.session_id, comment_body: "Sentinel completed this task (session: #{result.session_id})."}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp provenance_context(%ErrorBucket{} = bucket) do
    if Code.ensure_loaded?(Provenance) do
      ids = [bucket.signature.origin_module, bucket.signature.origin_function] |> Enum.reject(&is_nil/1)

      related =
        Enum.flat_map(ids, fn id ->
          try do
            Provenance.related(id)
          rescue
            _ -> []
          end
        end)
        |> Enum.uniq()

      %{related_modules: related}
    else
      %{}
    end
  end

  defp provenance_context_for_issue(_issue), do: %{}

  defp log_agent_message(msg) do
    case msg do
      %{event: :turn_completed} -> Logger.debug("Sentinel agent turn completed")
      %{event: :turn_failed, reason: reason} -> Logger.warning("Sentinel agent turn failed: #{inspect(reason)}")
      _ -> :ok
    end
  end

  defp workspace_path do
    Application.get_env(:sentinel, :workspace, File.cwd!())
  end

  defp agent_config do
    Application.get_env(:sentinel, :agent, [])
  end

  defp allowed_environment? do
    Sentinel.environment() in [:dev, :staging, :test]
  end
end
