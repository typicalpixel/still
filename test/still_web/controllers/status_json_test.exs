defmodule StillWeb.StatusJSONTest do
  use ExUnit.Case, async: true

  alias Still.Applications.Application
  alias Still.Applications.ApplicationServer
  alias Still.Fleet.Server
  alias StillWeb.APIVersion
  alias StillWeb.StatusJSON

  import Still.AgentFixtures

  defp sample_server(overrides \\ %{}) do
    base = %Server{
      id: "srv-1",
      name: "bm-fra-01",
      host: "10.10.0.11",
      roles: ["application"],
      last_seen_at: ~U[2026-04-20 15:00:00.000000Z],
      metadata: %{"hostname" => "bm-fra-01"}
    }

    struct(base, overrides)
  end

  describe "render_overview/1" do
    test "folds the API version into the payload" do
      overview = %{bootstrap_required: false, server_count: 2, connected_server_count: 1}
      shape = StatusJSON.render_overview(overview)

      assert shape.data.api_version == APIVersion.current()
      assert shape.data.server_count == 2
      assert shape.data.connected_server_count == 1
    end
  end

  describe "server/1" do
    test "renders disconnected when report is nil" do
      shape = StatusJSON.server(%{server: sample_server(), report: nil, metrics: nil})

      assert shape.connection_status == "disconnected"
      assert shape.connected_at == nil
      assert shape.applications == []
      assert shape.metadata["hostname"] == "bm-fra-01"
      assert shape.metrics == nil
    end

    test "renders connected with live application list" do
      report =
        agent_report_fixture(
          server_id: "srv-1",
          applications: [reported_application_fixture(application_name: "my-api")]
        )

      shape =
        StatusJSON.server(%{
          server: sample_server(),
          report: report,
          metrics: nil
        })

      assert shape.connection_status == "connected"
      assert shape.connected_at == report.connected_at

      assert [%{application_name: "my-api", health: :healthy}] = shape.applications
    end

    test "includes the metrics shape when a sample is present" do
      sample = %{
        at: ~U[2026-04-20 15:00:00.000000Z],
        cpu_pct: 12,
        mem_pct: 48,
        disk_pct: 37
      }

      shape =
        StatusJSON.server(%{
          server: sample_server(),
          report: nil,
          metrics: sample
        })

      assert shape.metrics == sample
    end
  end

  describe "render_servers/1" do
    test "maps over the entry list" do
      assert %{data: [%{connection_status: "disconnected"}]} =
               StatusJSON.render_servers([%{server: sample_server(), report: nil, metrics: nil}])
    end
  end

  describe "application/1" do
    test "counts healthy servers across the assignments" do
      app = %Application{name: "my-api", type: :elixir_release, domain: "d", min_healthy: 1}

      row = %ApplicationServer{server_id: "srv-1", desired_version: "2.0.0"}

      healthy_live = %{application_name: "my-api", current_version: "2.0.0", health: :healthy}
      unhealthy_live = %{application_name: "my-api", current_version: "2.0.0", health: :unhealthy}

      shape =
        StatusJSON.application(%{
          application: app,
          assigned: [{row, %{}, healthy_live}, {row, %{}, unhealthy_live}],
          metrics: %{window_total: 0, samples: []}
        })

      assert shape.healthy_server_count == 1
      assert length(shape.servers) == 2
    end

    test "passes the metrics shape through" do
      app = %Application{name: "my-api", type: :elixir_release, domain: "d", min_healthy: 1}

      shape =
        StatusJSON.application(%{
          application: app,
          assigned: [],
          metrics: %{window_total: 42, samples: [%{at: DateTime.utc_now(), delta: 42, total: 42}]}
        })

      assert shape.metrics.window_total == 42
      assert [%{delta: 42}] = shape.metrics.samples
    end
  end

  describe "application_server/1" do
    test "renders the disconnected tuple" do
      row = %ApplicationServer{server_id: "srv-1", desired_version: "1.0.0"}

      assert %{
               server_id: "srv-1",
               desired_version: "1.0.0",
               current_version: nil,
               health: nil,
               connected: false
             } = StatusJSON.application_server({row, nil, nil})
    end

    test "renders the connected tuple with live fields" do
      row = %ApplicationServer{server_id: "srv-1", desired_version: "1.0.0"}
      live = %{current_version: "1.0.0", health: :healthy}

      assert %{
               server_id: "srv-1",
               desired_version: "1.0.0",
               current_version: "1.0.0",
               health: :healthy,
               connected: true
             } = StatusJSON.application_server({row, %{}, live})
    end
  end
end
