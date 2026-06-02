defmodule Still.Credo.NoResourcesInRouterTest do
  use Credo.Test.Case, async: true

  alias Still.Credo.NoResourcesInRouter

  test "reports resources macro in included router file" do
    """
    defmodule StillWeb.Router do
      scope "/", StillWeb do
        pipe_through :api
        resources "/users", UserController
      end
    end
    """
    |> to_source_file("lib/still_web/router.ex")
    |> run_check(NoResourcesInRouter, included_files: ["lib/still_web/router.ex"])
    |> assert_issue(fn issue ->
      assert issue.trigger == "resources"
    end)
  end

  test "ignores files not in included_files" do
    """
    defmodule StillWeb.Router do
      resources "/users", UserController
    end
    """
    |> to_source_file("lib/still_web/other_router.ex")
    |> run_check(NoResourcesInRouter, included_files: ["lib/still_web/router.ex"])
    |> refute_issues()
  end

  test "no issues when explicit routes are used" do
    """
    defmodule StillWeb.Router do
      scope "/", StillWeb do
        get "/users", UserController, :index
        post "/users", UserController, :create
      end
    end
    """
    |> to_source_file("lib/still_web/router.ex")
    |> run_check(NoResourcesInRouter, included_files: ["lib/still_web/router.ex"])
    |> refute_issues()
  end

  test "returns no issues when included_files is empty" do
    """
    defmodule StillWeb.Router do
      resources "/users", UserController
    end
    """
    |> to_source_file("lib/still_web/router.ex")
    |> run_check(NoResourcesInRouter, included_files: [])
    |> refute_issues()
  end

  test "includes path in issue message when path is a string" do
    """
    defmodule StillWeb.Router do
      resources "/api/users", UserController
    end
    """
    |> to_source_file("lib/still_web/router.ex")
    |> run_check(NoResourcesInRouter, included_files: ["lib/still_web/router.ex"])
    |> assert_issue(fn issue ->
      assert issue.message =~ "/api/users"
    end)
  end

  test "handles resources without a path argument" do
    """
    defmodule StillWeb.Router do
      resources UserController
    end
    """
    |> to_source_file("lib/still_web/router.ex")
    |> run_check(NoResourcesInRouter, included_files: ["lib/still_web/router.ex"])
    |> assert_issue(fn issue ->
      assert issue.message =~ "Avoid using `resources` macro"
      refute issue.message =~ "\""
    end)
  end
end
