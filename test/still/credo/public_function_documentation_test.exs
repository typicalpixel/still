defmodule Still.Credo.PublicFunctionDocumentationTest do
  use Credo.Test.Case, async: true

  alias Still.Credo.PublicFunctionDocumentation

  test "reports missing @doc on public function" do
    """
    defmodule MyApp.Foo do
      def process(data), do: data
    end
    """
    |> to_source_file()
    |> run_check(PublicFunctionDocumentation)
    |> assert_issue(fn issue ->
      assert issue.message =~ "missing a @doc"
    end)
  end

  test "allows function with @doc string" do
    ~S'''
    defmodule MyApp.Foo do
      @doc "Processes data."
      def process(data), do: data
    end
    '''
    |> to_source_file()
    |> run_check(PublicFunctionDocumentation)
    |> refute_issues()
  end

  test "allows function with @doc heredoc" do
    ~S'''
    defmodule MyApp.Foo do
      @doc """
      Processes data.
      """
      def process(data), do: data
    end
    '''
    |> to_source_file()
    |> run_check(PublicFunctionDocumentation)
    |> refute_issues()
  end

  test "reports @doc false" do
    """
    defmodule MyApp.Foo do
      @doc false
      def process(data), do: data
    end
    """
    |> to_source_file()
    |> run_check(PublicFunctionDocumentation)
    |> assert_issue(fn issue ->
      assert issue.message =~ "@doc false"
    end)
  end

  test "only requires @doc on first clause of multi-clause function" do
    ~S'''
    defmodule MyApp.Foo do
      @doc "Processes data."
      def process(0), do: :zero
      def process(n), do: n * 2
    end
    '''
    |> to_source_file()
    |> run_check(PublicFunctionDocumentation)
    |> refute_issues()
  end

  test "respects ignore_functions option" do
    """
    defmodule MyApp.Foo do
      def child_spec(opts), do: opts
    end
    """
    |> to_source_file()
    |> run_check(PublicFunctionDocumentation, ignore_functions: [:child_spec])
    |> refute_issues()
  end

  test "respects ignore_arities option" do
    """
    defmodule MyApp.Foo do
      def init(state), do: {:ok, state}
    end
    """
    |> to_source_file()
    |> run_check(PublicFunctionDocumentation, ignore_arities: [{:init, 1}])
    |> refute_issues()
  end

  test "respects ignored_files with regex" do
    """
    defmodule MyApp.FooTest do
      def process(data), do: data
    end
    """
    |> to_source_file("test/my_app/foo_test.exs")
    |> run_check(PublicFunctionDocumentation, ignored_files: [~r/test\/.+_test\.exs$/])
    |> refute_issues()
  end

  test "ignores private functions" do
    """
    defmodule MyApp.Foo do
      defp process(data), do: data
    end
    """
    |> to_source_file()
    |> run_check(PublicFunctionDocumentation)
    |> refute_issues()
  end

  test "handles zero-arity functions" do
    """
    defmodule MyApp.Foo do
      def now, do: DateTime.utc_now()
    end
    """
    |> to_source_file()
    |> run_check(PublicFunctionDocumentation)
    |> assert_issue()
  end

  test "handles function with guard clause" do
    ~S'''
    defmodule MyApp.Foo do
      @doc "Does something."
      def process(x) when is_integer(x), do: x
    end
    '''
    |> to_source_file()
    |> run_check(PublicFunctionDocumentation)
    |> refute_issues()
  end

  test "respects ignored_files with glob pattern" do
    """
    defmodule MyApp.Foo do
      def process(data), do: data
    end
    """
    |> to_source_file("test/support/helpers/sub/foo.ex")
    |> run_check(PublicFunctionDocumentation, ignored_files: ["test/support/helpers/**/*.ex"])
    |> refute_issues()
  end

  test "handles exact path in ignored_files" do
    """
    defmodule MyApp.Foo do
      def process(data), do: data
    end
    """
    |> to_source_file("lib/my_app/generated.ex")
    |> run_check(PublicFunctionDocumentation, ignored_files: ["lib/my_app/generated.ex"])
    |> refute_issues()
  end

  test "handles non-matching ignored_files pattern" do
    """
    defmodule MyApp.Foo do
      def process(data), do: data
    end
    """
    |> to_source_file("lib/my_app/core.ex")
    |> run_check(PublicFunctionDocumentation, ignored_files: ["lib/my_app/legacy/**/*.ex"])
    |> assert_issue()
  end

  test "handles multiple functions with docs and without" do
    ~S'''
    defmodule MyApp.Foo do
      @doc "Does a."
      def a, do: :a

      def b, do: :b
    end
    '''
    |> to_source_file()
    |> run_check(PublicFunctionDocumentation)
    |> assert_issue(fn issue ->
      assert issue.message =~ "b/0"
    end)
  end

  test "handles function with guard but no doc" do
    """
    defmodule MyApp.Foo do
      def process(x) when is_integer(x), do: x
    end
    """
    |> to_source_file()
    |> run_check(PublicFunctionDocumentation)
    |> assert_issue()
  end

  test "does not ignore invalid pattern types" do
    """
    defmodule MyApp.Foo do
      def process(data), do: data
    end
    """
    |> to_source_file("lib/my_app/foo.ex")
    |> run_check(PublicFunctionDocumentation, ignored_files: [123])
    |> assert_issue()
  end

  test "respects ignored_files with path suffix match" do
    """
    defmodule MyApp.Foo do
      def process(data), do: data
    end
    """
    |> to_source_file("lib/my_app/foo.ex")
    |> run_check(PublicFunctionDocumentation, ignored_files: ["my_app/foo.ex"])
    |> refute_issues()
  end

  test "handles regex compile failure gracefully" do
    """
    defmodule MyApp.Foo do
      def process(data), do: data
    end
    """
    |> to_source_file("lib/my_app/foo.ex")
    |> run_check(PublicFunctionDocumentation, ignored_files: ["lib/[invalid"])
    |> assert_issue()
  end

  test "allows function with @doc sigil_S" do
    """
    defmodule MyApp.Foo do
      @doc ~S"Processes data."
      def process(data), do: data
    end
    """
    |> to_source_file()
    |> run_check(PublicFunctionDocumentation)
    |> refute_issues()
  end

  test "reports functions defined with unquote as needing docs" do
    """
    defmodule MyApp.Foo do
      name = :process
      def unquote(name), do: :ok
    end
    """
    |> to_source_file()
    |> run_check(PublicFunctionDocumentation)
    |> assert_issue()
  end

  test "associates @doc separated from the function by attr/slot declarations" do
    # Phoenix function components put @doc above the attr/slot block, which can
    # push it well beyond the function head. The @doc still belongs to it.
    ~S'''
    defmodule MyApp.Components do
      @doc "Renders a button."
      attr :rest, :global
      attr :class, :any
      slot :inner_block, required: true

      def button(assigns), do: assigns
    end
    '''
    |> to_source_file()
    |> run_check(PublicFunctionDocumentation)
    |> refute_issues()
  end

  test "ignores @doc that appears after the function" do
    """
    defmodule MyApp.Foo do
      def process(data), do: data
      @doc "Too late."
      def other(x), do: x
    end
    """
    |> to_source_file()
    |> run_check(PublicFunctionDocumentation)
    |> assert_issue(fn issue ->
      assert issue.message =~ "process/1"
    end)
  end
end
