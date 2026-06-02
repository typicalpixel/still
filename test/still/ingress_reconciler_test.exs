defmodule Still.IngressReconcilerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Still.Applications.Application
  alias Still.Applications.HealthCheck
  alias Still.Events
  alias Still.Fleet.Server
  alias Still.IngressReconciler

  # ---------------------------------------------------------------------------
  # Stub Caddy — an Agent that records every get/load call so tests can assert
  # on sequence, counts, and the final config shape. Used via the injected
  # `:caddy_module` option (see CaddyProxy below).
  # ---------------------------------------------------------------------------

  defmodule StubCaddy do
    def setup(name, opts \\ []) do
      initial = Keyword.get(opts, :initial_config, %{})
      load_result = Keyword.get(opts, :load_result, :ok)

      Agent.start_link(
        fn -> %{config: initial, load_result: load_result, calls: []} end,
        name: name
      )
    end

    def set_config(name, config) do
      Agent.update(name, &Map.put(&1, :config, config))
    end

    def set_load_result(name, result) do
      Agent.update(name, &Map.put(&1, :load_result, result))
    end

    def calls(name), do: Agent.get(name, & &1.calls) |> Enum.reverse()

    def current_config(name), do: Agent.get(name, & &1.config)

    def get_config(name) do
      Agent.get_and_update(name, fn state ->
        {{:ok, state.config}, Map.update!(state, :calls, &[:get | &1])}
      end)
    end

    def load_config(name, new_config) do
      Agent.get_and_update(name, fn state ->
        new_state =
          state
          |> Map.update!(:calls, &[{:load, new_config} | &1])
          |> Map.put(:config, new_config)

        {state.load_result, new_state}
      end)
    end
  end

  defmodule CaddyProxy do
    alias Still.IngressReconcilerTest.StubCaddy

    def get_config, do: StubCaddy.get_config(:stub_caddy)
    def load_config(c), do: StubCaddy.load_config(:stub_caddy, c)
  end

  defp server(host, name \\ nil) do
    %Server{
      id: Ecto.UUID.generate(),
      name: name || "agent-#{host}",
      host: host,
      roles: ["application"]
    }
  end

  defp app(overrides) do
    defaults = %{
      id: Ecto.UUID.generate(),
      name: "api",
      type: :elixir_release,
      domain: "api.example.com",
      path_prefix: nil,
      exec_command: "bin/api start",
      health_check: %HealthCheck{
        path: "/health",
        interval_ms: 5_000,
        deadline_ms: 3_000
      }
    }

    struct(Application, Map.merge(defaults, overrides))
  end

  defp base_config do
    %{
      "admin" => %{"listen" => "localhost:2019"},
      "apps" => %{
        "http" => %{
          "servers" => %{
            "still" => %{
              "listen" => [":80"],
              "routes" => [
                %{
                  "@id" => "still_controller",
                  "match" => [%{"host" => ["still.example.com"]}],
                  "handle" => [%{"handler" => "reverse_proxy"}],
                  "terminal" => true
                },
                %{
                  "@id" => "still_catchall",
                  "handle" => [
                    %{"handler" => "static_response", "status_code" => 200, "body" => "Still"}
                  ],
                  "terminal" => true
                }
              ]
            }
          }
        }
      }
    }
  end

  setup do
    {:ok, pid} = StubCaddy.setup(:stub_caddy, initial_config: base_config())

    # Agent.start_link makes the stub die when the test process exits, but
    # that shutdown races the next test's start_link with the same name —
    # which intermittently fails with {:already_started, pid}. Stop it
    # synchronously here so the named registration is gone before the next
    # setup runs.
    on_exit(fn -> if Process.alive?(pid), do: Agent.stop(pid) end)

    :ok
  end

  # Starts a reconciler that sends {:ingress_reconciled, result} to the test
  # process after every reconcile pass. Consumes the mandatory initial
  # reconcile's message before returning so tests start from a known
  # post-initial-pass baseline.
  defp start_reconciler(routes_fn, opts \\ []) do
    {:ok, pid} =
      IngressReconciler.start_link(
        name: :"reconciler_#{System.unique_integer([:positive])}",
        caddy_module: CaddyProxy,
        list_routes: routes_fn,
        debounce_ms: Keyword.get(opts, :debounce_ms, 20),
        notifier: self()
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    assert_receive {:ingress_reconciled, _}, 500
    pid
  end

  describe "initial reconcile" do
    test "on startup, builds ingress routes from list_routes and pushes to Caddy" do
      routes_fn = fn ->
        [%{application: app(%{name: "api"}), servers: [server("10.0.0.3")]}]
      end

      _reconciler = start_reconciler(routes_fn)

      loaded = StubCaddy.current_config(:stub_caddy)
      routes = get_in(loaded, ["apps", "http", "servers", "still", "routes"])

      ids = Enum.map(routes, & &1["@id"])
      assert "still_controller" in ids
      assert "still_ingress_api" in ids
      # The catch-all is re-pinned to the very end after every reconcile.
      assert List.last(routes)["@id"] == "still_catchall"
      assert Enum.count(routes, &(&1["@id"] == "still_catchall")) == 1
    end

    test "when no apps have servers, pushes a config with no ingress routes" do
      _reconciler = start_reconciler(fn -> [] end)

      loaded = StubCaddy.current_config(:stub_caddy)
      routes = get_in(loaded, ["apps", "http", "servers", "still", "routes"])

      ingress_routes =
        Enum.filter(routes, &String.starts_with?(&1["@id"] || "", "still_ingress_"))

      assert ingress_routes == []
    end
  end

  describe "reconcile preserves non-ingress routes" do
    test "keeps the controller route and agent-local still_app_* routes untouched" do
      seeded =
        put_in(
          base_config(),
          ["apps", "http", "servers", "still", "routes"],
          [
            %{
              "@id" => "still_controller",
              "match" => [%{"host" => ["still.example.com"]}],
              "handle" => []
            },
            %{
              "@id" => "still_app_legacy",
              "match" => [%{"host" => ["legacy.test"]}],
              "handle" => []
            },
            %{
              "@id" => "still_catchall",
              "handle" => [
                %{"handler" => "static_response", "status_code" => 200, "body" => "Still"}
              ]
            }
          ]
        )

      StubCaddy.set_config(:stub_caddy, seeded)

      routes_fn = fn ->
        [%{application: app(%{name: "api"}), servers: [server("10.0.0.3")]}]
      end

      _reconciler = start_reconciler(routes_fn)

      loaded = StubCaddy.current_config(:stub_caddy)
      routes = get_in(loaded, ["apps", "http", "servers", "still", "routes"])
      ids = Enum.map(routes, & &1["@id"])

      assert "still_controller" in ids
      assert "still_app_legacy" in ids
      assert "still_ingress_api" in ids
      # Catch-all preserved, deduplicated, and kept last so it can't shadow
      # the freshly-appended ingress route.
      assert Enum.count(routes, &(&1["@id"] == "still_catchall")) == 1
      assert List.last(routes)["@id"] == "still_catchall"
      ingress_idx = Enum.find_index(routes, &(&1["@id"] == "still_ingress_api"))
      catchall_idx = Enum.find_index(routes, &(&1["@id"] == "still_catchall"))
      assert ingress_idx < catchall_idx
    end

    test "drops stale ingress routes that aren't in the current desired set" do
      seeded =
        put_in(
          base_config(),
          ["apps", "http", "servers", "still", "routes"],
          [
            %{
              "@id" => "still_ingress_gone",
              "match" => [%{"host" => ["gone.test"]}],
              "handle" => []
            }
          ]
        )

      StubCaddy.set_config(:stub_caddy, seeded)

      routes_fn = fn ->
        [%{application: app(%{name: "api"}), servers: [server("10.0.0.3")]}]
      end

      _reconciler = start_reconciler(routes_fn)

      loaded = StubCaddy.current_config(:stub_caddy)
      routes = get_in(loaded, ["apps", "http", "servers", "still", "routes"])
      ids = Enum.map(routes, & &1["@id"])

      refute "still_ingress_gone" in ids
      assert "still_ingress_api" in ids
    end
  end

  describe "debounced reconcile on fleet:changes events" do
    test "a fleet_changed event triggers one reconcile after debounce_ms" do
      routes_fn = fn -> [%{application: app(%{name: "api"}), servers: [server("10.0.0.3")]}] end

      _reconciler = start_reconciler(routes_fn)

      Events.fleet_changed()

      assert_receive {:ingress_reconciled, :ok}, 500
    end

    test "rapid bursts of fleet_changed events coalesce into a single reconcile" do
      routes_fn = fn -> [%{application: app(%{name: "api"}), servers: [server("10.0.0.3")]}] end

      _reconciler = start_reconciler(routes_fn, debounce_ms: 50)

      for _ <- 1..20, do: Events.fleet_changed()

      # The burst all falls inside one debounce window. Expect exactly one
      # completion message — and then no further completions even after the
      # debounce window has fully elapsed.
      assert_receive {:ingress_reconciled, :ok}, 500
      refute_receive {:ingress_reconciled, _}, 200
    end
  end

  describe "reconcile_now/0 with the default registered name" do
    test "targets the default-named process when no pid/name is passed" do
      routes_fn = fn -> [%{application: app(%{name: "api"}), servers: [server("10.0.0.3")]}] end

      {:ok, pid} =
        IngressReconciler.start_link(
          caddy_module: CaddyProxy,
          list_routes: routes_fn,
          debounce_ms: 20,
          notifier: self()
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      assert_receive {:ingress_reconciled, :ok}, 500

      assert :ok = IngressReconciler.reconcile_now()
    end
  end

  describe "unrelated messages" do
    test "handle_info ignores messages that aren't fleet events or debounce timers" do
      routes_fn = fn -> [%{application: app(%{name: "api"}), servers: [server("10.0.0.3")]}] end

      reconciler = start_reconciler(routes_fn)

      # Send a garbage message directly. The reconciler should drop it and
      # stay alive — a subsequent reconcile_now should still succeed.
      send(reconciler, :totally_unrelated)

      assert :ok = IngressReconciler.reconcile_now(reconciler)
      assert Process.alive?(reconciler)
    end
  end

  describe "Caddy load failures" do
    test "a load_config error is reported via notifier, logged, and the reconciler stays up" do
      StubCaddy.set_load_result(:stub_caddy, {:error, :boom})

      routes_fn = fn -> [%{application: app(%{name: "api"}), servers: [server("10.0.0.3")]}] end
      test_pid = self()

      log =
        capture_log(fn ->
          # start_reconciler waits for the initial reconcile; it should come
          # through with the stub's :boom error instead of :ok.
          {:ok, pid} =
            IngressReconciler.start_link(
              name: :"reconciler_#{System.unique_integer([:positive])}",
              caddy_module: CaddyProxy,
              list_routes: routes_fn,
              debounce_ms: 20,
              notifier: test_pid
            )

          on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

          assert_receive {:ingress_reconciled, {:error, :boom}}, 500
          assert Process.alive?(pid)

          # reconcile_now surfaces the error synchronously too.
          assert {:error, :boom} = IngressReconciler.reconcile_now(pid)
        end)

      assert log =~ "IngressReconciler: Caddy reconcile failed"
      assert log =~ ":boom"
    end
  end
end
