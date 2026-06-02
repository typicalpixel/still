defmodule StillWeb.ApiKeyComponentsTest do
  use StillWeb.ConnCase

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import StillWeb.ApiKeyComponents

  describe "api_keys_table/1" do
    test "renders keys with permissions and last-used, gating the revoke action" do
      assigns = %{
        keys: [
          %{
            id: "abcdef123456",
            name: "ci-bot",
            permissions: ["deploy", "read"],
            last_used_at: ~U[2026-01-01 00:00:00Z],
            inserted_at: ~U[2026-01-01 00:00:00Z]
          }
        ]
      }

      html = rendered_to_string(~H|<.api_keys_table keys={@keys} can_admin={true} />|)
      assert html =~ "ci-bot"
      assert html =~ "abcdef12"
      assert html =~ "deploy"
      assert html =~ "Revoke"
      # A used key shows a relative time, not "never".
      refute html =~ "never"

      refute rendered_to_string(~H|<.api_keys_table keys={@keys} can_admin={false} />|) =~
               "Revoke"
    end

    test "shows 'never' for unused keys and an empty notice" do
      assigns = %{
        keys: [
          %{
            id: "abcdef123456",
            name: "k",
            permissions: ["read"],
            last_used_at: nil,
            inserted_at: ~U[2026-01-01 00:00:00Z]
          }
        ]
      }

      assert rendered_to_string(~H|<.api_keys_table keys={@keys} can_admin={true} />|) =~ "never"

      assert rendered_to_string(~H|<.api_keys_table keys={[]} can_admin={true} />|) =~
               "No API keys yet."
    end
  end
end
