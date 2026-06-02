defmodule Still.Credo.PublicFunctionDocumentation do
  @moduledoc """
  Checks that all public functions (defined with `def`) have a `@doc` attribute
  with meaningful content (not `false` or empty).

  ## Examples

  # Valid - has documentation
  @doc \"\"\"
  Fetches a user by their ID.
  \"\"\"
  def fetch_user(id), do: Repo.get(User, id)

  # Valid - has single-line documentation
  @doc "Returns the current timestamp."
  def now, do: DateTime.utc_now()

  # Valid - multiple function heads with one @doc block
  @doc \"\"\"
  Extracts the timestamp from the UUID.
  \"\"\"
  def timestamp(<<milliseconds::48, 7::4, _::76>>), do: milliseconds
  def timestamp(<<_::288>> = uuid), do: uuid |> dump!() |> timestamp()

  # Invalid - no @doc attribute
  def process(data), do: do_process(data)

  # Invalid - @doc false
  @doc false
  def internal_but_public(x), do: x

  ## Configuration

  You can configure files to ignore using the `ignored_files` parameter:

      {Still.Credo.PublicFunctionDocumentation, [
        ignored_files: [
          ~r/test\\/.+_test\\.exs$/,
          "test/support/**/*.ex",
          "lib/still/generated.ex"
        ]
      ]}

  The `ignored_files` parameter accepts:
  - Regular expressions (e.g., `~r/test\\/.+_test\\.exs$/`)
  - Exact file path strings (e.g., `"lib/still/some_file.ex"`)
  - Glob patterns as strings (e.g., `"lib/still/legacy/**/*.ex"`)

  You can configure functions to ignore by name only or name and arity.

      {Still.Credo.PublicFunctionDocumentation,
        [
          ignore_functions: [
            # Common auto-generated functions
            :__struct__,
            :child_spec
          ],
          ignore_arities: [
            # GenServer callbacks
            {:init, 1},
            {:start_link, 1},
            {:handle_call, 3},
            {:handle_cast, 2},
            {:handle_info, 2},
            {:handle_continue, 2},
            {:terminate, 2},
            {:code_change, 3},
          ]
        ]}
  """

  use Credo.Check,
    base_priority: :normal,
    category: :readability,
    explanations: [
      params: [
        ignore_functions: "A list of function names (as atoms) to ignore.",
        ignore_arities: "A list of {function_name, arity} tuples to ignore.",
        ignored_files: "A list of file patterns (regex, globs, or exact paths) to ignore."
      ]
    ],
    param_defaults: [
      ignore_functions: [],
      ignore_arities: [],
      ignored_files: []
    ]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    ignored_files = Params.get(params, :ignored_files, __MODULE__)

    if file_ignored?(source_file.filename, ignored_files) do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)
      ignore_functions = Params.get(params, :ignore_functions, __MODULE__)
      ignore_arities = Params.get(params, :ignore_arities, __MODULE__)

      # First pass: collect all @doc attributes and track ranges they cover
      doc_attributes = collect_doc_attributes(source_file)

      # Second pass: collect all public function definitions with their locations
      function_defs = collect_function_definitions(source_file)

      # Third pass: group consecutive function clauses and check documentation
      check_function_groups(
        function_defs,
        doc_attributes,
        issue_meta,
        ignore_functions,
        ignore_arities
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

  # Collect all @doc attributes as a list of {start_line, end_line, status} tuples
  defp collect_doc_attributes(source_file) do
    Credo.Code.prewalk(source_file, &collect_docs/2, [])
  end

  # Match @doc with a string value (valid documentation)
  defp collect_docs({:@, meta, [{:doc, _doc_meta, [content]}]} = ast, acc)
       when is_binary(content) do
    start_line = meta[:line]
    # For single-line @doc "string", the doc is on the same line
    # For multi-line strings, count the newlines in the content
    newline_count = content |> String.graphemes() |> Enum.count(&(&1 == "\n"))
    end_line = start_line + newline_count
    {ast, [{start_line, end_line, {:valid, content}} | acc]}
  end

  # Match @doc with a sigil (like ~S or ~s) - valid documentation
  defp collect_docs({:@, meta, [{:doc, _doc_meta, [{sigil, sigil_meta, _}]}]} = ast, acc)
       when sigil in [:sigil_S, :sigil_s] do
    start_line = meta[:line]
    end_line = sigil_meta[:closing][:line] || start_line
    {ast, [{start_line, end_line, {:valid, "sigil"}} | acc]}
  end

  # Match @doc false - invalid/hidden documentation (single line)
  defp collect_docs({:@, meta, [{:doc, _doc_meta, [false]}]} = ast, acc) do
    line = meta[:line]
    {ast, [{line, line, {false, false}} | acc]}
  end

  # Match @doc with heredoc block structure (produced by parsers using literal_encoder)
  # six:ignore:start
  defp collect_docs(
         {:@, meta, [{:doc, _doc_meta, [{:__block__, block_meta, [content]}]}]} = ast,
         acc
       )
       when is_binary(content) do
    start_line = meta[:line]
    # For heredocs, count actual newlines in content, plus the closing """
    newline_count = content |> String.graphemes() |> Enum.count(&(&1 == "\n"))
    # Add 1 for the closing """ which is on its own line
    end_line = block_meta[:closing][:line] || start_line + newline_count + 1
    {ast, [{start_line, end_line, {:valid, content}} | acc]}
  end

  # six:ignore:stop

  defp collect_docs(ast, acc) do
    {ast, acc}
  end

  # Collect all public function definitions
  defp collect_function_definitions(source_file) do
    Credo.Code.prewalk(source_file, &collect_defs/2, [])
    |> Enum.reverse()
  end

  # Handle `def` with a guard clause
  defp collect_defs(
         {:def, meta, [{:when, _when_meta, [{fun_name, _fun_meta, args} | _]} | _]} = ast,
         acc
       )
       when is_atom(fun_name) do
    arity = length(args || [])
    {ast, [{fun_name, arity, meta[:line]} | acc]}
  end

  # Handle `def` without a guard clause, with arguments
  defp collect_defs(
         {:def, meta, [{fun_name, _fun_meta, args} | _]} = ast,
         acc
       )
       when is_atom(fun_name) and is_list(args) do
    arity = length(args)
    {ast, [{fun_name, arity, meta[:line]} | acc]}
  end

  # Handle `def` with no arguments (arity 0)
  defp collect_defs(
         {:def, meta, [{fun_name, _fun_meta, nil} | _]} = ast,
         acc
       )
       when is_atom(fun_name) do
    {ast, [{fun_name, 0, meta[:line]} | acc]}
  end

  # Handle unquote in function name (dynamic function definition) - skip
  # Note: this clause is shadowed by the general clause above since :unquote is an atom
  # six:ignore:next
  defp collect_defs({:def, _meta, [{:unquote, _, _} | _]} = ast, acc) do
    {ast, acc}
  end

  defp collect_defs(ast, acc) do
    {ast, acc}
  end

  # Group consecutive function clauses and check only the first one for documentation
  defp check_function_groups(
         function_defs,
         doc_attributes,
         issue_meta,
         ignore_functions,
         ignore_arities
       ) do
    grouped_functions = group_consecutive_clauses(function_defs)

    # Get all first-line numbers of function groups for boundary checking
    all_function_lines =
      grouped_functions
      |> Enum.map(fn {_name, _arity, line} -> line end)
      |> Enum.sort()

    grouped_functions
    |> Enum.flat_map(fn {fun_name, arity, first_line} ->
      if should_ignore?(fun_name, arity, ignore_functions, ignore_arities) do
        []
      else
        check_documentation(
          fun_name,
          arity,
          first_line,
          doc_attributes,
          all_function_lines,
          issue_meta
        )
      end
    end)
  end

  # Group consecutive function definitions with the same name and arity
  # Returns a list of {fun_name, arity, first_line_of_group}
  defp group_consecutive_clauses(function_defs) do
    function_defs
    |> Enum.reduce([], fn {fun_name, arity, line}, acc ->
      case acc do
        # If the previous function has the same name and arity, skip (it's a continuation)
        [{^fun_name, ^arity, _first_line} | _rest] ->
          acc

        # Otherwise, this is a new function group
        _ ->
          [{fun_name, arity, line} | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp should_ignore?(fun_name, arity, ignore_functions, ignore_arities) do
    fun_name in ignore_functions or {fun_name, arity} in ignore_arities
  end

  defp check_documentation(
         fun_name,
         arity,
         line_no,
         doc_attributes,
         all_function_lines,
         issue_meta
       ) do
    # Look for a @doc attribute that ends within a reasonable range before this function
    doc_status = find_preceding_doc(doc_attributes, line_no, all_function_lines)

    case doc_status do
      {:valid, _content} ->
        # Has valid documentation
        []

      {false, _} ->
        # Has @doc false
        [issue_for_doc_false(issue_meta, line_no, fun_name, arity)]

      :missing ->
        # No @doc attribute found
        [issue_for_missing_doc(issue_meta, line_no, fun_name, arity)]
    end
  end

  # Find the @doc attribute that directly precedes this function definition
  # Ensures no other function definition exists between the @doc and this function
  defp find_preceding_doc(doc_attributes, function_line, all_function_lines) do
    # Find the closest preceding function line (if any)
    preceding_function_line =
      all_function_lines
      |> Enum.filter(&(&1 < function_line))
      |> Enum.max(fn -> 0 end)

    doc_attributes
    |> Enum.filter(fn {start_line, end_line, _status} ->
      # The @doc must:
      # 1. Start and end before this function
      # 2. Start AFTER any preceding function (so it belongs to this function, not
      #    the previous one)
      #
      # No upper bound on the distance to the function: a `@doc` attaches to the
      # next definition the way Elixir itself does, even when `attr`/`slot`
      # declarations sit between it and the `def` (Phoenix function components).
      start_line < function_line and
        end_line < function_line and
        start_line > preceding_function_line
    end)
    |> Enum.sort_by(fn {_start, end_line, _status} -> end_line end, :desc)
    |> case do
      [{_start, _end, status} | _] -> status
      [] -> :missing
    end
  end

  defp issue_for_missing_doc(issue_meta, line_no, fun_name, arity) do
    format_issue(
      issue_meta,
      message: "Public function `#{fun_name}/#{arity}` is missing a @doc attribute.",
      trigger: fun_name,
      line_no: line_no
    )
  end

  defp issue_for_doc_false(issue_meta, line_no, fun_name, arity) do
    format_issue(
      issue_meta,
      message:
        "Public function `#{fun_name}/#{arity}` has `@doc false`. Consider adding documentation or making the function private.",
      trigger: fun_name,
      line_no: line_no
    )
  end
end
