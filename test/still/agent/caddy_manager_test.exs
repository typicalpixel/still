defmodule Still.Agent.CaddyManagerTest do
  use ExUnit.Case, async: true

  alias Still.Agent.CaddyManager

  describe "get_config/0" do
    test "returns the parsed Caddy config on a 2xx response" do
      Req.Test.stub(CaddyManager, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/config/"
        Req.Test.json(conn, %{"apps" => %{"http" => %{}}})
      end)

      assert {:ok, %{"apps" => %{"http" => %{}}}} = CaddyManager.get_config()
    end

    @tag :capture_log
    test "returns a tagged error on non-2xx" do
      Req.Test.stub(CaddyManager, fn conn ->
        conn
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{"error" => "boom"})
      end)

      assert {:error, {:caddy_status, 500, %{"error" => "boom"}}} = CaddyManager.get_config()
    end

    @tag :capture_log
    test "returns the underlying error when the request fails" do
      Req.Test.stub(CaddyManager, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, %Req.TransportError{reason: :econnrefused}} = CaddyManager.get_config()
    end
  end

  describe "load_config/1" do
    test "POSTs the config to /load and returns :ok on success" do
      config = %{"apps" => %{"http" => %{"servers" => %{}}}}

      Req.Test.stub(CaddyManager, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/load"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == config
        Req.Test.json(conn, %{})
      end)

      assert :ok = CaddyManager.load_config(config)
    end

    @tag :capture_log
    test "returns a tagged error when Caddy rejects the config" do
      Req.Test.stub(CaddyManager, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"error" => "invalid config"})
      end)

      assert {:error, {:caddy_status, 400, %{"error" => "invalid config"}}} =
               CaddyManager.load_config(%{"bad" => "config"})
    end

    @tag :capture_log
    test "returns the underlying error when the request fails" do
      Req.Test.stub(CaddyManager, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, %Req.TransportError{reason: :timeout}} =
               CaddyManager.load_config(%{})
    end
  end
end
