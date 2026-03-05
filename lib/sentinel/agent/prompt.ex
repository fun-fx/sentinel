defmodule Sentinel.Agent.Prompt do
  @moduledoc false

  alias Sentinel.ErrorBucket

  @spec error_investigation(ErrorBucket.t(), map()) :: String.t()
  def error_investigation(%ErrorBucket{} = bucket, provenance) do
    sample = List.first(bucket.samples)

    stacktrace_section =
      if sample && is_list(sample.stacktrace) && sample.stacktrace != [] do
        formatted = Enum.map_join(sample.stacktrace, "\n", &Exception.format_stacktrace_entry/1)
        "\n## Stacktrace\n\n```\n#{formatted}\n```\n"
      else
        ""
      end

    provenance_section =
      case Map.get(provenance, :related_modules, []) do
        [] -> ""
        mods -> "\n## Related Modules (from provenance)\n\n#{Enum.map_join(mods, "\n", &"- `#{&1}`")}\n"
      end

    """
    You are investigating a runtime error in this codebase.

    ## Error

    **Type**: #{bucket.signature.exception_type}
    **Message**: #{bucket.signature.message_pattern}
    **Origin**: #{bucket.signature.origin_function || bucket.signature.origin_module || "unknown"}
    **Line**: #{bucket.signature.origin_line || "unknown"}
    **Occurrences**: #{bucket.count}
    #{stacktrace_section}#{provenance_section}
    ## Instructions

    1. Read the source code at the error origin.
    2. Understand the root cause of this error.
    3. Propose a fix. If confident, apply the fix directly.
    4. If you applied a fix, run any relevant tests to verify.
    5. Summarize your findings and the fix.
    """
  end

  @spec board_task(map(), map()) :: String.t()
  def board_task(issue, _provenance) do
    description = Map.get(issue, :description) || Map.get(issue, "description") || ""

    """
    You are working on the following task from the project board.

    ## Task

    **#{Map.get(issue, :identifier, "")}**: #{Map.get(issue, :title, "")}

    #{description}

    ## Instructions

    1. Understand what this task requires by reading the codebase.
    2. Implement the changes needed.
    3. Run relevant tests to verify your changes work.
    4. Summarize what you did.
    """
  end
end
