defmodule Still.Credo.NoSleepInTestsTest do
  use Credo.Test.Case, async: true

  alias Still.Credo.NoSleepInTests

  test "reports Process.sleep in test files" do
    """
    defmodule MyApp.FooTest do
      test "something" do
        Process.sleep(100)
        assert true
      end
    end
    """
    |> to_source_file("test/my_app/foo_test.exs")
    |> run_check(NoSleepInTests)
    |> assert_issue(fn issue ->
      assert issue.trigger == "Process.sleep/1"
    end)
  end

  test "reports :timer.sleep in test files" do
    """
    defmodule MyApp.FooTest do
      test "something" do
        :timer.sleep(100)
        assert true
      end
    end
    """
    |> to_source_file("test/my_app/foo_test.exs")
    |> run_check(NoSleepInTests)
    |> assert_issue(fn issue ->
      assert issue.trigger == ":timer.sleep/1"
    end)
  end

  test "ignores sleep in non-test files" do
    """
    defmodule MyApp.Worker do
      def run do
        Process.sleep(1000)
      end
    end
    """
    |> to_source_file("lib/my_app/worker.ex")
    |> run_check(NoSleepInTests)
    |> refute_issues()
  end
end
