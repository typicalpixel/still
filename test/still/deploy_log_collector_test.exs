defmodule Still.DeployLogCollectorTest do
  use Still.DataCase, async: false

  import ExUnit.CaptureLog
  import Still.ApplicationsFixtures
  import Still.DeploymentsFixtures
  import Still.FleetFixtures

  alias Still.Applications
  alias Still.Audit.Actor
  alias Still.DeployLogCollector
  alias Still.Deployments
  alias Still.Events

  setup do
    start_supervised!(DeployLogCollector)

    app = application_fixture()
    server = server_fixture()
    {:ok, _} = Applications.assign_server(Actor.system(), app, server)
    deploy = deployment_fixture(app)
    step = Deployments.get_step_for_server!(deploy.id, server.id)

    %{deploy: deploy, server: server, step: step}
  end

  test "buffers a live capture and exposes it via text_for/2", %{deploy: deploy, server: server} do
    Events.subscribe("deploy_logs:#{deploy.id}")

    DeployLogCollector.capture(deploy.id, server.id, "booting…", false)

    # The broadcast is sent after the ETS write, so receiving it means the
    # buffer is populated.
    assert_receive {:deploy_log_updated, %{deployment_id: id}}
    assert id == deploy.id
    assert DeployLogCollector.text_for(deploy.id, server.id) == "booting…"
  end

  test "finalizing persists the log onto the step and clears the buffer", %{
    deploy: deploy,
    server: server,
    step: step
  } do
    Events.subscribe("deploy_logs:#{deploy.id}")

    DeployLogCollector.capture(deploy.id, server.id, "live tick", false)
    DeployLogCollector.capture(deploy.id, server.id, "final crash blob", true)

    assert_receive {:deploy_log_updated, _}
    assert_receive {:deploy_log_updated, _}

    assert DeployLogCollector.text_for(deploy.id, server.id) == nil
    assert Deployments.get_deployment_step!(step.id).log == "final crash blob"
  end

  test "finalizing an unknown step is a no-op and keeps the collector alive", %{server: server} do
    bogus = Ecto.UUID.generate()
    Events.subscribe("deploy_logs:#{bogus}")

    DeployLogCollector.capture(bogus, server.id, "orphan", true)

    assert_receive {:deploy_log_updated, %{deployment_id: ^bogus}}
    assert Process.alive?(Process.whereis(DeployLogCollector))
  end

  test "sweep drops a buffer whose deployment no longer exists", %{server: server} do
    ghost = Ecto.UUID.generate()
    Events.subscribe("deploy_logs:#{ghost}")
    DeployLogCollector.capture(ghost, server.id, "ghost", false)
    assert_receive {:deploy_log_updated, _}
    assert DeployLogCollector.text_for(ghost, server.id) == "ghost"

    pid = Process.whereis(DeployLogCollector)
    send(pid, :sweep)
    :sys.get_state(pid)
    assert DeployLogCollector.text_for(ghost, server.id) == nil
  end

  test "a persist exception is contained — the collector survives and other buffers live", %{
    deploy: deploy,
    server: server
  } do
    pid = Process.whereis(DeployLogCollector)
    Events.subscribe("deploy_logs:#{deploy.id}")

    # Raw cast bypassing capture/4's is_binary guard: a non-binary log makes
    # put_step_log raise inside persist, exercising the rescue.
    log =
      capture_log(fn ->
        GenServer.cast(pid, {:capture, deploy.id, server.id, :not_a_binary, true})
        assert_receive {:deploy_log_updated, _}
      end)

    assert log =~ "persisting"
    assert Process.alive?(pid)
  end

  test "sweep keeps an in-flight buffer but drops one whose deploy went terminal", %{
    deploy: deploy,
    server: server
  } do
    Events.subscribe("deploy_logs:#{deploy.id}")
    DeployLogCollector.capture(deploy.id, server.id, "orphaned buffer", false)
    assert_receive {:deploy_log_updated, _}

    pid = Process.whereis(DeployLogCollector)

    # deploy is still pending (non-terminal) -> sweep leaves the buffer alone.
    send(pid, :sweep)
    :sys.get_state(pid)
    assert DeployLogCollector.text_for(deploy.id, server.id) == "orphaned buffer"

    # once the deploy is terminal without a done:true finalize, sweep reclaims it.
    Deployments.fail_deployment!(deploy, "crashed")
    send(pid, :sweep)
    :sys.get_state(pid)
    assert DeployLogCollector.text_for(deploy.id, server.id) == nil
  end
end
