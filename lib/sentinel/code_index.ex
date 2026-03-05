defmodule Sentinel.CodeIndex do
  @moduledoc """
  Lightweight codebase indexer with file watching and git history awareness.

  Provides the agent with structural context about the codebase:
  which files exist, what changed recently, and the project layout.

  Starts automatically when Sentinel is enabled in dev/staging.
  """

  use GenServer

  require Logger

  @refresh_interval 30_000

  defstruct [
    :project_root,
    files: %{},
    recent_commits: [],
    last_indexed_at: nil
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get the project file tree as a map of relative paths to metadata."
  @spec files() :: %{String.t() => map()}
  def files do
    GenServer.call(__MODULE__, :files)
  end

  @doc "Get recent git commits (last 20)."
  @spec recent_commits() :: [map()]
  def recent_commits do
    GenServer.call(__MODULE__, :recent_commits)
  end

  @doc "Get files changed in recent commits that are related to a module or path."
  @spec recent_changes_for(String.t()) :: [map()]
  def recent_changes_for(path_or_module) do
    GenServer.call(__MODULE__, {:recent_changes_for, path_or_module})
  end

  @doc "Get a summary of the project structure suitable for agent prompts."
  @spec project_summary() :: String.t()
  def project_summary do
    GenServer.call(__MODULE__, :project_summary)
  end

  @impl true
  def init(opts) do
    root = Keyword.get(opts, :project_root, File.cwd!())

    state = %__MODULE__{project_root: root}
    state = do_index(state)

    schedule_refresh()

    {:ok, state}
  end

  @impl true
  def handle_call(:files, _from, state) do
    {:reply, state.files, state}
  end

  def handle_call(:recent_commits, _from, state) do
    {:reply, state.recent_commits, state}
  end

  def handle_call({:recent_changes_for, query}, _from, state) do
    matches =
      state.recent_commits
      |> Enum.filter(fn commit ->
        Enum.any?(commit.files_changed, fn f ->
          String.contains?(f, query) or String.contains?(query, Path.basename(f, ".ex"))
        end)
      end)

    {:reply, matches, state}
  end

  def handle_call(:project_summary, _from, state) do
    summary = build_summary(state)
    {:reply, summary, state}
  end

  @impl true
  def handle_info(:refresh, state) do
    state = do_index(state)
    schedule_refresh()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp do_index(state) do
    files = index_files(state.project_root)
    commits = index_git_log(state.project_root)

    %{state | files: files, recent_commits: commits, last_indexed_at: DateTime.utc_now()}
  end

  defp index_files(root) do
    patterns = [
      Path.join(root, "lib/**/*.ex"),
      Path.join(root, "test/**/*.exs"),
      Path.join(root, "config/**/*.exs"),
      Path.join(root, "priv/repo/migrations/**/*.exs")
    ]

    patterns
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.into(%{}, fn path ->
      relative = Path.relative_to(path, root)
      stat = File.stat(path)

      meta = %{
        relative_path: relative,
        size: elem(stat, 1) |> Map.get(:size, 0),
        layer: classify_file(relative),
        modified: elem(stat, 1) |> Map.get(:mtime)
      }

      {relative, meta}
    end)
  rescue
    _ -> %{}
  end

  defp index_git_log(root) do
    case System.cmd("git", ["log", "--oneline", "--name-only", "-20", "--pretty=format:%H|%s|%ar"],
           cd: root,
           stderr_to_stdout: true
         ) do
      {output, 0} -> parse_git_log(output)
      _ -> []
    end
  rescue
    _ -> []
  end

  defp parse_git_log(output) do
    output
    |> String.split("\n")
    |> Enum.chunk_while(
      nil,
      fn line, acc ->
        if String.contains?(line, "|") do
          if acc, do: {:cont, acc, parse_commit_header(line)}, else: {:cont, parse_commit_header(line)}
        else
          trimmed = String.trim(line)

          if trimmed != "" and acc do
            {:cont, %{acc | files_changed: [trimmed | acc.files_changed]}}
          else
            {:cont, acc}
          end
        end
      end,
      fn
        nil -> {:cont, []}
        acc -> {:cont, acc, nil}
      end
    )
    |> Enum.reject(&is_nil/1)
  end

  defp parse_commit_header(line) do
    case String.split(line, "|", parts: 3) do
      [hash, subject, ago] ->
        %{hash: String.trim(hash), subject: String.trim(subject), ago: String.trim(ago), files_changed: []}

      _ ->
        %{hash: "", subject: line, ago: "", files_changed: []}
    end
  end

  defp classify_file(path) do
    cond do
      String.starts_with?(path, "lib/") and String.contains?(path, "_web/") -> :web
      String.starts_with?(path, "lib/") -> :lib
      String.starts_with?(path, "test/") -> :test
      String.starts_with?(path, "config/") -> :config
      String.starts_with?(path, "priv/repo/migrations/") -> :migration
      true -> :other
    end
  end

  defp build_summary(state) do
    file_count = map_size(state.files)

    layer_counts =
      state.files
      |> Enum.group_by(fn {_path, meta} -> meta.layer end)
      |> Enum.map(fn {layer, files} -> "  #{layer}: #{length(files)} files" end)
      |> Enum.join("\n")

    recent =
      state.recent_commits
      |> Enum.take(5)
      |> Enum.map(fn c -> "  #{String.slice(c.hash, 0, 7)} #{c.subject} (#{c.ago})" end)
      |> Enum.join("\n")

    """
    Project: #{Path.basename(state.project_root)}
    Root: #{state.project_root}
    Files: #{file_count}

    By layer:
    #{layer_counts}

    Recent commits:
    #{recent}
    """
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval)
  end
end
