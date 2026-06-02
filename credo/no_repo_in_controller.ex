defmodule Still.Credo.NoRepoInController do
  @moduledoc """
  Checks that Ecto Repo modules are not called directly in Phoenix controllers.

  Direct Repo calls in controllers bypass your context layer, making code harder
  to test, reuse, and maintain. Always go through context modules instead.

  ## Examples

  # Not preferred - direct Repo call in controller:

      defmodule StillWeb.UserController do
        def show(conn, %{"id" => id}) do
          user = Still.Repo.get!(User, id)
          render(conn, :show, user: user)
        end
      end

  # Preferred - using context module:

      defmodule StillWeb.UserController do
        def show(conn, %{"id" => id}) do
          user = Still.Accounts.get_user!(id)
          render(conn, :show, user: user)
        end
      end

  ## Configuration

      {Still.Credo.NoRepoInController, [
        repo_modules: [Still.Repo],
        controller_paths: ["lib/still_web/controllers/"]
      ]}

  - `repo_modules`: List of Repo module names to check for (default: detects modules ending in `Repo`)
  - `controller_paths`: List of path prefixes that identify controller files
  """

  use Credo.Check,
    base_priority: :high,
    category: :design,
    param_defaults: [
      repo_modules: [],
      controller_paths: []
    ],
    explanations: [
      check: """
      Avoid calling Repo modules directly in Phoenix controllers.

      Direct Repo access in controllers:
      - Bypasses your context/domain layer
      - Makes controllers harder to test
      - Scatters data access logic throughout the codebase
      - Violates separation of concerns

      Instead, create functions in your context modules that encapsulate
      the data access logic.
      """,
      params: [
        repo_modules: "List of Repo module names to detect (e.g., `[Still.Repo]`).",
        controller_paths: "List of path prefixes for controller files."
      ]
    ]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    controller_paths = Params.get(params, :controller_paths, __MODULE__)

    if controller_file?(source_file.filename, controller_paths) do
      repo_modules = Params.get(params, :repo_modules, __MODULE__)
      issue_meta = IssueMeta.for(source_file, params)
      Credo.Code.prewalk(source_file, &traverse(&1, &2, {issue_meta, repo_modules}), [])
    else
      []
    end
  end

  defp controller_file?(_filename, []), do: false

  defp controller_file?(filename, controller_paths) do
    Enum.any?(controller_paths, fn path ->
      String.contains?(filename, path)
    end)
  end

  # Match Repo.function() calls - e.g., MyApp.Repo.get!(User, id)
  defp traverse(
         {{:., _, [{:__aliases__, _, module_parts}, function]}, meta, _args} = ast,
         issues,
         {issue_meta, repo_modules}
       ) do
    module_name = Module.concat(module_parts)

    if repo_call?(module_name, module_parts, repo_modules) do
      trigger = "#{inspect(module_name)}.#{function}"
      issue = issue_for(issue_meta, meta[:line], trigger)
      {ast, [issue | issues]}
    else
      {ast, issues}
    end
  end

  defp traverse(ast, issues, _context) do
    {ast, issues}
  end

  defp repo_call?(module_name, module_parts, repo_modules) do
    cond do
      # Check against explicitly configured repo modules
      repo_modules != [] ->
        module_name in repo_modules

      # Default: check if module name ends with "Repo"
      true ->
        module_parts
        |> List.last()
        |> Atom.to_string()
        |> String.ends_with?("Repo")
    end
  end

  defp issue_for(issue_meta, line_no, trigger) do
    format_issue(
      issue_meta,
      message:
        "Avoid calling `#{trigger}` directly in controllers. Use a context module instead.",
      line_no: line_no,
      trigger: trigger
    )
  end
end
