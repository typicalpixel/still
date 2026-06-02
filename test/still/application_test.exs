defmodule Still.ApplicationTest do
  use ExUnit.Case, async: false

  describe "config_change/3" do
    test "delegates to StillWeb.Endpoint.config_change and returns :ok" do
      assert :ok = Still.Application.config_change([], [], [])
    end
  end

  describe "children_for_mode/1" do
    # These tests assert the full, production-shaped supervision tree for
    # :controller mode. The test env disables controller workers so the
    # default `mix test` run doesn't boot them; these tests flip the flag
    # back on to exercise the real shape.
    setup :enable_controller_workers

    test ":controller with workers on returns base + workers + only + self-announce" do
      children = Still.Application.children_for_mode(:controller)
      modules = Enum.map(children, &child_module/1)

      assert Still.Repo in modules
      assert Phoenix.PubSub in modules
      assert StillWeb.Endpoint in modules
      assert Still.AgentConnectionManager in modules
      assert Still.Orchestrator in modules
      assert Still.IngressReconciler in modules
      assert Still.Agent.NodeConnector in modules
      assert Still.Agent.NodeMetrics in modules
      refute Still.Agent.DeploymentManager in modules
      refute Still.Agent.HealthMonitor in modules
    end

    test ":controller with workers off returns just base children" do
      Application.put_env(:still, :start_controller_workers, false)

      children = Still.Application.children_for_mode(:controller)
      modules = Enum.map(children, &child_module/1)

      assert Still.Repo in modules
      assert StillWeb.Endpoint in modules
      refute Still.AgentConnectionManager in modules
      refute Still.Agent.NodeConnector in modules
    end

    test ":controller's NodeConnector is configured with the local node as the controller" do
      children = Still.Application.children_for_mode(:controller)

      connector_spec =
        Enum.find(children, fn
          {Still.Agent.NodeConnector, _opts} -> true
          _ -> false
        end)

      assert {Still.Agent.NodeConnector, opts} = connector_spec
      assert Keyword.get(opts, :controller_node) == node()
    end

    test ":agent includes NodeConnector, DeploymentManager, and HealthMonitor" do
      Application.put_env(:still, :controller_node, :fake@host)
      on_exit(fn -> Application.delete_env(:still, :controller_node) end)

      children = Still.Application.children_for_mode(:agent)
      modules = Enum.map(children, &child_module/1)

      assert Still.Agent.NodeConnector in modules
      assert Still.Agent.DeploymentManager in modules
      assert Still.Agent.HealthMonitor in modules
      refute Still.Repo in modules
      refute StillWeb.Endpoint in modules
    end

    test ":standalone includes controller children plus the full agent stack" do
      children = Still.Application.children_for_mode(:standalone)
      modules = Enum.map(children, &child_module/1)

      assert Still.Repo in modules
      assert StillWeb.Endpoint in modules
      assert Still.Agent.NodeConnector in modules
      assert Still.Agent.DeploymentManager in modules
      assert Still.Agent.HealthMonitor in modules
    end

    test ":standalone configures NodeConnector with the local node as the controller" do
      children = Still.Application.children_for_mode(:standalone)

      connector_spec =
        Enum.find(children, fn
          {Still.Agent.NodeConnector, _opts} -> true
          _ -> false
        end)

      assert {Still.Agent.NodeConnector, opts} = connector_spec
      assert Keyword.get(opts, :controller_node) == node()
    end
  end

  # Extract the module from a child spec (handles {Module, opts}, Module, and tuples)
  defp child_module({module, _opts}) when is_atom(module), do: module
  defp child_module(module) when is_atom(module), do: module

  defp enable_controller_workers(_context) do
    prior = Application.get_env(:still, :start_controller_workers, true)
    Application.put_env(:still, :start_controller_workers, true)
    on_exit(fn -> Application.put_env(:still, :start_controller_workers, prior) end)
    :ok
  end
end
