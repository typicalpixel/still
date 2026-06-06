defmodule StillWeb.ApiSpecTest do
  use StillWeb.ConnCase, async: false

  alias StillWeb.ApiSpec

  describe "spec/0" do
    test "produces a structurally valid OpenAPI document" do
      spec = ApiSpec.spec()

      assert %OpenApiSpex.OpenApi{} = spec
      assert spec.openapi =~ ~r/^3\./
      assert spec.info.title == "Still API"
      assert spec.info.version == "2026-04-09"
    end

    test "round-trips through JSON without losing required fields" do
      json =
        ApiSpec.spec()
        |> Jason.encode!()
        |> Jason.decode!()

      assert json["openapi"] =~ ~r/^3\./
      assert json["info"]["title"] == "Still API"
      assert is_map(json["paths"])
      assert is_map(json["components"]["securitySchemes"]["bearerAuth"])
    end

    test "registers the bearerAuth security scheme" do
      spec = ApiSpec.spec()

      assert %OpenApiSpex.SecurityScheme{type: "http", scheme: "bearer"} =
               spec.components.securitySchemes["bearerAuth"]
    end

    test "every /api route in the router has a matching operation in the spec" do
      spec_paths = ApiSpec.spec().paths

      missing =
        for route <- Phoenix.Router.routes(StillWeb.Router),
            String.starts_with?(route.path, "/api/"),
            not has_operation?(spec_paths, route) do
          "#{String.upcase(to_string(route.verb))} #{route.path}"
        end

      assert missing == [],
             "router exposes routes with no operation/3 spec — add them to their controller:\n  " <>
               Enum.join(missing, "\n  ")
    end

    test "every operation in the spec carries at least one tag" do
      untagged =
        for {path, item} <- ApiSpec.spec().paths,
            {method, op} <- Map.from_struct(item),
            match?(%OpenApiSpex.Operation{}, op),
            op.tags in [nil, []] do
          "#{String.upcase(to_string(method))} #{path}"
        end

      assert untagged == [], "operations missing tags:\n  " <> Enum.join(untagged, "\n  ")
    end
  end

  # Phoenix path params look like `:name`; OpenAPI uses `{name}`.
  defp has_operation?(spec_paths, %{path: path, verb: verb}) do
    spec_path = Regex.replace(~r/:(\w+)/, path, "{\\1}")
    method = verb |> to_string() |> String.downcase() |> String.to_atom()

    case Map.get(spec_paths, spec_path) do
      nil -> false
      item -> not is_nil(Map.get(Map.from_struct(item), method))
    end
  end

  describe "GET /api/openapi" do
    test "serves the live spec as JSON without authentication", %{conn: conn} do
      body = conn |> get("/api/openapi") |> json_response(200)

      assert body["openapi"] =~ ~r/^3\./
      assert body["info"]["title"] == "Still API"
      assert is_map(body["paths"]["/api/auth/login"])
    end

    test "exposes the app version as the x-still-version vendor extension", %{conn: conn} do
      body = conn |> get("/api/openapi") |> json_response(200)

      assert body["info"]["x-still-version"] == to_string(Application.spec(:still, :vsn))
      assert body["info"]["x-still-version"] =~ ~r/^\d+\.\d+\.\d+/
      assert body["info"]["version"] == "2026-04-09"
    end
  end
end
