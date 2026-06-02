defmodule StillWeb.ApplicationServerJSONTest do
  use ExUnit.Case, async: true

  alias Still.Applications.ApplicationServer
  alias StillWeb.ApplicationServerJSON

  defp sample_assignment(overrides \\ %{}) do
    base = %ApplicationServer{
      id: "as-1",
      application_id: "app-1",
      server_id: "srv-1",
      port_blue: 20_000,
      port_green: 20_001,
      desired_version: nil,
      inserted_at: ~U[2026-04-01 09:00:00.000000Z],
      updated_at: ~U[2026-04-20 15:00:00.000000Z]
    }

    struct(base, overrides)
  end

  describe "assignment/1" do
    test "emits the full shape" do
      assert %{
               id: "as-1",
               application_id: "app-1",
               server_id: "srv-1",
               port_blue: 20_000,
               port_green: 20_001,
               desired_version: nil
             } = ApplicationServerJSON.assignment(sample_assignment())
    end
  end

  describe "render/1" do
    test "wraps a list under data" do
      assert %{data: [%{id: "as-1"}]} = ApplicationServerJSON.render([sample_assignment()])
    end
  end

  describe "render_one/1" do
    test "wraps a single assignment under data" do
      assert %{data: %{id: "as-1"}} = ApplicationServerJSON.render_one(sample_assignment())
    end
  end
end
