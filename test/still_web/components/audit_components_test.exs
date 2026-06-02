defmodule StillWeb.AuditComponentsTest do
  use StillWeb.ConnCase

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import StillWeb.AuditComponents

  describe "actor_dot/1 and humanize_audit_type/1" do
    test "maps actor kinds to tones and humanizes types" do
      assert actor_dot(:user) == :info
      assert actor_dot(:anonymous) == :warn
      assert actor_dot(:system) == :neutral
      assert actor_dot(:agent) == :neutral

      assert humanize_audit_type("application_server_unassigned") ==
               "application server unassigned"
    end
  end

  describe "audit_log/1" do
    test "renders an expanded event with its full detail" do
      assigns = %{
        events: [
          %{
            id: "e1",
            inserted_at: ~U[2026-01-01 00:00:00Z],
            actor_kind: :user,
            actor_label: "user:alex@example.com",
            type: "user_updated",
            subject_type: "user",
            subject_id: "abcdef123456",
            ip: "10.0.0.1",
            user_agent: "curl/8",
            before: %{"name" => "Al"},
            after: %{"name" => "Alex"},
            payload: %{"changed" => true}
          }
        ],
        expanded: MapSet.new(["e1"])
      }

      html = rendered_to_string(~H|<.audit_log events={@events} expanded={@expanded} />|)
      assert html =~ "user:alex@example.com"
      assert html =~ "user updated"
      assert html =~ "user · abcdef12"
      assert html =~ "▾"
      assert html =~ "10.0.0.1"
      assert html =~ "curl/8"
      assert html =~ "Alex"
    end

    test "renders detail-less events as non-expandable, with subject variants" do
      assigns = %{
        events: [
          %{
            id: "e2",
            inserted_at: ~U[2026-01-01 00:00:00Z],
            actor_kind: :system,
            actor_label: "system",
            type: "login_succeeded",
            subject_type: nil,
            subject_id: nil,
            ip: nil,
            user_agent: nil,
            before: nil,
            after: nil,
            payload: %{}
          },
          %{
            id: "e3",
            inserted_at: ~U[2026-01-01 00:00:00Z],
            actor_kind: :agent,
            actor_label: "agent:web-1",
            type: "server_connected",
            subject_type: "server",
            subject_id: nil,
            ip: nil,
            user_agent: nil,
            before: nil,
            after: nil,
            payload: %{}
          }
        ],
        expanded: MapSet.new()
      }

      html = rendered_to_string(~H|<.audit_log events={@events} expanded={@expanded} />|)
      assert html =~ "login succeeded"
      assert html =~ "—"
      assert html =~ "server"
      refute html =~ "▾"
      assert html =~ "disabled"
    end

    test "hides the subject column and shows the empty label" do
      assigns = %{events: [], expanded: MapSet.new()}

      assert rendered_to_string(
               ~H|<.audit_log events={@events} expanded={@expanded} empty="Nothing logged." />|
             ) =~ "Nothing logged."

      assigns = %{
        events: [
          %{
            id: "e4",
            inserted_at: ~U[2026-01-01 00:00:00Z],
            actor_kind: :system,
            actor_label: "system",
            type: "deploy_initiated",
            subject_type: "deployment",
            subject_id: "abcdef123456",
            ip: nil,
            user_agent: nil,
            before: nil,
            after: nil,
            payload: %{}
          }
        ],
        expanded: MapSet.new()
      }

      html =
        rendered_to_string(
          ~H|<.audit_log events={@events} expanded={@expanded} show_subject={false} />|
        )

      refute html =~ "deployment"
    end
  end
end
