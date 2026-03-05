defmodule Sentinel.TestHelpers do
  @moduledoc false

  def unique_id, do: "test-#{System.unique_integer([:positive])}"
end
