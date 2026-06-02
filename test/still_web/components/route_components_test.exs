defmodule StillWeb.RouteComponentsTest do
  use StillWeb.ConnCase

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import StillWeb.RouteComponents

  describe "routes_list/1" do
    test "renders application cards with upstream dials, or an empty notice" do
      assigns = %{
        routes: [
          %{
            name: "api",
            type: :elixir_release,
            domain: "api.example.com",
            path_prefix: "/v1",
            upstreams: [
              %{
                server_id: "s1",
                server_name: "web-1",
                host: "10.0.0.1",
                port: 8080,
                dial: "10.0.0.1:8080"
              }
            ]
          }
        ]
      }

      html = rendered_to_string(~H|<.routes_list routes={@routes} />|)
      assert html =~ "api"
      assert html =~ "elixir"
      assert html =~ "api.example.com"
      assert html =~ "/v1"
      assert html =~ "web-1"
      assert html =~ "10.0.0.1:8080"
      assert html =~ ~p"/applications/api"
      assert html =~ ~p"/servers/s1"

      assigns = %{routes: []}
      assert rendered_to_string(~H|<.routes_list routes={@routes} />|) =~ "No routes yet."
    end
  end
end
