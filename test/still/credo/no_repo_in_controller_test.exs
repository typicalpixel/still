defmodule Still.Credo.NoRepoInControllerTest do
  use Credo.Test.Case, async: true

  alias Still.Credo.NoRepoInController

  @controller_params [controller_paths: ["lib/still_web/controllers/"]]

  test "reports Repo calls in controller files" do
    """
    defmodule StillWeb.UserController do
      def show(conn, %{"id" => id}) do
        user = Still.Repo.get!(User, id)
        render(conn, :show, user: user)
      end
    end
    """
    |> to_source_file("lib/still_web/controllers/user_controller.ex")
    |> run_check(NoRepoInController, @controller_params)
    |> assert_issue(fn issue ->
      assert issue.trigger == "Still.Repo.get!"
    end)
  end

  test "ignores non-controller files" do
    """
    defmodule Still.Accounts do
      def get_user!(id), do: Still.Repo.get!(User, id)
    end
    """
    |> to_source_file("lib/still/accounts.ex")
    |> run_check(NoRepoInController, @controller_params)
    |> refute_issues()
  end

  test "detects Repo by name ending when no repo_modules configured" do
    """
    defmodule StillWeb.UserController do
      def show(conn, %{"id" => id}) do
        user = MyApp.Repo.get!(User, id)
        render(conn, :show, user: user)
      end
    end
    """
    |> to_source_file("lib/still_web/controllers/user_controller.ex")
    |> run_check(NoRepoInController, @controller_params)
    |> assert_issue()
  end

  test "only checks configured repo_modules when provided" do
    """
    defmodule StillWeb.UserController do
      def show(conn, %{"id" => id}) do
        user = Other.Repo.get!(User, id)
        render(conn, :show, user: user)
      end
    end
    """
    |> to_source_file("lib/still_web/controllers/user_controller.ex")
    |> run_check(NoRepoInController,
      controller_paths: ["lib/still_web/controllers/"],
      repo_modules: [Still.Repo]
    )
    |> refute_issues()
  end

  test "returns no issues when controller_paths is empty" do
    """
    defmodule StillWeb.UserController do
      def show(conn, %{"id" => id}) do
        user = Still.Repo.get!(User, id)
        render(conn, :show, user: user)
      end
    end
    """
    |> to_source_file("lib/still_web/controllers/user_controller.ex")
    |> run_check(NoRepoInController, controller_paths: [])
    |> refute_issues()
  end
end
