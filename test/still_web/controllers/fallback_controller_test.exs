defmodule StillWeb.FallbackControllerTest do
  use StillWeb.ConnCase, async: false

  alias StillWeb.FallbackController

  defp call_fallback(conn, error) do
    FallbackController.call(conn, error)
  end

  describe "changeset errors" do
    test "renders 422 with formatted errors", %{conn: conn} do
      changeset =
        %Still.Accounts.User{}
        |> Ecto.Changeset.change(%{})
        |> Ecto.Changeset.validate_required([:email])

      conn = call_fallback(conn, {:error, changeset})

      assert conn.status == 422
      body = json_response(conn, 422)
      assert body["error"]["message"] == "Validation failed"
      assert body["error"]["detail"]["email"] == ["can't be blank"]
    end

    test "interpolates changeset error parameters", %{conn: conn} do
      changeset =
        %Still.Accounts.User{}
        |> Ecto.Changeset.change(%{name: ""})
        |> Ecto.Changeset.validate_length(:name, min: 1)

      conn = call_fallback(conn, {:error, changeset})

      body = json_response(conn, 422)
      assert "should be at least 1 character(s)" in body["error"]["detail"]["name"]
    end
  end

  describe "domain errors" do
    test "renders 404 for :not_found", %{conn: conn} do
      conn = call_fallback(conn, {:error, :not_found})
      assert json_response(conn, 404)["error"]["message"] == "Not found"
    end

    test "renders 409 for :deployment_in_progress", %{conn: conn} do
      conn = call_fallback(conn, {:error, :deployment_in_progress})
      assert json_response(conn, 409)["error"]["message"] =~ "already in progress"
    end

    test "renders 409 for :no_servers_assigned", %{conn: conn} do
      conn = call_fallback(conn, {:error, :no_servers_assigned})
      assert json_response(conn, 409)["error"]["message"] =~ "No servers"
    end

    test "renders 409 for :insufficient_healthy_agents", %{conn: conn} do
      conn = call_fallback(conn, {:error, :insufficient_healthy_agents})
      assert json_response(conn, 409)["error"]["message"] =~ "healthy agents"
    end

    test "renders 409 for :no_available_ports", %{conn: conn} do
      conn = call_fallback(conn, {:error, :no_available_ports})
      assert json_response(conn, 409)["error"]["message"] =~ "port pair"
    end
  end
end
