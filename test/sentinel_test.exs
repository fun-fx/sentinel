defmodule SentinelTest do
  use ExUnit.Case, async: false

  alias Sentinel.{ErrorBucket, Deduplicator}

  setup do
    Application.put_env(:sentinel, :enabled, true)

    unless GenServer.whereis(Sentinel.Deduplicator) do
      start_supervised!(Sentinel.Deduplicator)
    end

    on_exit(fn ->
      Application.delete_env(:sentinel, :enabled)
      Application.delete_env(:sentinel, :tracker)
      Application.delete_env(:sentinel, :agent)
      Application.delete_env(:sentinel, :board_watcher)
    end)

    :ok
  end

  describe "ErrorBucket" do
    test "signature_key extracts from stacktrace" do
      error = %ArgumentError{message: "invalid argument"}

      stacktrace = [
        {MyApp.Orders, :get_order, 1, [file: ~c"lib/my_app/orders.ex", line: 42]}
      ]

      sig = ErrorBucket.signature_key(error, stacktrace)
      assert sig.exception_type == "ArgumentError"
      assert sig.origin_module == "mod:MyApp.Orders"
      assert sig.origin_function == "fn:MyApp.Orders.get_order/1"
      assert sig.origin_line == 42
    end

    test "generate_id is deterministic" do
      sig = %{
        exception_type: "ArgumentError",
        origin_module: "mod:MyApp.Orders",
        origin_function: "fn:MyApp.Orders.get_order/1",
        origin_line: 42,
        message_pattern: "test"
      }

      id1 = ErrorBucket.generate_id(sig)
      id2 = ErrorBucket.generate_id(sig)
      assert id1 == id2
      assert String.starts_with?(id1, "eb:")
    end

    test "new creates a bucket with one sample" do
      sig = %{
        exception_type: "RuntimeError",
        origin_module: nil,
        origin_function: nil,
        origin_line: nil,
        message_pattern: "boom"
      }

      sample = %{timestamp: DateTime.utc_now(), stacktrace: [], process_info: %{}, metadata: %{}}

      bucket = ErrorBucket.new(sig, sample)
      assert bucket.count == 1
      assert length(bucket.samples) == 1
      assert bucket.state == :open
    end

    test "add_occurrence increments count and prepends sample" do
      sig = %{
        exception_type: "RuntimeError",
        origin_module: nil,
        origin_function: nil,
        origin_line: nil,
        message_pattern: "boom"
      }

      sample1 = %{timestamp: DateTime.utc_now(), stacktrace: [], process_info: %{}, metadata: %{}}
      sample2 = %{timestamp: DateTime.utc_now(), stacktrace: [], process_info: %{}, metadata: %{extra: true}}

      bucket = ErrorBucket.new(sig, sample1) |> ErrorBucket.add_occurrence(sample2)
      assert bucket.count == 2
      assert length(bucket.samples) == 2
    end
  end

  describe "Deduplicator" do
    test "records errors and creates buckets" do
      error = %RuntimeError{message: "test error"}
      stacktrace = [{TestModule, :test_fn, 0, [file: ~c"test.ex", line: 1]}]

      Deduplicator.record_error(error, stacktrace, %{})
      Process.sleep(50)

      buckets = Deduplicator.list_buckets()
      assert length(buckets) >= 1

      bucket = hd(buckets)
      assert bucket.count >= 1
      assert bucket.signature.exception_type == "RuntimeError"
    end

    test "deduplicates same errors" do
      error = %RuntimeError{message: "dedup test"}
      stacktrace = [{DedupModule, :dedup_fn, 0, [file: ~c"dedup.ex", line: 10]}]

      Deduplicator.record_error(error, stacktrace, %{})
      Deduplicator.record_error(error, stacktrace, %{})
      Process.sleep(50)

      buckets = Deduplicator.list_buckets()

      matching =
        Enum.filter(
          buckets,
          &(&1.signature.exception_type == "RuntimeError" and &1.signature.message_pattern =~ "dedup")
        )

      assert length(matching) == 1
      assert hd(matching).count == 2
    end

    test "update_bucket_state changes state" do
      error = %RuntimeError{message: "state test #{System.unique_integer([:positive])}"}
      stacktrace = [{StateModule, :state_fn, 0, [file: ~c"state.ex", line: 1]}]

      Deduplicator.record_error(error, stacktrace, %{})
      Process.sleep(50)

      [bucket | _] = Deduplicator.list_buckets()
      assert :ok = Deduplicator.update_bucket_state(bucket.id, :investigating)
      assert {:ok, updated} = Deduplicator.get_bucket(bucket.id)
      assert updated.state == :investigating
    end
  end

  describe "Collector" do
    test "install and uninstall handler" do
      assert :ok = Sentinel.Collector.install()
      assert :ok = Sentinel.Collector.uninstall()
    end

    test "handle_error records through deduplicator" do
      error = %RuntimeError{message: "collector test #{System.unique_integer([:positive])}"}
      stacktrace = [{CollectorMod, :coll_fn, 0, [file: ~c"coll.ex", line: 5]}]

      Sentinel.Collector.handle_error(error, stacktrace, %{})
      Process.sleep(50)

      buckets = Sentinel.error_buckets()
      assert Enum.any?(buckets, &(&1.signature.message_pattern =~ "collector test"))
    end
  end

  describe "Sentinel public API" do
    test "status returns current state" do
      status = Sentinel.status()
      assert status.enabled == true
      assert is_integer(status.error_bucket_count)
    end

    test "report/2 records an error" do
      error = %RuntimeError{message: "manual report #{System.unique_integer([:positive])}"}
      Sentinel.report(error, stacktrace: [{ReportMod, :rep_fn, 0, [file: ~c"rep.ex", line: 1]}])
      Process.sleep(50)

      assert Enum.any?(Sentinel.error_buckets(), &(&1.signature.message_pattern =~ "manual report"))
    end
  end

  describe "Tracker behaviour" do
    test "adapter returns nil when not configured" do
      Application.delete_env(:sentinel, :tracker)
      assert Sentinel.Tracker.adapter() == nil
    end

    test "adapter returns configured module" do
      Application.put_env(:sentinel, :tracker, {Sentinel.Tracker.Linear, api_key: "test"})
      assert {Sentinel.Tracker.Linear, [api_key: "test"]} = Sentinel.Tracker.adapter()
    end
  end

  describe "Agent.Prompt" do
    test "error_investigation builds a prompt" do
      bucket = %ErrorBucket{
        id: "eb:test",
        signature: %{
          exception_type: "ArgumentError",
          origin_module: "mod:MyApp.Orders",
          origin_function: "fn:MyApp.Orders.get/1",
          origin_line: 42,
          message_pattern: "argument error"
        },
        first_seen_at: DateTime.utc_now(),
        last_seen_at: DateTime.utc_now(),
        count: 3,
        samples: [%{timestamp: DateTime.utc_now(), stacktrace: [], process_info: %{}, metadata: %{}}],
        state: :open
      }

      prompt = Sentinel.Agent.Prompt.error_investigation(bucket, %{})
      assert prompt =~ "ArgumentError"
      assert prompt =~ "argument error"
      assert prompt =~ "investigating"
    end

    test "board_task builds a prompt" do
      issue = %{identifier: "ABC-123", title: "Fix the bug", description: "It's broken"}
      prompt = Sentinel.Agent.Prompt.board_task(issue, %{})
      assert prompt =~ "ABC-123"
      assert prompt =~ "Fix the bug"
      assert prompt =~ "It's broken"
    end
  end
end
