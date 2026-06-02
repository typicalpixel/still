defmodule StillWeb.DashboardComponentsTest do
  use StillWeb.ConnCase

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import StillWeb.DashboardComponents

  describe "status_dot/1" do
    test "renders a success dot for connected/healthy statuses" do
      assigns = %{}
      assert rendered_to_string(~H|<.status_dot status={:connected} />|) =~ "bg-success"
      assert rendered_to_string(~H|<.status_dot status="healthy" />|) =~ "bg-success"
    end

    test "renders an error dot for disconnected statuses" do
      assigns = %{}
      assert rendered_to_string(~H|<.status_dot status={:disconnected} />|) =~ "bg-error"
    end

    test "renders a warning dot for transitional statuses" do
      assigns = %{}
      assert rendered_to_string(~H|<.status_dot status={:degraded} />|) =~ "bg-warning"
    end

    test "renders a neutral dot for unknown statuses" do
      assigns = %{}
      assert rendered_to_string(~H|<.status_dot status={:wat} />|) =~ "bg-paper-400"
    end

    test "renders an optional label beside the dot" do
      assigns = %{}

      assert rendered_to_string(~H|<.status_dot status={:connected} label="Online" />|) =~
               "Online"
    end

    test "maps the dashboard tone vocabulary to semantic colors" do
      assigns = %{}
      assert rendered_to_string(~H|<.status_dot status={:healthy} />|) =~ "bg-success"
      assert rendered_to_string(~H|<.status_dot status={:warn} />|) =~ "bg-warning"
      assert rendered_to_string(~H|<.status_dot status={:danger} />|) =~ "bg-error"
      assert rendered_to_string(~H|<.status_dot status={:info} />|) =~ "bg-info"
      assert rendered_to_string(~H|<.status_dot status={:neutral} />|) =~ "bg-paper-400"
    end
  end

  describe "nav_link/1" do
    test "highlights the active link" do
      assigns = %{}

      html =
        rendered_to_string(
          ~H|<.nav_link navigate="/" icon="hero-squares-2x2" label="Dashboard" active />|
        )

      assert html =~ "Dashboard"
      assert html =~ "font-medium"
    end

    test "renders an inactive link without the active style" do
      assigns = %{}

      html =
        rendered_to_string(
          ~H|<.nav_link navigate="/servers" icon="hero-server-stack" label="Servers" />|
        )

      assert html =~ "Servers"
      assert html =~ "text-paper-600"
      refute html =~ "font-medium"
    end
  end

  describe "meter/1" do
    test "colors the bar by threshold" do
      assigns = %{}
      assert rendered_to_string(~H|<.meter value={95} />|) =~ "bg-error"
      assert rendered_to_string(~H|<.meter value={75} />|) =~ "bg-warning"
      assert rendered_to_string(~H|<.meter value={40} />|) =~ "bg-success"
    end

    test "sets the bar width from the value" do
      assigns = %{}
      assert rendered_to_string(~H|<.meter value={42} />|) =~ "width: 42%"
    end
  end

  describe "metric_bar/1" do
    test "renders a meter for a value and a dash for nil" do
      assigns = %{}
      assert rendered_to_string(~H|<.metric_bar value={55} />|) =~ "width: 55%"
      assert rendered_to_string(~H|<.metric_bar value={nil} />|) =~ "—"
    end
  end

  describe "relative_time/1" do
    test "formats by magnitude, em dash for nil, date past a week" do
      now = DateTime.utc_now()
      assert relative_time(nil) == "—"
      assert relative_time(DateTime.add(now, -1, :second)) == "just now"
      assert relative_time(DateTime.add(now, -30, :second)) =~ ~r/^\d+s ago$/
      assert relative_time(DateTime.add(now, -300, :second)) == "5m ago"
      assert relative_time(DateTime.add(now, -7200, :second)) == "2h ago"
      assert relative_time(DateTime.add(now, -172_800, :second)) == "2d ago"
      old = DateTime.add(now, -30 * 86_400, :second)
      assert relative_time(old) == Calendar.strftime(old, "%b ") <> Integer.to_string(old.day)
    end
  end

  @at ~U[2026-01-02 09:30:15Z]

  defp deploy(payload),
    do: event_activity(%{id: "e", at: @at, type: :deployment_updated, payload: payload}, %{})

  defp health(payload),
    do: event_activity(%{id: "e", at: @at, type: :health_transition, payload: payload}, %{})

  describe "event_activity/2" do
    test "derives deployment events, dropping per-step pings" do
      completed = deploy(%{application_name: "api", status: :completed, deployment_id: "d1"})
      assert completed.status == :healthy
      assert completed.label == "ok"
      assert completed.text == "api deploy completed"
      assert completed.link_to == ~p"/deployments/d1"

      assert deploy(%{status: :failed}).status == :danger
      assert deploy(%{status: :failed}).label == "failed"
      assert deploy(%{status: :rolled_back}).status == :warn
      assert deploy(%{status: :rolled_back}).label == "rollback"

      bare = deploy(%{})
      assert bare.label == "deploy"
      assert bare.text == "deploy updated"
      refute bare.link_to

      # Per-step pings (step_status, no top-level status) are dropped.
      assert deploy(%{server_id: "s1", step_status: :completed}) == nil
    end

    test "derives health transitions" do
      to_healthy = health(%{application_name: "api", from: :degraded, to: :healthy})
      assert to_healthy.status == :healthy
      assert to_healthy.label == "healthy"
      assert to_healthy.text == "api health degraded → healthy"
      assert to_healthy.link_to == ~p"/applications/api"

      assert health(%{to: :degraded}).status == :warn
      assert health(%{to: :unhealthy}).status == :danger
      assert health(%{to: :recovering}).status == :neutral

      no_app = health(%{from: :healthy, to: :degraded})
      refute no_app.link_to
      assert no_app.text == "health healthy → degraded"
    end

    test "derives server connect/disconnect, resolving names when known" do
      base = %{id: "e", at: @at}

      up =
        event_activity(
          Map.merge(base, %{type: :server_connected, payload: %{server_id: "srv-1"}}),
          %{"srv-1" => "web-1"}
        )

      assert up.status == :healthy
      assert up.label == "online"
      assert up.text == "web-1 connected"
      assert up.link_to == ~p"/servers/srv-1"

      down =
        event_activity(
          Map.merge(base, %{type: :server_disconnected, payload: %{server_id: "deadbeefcafe"}}),
          %{}
        )

      assert down.status == :danger
      assert down.label == "offline"
      assert down.text == "deadbeef disconnected"
      refute down.link_to

      # No server id in the payload — generic label, no link.
      anon = event_activity(Map.merge(base, %{type: :server_disconnected, payload: %{}}), %{})
      assert anon.text == "server disconnected"
      refute anon.link_to
    end

    test "returns nil for unknown event types" do
      assert event_activity(%{id: "e", at: @at, type: :mystery, payload: %{}}, %{}) == nil
    end
  end

  describe "modal/1" do
    test "renders when shown, with a title and close controls" do
      assigns = %{}

      html =
        rendered_to_string(
          ~H|<.modal id="m" show={true} on_cancel="close"><:title>Heads up</:title><p>Body</p></.modal>|
        )

      assert html =~ "Heads up"
      assert html =~ "Body"
      assert html =~ ~s(phx-click="close")
      assert html =~ "modal-backdrop"
    end

    test "is hidden when not shown, and omits close controls without on_cancel" do
      assigns = %{}

      refute rendered_to_string(~H|<.modal id="m" show={false}><p>Body</p></.modal>|) =~ "Body"

      no_cancel = rendered_to_string(~H|<.modal id="m" show={true}><p>Body</p></.modal>|)
      assert no_cancel =~ "Body"
      refute no_cancel =~ "modal-backdrop"
    end
  end

  describe "activity_feed/1" do
    test "renders an empty notice, with a customizable message" do
      assigns = %{}
      assert rendered_to_string(~H|<.activity_feed activities={[]} />|) =~ "No activity yet."

      assert rendered_to_string(~H|<.activity_feed activities={[]} empty="Nothing here." />|) =~
               "Nothing here."
    end

    test "renders each activity's time, label, text, and link" do
      assigns = %{
        activities: [
          %{
            id: "e1",
            at: ~U[2026-01-02 09:30:15Z],
            status: :healthy,
            label: "online",
            text: "web-1 connected",
            link_to: "/servers/srv-1"
          }
        ]
      }

      html = rendered_to_string(~H|<.activity_feed activities={@activities} />|)
      assert html =~ "online"
      assert html =~ "web-1 connected"
      assert html =~ "/servers/srv-1"
      assert html =~ "open →"
    end
  end

  describe "sparkline/1" do
    test "renders an empty path for no points" do
      assigns = %{}
      assert rendered_to_string(~H|<.sparkline points={[]} />|) =~ ~s(d="")
    end

    test "renders a flat midline for a single point" do
      assigns = %{}
      assert rendered_to_string(~H|<.sparkline points={[5]} />|) =~ "M 0 10.00"
    end

    test "renders a path across multiple points" do
      assigns = %{}
      html = rendered_to_string(~H|<.sparkline points={[1, 4, 2, 8]} />|)
      assert html =~ "M 0.00"
      assert html =~ "L "
    end
  end

  describe "chip/1" do
    test "renders its content" do
      assigns = %{}
      assert rendered_to_string(~H|<.chip>v1.2.3</.chip>|) =~ "v1.2.3"
    end
  end
end
