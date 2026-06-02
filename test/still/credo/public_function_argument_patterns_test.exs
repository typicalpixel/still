defmodule Still.Credo.PublicFunctionArgumentPatternsTest do
  use Credo.Test.Case, async: true

  alias Still.Credo.PublicFunctionArgumentPatterns

  test "reports plain variable arguments" do
    """
    defmodule MyApp.Foo do
      def process(user), do: user
    end
    """
    |> to_source_file()
    |> run_check(PublicFunctionArgumentPatterns)
    |> assert_issue(fn issue ->
      assert issue.trigger == "user"
    end)
  end

  test "allows pattern-matched arguments" do
    """
    defmodule MyApp.Foo do
      def process(%User{} = user), do: user
    end
    """
    |> to_source_file()
    |> run_check(PublicFunctionArgumentPatterns)
    |> refute_issues()
  end

  test "allows guarded arguments" do
    """
    defmodule MyApp.Foo do
      def process(name) when is_binary(name), do: name
    end
    """
    |> to_source_file()
    |> run_check(PublicFunctionArgumentPatterns)
    |> refute_issues()
  end

  test "ignores underscore-prefixed arguments" do
    """
    defmodule MyApp.Foo do
      def process(_unused, %{} = data), do: data
    end
    """
    |> to_source_file()
    |> run_check(PublicFunctionArgumentPatterns)
    |> refute_issues()
  end

  test "allows tuple pattern arguments" do
    """
    defmodule MyApp.Foo do
      def process({x, y}), do: x + y
    end
    """
    |> to_source_file()
    |> run_check(PublicFunctionArgumentPatterns)
    |> refute_issues()
  end

  test "ignores private functions" do
    """
    defmodule MyApp.Foo do
      defp process(user), do: user
    end
    """
    |> to_source_file()
    |> run_check(PublicFunctionArgumentPatterns)
    |> refute_issues()
  end

  test "respects ignored_files with regex" do
    """
    defmodule MyApp.FooTest do
      def process(user), do: user
    end
    """
    |> to_source_file("test/my_app/foo_test.exs")
    |> run_check(PublicFunctionArgumentPatterns, ignored_files: [~r/test\/.+_test\.exs$/])
    |> refute_issues()
  end

  test "respects ignored_files with exact path" do
    """
    defmodule MyApp.Foo do
      def process(user), do: user
    end
    """
    |> to_source_file("lib/my_app/legacy/foo.ex")
    |> run_check(PublicFunctionArgumentPatterns, ignored_files: ["lib/my_app/legacy/foo.ex"])
    |> refute_issues()
  end

  test "handles zero-arity functions" do
    """
    defmodule MyApp.Foo do
      def run, do: :ok
    end
    """
    |> to_source_file()
    |> run_check(PublicFunctionArgumentPatterns)
    |> refute_issues()
  end

  test "reports multiple plain arguments" do
    """
    defmodule MyApp.Foo do
      def process(a, b), do: {a, b}
    end
    """
    |> to_source_file()
    |> run_check(PublicFunctionArgumentPatterns)
    |> assert_issues()
  end

  test "respects ignored_files with glob pattern" do
    """
    defmodule MyApp.Foo do
      def process(user), do: user
    end
    """
    |> to_source_file("lib/my_app/legacy/stuff/foo.ex")
    |> run_check(PublicFunctionArgumentPatterns, ignored_files: ["lib/my_app/legacy/**/*.ex"])
    |> refute_issues()
  end

  test "does not ignore files that don't match patterns" do
    """
    defmodule MyApp.Foo do
      def process(user), do: user
    end
    """
    |> to_source_file("lib/my_app/core/foo.ex")
    |> run_check(PublicFunctionArgumentPatterns, ignored_files: ["lib/my_app/legacy/**/*.ex"])
    |> assert_issue()
  end

  test "handles function with no body block" do
    """
    defmodule MyApp.Foo do
      def process(data)
    end
    """
    |> to_source_file()
    |> run_check(PublicFunctionArgumentPatterns)
    |> assert_issue()
  end

  test "handles non-matching pattern types in ignored_files" do
    """
    defmodule MyApp.Foo do
      def process(user), do: user
    end
    """
    |> to_source_file("lib/foo.ex")
    |> run_check(PublicFunctionArgumentPatterns, ignored_files: [123])
    |> assert_issue()
  end

  test "respects ignored_files with path suffix match" do
    """
    defmodule MyApp.Foo do
      def process(user), do: user
    end
    """
    |> to_source_file("lib/my_app/foo.ex")
    |> run_check(PublicFunctionArgumentPatterns, ignored_files: ["my_app/foo.ex"])
    |> refute_issues()
  end

  test "handles map pattern arguments" do
    """
    defmodule MyApp.Foo do
      def process(%{key: value}), do: value
    end
    """
    |> to_source_file()
    |> run_check(PublicFunctionArgumentPatterns)
    |> refute_issues()
  end

  test "handles explicit empty parens (def foo())" do
    """
    defmodule MyApp.Foo do
      def foo(), do: :ok
    end
    """
    |> to_source_file()
    |> run_check(PublicFunctionArgumentPatterns)
    |> refute_issues()
  end

  test "skips arguments named in ignored_argument_names" do
    """
    defmodule MyApp.Components do
      def render(assigns), do: assigns
    end
    """
    |> to_source_file()
    |> run_check(PublicFunctionArgumentPatterns, ignored_argument_names: [:assigns])
    |> refute_issues()
  end

  test "still reports non-ignored arguments when ignored_argument_names is set" do
    """
    defmodule MyApp.Foo do
      def build(assigns, thing), do: {assigns, thing}
    end
    """
    |> to_source_file()
    |> run_check(PublicFunctionArgumentPatterns, ignored_argument_names: [:assigns])
    |> assert_issue(fn issue -> assert issue.trigger == "thing" end)
  end

  test "skips framework callbacks listed in ignore_arities" do
    """
    defmodule MyApp.Live do
      def mount(params, session, socket), do: {params, session, socket}
    end
    """
    |> to_source_file()
    |> run_check(PublicFunctionArgumentPatterns, ignore_arities: [{:mount, 3}])
    |> refute_issues()
  end

  test "skips functions listed in ignore_functions" do
    """
    defmodule MyApp.Live do
      def render(assigns), do: assigns
    end
    """
    |> to_source_file()
    |> run_check(PublicFunctionArgumentPatterns, ignore_functions: [:render])
    |> refute_issues()
  end

  test "ignore_arities only matches the configured arity" do
    """
    defmodule MyApp.Live do
      def mount(socket), do: socket
    end
    """
    |> to_source_file()
    |> run_check(PublicFunctionArgumentPatterns, ignore_arities: [{:mount, 3}])
    |> assert_issue(fn issue -> assert issue.trigger == "socket" end)
  end
end
