defmodule Still.Agent.DeployLogCollectorTest do
  use ExUnit.Case, async: false

  alias Still.Agent.DeployLogCollector

  setup do
    start_supervised!({DeployLogCollector, controller_node: node()})
    :ok
  end

  test "finish on an idle collector is a no-op" do
    assert DeployLogCollector.finish() == :ok
  end

  test "begin without a deployment_id stays idle" do
    # nil deployment_id short-circuits before any journalctl shellout.
    assert DeployLogCollector.begin(nil, "app", :blue) == :ok
    assert DeployLogCollector.finish() == :ok
  end

  test "a tick while idle is ignored" do
    send(Process.whereis(DeployLogCollector), :tick)
    assert %{capture: nil} = :sys.get_state(DeployLogCollector)
  end
end
