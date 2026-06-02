defmodule Still.Credo.NoSleepInTests do
  @moduledoc """
  Checks that `Process.sleep/1` and `:timer.sleep/1` are not used in test files.

  Using sleep in tests leads to flaky, slow tests. Instead, use explicit
  synchronization mechanisms like `assert_receive/2` with timeouts, or
  alternatives that wait for specific conditions.

  ## Examples

  # Not preferred - using sleep:

      test "message is processed" do
        send(pid, :process)
        Process.sleep(100)
        assert processed?()
      end

  # Preferred - using assert_receive:

      test "message is processed" do
        send(pid, :process)
        assert_receive :done, 1000
      end

  ## Configuration

  This check runs on all test files by default (files matching `*_test.exs`).
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    param_defaults: [],
    explanations: [
      check: """
      Avoid using `Process.sleep/1` or `:timer.sleep/1` in tests.

      Sleep-based tests are slow and flaky. Use explicit synchronization instead:
      - `assert_receive/2` with a timeout
      - `GenServer.call/2` for synchronous operations
      - Test helpers that wait for specific conditions
      """
    ]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    if test_file?(source_file.filename) do
      issue_meta = IssueMeta.for(source_file, params)
      Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta), [])
    else
      []
    end
  end

  defp test_file?(filename) do
    String.ends_with?(filename, "_test.exs")
  end

  # Match Process.sleep/1
  defp traverse(
         {{:., _, [{:__aliases__, _, [:Process]}, :sleep]}, meta, _args} = ast,
         issues,
         issue_meta
       ) do
    issue = issue_for(issue_meta, meta[:line], "Process.sleep/1")
    {ast, [issue | issues]}
  end

  # Match :timer.sleep/1
  defp traverse(
         {{:., _, [:timer, :sleep]}, meta, _args} = ast,
         issues,
         issue_meta
       ) do
    issue = issue_for(issue_meta, meta[:line], ":timer.sleep/1")
    {ast, [issue | issues]}
  end

  defp traverse(ast, issues, _issue_meta) do
    {ast, issues}
  end

  defp issue_for(issue_meta, line_no, trigger) do
    format_issue(
      issue_meta,
      message:
        "Avoid using `#{trigger}` in tests. Use explicit synchronization like `assert_receive/2` instead.",
      line_no: line_no,
      trigger: trigger
    )
  end
end
