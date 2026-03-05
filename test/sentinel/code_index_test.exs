defmodule Sentinel.CodeIndexTest do
  use ExUnit.Case, async: false

  setup do
    if pid = GenServer.whereis(Sentinel.CodeIndex) do
      GenServer.stop(pid)
    end

    {:ok, pid} = Sentinel.CodeIndex.start_link(project_root: File.cwd!())
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    :ok
  end

  describe "files/0" do
    test "returns a map of project files" do
      files = Sentinel.CodeIndex.files()
      assert is_map(files)
      assert map_size(files) > 0

      {_path, meta} = Enum.at(files, 0)
      assert Map.has_key?(meta, :relative_path)
      assert Map.has_key?(meta, :layer)
    end
  end

  describe "recent_commits/0" do
    test "returns a list of commits" do
      commits = Sentinel.CodeIndex.recent_commits()
      assert is_list(commits)

      if length(commits) > 0 do
        commit = hd(commits)
        assert Map.has_key?(commit, :hash)
        assert Map.has_key?(commit, :subject)
      end
    end
  end

  describe "project_summary/0" do
    test "returns a formatted string" do
      summary = Sentinel.CodeIndex.project_summary()
      assert is_binary(summary)
      assert summary =~ "Project:"
      assert summary =~ "Files:"
    end
  end
end
