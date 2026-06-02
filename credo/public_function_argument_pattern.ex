defmodule Still.Credo.PublicFunctionArgumentPatterns do
  @moduledoc """
  Checks that all public function arguments have pattern matching or guard clauses.

  ## Examples

  # Preferred - arguments have pattern matching or guards:

      def process_user(%User{} = user), do: ...
      def handle_message(message) when is_binary(message), do: ...
      def calculate({x, y}), do: ...

  # Not preferred - plain variable arguments without validation:

      def process_user(user), do: ...
      def handle_message(message), do: ...

  Note: Arguments starting with `_` are ignored as they indicate unused parameters.

  ## Configuration

  You can configure files to ignore using the `ignored_files` parameter:

      {Still.Credo.PublicFunctionArgumentPatterns, [
        ignored_files: [
          ~r/test\/.+_test\\.exs$/,
          ~r/lib\\/still\\/legacy\\/.+\\.ex$/,
          "lib/still/generated.ex"
        ]
      ]}

  The `ignored_files` parameter accepts:
  - Regular expressions (e.g., `~r/test\\/.+_test\\.exs$/`)
  - Exact file path strings (e.g., `"lib/still/some_file.ex"`)
  - Glob patterns as strings (e.g., `"lib/still/legacy/**/*.ex"`)
  """

  use Credo.Check,
    base_priority: :normal,
    category: :design,
    param_defaults: [
      ignored_files: [],
      ignored_argument_names: [],
      ignore_functions: [],
      ignore_arities: []
    ],
    explanations: [
      check: """
        Public functions should validate their inputs through pattern matching or guards.

        ## Preferred - arguments have pattern matching or guards:

            def process_user(%User{} = user), do: ...
            def handle_message(message) when is_binary(message), do: ...
            def calculate({x, y}), do: ...

        ## Not preferred - plain variable arguments without validation:

            def process_user(user), do: ...
            def handle_message(message), do: ...

        Note: Arguments starting with `_` are ignored as they indicate unused arguments.
      """,
      params: [
        ignored_files: "A list of file patterns (regex, globs, or exact paths) to ignore.",
        ignored_argument_names:
          "A list of argument names (as atoms) to skip — e.g. `assigns`, which " <>
            "function components take whole and never head-match.",
        ignore_functions: "A list of function names (as atoms) to ignore.",
        ignore_arities:
          "A list of {function_name, arity} tuples to ignore — framework callbacks " <>
            "(e.g. `mount/3`, `render/1`, `handle_event/3`) whose entry signatures are " <>
            "framework-dictated."
      ]
    ]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    ignored_files = Params.get(params, :ignored_files, __MODULE__)

    if file_ignored?(source_file.filename, ignored_files) do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)

      ignore = %{
        names: Params.get(params, :ignored_argument_names, __MODULE__),
        functions: Params.get(params, :ignore_functions, __MODULE__),
        arities: Params.get(params, :ignore_arities, __MODULE__)
      }

      Credo.Code.prewalk(
        source_file,
        fn ast, issues -> traverse(ast, issues, issue_meta, ignore) end,
        []
      )
    end
  end

  # Check if the file should be ignored based on the ignored_files patterns
  defp file_ignored?(_filename, []), do: false

  defp file_ignored?(filename, ignored_files) do
    Enum.any?(ignored_files, fn pattern ->
      matches_pattern?(filename, pattern)
    end)
  end

  defp matches_pattern?(filename, %Regex{} = regex) do
    Regex.match?(regex, filename)
  end

  defp matches_pattern?(filename, pattern) when is_binary(pattern) do
    cond do
      # Check for glob pattern (contains * or ?)
      String.contains?(pattern, ["*", "?"]) ->
        glob_matches?(filename, pattern)

      # Exact path match
      true ->
        Path.expand(filename) == Path.expand(pattern) ||
          String.ends_with?(filename, pattern)
    end
  end

  defp matches_pattern?(_filename, _pattern), do: false

  defp glob_matches?(filename, pattern) do
    # Convert glob pattern to regex
    regex_pattern =
      pattern
      |> Regex.escape()
      |> String.replace("\\*\\*", "{{DOUBLE_STAR}}")
      |> String.replace("\\*", "[^/]*")
      |> String.replace("{{DOUBLE_STAR}}", ".*")
      |> String.replace("\\?", ".")

    case Regex.compile("#{regex_pattern}$") do
      {:ok, regex} -> Regex.match?(regex, filename)
      # six:ignore:next
      _ -> false
    end
  end

  # Match public function definitions (def, not defp)
  # Handle function with guards: def foo(arg) when guard, do: ...
  defp traverse(
         {:def, meta, [{:when, _, [{name, _, params}, _guards]}, _body]} = ast,
         issues,
         issue_meta,
         ignore
       )
       when is_list(params) do
    # Function has guards, but we still need to check each parameter
    # Guards apply to the whole function, so we check if params have pattern matching
    new_issues = check_def(name, params, meta, issue_meta, ignore, has_guards: true)
    {ast, new_issues ++ issues}
  end

  # Handle regular function: def foo(arg), do: ...
  defp traverse({:def, meta, [{name, _, params}, _body]} = ast, issues, issue_meta, ignore)
       when is_list(params) do
    new_issues = check_def(name, params, meta, issue_meta, ignore, has_guards: false)
    {ast, new_issues ++ issues}
  end

  # Handle single-clause function without body block: def foo(arg)
  defp traverse({:def, meta, [{name, _, params}]} = ast, issues, issue_meta, ignore)
       when is_list(params) do
    new_issues = check_def(name, params, meta, issue_meta, ignore, has_guards: false)
    {ast, new_issues ++ issues}
  end

  defp traverse(ast, issues, _issue_meta, _ignore), do: {ast, issues}

  # Skip framework callbacks (by name or {name, arity}); otherwise check params.
  defp check_def(name, params, meta, issue_meta, ignore, opts) do
    if name in ignore.functions or {name, length(params)} in ignore.arities do
      []
    else
      check_params_for_patterns(params, meta, issue_meta, Keyword.put(opts, :ignored_names, ignore.names))
    end
  end

  # six:ignore:next
  defp check_params_for_patterns(nil, _meta, _issue_meta, _opts), do: []
  defp check_params_for_patterns([], _meta, _issue_meta, _opts), do: []

  defp check_params_for_patterns(params, meta, issue_meta, opts) do
    has_guards = Keyword.get(opts, :has_guards, false)
    ignored_names = Keyword.get(opts, :ignored_names, [])

    params
    |> Enum.with_index()
    |> Enum.filter(fn {param, _index} -> plain_variable?(param) end)
    |> Enum.reject(fn {param, _index} -> ignored_variable?(param) end)
    |> Enum.reject(fn {param, _index} -> argument_name_ignored?(param, ignored_names) end)
    |> Enum.reject(fn {_param, _index} -> has_guards end)
    |> Enum.map(fn {param, _index} ->
      issue_for(issue_meta, meta[:line], get_variable_name(param))
    end)
  end

  # Check if a parameter's name is in the configured ignore list
  defp argument_name_ignored?({name, _meta, _context}, ignored_names) when is_atom(name) do
    name in ignored_names
  end

  # Only plain variables reach here (the pipeline filters first), so this
  # defensive clause is unreachable in practice — same as the fallbacks above.
  # six:ignore:next
  defp argument_name_ignored?(_param, _ignored_names), do: false

  # Check if a parameter is a plain variable (no pattern matching)
  # Plain variable: {name, meta, nil} or {name, meta, context} where context is an atom
  defp plain_variable?({name, _meta, context}) when is_atom(name) and is_atom(context), do: true
  defp plain_variable?(_), do: false

  # Check if variable name starts with underscore (ignored/unused parameter)
  defp ignored_variable?({name, _meta, _context}) when is_atom(name) do
    name
    |> Atom.to_string()
    |> String.starts_with?("_")
  end

  # six:ignore:next
  defp ignored_variable?(_), do: false

  defp get_variable_name({name, _meta, _context}) when is_atom(name), do: Atom.to_string(name)
  # six:ignore:next
  defp get_variable_name(_), do: "unknown"

  defp issue_for(issue_meta, line_no, trigger) do
    format_issue(
      issue_meta,
      message:
        "Public function argument `#{trigger}` should use pattern matching or a guard clause.",
      trigger: trigger,
      line_no: line_no
    )
  end
end
