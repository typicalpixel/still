defmodule Still.Agent.DeploymentManagerTest do
  use ExUnit.Case, async: false

  alias Still.Agent.ApplicationState
  alias Still.Agent.CaddyManager
  alias Still.Agent.DeploymentManager
  alias Still.Agent.StatePersistence

  # ExUnit-shaped wrapper over setup_tmp_applications_dir/0 so it can be
  # used with `setup :tmp_applications_dir`.
  defp tmp_applications_dir(_ctx) do
    %{tmp_dir: setup_tmp_applications_dir()}
  end

  defp valid_spec(overrides \\ %{}) do
    Map.merge(
      %{
        application: "my-api",
        type: :elixir_release,
        version: "0.0.1+abc",
        artifact_url: "https://example.com/app.tar.gz",
        domain: "my-api.example.com",
        env_vars: %{},
        exec_command: "bin/my_api start",
        health_check: %{path: "/health", interval_ms: 1_000, deadline_ms: 30_000},
        hooks: %{},
        port_blue: 4_000,
        port_green: 4_001
      },
      overrides
    )
  end

  describe "run_steps/2" do
    test "returns the initial context unchanged when the step list is empty" do
      ctx = %{spec: valid_spec()}
      assert {:ok, ^ctx} = DeploymentManager.run_steps([], ctx)
    end

    test "runs a single successful step and threads the modified context through" do
      step = fn ctx -> {:ok, Map.put(ctx, :marker, :ran)} end
      ctx = %{spec: valid_spec()}

      assert {:ok, new_ctx} = DeploymentManager.run_steps([{:only, step}], ctx)
      assert new_ctx.marker == :ran
    end

    test "runs multiple steps in sequence, each seeing the previous step's modifications" do
      steps = [
        {:first, fn ctx -> {:ok, Map.put(ctx, :order, [:first])} end},
        {:second, fn ctx -> {:ok, Map.update!(ctx, :order, &(&1 ++ [:second]))} end},
        {:third, fn ctx -> {:ok, Map.update!(ctx, :order, &(&1 ++ [:third]))} end}
      ]

      ctx = %{spec: valid_spec()}

      assert {:ok, new_ctx} = DeploymentManager.run_steps(steps, ctx)
      assert new_ctx.order == [:first, :second, :third]
    end

    test "halts on the first failing step and reports its name" do
      steps = [
        {:ok_one, fn ctx -> {:ok, ctx} end},
        {:bad, fn _ctx -> {:error, "boom"} end},
        {:never_run, fn _ctx -> raise "should not run" end}
      ]

      ctx = %{spec: valid_spec()}

      assert {:error, %{step: :bad, reason: "boom"}} = DeploymentManager.run_steps(steps, ctx)
    end

    test "reports the first step's name when the first step fails" do
      steps = [{:first, fn _ctx -> {:error, "nope"} end}]
      ctx = %{spec: valid_spec()}

      assert {:error, %{step: :first, reason: "nope"}} = DeploymentManager.run_steps(steps, ctx)
    end
  end

  describe "default_steps_for/1" do
    test ":elixir_release returns the full lifecycle including blue/green orchestration" do
      names = DeploymentManager.default_steps_for(:elixir_release) |> Enum.map(&elem(&1, 0))

      assert names == [
               :pre_deploy,
               :downloading,
               :unpacking,
               :symlinking,
               :release,
               :starting,
               :health_checking,
               :switching,
               :monitoring,
               :draining,
               :stopping_old,
               :cleanup,
               :post_deploy
             ]
    end

    test ":release sits between :symlinking and :starting so migrations run against the new release files but before the new BEAM boots" do
      names = DeploymentManager.default_steps_for(:elixir_release) |> Enum.map(&elem(&1, 0))
      release_index = Enum.find_index(names, &(&1 == :release))
      assert Enum.at(names, release_index - 1) == :symlinking
      assert Enum.at(names, release_index + 1) == :starting
    end

    test ":process uses the same lifecycle as :elixir_release" do
      assert DeploymentManager.default_steps_for(:process) ==
               DeploymentManager.default_steps_for(:elixir_release)
    end

    test ":static_site skips start, health_check, and stop_old" do
      names = DeploymentManager.default_steps_for(:static_site) |> Enum.map(&elem(&1, 0))

      assert names == [
               :pre_deploy,
               :downloading,
               :unpacking,
               :symlinking,
               :switching,
               :cleanup,
               :post_deploy
             ]

      refute :starting in names
      refute :health_checking in names
      refute :stopping_old in names
      refute :release in names
    end
  end

  describe "build_app_route/1" do
    test "matches on host only when path_prefix is absent" do
      ctx = %{spec: valid_spec(%{domain: "api.example.com"}), target_port: 4_000}
      route = DeploymentManager.build_app_route(ctx)

      assert route["@id"] == "still_app_my-api"
      assert route["terminal"] == true
      assert [%{"host" => ["api.example.com"]} = match] = route["match"]
      refute Map.has_key?(match, "path")
    end

    test "matches on host and path when path_prefix is set" do
      ctx = %{
        spec: valid_spec(%{domain: "example.com", path_prefix: "/api"}),
        target_port: 4_000
      }

      assert [%{"host" => ["example.com"], "path" => ["/api*"]}] =
               DeploymentManager.build_app_route(ctx)["match"]
    end

    test "ignores an empty string path_prefix the same as nil" do
      ctx = %{spec: valid_spec(%{path_prefix: ""}), target_port: 4_000}

      assert [match] = DeploymentManager.build_app_route(ctx)["match"]
      refute Map.has_key?(match, "path")
    end

    test ":elixir_release builds a reverse_proxy handle pointed at the target port" do
      ctx = %{
        spec: valid_spec(%{type: :elixir_release, domain: "api.example.com"}),
        target_port: 4_321
      }

      assert [
               %{
                 "handler" => "reverse_proxy",
                 "upstreams" => [%{"dial" => "localhost:4321"}]
               }
             ] = DeploymentManager.build_app_route(ctx)["handle"]
    end

    test ":process uses the same reverse_proxy handle shape as :elixir_release" do
      ctx = %{
        spec: valid_spec(%{type: :process, domain: "worker.example.com"}),
        target_port: 9_999
      }

      assert [%{"handler" => "reverse_proxy"}] =
               DeploymentManager.build_app_route(ctx)["handle"]
    end

    test "serves a 503 maintenance page instead of proxying when the spec is in maintenance" do
      ctx = %{
        spec: valid_spec(%{maintenance: true, maintenance_message: "brb"}),
        target_port: 4_000
      }

      assert [%{"handler" => "static_response", "status_code" => 503, "body" => "brb"}] =
               DeploymentManager.build_app_route(ctx)["handle"]
    end

    test ":static_site builds a subroute with try_files /index.html fallback" do
      ctx = %{
        spec: valid_spec(%{type: :static_site, domain: "www.example.com"}),
        target_port: nil,
        target_symlink: "/var/apps/my-api/current_blue"
      }

      assert [
               %{
                 "handler" => "subroute",
                 "routes" => routes
               }
             ] = DeploymentManager.build_app_route(ctx)["handle"]

      # vars sets the filesystem root for the file_server and the file matcher
      assert Enum.any?(routes, fn r ->
               match?(
                 [%{"handler" => "vars", "root" => "/var/apps/my-api/current_blue"} | _],
                 r["handle"]
               )
             end)

      # try_files matcher rewrites deep links to /index.html so SPAs don't 404
      try_files_route =
        Enum.find(routes, fn r ->
          match?([%{"file" => %{"try_files" => _}}], r["match"])
        end)

      assert try_files_route
      [%{"file" => %{"try_files" => files}}] = try_files_route["match"]
      assert "/index.html" in files

      assert [%{"handler" => "rewrite", "uri" => "{http.matchers.file.relative}"}] =
               try_files_route["handle"]

      # Final handler is a plain file_server; the vars handler set its root
      assert Enum.any?(routes, fn r ->
               match?([%{"handler" => "file_server"}], r["handle"])
             end)
    end
  end

  describe "slot_env_vars/1" do
    test "exposes the slot so a release can build a per-slot RELEASE_NODE; blue and green differ" do
      blue = slot_env_map(%{application: "forge"}, :blue)
      green = slot_env_map(%{application: "forge"}, :green)

      assert blue["STILL_APPLICATION"] == "forge"
      assert blue["STILL_TARGET_SLOT"] == "blue"
      assert green["STILL_TARGET_SLOT"] == "green"
      assert blue["STILL_TARGET_SLOT"] != green["STILL_TARGET_SLOT"]

      # Still emits the materials; the release owns RELEASE_NODE itself.
      refute Map.has_key?(blue, "RELEASE_NODE")
    end

    test "passes through the internal node host, the port, and the version" do
      env = slot_env_map(%{version: "2.3.4+build"}, :blue, node_host: "10.0.0.7", port: 4_123)

      assert env["STILL_NODE_HOST"] == "10.0.0.7"
      assert env["PORT"] == 4_123
      assert env["STILL_RELEASE_VERSION"] == "2.3.4+build"
    end

    test "lists Still-owned vars first, then the app's own env_vars" do
      list =
        DeploymentManager.slot_env_vars(%{
          spec: valid_spec(%{env_vars: %{"FOO" => "bar"}}),
          target_slot: :blue,
          target_port: 4_000,
          node_host: "127.0.0.1"
        })

      keys = Enum.map(list, &elem(&1, 0))

      assert Enum.take(keys, 5) == [
               "PORT",
               "STILL_APPLICATION",
               "STILL_TARGET_SLOT",
               "STILL_NODE_HOST",
               "STILL_RELEASE_VERSION"
             ]

      assert List.last(keys) == "FOO"
    end
  end

  describe "handle_call/3 :deploy" do
    setup :tmp_applications_dir

    test "returns the spec version on success when all steps pass" do
      stub_provider = fn _type ->
        [{:only, fn ctx -> {:ok, ctx} end}]
      end

      state = %{step_provider: stub_provider}
      spec = valid_spec(%{version: "1.2.3+xyz"})

      assert {:reply, {:ok, "1.2.3+xyz"}, ^state} =
               DeploymentManager.handle_call({:deploy, spec}, self(), state)
    end

    test "returns the failed step's tag and reason when a step fails" do
      stub_provider = fn _type ->
        [
          {:downloading, fn ctx -> {:ok, ctx} end},
          {:unpacking, fn _ctx -> {:error, "tar: file not found"} end}
        ]
      end

      state = %{step_provider: stub_provider}
      spec = valid_spec()

      assert {:reply, {:error, %{step: :unpacking, reason: "tar: file not found"}}, ^state} =
               DeploymentManager.handle_call({:deploy, spec}, self(), state)
    end

    test "uses the spec's type to choose the step list" do
      type_seen = :counters.new(1, [:atomics])

      provider = fn type ->
        :counters.add(type_seen, 1, 1)
        send(self(), {:type_seen, type})
        [{:only, fn ctx -> {:ok, ctx} end}]
      end

      state = %{step_provider: provider}
      spec = valid_spec(%{type: :static_site})

      DeploymentManager.handle_call({:deploy, spec}, self(), state)

      assert_received {:type_seen, :static_site}
    end

    test "fails with :state_unreadable when state.json is corrupt rather than clobbering the live slot" do
      spec = valid_spec()
      app_dir = Path.join(Application.fetch_env!(:still, :applications_dir), spec.application)
      File.mkdir_p!(app_dir)
      File.write!(Path.join(app_dir, "state.json"), "{ not valid json")

      state = %{step_provider: fn _type -> [{:only, fn ctx -> {:ok, ctx} end}] end}

      assert {:reply, {:error, {:state_unreadable, app}}, ^state} =
               DeploymentManager.handle_call({:deploy, spec}, self(), state)

      assert app == spec.application
    end
  end

  describe "start_link/1 + deploy/1 with an injected step provider" do
    setup :tmp_applications_dir

    test "runs the provided step list end-to-end and returns the deployed version" do
      stub_provider = fn _type -> [{:only, fn ctx -> {:ok, ctx} end}] end
      start_supervised!({DeploymentManager, step_provider: stub_provider})

      assert {:ok, "9.9.9+unit"} =
               DeploymentManager.deploy(valid_spec(%{version: "9.9.9+unit"}))
    end
  end

  describe "default_rollback_steps_for/1" do
    test ":elixir_release skips download/unpack/symlink and reuses the on-disk release" do
      names =
        DeploymentManager.default_rollback_steps_for(:elixir_release) |> Enum.map(&elem(&1, 0))

      assert names == [
               :pre_rollback,
               :starting,
               :health_checking,
               :switching,
               :monitoring,
               :draining,
               :stopping_old,
               :cleanup,
               :post_rollback
             ]
    end

    test ":process uses the same rollback lifecycle as :elixir_release" do
      assert DeploymentManager.default_rollback_steps_for(:process) ==
               DeploymentManager.default_rollback_steps_for(:elixir_release)
    end

    test ":static_site rollback flips caddy, cleans up, and runs pre/post hooks" do
      names = DeploymentManager.default_rollback_steps_for(:static_site) |> Enum.map(&elem(&1, 0))
      assert names == [:pre_rollback, :switching, :cleanup, :post_rollback]
    end
  end

  describe "handle_call/3 :rollback" do
    test "returns :no_previous_version when no state file exists for the application" do
      state = %{
        step_provider: fn _ -> [] end,
        rollback_step_provider: fn _ -> [] end
      }

      spec = valid_spec(%{application: "never-deployed-#{System.unique_integer([:positive])}"})

      assert {:reply, {:error, :no_previous_version}, ^state} =
               DeploymentManager.handle_call({:rollback, spec}, self(), state)
    end

    test "uses the rollback_step_provider and returns the previous version on success" do
      setup_tmp_applications_dir()
      spec = valid_spec(%{application: "rollback-unit-test"})

      write_state(spec.application,
        active_slot: "green",
        active_port: spec.port_green,
        current_version: "2.0.0",
        previous_version: "1.0.0"
      )

      test_pid = self()

      stub_rollback = fn type ->
        [
          {:only,
           fn ctx ->
             send(test_pid, {:rollback_ctx, type, ctx})
             {:ok, ctx}
           end}
        ]
      end

      state = %{
        step_provider: fn _ -> [] end,
        rollback_step_provider: stub_rollback
      }

      assert {:reply, {:ok, "1.0.0"}, ^state} =
               DeploymentManager.handle_call({:rollback, spec}, self(), state)

      assert_received {:rollback_ctx, :elixir_release, ctx}
      assert ctx.target_slot == :blue
      assert ctx.target_port == spec.port_blue
      assert ctx.previous_slot == :green
      assert ctx.spec.version == "1.0.0"
    end
  end

  describe "start_link/1 + rollback/1 with an injected rollback step provider" do
    test "exercises the public API and propagates a failing step's reason" do
      setup_tmp_applications_dir()
      spec = valid_spec(%{application: "rollback-fail-test"})

      write_state(spec.application,
        active_slot: "blue",
        active_port: spec.port_blue,
        current_version: "2.0.0",
        previous_version: "1.0.0"
      )

      failing_provider = fn _type ->
        [{:exploding_step, fn _ctx -> {:error, "it broke"} end}]
      end

      start_supervised!(
        {DeploymentManager,
         step_provider: fn _ -> [] end, rollback_step_provider: failing_provider}
      )

      assert {:error, %{step: :exploding_step, reason: "it broke"}} =
               DeploymentManager.rollback(spec)
    end
  end

  describe "handle_call/3 :reconcile_route" do
    setup do
      %{state: %{step_provider: fn _ -> [] end, rollback_step_provider: fn _ -> [] end}}
    end

    test "rebuilds the app route from active state with the new domain and port", %{state: state} do
      setup_tmp_applications_dir()

      write_state("reconcile-unit",
        active_slot: "green",
        active_port: 4_001,
        current_version: "1.0.0",
        previous_version: nil
      )

      stub_caddy(%{"apps" => %{"http" => %{"servers" => %{"still" => %{"routes" => []}}}}})

      spec = %{
        application: "reconcile-unit",
        type: :elixir_release,
        domain: "new.example.com",
        path_prefix: nil
      }

      assert {:reply, {:ok, :reconciled}, ^state} =
               DeploymentManager.handle_call({:reconcile_route, spec}, self(), state)

      assert_received {:loaded, loaded}
      routes = loaded["apps"]["http"]["servers"]["still"]["routes"]
      # App route written, catch-all kept last so it can't shadow it.
      assert List.last(routes)["@id"] == "still_catchall"
      route = Enum.find(routes, &(&1["@id"] == "still_app_reconcile-unit"))
      assert [%{"host" => ["new.example.com"]}] = route["match"]

      assert [%{"handler" => "reverse_proxy", "upstreams" => [%{"dial" => "localhost:4001"}]}] =
               route["handle"]
    end

    test "points a static_site route at the active slot's symlink", %{state: state} do
      tmp_dir = setup_tmp_applications_dir()

      write_state("reconcile-static",
        active_slot: "blue",
        active_port: nil,
        current_version: "1.0.0",
        previous_version: nil
      )

      stub_caddy(%{"apps" => %{"http" => %{"servers" => %{"still" => %{"routes" => []}}}}})

      spec = %{
        application: "reconcile-static",
        type: :static_site,
        domain: "site.example.com",
        path_prefix: nil
      }

      assert {:reply, {:ok, :reconciled}, ^state} =
               DeploymentManager.handle_call({:reconcile_route, spec}, self(), state)

      assert_received {:loaded, loaded}
      all_routes = loaded["apps"]["http"]["servers"]["still"]["routes"]
      assert List.last(all_routes)["@id"] == "still_catchall"
      route = Enum.find(all_routes, &(&1["@id"] == "still_app_reconcile-static"))
      [%{"handler" => "subroute", "routes" => routes}] = route["handle"]
      expected_root = Path.join([tmp_dir, "reconcile-static", "current_blue"])

      assert Enum.any?(routes, fn r ->
               match?([%{"handler" => "vars", "root" => ^expected_root} | _], r["handle"])
             end)
    end

    test "returns :noop when the app has no persisted state", %{state: state} do
      setup_tmp_applications_dir()

      spec = %{
        application: "never-deployed-#{System.unique_integer([:positive])}",
        type: :elixir_release,
        domain: "x.example.com",
        path_prefix: nil
      }

      assert {:reply, {:ok, :noop}, ^state} =
               DeploymentManager.handle_call({:reconcile_route, spec}, self(), state)
    end

    test "surfaces the Caddy error when the still server isn't provisioned", %{state: state} do
      setup_tmp_applications_dir()

      write_state("reconcile-err",
        active_slot: "blue",
        active_port: 4_000,
        current_version: "1.0.0",
        previous_version: nil
      )

      # No "still" server in the config → put_app_route can't find its routes.
      stub_caddy(%{"apps" => %{"http" => %{"servers" => %{}}}})

      spec = %{
        application: "reconcile-err",
        type: :elixir_release,
        domain: "x.example.com",
        path_prefix: nil
      }

      assert {:reply, {:error, :caddy_server_not_provisioned}, ^state} =
               DeploymentManager.handle_call({:reconcile_route, spec}, self(), state)
    end

    test "toggling maintenance off through reconcile restores the proxy handle", %{state: state} do
      setup_tmp_applications_dir()

      write_state("reconcile-maint",
        active_slot: "green",
        active_port: 4_002,
        current_version: "1.0.0",
        previous_version: nil
      )

      stub_caddy(%{"apps" => %{"http" => %{"servers" => %{"still" => %{"routes" => []}}}}})

      base = %{
        application: "reconcile-maint",
        type: :elixir_release,
        domain: "maint.example.com",
        path_prefix: nil
      }

      # Enter maintenance: the app's route serves a 503 instead of proxying.
      maint_on = Map.merge(base, %{maintenance: true, maintenance_message: "brb"})

      assert {:reply, {:ok, :reconciled}, ^state} =
               DeploymentManager.handle_call({:reconcile_route, maint_on}, self(), state)

      assert_received {:loaded, on_loaded}
      on_routes = on_loaded["apps"]["http"]["servers"]["still"]["routes"]
      assert List.last(on_routes)["@id"] == "still_catchall"
      on_route = Enum.find(on_routes, &(&1["@id"] == "still_app_reconcile-maint"))

      assert [%{"handler" => "static_response", "status_code" => 503, "body" => "brb"}] =
               on_route["handle"]

      # Exit maintenance: the route goes back to a reverse_proxy at the active port.
      assert {:reply, {:ok, :reconciled}, ^state} =
               DeploymentManager.handle_call(
                 {:reconcile_route, Map.put(base, :maintenance, false)},
                 self(),
                 state
               )

      assert_received {:loaded, off_loaded}
      off_routes = off_loaded["apps"]["http"]["servers"]["still"]["routes"]
      assert List.last(off_routes)["@id"] == "still_catchall"
      off_route = Enum.find(off_routes, &(&1["@id"] == "still_app_reconcile-maint"))

      assert [%{"handler" => "reverse_proxy", "upstreams" => [%{"dial" => "localhost:4002"}]}] =
               off_route["handle"]
    end
  end

  describe "start_link/1 + reconcile_route/1" do
    test "exercises the public API and no-ops when nothing is deployed" do
      setup_tmp_applications_dir()
      start_supervised!({DeploymentManager, step_provider: fn _ -> [] end})

      spec = %{
        application: "never-deployed-#{System.unique_integer([:positive])}",
        type: :elixir_release,
        domain: "x.example.com",
        path_prefix: nil
      }

      assert {:ok, :noop} = DeploymentManager.reconcile_route(spec)
    end
  end

  defp slot_env_map(spec_overrides, slot, opts \\ []) do
    %{
      spec: valid_spec(spec_overrides),
      target_slot: slot,
      target_port: Keyword.get(opts, :port, 4_000),
      node_host: Keyword.get(opts, :node_host, "127.0.0.1")
    }
    |> DeploymentManager.slot_env_vars()
    |> Map.new()
  end

  defp stub_caddy(current) do
    test_pid = self()

    Req.Test.stub(CaddyManager, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/config/"} ->
          Req.Test.json(conn, current)

        {"POST", "/load"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:loaded, Jason.decode!(body)})
          Req.Test.json(conn, %{})
      end
    end)
  end

  defp setup_tmp_applications_dir do
    tmp_dir =
      Path.join(System.tmp_dir!(), "still-dm-rollback-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    original = Application.get_env(:still, :applications_dir)
    Application.put_env(:still, :applications_dir, tmp_dir)

    ExUnit.Callbacks.on_exit(fn ->
      File.rm_rf!(tmp_dir)

      if is_nil(original) do
        Application.delete_env(:still, :applications_dir)
      else
        Application.put_env(:still, :applications_dir, original)
      end
    end)

    tmp_dir
  end

  defp write_state(application, opts) do
    state = %ApplicationState{
      type: Keyword.get(opts, :type, "elixir_release"),
      active_slot: Keyword.fetch!(opts, :active_slot),
      active_port: Keyword.get(opts, :active_port),
      current_version: Keyword.fetch!(opts, :current_version),
      previous_version: Keyword.fetch!(opts, :previous_version),
      last_health_check_at: nil
    }

    :ok = StatePersistence.write(application, state)
  end
end
