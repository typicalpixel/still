defmodule Still.Credo.NoDirectErrorRendering do
  @moduledoc """
  Checks that controllers don't render error responses directly.

  Controllers should return `{:error, ...}` tuples and let `FallbackController`
  handle error rendering to ensure a consistent error format.

  ## Examples

  # Not preferred - direct error rendering in controller:

      defmodule StillWeb.UserController do
        def create(conn, params) do
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "something went wrong"})
        end
      end

  # Preferred - return error tuple for FallbackController:

      defmodule StillWeb.UserController do
        action_fallback StillWeb.FallbackController

        def create(conn, params) do
          with {:ok, user} <- Accounts.create_user(params) do
            render(conn, :show, user: user)
          end
        end
      end

  ## Configuration

      {Still.Credo.NoDirectErrorRendering, [
        controller_paths: ["lib/still_web/controllers/"]
      ]}

  - `controller_paths`: List of path prefixes that identify controller files
  """

  use Credo.Check,
    base_priority: :high,
    category: :design,
    param_defaults: [
      controller_paths: []
    ],
    explanations: [
      check: """
      Avoid rendering error responses directly in controllers.

      Direct error rendering in controllers:
      - Bypasses FallbackController and the standardized error format
      - Leads to inconsistent error response structures across the API
      - Makes it harder to maintain a uniform API contract

      Instead, return `{:error, ...}` tuples from your controller actions
      and let FallbackController handle the rendering.
      """,
      params: [
        controller_paths: "List of path prefixes for controller files."
      ]
    ]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    controller_paths = Params.get(params, :controller_paths, __MODULE__)

    if controller_file?(source_file.filename, controller_paths) and
         not fallback_controller?(source_file.filename) do
      issue_meta = IssueMeta.for(source_file, params)
      Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta), [])
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

  defp fallback_controller?(filename) do
    String.contains?(filename, "fallback_controller")
  end

  # Match `put_status(conn, status)` and `Plug.Conn.put_status(conn, status)`
  # with any status argument (atom or integer) that resolves to a 4xx/5xx
  # code. Delegating to Plug.Conn.Status.code/1 means we catch every atom
  # Plug recognizes — not just a hand-curated list that drifts behind.
  defp traverse(
         {{:., _, [{:__aliases__, _, [:Plug, :Conn]}, :put_status]}, meta, [_conn, status]} = ast,
         issues,
         issue_meta
       ) do
    maybe_issue(ast, meta, status, issues, issue_meta)
  end

  defp traverse({:put_status, meta, [_conn, status]} = ast, issues, issue_meta) do
    maybe_issue(ast, meta, status, issues, issue_meta)
  end

  # Match `json(conn, %{error: ...})` / `json(conn, %{"error" => ...})` /
  # the fully-qualified `Phoenix.Controller.json/2`. Shaping an error body
  # inside a controller breaks the API's single-error-shape contract —
  # that work belongs in FallbackController.
  defp traverse(
         {{:., _, [{:__aliases__, _, [:Phoenix, :Controller]}, :json]}, meta, [_conn, body]} =
           ast,
         issues,
         issue_meta
       ) do
    maybe_body_issue(ast, meta, body, "json/2", issues, issue_meta)
  end

  defp traverse({:json, meta, [_conn, body]} = ast, issues, issue_meta) do
    maybe_body_issue(ast, meta, body, "json/2", issues, issue_meta)
  end

  # Match `render(conn, :error, ...)` / `render(conn, "error.json", ...)`.
  # Rendering a dedicated error template from a controller action has the
  # same problem — the shape lives outside FallbackController.
  defp traverse(
         {{:., _, [{:__aliases__, _, [:Phoenix, :Controller]}, :render]}, meta,
          [_conn, template | _]} = ast,
         issues,
         issue_meta
       ) do
    maybe_template_issue(ast, meta, template, issues, issue_meta)
  end

  defp traverse({:render, meta, [_conn, template | _]} = ast, issues, issue_meta) do
    maybe_template_issue(ast, meta, template, issues, issue_meta)
  end

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}

  defp maybe_issue(ast, meta, status, issues, issue_meta) do
    case status_code(status) do
      {:ok, code} when code >= 400 ->
        {ast, [issue_for(issue_meta, meta[:line], "put_status(#{inspect(status)})") | issues]}

      _ ->
        {ast, issues}
    end
  end

  defp maybe_body_issue(ast, meta, body, trigger, issues, issue_meta) do
    if error_shaped_map?(body) do
      {ast, [issue_for(issue_meta, meta[:line], trigger) | issues]}
    else
      {ast, issues}
    end
  end

  defp maybe_template_issue(ast, meta, template, issues, issue_meta) do
    if error_template?(template) do
      {ast, [issue_for(issue_meta, meta[:line], "render/3") | issues]}
    else
      {ast, issues}
    end
  end

  # A literal map whose top-level keys include `:error` or `"error"` counts
  # as an error body. Nested shapes are ignored — we only look at the
  # outermost map the controller hands to `json/2`, which is exactly the
  # shape that defines the API's error contract.
  defp error_shaped_map?({:%{}, _, pairs}) when is_list(pairs) do
    Enum.any?(pairs, fn
      {:error, _} -> true
      {"error", _} -> true
      _ -> false
    end)
  end

  defp error_shaped_map?(_), do: false

  defp error_template?(:error), do: true
  defp error_template?("error.json"), do: true
  defp error_template?("error.html"), do: true
  defp error_template?(_), do: false

  defp status_code(status) when is_integer(status), do: {:ok, status}

  defp status_code(status) when is_atom(status) do
    {:ok, Plug.Conn.Status.code(status)}
  rescue
    FunctionClauseError -> :error
  end

  defp status_code(_), do: :error

  defp issue_for(issue_meta, line_no, trigger) do
    format_issue(
      issue_meta,
      message:
        "Avoid shaping error responses with `#{trigger}` directly in controllers. " <>
          "Return `{:error, ...}` tuples and let FallbackController handle error rendering.",
      line_no: line_no,
      trigger: trigger
    )
  end
end
