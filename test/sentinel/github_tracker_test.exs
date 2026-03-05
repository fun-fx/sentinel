defmodule Sentinel.Tracker.GitHubTest do
  use ExUnit.Case, async: true

  alias Sentinel.{ErrorBucket, Tracker.GitHub}

  describe "configuration" do
    test "returns error when token is missing" do
      Application.put_env(:sentinel, :tracker, {GitHub, owner: "org", repo: "repo"})
      on_exit(fn -> Application.delete_env(:sentinel, :tracker) end)

      bucket = test_bucket()
      assert {:error, :missing_github_token} = GitHub.create_issue(bucket)
    end

    test "returns error when owner is missing" do
      Application.put_env(:sentinel, :tracker, {GitHub, token: "tok", repo: "repo"})
      on_exit(fn -> Application.delete_env(:sentinel, :tracker) end)

      bucket = test_bucket()
      assert {:error, :missing_github_owner} = GitHub.create_issue(bucket)
    end

    test "returns error when repo is missing" do
      Application.put_env(:sentinel, :tracker, {GitHub, token: "tok", owner: "org"})
      on_exit(fn -> Application.delete_env(:sentinel, :tracker) end)

      bucket = test_bucket()
      assert {:error, :missing_github_repo} = GitHub.create_issue(bucket)
    end

    test "returns error when not configured" do
      Application.delete_env(:sentinel, :tracker)

      bucket = test_bucket()
      assert {:error, :tracker_not_configured} = GitHub.create_issue(bucket)
    end
  end

  describe "normalize_issues" do
    test "GitHub adapter implements the Tracker behaviour" do
      assert function_exported?(GitHub, :create_issue, 1)
      assert function_exported?(GitHub, :update_issue, 2)
      assert function_exported?(GitHub, :find_existing, 1)
      assert function_exported?(GitHub, :fetch_available_issues, 1)
      assert function_exported?(GitHub, :assign_issue, 2)
      assert function_exported?(GitHub, :transition_issue, 2)
      assert function_exported?(GitHub, :add_comment, 2)
    end
  end

  defp test_bucket do
    %ErrorBucket{
      id: "eb:test123",
      signature: %{
        exception_type: "RuntimeError",
        origin_module: "mod:Test",
        origin_function: "fn:Test.run/0",
        origin_line: 1,
        message_pattern: "boom"
      },
      first_seen_at: DateTime.utc_now(),
      last_seen_at: DateTime.utc_now(),
      count: 1,
      samples: [],
      state: :open
    }
  end
end
