defmodule Still.Credo.NoDirectErrorRenderingTest do
  use Credo.Test.Case, async: true

  alias Still.Credo.NoDirectErrorRendering

  @params [controller_paths: ["lib/still_web/controllers/"]]

  test "reports put_status with error atom in controllers" do
    """
    defmodule StillWeb.UserController do
      def create(conn, _params) do
        put_status(conn, :unprocessable_entity)
      end
    end
    """
    |> to_source_file("lib/still_web/controllers/user_controller.ex")
    |> run_check(NoDirectErrorRendering, @params)
    |> assert_issue()
  end

  test "reports put_status with integer error code in controllers" do
    """
    defmodule StillWeb.UserController do
      def create(conn, _params) do
        put_status(conn, 422)
      end
    end
    """
    |> to_source_file("lib/still_web/controllers/user_controller.ex")
    |> run_check(NoDirectErrorRendering, @params)
    |> assert_issue()
  end

  test "ignores non-controller files" do
    """
    defmodule StillWeb.SomeView do
      def render(conn) do
        put_status(conn, :not_found)
      end
    end
    """
    |> to_source_file("lib/still_web/views/some_view.ex")
    |> run_check(NoDirectErrorRendering, @params)
    |> refute_issues()
  end

  test "ignores fallback controller" do
    """
    defmodule StillWeb.FallbackController do
      def call(conn, {:error, :not_found}) do
        put_status(conn, :not_found)
      end
    end
    """
    |> to_source_file("lib/still_web/controllers/fallback_controller.ex")
    |> run_check(NoDirectErrorRendering, @params)
    |> refute_issues()
  end

  test "no issues for controllers without put_status" do
    """
    defmodule StillWeb.UserController do
      def create(conn, params) do
        render(conn, :show, user: params)
      end
    end
    """
    |> to_source_file("lib/still_web/controllers/user_controller.ex")
    |> run_check(NoDirectErrorRendering, @params)
    |> refute_issues()
  end

  test "returns no issues when controller_paths is empty" do
    """
    defmodule StillWeb.UserController do
      def create(conn, _params) do
        put_status(conn, :unprocessable_entity)
      end
    end
    """
    |> to_source_file("lib/still_web/controllers/user_controller.ex")
    |> run_check(NoDirectErrorRendering, controller_paths: [])
    |> refute_issues()
  end

  test "reports Plug.Conn.put_status with error atom in controllers" do
    """
    defmodule StillWeb.UserController do
      def create(conn, _params) do
        Plug.Conn.put_status(conn, :forbidden)
      end
    end
    """
    |> to_source_file("lib/still_web/controllers/user_controller.ex")
    |> run_check(NoDirectErrorRendering, @params)
    |> assert_issue()
  end

  test "reports :conflict (409) — not in the original hand-curated list" do
    """
    defmodule StillWeb.UserController do
      def create(conn, _params) do
        put_status(conn, :conflict)
      end
    end
    """
    |> to_source_file("lib/still_web/controllers/user_controller.ex")
    |> run_check(NoDirectErrorRendering, @params)
    |> assert_issue()
  end

  test "reports :not_implemented (501) — the atom the old rollback shipped" do
    """
    defmodule StillWeb.DeploymentController do
      def rollback(conn, _params) do
        put_status(conn, :not_implemented)
      end
    end
    """
    |> to_source_file("lib/still_web/controllers/deployment_controller.ex")
    |> run_check(NoDirectErrorRendering, @params)
    |> assert_issue()
  end

  test "reports :method_not_allowed (405)" do
    """
    defmodule StillWeb.UserController do
      def create(conn, _params) do
        put_status(conn, :method_not_allowed)
      end
    end
    """
    |> to_source_file("lib/still_web/controllers/user_controller.ex")
    |> run_check(NoDirectErrorRendering, @params)
    |> assert_issue()
  end

  test "does not report :ok (200) or :created (201)" do
    """
    defmodule StillWeb.UserController do
      def create(conn, _params) do
        conn
        |> put_status(:ok)
        |> put_status(:created)
      end
    end
    """
    |> to_source_file("lib/still_web/controllers/user_controller.ex")
    |> run_check(NoDirectErrorRendering, @params)
    |> refute_issues()
  end

  test "does not report put_status with a runtime variable" do
    # Variable status codes can't be analyzed statically — we only flag
    # literal atoms and integers. This is deliberate to avoid false
    # positives on helper wrappers.
    """
    defmodule StillWeb.UserController do
      def create(conn, %{"status" => status}) do
        put_status(conn, status)
      end
    end
    """
    |> to_source_file("lib/still_web/controllers/user_controller.ex")
    |> run_check(NoDirectErrorRendering, @params)
    |> refute_issues()
  end

  describe "error body shaping via json/2" do
    test "reports json(conn, %{error: _}) with atom key" do
      """
      defmodule StillWeb.UserController do
        def show(conn, _params) do
          json(conn, %{error: %{message: "nope"}})
        end
      end
      """
      |> to_source_file("lib/still_web/controllers/user_controller.ex")
      |> run_check(NoDirectErrorRendering, @params)
      |> assert_issue()
    end

    test "reports json(conn, %{\"error\" => _}) with string key" do
      """
      defmodule StillWeb.UserController do
        def show(conn, _params) do
          json(conn, %{"error" => "nope"})
        end
      end
      """
      |> to_source_file("lib/still_web/controllers/user_controller.ex")
      |> run_check(NoDirectErrorRendering, @params)
      |> assert_issue()
    end

    test "reports Phoenix.Controller.json with an error-shaped body" do
      """
      defmodule StillWeb.UserController do
        def show(conn, _params) do
          Phoenix.Controller.json(conn, %{error: "nope"})
        end
      end
      """
      |> to_source_file("lib/still_web/controllers/user_controller.ex")
      |> run_check(NoDirectErrorRendering, @params)
      |> assert_issue()
    end

    test "does not report json(conn, %{data: _}) — success bodies are fine" do
      """
      defmodule StillWeb.UserController do
        def show(conn, _params) do
          json(conn, %{data: %{name: "alice"}})
        end
      end
      """
      |> to_source_file("lib/still_web/controllers/user_controller.ex")
      |> run_check(NoDirectErrorRendering, @params)
      |> refute_issues()
    end

    test "does not report json/2 called with a non-literal body" do
      # Variable bodies can't be statically analyzed. We deliberately skip
      # them to avoid false positives on helper wrappers that build the
      # body elsewhere.
      """
      defmodule StillWeb.UserController do
        def show(conn, _params) do
          body = %{data: "ok"}
          json(conn, body)
        end
      end
      """
      |> to_source_file("lib/still_web/controllers/user_controller.ex")
      |> run_check(NoDirectErrorRendering, @params)
      |> refute_issues()
    end

    test "does not report json in the fallback controller" do
      """
      defmodule StillWeb.FallbackController do
        def call(conn, {:error, :not_found}) do
          json(conn, %{error: %{message: "Not found"}})
        end
      end
      """
      |> to_source_file("lib/still_web/controllers/fallback_controller.ex")
      |> run_check(NoDirectErrorRendering, @params)
      |> refute_issues()
    end
  end

  describe "error template rendering" do
    test "reports render(conn, :error, ...)" do
      """
      defmodule StillWeb.UserController do
        def show(conn, _params) do
          render(conn, :error, reason: "nope")
        end
      end
      """
      |> to_source_file("lib/still_web/controllers/user_controller.ex")
      |> run_check(NoDirectErrorRendering, @params)
      |> assert_issue()
    end

    test "reports render(conn, \"error.json\", ...)" do
      """
      defmodule StillWeb.UserController do
        def show(conn, _params) do
          render(conn, "error.json", reason: "nope")
        end
      end
      """
      |> to_source_file("lib/still_web/controllers/user_controller.ex")
      |> run_check(NoDirectErrorRendering, @params)
      |> assert_issue()
    end

    test "does not report render with non-error templates" do
      """
      defmodule StillWeb.UserController do
        def show(conn, _params) do
          render(conn, :show, user: %{})
        end
      end
      """
      |> to_source_file("lib/still_web/controllers/user_controller.ex")
      |> run_check(NoDirectErrorRendering, @params)
      |> refute_issues()
    end

    test "reports Phoenix.Controller.render(conn, :error, ...)" do
      """
      defmodule StillWeb.UserController do
        def show(conn, _params) do
          Phoenix.Controller.render(conn, :error, reason: "nope")
        end
      end
      """
      |> to_source_file("lib/still_web/controllers/user_controller.ex")
      |> run_check(NoDirectErrorRendering, @params)
      |> assert_issue()
    end

    test "reports render(conn, \"error.html\", ...)" do
      """
      defmodule StillWeb.UserController do
        def show(conn, _params) do
          render(conn, "error.html", reason: "nope")
        end
      end
      """
      |> to_source_file("lib/still_web/controllers/user_controller.ex")
      |> run_check(NoDirectErrorRendering, @params)
      |> assert_issue()
    end
  end

  describe "unknown status atoms" do
    test "does not crash on atoms Plug.Conn.Status doesn't recognize" do
      # Plug.Conn.Status.code/1 raises FunctionClauseError for unknown atoms
      # — the check must rescue that and silently skip the call rather
      # than blowing up the analysis.
      """
      defmodule StillWeb.UserController do
        def show(conn, _params) do
          put_status(conn, :definitely_not_a_real_status)
        end
      end
      """
      |> to_source_file("lib/still_web/controllers/user_controller.ex")
      |> run_check(NoDirectErrorRendering, @params)
      |> refute_issues()
    end

    test "does not crash on put_status with a nil literal" do
      """
      defmodule StillWeb.UserController do
        def show(conn, _params) do
          put_status(conn, nil)
        end
      end
      """
      |> to_source_file("lib/still_web/controllers/user_controller.ex")
      |> run_check(NoDirectErrorRendering, @params)
      |> refute_issues()
    end
  end
end
