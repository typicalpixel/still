defmodule StillWeb.LayoutsTest do
  use StillWeb.ConnCase

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias StillWeb.Layouts

  describe "app/1" do
    test "renders the content and flash group without a scope" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <Layouts.app flash={%{}} current_scope={nil}>
          <p>Body content</p>
        </Layouts.app>
        """)

      assert html =~ "Body content"
      # flash group reconnect markers
      assert html =~ "phx-disconnected"
    end

    test "renders the sidebar, nav, and user menu when authenticated" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <Layouts.app
          flash={%{}}
          current_scope={%{user: %{name: "Ops", email: "ops@example.com"}}}
          active_nav={:dashboard}
        >
          <p>Body content</p>
        </Layouts.app>
        """)

      assert html =~ "Dashboard"
      assert html =~ "Applications"
      assert html =~ "Servers"
      assert html =~ "ops@example.com"
      assert html =~ "Account"
      assert html =~ "Sign out"
      assert html =~ "Body content"
    end

    test "shows multi-node mode and sidebar counts when nav has multiple servers" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <Layouts.app
          flash={%{}}
          current_scope={%{user: %{name: "Ops", email: "ops@example.com"}}}
          active_nav={:applications}
          nav={%{apps: 3, servers: 2}}
        >
          <p>Body content</p>
        </Layouts.app>
        """)

      assert html =~ "multi-node"
      # the multi-node mode dot uses the plum accent
      assert html =~ "bg-plum-500"
    end
  end

  describe "flash_group/1" do
    test "renders info and error flashes" do
      assigns = %{}

      html =
        rendered_to_string(
          ~H|<Layouts.flash_group flash={%{"info" => "hello", "error" => "uh oh"}} />|
        )

      assert html =~ "hello"
      assert html =~ "uh oh"
    end
  end
end
