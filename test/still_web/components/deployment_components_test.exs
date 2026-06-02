defmodule StillWeb.DeploymentComponentsTest do
  use StillWeb.ConnCase

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import StillWeb.DeploymentComponents

  describe "derivations" do
    test "deployment_dot maps status to a tone" do
      assert deployment_dot(:completed) == :healthy
      assert deployment_dot(:rolled_back) == :warn
      assert deployment_dot(:failed) == :danger
      assert deployment_dot(:in_progress) == :info
    end

    test "deployment_label reads completed as succeeded, else humanizes" do
      assert deployment_label(:completed) == "succeeded"
      assert deployment_label(:in_progress) == "in progress"
    end

    test "in_flight? is true for pending and in-progress" do
      assert in_flight?(%{status: :pending})
      assert in_flight?(%{status: :in_progress})
      refute in_flight?(%{status: :completed})
    end

    test "trigger_label prefers the source, else the actor" do
      assert trigger_label(%{source: "git:main@abc", initiated_by: "user:x"}) == "git:main@abc"
      assert trigger_label(%{source: nil, initiated_by: "user:foo@x.com"}) == "foo@x.com"
    end

    test "actor strips the user/api prefix" do
      assert actor(%{initiated_by: "api:ci"}) == "ci"
    end

    test "duration_label formats, or em dash when unfinished" do
      assert duration_label(%{started_at: nil, completed_at: nil}) == "—"
      assert duration_label(%{started_at: ~U[2026-01-01 00:00:00Z], completed_at: nil}) == "—"

      assert duration_label(%{
               started_at: ~U[2026-01-01 00:00:00Z],
               completed_at: ~U[2026-01-01 00:00:42Z]
             }) == "42s"

      assert duration_label(%{
               started_at: ~U[2026-01-01 00:00:00Z],
               completed_at: ~U[2026-01-01 00:01:05Z]
             }) == "1m 05s"
    end

    test "step_dot maps a step status to a tone" do
      assert step_dot(:completed) == :healthy
      assert step_dot(:failed) == :danger
      assert step_dot(:pending) == :neutral
      assert step_dot(:health_checking) == :info
    end

    test "step_label humanizes the status" do
      assert step_label(:health_checking) == "health checking"
    end

    test "step_duration formats finished, elapsed, and unstarted steps" do
      assert step_duration(%{started_at: nil, completed_at: nil}) == "—"

      assert step_duration(%{
               started_at: ~U[2026-01-01 00:00:05Z],
               completed_at: ~U[2026-01-01 00:00:00Z]
             }) == "—"

      assert step_duration(%{
               started_at: ~U[2026-01-01 00:00:00Z],
               completed_at: ~U[2026-01-01 00:00:30Z]
             }) == "30s"

      assert step_duration(%{
               started_at: ~U[2026-01-01 00:00:00Z],
               completed_at: ~U[2026-01-01 00:01:05Z]
             }) == "1m 05s"

      assert step_duration(%{
               started_at: DateTime.add(DateTime.utc_now(), -3, :second),
               completed_at: nil
             }) =~ ~r/^\d+s elapsed$/
    end

    test "progress_bar_class colors by status" do
      assert progress_bar_class(:completed) == "bg-success"
      assert progress_bar_class(:failed) == "bg-error"
      assert progress_bar_class(:rolled_back) == "bg-warning"
      assert progress_bar_class(:in_progress) == "bg-info"
    end
  end

  describe "deploy_table/1" do
    test "renders deploys, or an empty notice" do
      assigns = %{
        deployments: [
          %{
            id: "abcd1234efgh",
            version: "1.0.0",
            status: :completed,
            source: nil,
            initiated_by: "user:me",
            started_at: ~U[2026-01-01 00:00:00Z],
            completed_at: ~U[2026-01-01 00:00:30Z],
            inserted_at: ~U[2026-01-01 00:00:00Z]
          }
        ]
      }

      html = rendered_to_string(~H|<.deploy_table deployments={@deployments} />|)
      assert html =~ "1.0.0"
      assert html =~ "succeeded"
      assert html =~ "abcd1234"
      assert html =~ "30s"

      assigns = %{deployments: []}

      assert rendered_to_string(~H|<.deploy_table deployments={@deployments} />|) =~
               "No deploys yet."
    end
  end

  describe "deployments_table/1" do
    test "lists deployments with the application, or an empty notice" do
      assigns = %{
        deployments: [
          %{
            id: "abcd1234efgh",
            application: %{name: "api"},
            version: "1.0.0",
            status: :completed,
            source: nil,
            initiated_by: "user:me",
            started_at: ~U[2026-01-01 00:00:00Z],
            completed_at: ~U[2026-01-01 00:00:30Z],
            inserted_at: ~U[2026-01-01 00:00:00Z]
          }
        ]
      }

      html = rendered_to_string(~H|<.deployments_table deployments={@deployments} />|)
      assert html =~ "api"
      assert html =~ "abcd1234"
      assert html =~ "1.0.0"
      assert html =~ "succeeded"
      assert html =~ "me"
      assert html =~ "30s"

      assigns = %{deployments: []}

      assert rendered_to_string(~H|<.deployments_table deployments={@deployments} />|) =~
               "No deployments match this filter."
    end
  end

  describe "deployment_header/1" do
    test "shows the ETA in flight, the duration when finished, and an em dash without an app" do
      assigns = %{
        inflight: %{
          id: "abcd1234efgh",
          status: :in_progress,
          version: "1.0.0",
          source: nil,
          initiated_by: "user:me",
          started_at: ~U[2026-01-01 00:00:00Z],
          completed_at: nil
        },
        done: %{
          id: "abcd1234efgh",
          status: :completed,
          version: "1.0.0",
          source: "git:main",
          initiated_by: "api:ci",
          started_at: ~U[2026-01-01 00:00:00Z],
          completed_at: ~U[2026-01-01 00:00:30Z]
        },
        # Failed before it ever started — terminal, but no duration to show.
        unstarted: %{
          id: "abcd1234efgh",
          status: :failed,
          version: "1.0.0",
          source: nil,
          initiated_by: "user:me",
          started_at: nil,
          completed_at: ~U[2026-01-01 00:00:30Z]
        },
        eta: ~U[2030-01-01 00:00:00Z]
      }

      html =
        rendered_to_string(
          ~H|<.deployment_header deployment={@inflight} app_name="api" eta_at={@eta} />|
        )

      assert html =~ "in progress"
      assert html =~ "ETA"
      assert html =~ "api"

      html =
        rendered_to_string(
          ~H|<.deployment_header deployment={@done} app_name="api" eta_at={nil} />|
        )

      assert html =~ "succeeded"
      assert html =~ "git:main"
      assert html =~ "took"
      assert html =~ "30s"

      html =
        rendered_to_string(
          ~H|<.deployment_header deployment={@done} app_name={nil} eta_at={nil} />|
        )

      assert html =~ "—"

      html =
        rendered_to_string(
          ~H|<.deployment_header deployment={@unstarted} app_name="api" eta_at={nil} />|
        )

      assert html =~ "failed"
      refute html =~ "took"
    end
  end

  describe "deployment_progress/1" do
    test "shows host counts, percent, and a status color" do
      assigns = %{progress: %{completed_steps: 1, total_steps: 2, pct: 50}, status: :in_progress}

      html =
        rendered_to_string(~H|<.deployment_progress progress={@progress} status={@status} />|)

      assert html =~ "1 / 2 hosts"
      assert html =~ "50% complete"
      assert html =~ "bg-info"
    end
  end

  describe "deployment_steps/1" do
    test "renders host rows with errors, or an empty notice" do
      assigns = %{
        steps: [
          %{
            id: "st1",
            server_id: "srv1",
            server_name: "web-1",
            host: "10.0.0.1",
            status: :failed,
            error: "boom",
            started_at: ~U[2026-01-01 00:00:00Z],
            completed_at: ~U[2026-01-01 00:00:05Z]
          }
        ]
      }

      html = rendered_to_string(~H|<.deployment_steps steps={@steps} />|)
      assert html =~ "web-1"
      assert html =~ "10.0.0.1"
      assert html =~ "failed"
      assert html =~ "boom"
      assert html =~ "5s"

      assigns = %{steps: []}

      assert rendered_to_string(~H|<.deployment_steps steps={@steps} />|) =~
               "No steps recorded yet."
    end
  end

  describe "deployment_log/1" do
    test "toggles between live and finished states" do
      assigns = %{
        inflight: %{
          status: :in_progress,
          started_at: ~U[2026-01-01 00:00:00Z],
          completed_at: nil
        },
        done: %{
          status: :completed,
          started_at: ~U[2026-01-01 00:00:00Z],
          completed_at: ~U[2026-01-01 00:00:30Z]
        }
      }

      html = rendered_to_string(~H|<.deployment_log deployment={@inflight} />|)
      assert html =~ "Live log"
      assert html =~ "streaming arrives in v0.2.0"

      html = rendered_to_string(~H|<.deployment_log deployment={@done} />|)
      assert html =~ "Log"
      assert html =~ "last activity"
    end
  end
end
