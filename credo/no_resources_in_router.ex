defmodule Still.Credo.NoResourcesInRouter do
  @moduledoc """
  Checks that the `resources` macro is not used in router files.

  The `resources` macro automatically generates multiple routes (index, show, new,
  edit, create, update, delete) which can lead to unintended route exposure and
  makes it harder to audit which endpoints are available.

  Instead, prefer explicitly defining each route that your application needs.

  ## Examples

  # Not preferred - using resources macro:

      scope "/", StillWeb do
        pipe_through :api
        resources "/users", UserController
      end

  # Preferred - explicit route definitions:

      scope "/", StillWeb do
        pipe_through :api
        get "/users", UserController, :index
        get "/users/:id", UserController, :show
        post "/users", UserController, :create
        put "/users/:id", UserController, :update
        delete "/users/:id", UserController, :delete
      end

  ## Configuration

  You can configure which files to check using the `included_files` parameter:

      {Still.Credo.NoResourcesInRouter, [
        included_files: [
          "lib/still_web/router.ex"
        ]
      ]}

  The `included_files` parameter accepts a list of exact file paths.
  This check is intentionally strict: add router files explicitly rather than
  relying on fuzzy matching.
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    param_defaults: [
      included_files: []
    ],
    explanations: [
      check: """
      The `resources` macro automatically generates multiple routes which can lead
      to unintended route exposure. Prefer explicit route definitions instead.

      # Not preferred:

          resources "/users", UserController

      # Preferred:

          get "/users", UserController, :index
          get "/users/:id", UserController, :show
          post "/users", UserController, :create
          put "/users/:id", UserController, :update
          delete "/users/:id", UserController, :delete
      """,
      params: [
        included_files: "A list of exact router file paths to check."
      ]
    ]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    included_files = Params.get(params, :included_files, __MODULE__)

    if file_included?(source_file.filename, included_files) do
      issue_meta = IssueMeta.for(source_file, params)
      Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta), [])
    else
      []
    end
  end

  # Check if the file should be included based on the included_files patterns
  defp file_included?(_filename, []), do: false

  defp file_included?(filename, included_files) do
    Enum.any?(included_files, fn included_file ->
      Path.expand(filename) == Path.expand(included_file)
    end)
  end

  # Traverse the AST looking for `resources` macro calls
  defp traverse({:resources, meta, args} = ast, issues, issue_meta) when is_list(args) do
    issue = issue_for(issue_meta, meta[:line], extract_path(args))
    {ast, [issue | issues]}
  end

  defp traverse(ast, issues, _issue_meta) do
    {ast, issues}
  end

  defp extract_path([path | _]) when is_binary(path), do: path
  defp extract_path(_), do: nil

  defp issue_for(issue_meta, line_no, path) do
    message =
      if path do
        "Avoid using `resources` macro for \"#{path}\". Define routes explicitly instead."
      else
        "Avoid using `resources` macro. Define routes explicitly instead."
      end

    format_issue(
      issue_meta,
      message: message,
      line_no: line_no,
      trigger: "resources"
    )
  end
end
