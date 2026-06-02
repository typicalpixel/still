defmodule StillWeb.TelemetryTest do
  use ExUnit.Case, async: true

  alias StillWeb.Telemetry

  describe "metrics/0" do
    test "returns a list of telemetry metrics" do
      metrics = Telemetry.metrics()

      assert [_ | _] = metrics
    end
  end
end
