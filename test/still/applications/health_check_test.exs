defmodule Still.Applications.HealthCheckTest do
  use ExUnit.Case, async: true

  import Ecto.Changeset, only: [get_change: 2, get_field: 2]

  alias Still.Applications.HealthCheck

  describe "changeset/2" do
    test "is valid with all required fields" do
      changeset =
        HealthCheck.changeset(%HealthCheck{}, %{
          path: "/health",
          interval_ms: 5000,
          deadline_ms: 3000
        })

      assert changeset.valid?
      assert get_change(changeset, :path) == "/health"
    end

    test "requires path; integer fields fall back to schema defaults" do
      changeset = HealthCheck.changeset(%HealthCheck{}, %{})

      errors = errors_on(changeset)
      assert "can't be blank" in errors.path
      refute Map.has_key?(errors, :interval_ms)
      refute Map.has_key?(errors, :deadline_ms)
    end

    test "uses schema defaults when integer fields are omitted" do
      changeset = HealthCheck.changeset(%HealthCheck{}, %{path: "/health"})
      assert changeset.valid?
      assert get_field(changeset, :interval_ms) == 5000
      assert get_field(changeset, :deadline_ms) == 3000
    end

    test "rejects a path that doesn't start with /" do
      changeset =
        HealthCheck.changeset(%HealthCheck{}, %{
          path: "health",
          interval_ms: 5000,
          deadline_ms: 3000
        })

      assert "must start with /" in errors_on(changeset).path
    end

    test "validates path length cap" do
      changeset =
        HealthCheck.changeset(%HealthCheck{}, %{
          path: "/" <> String.duplicate("a", 256),
          interval_ms: 5000,
          deadline_ms: 3000
        })

      assert "should be at most 255 character(s)" in errors_on(changeset).path
    end

    test "rejects non-positive interval_ms" do
      for invalid <- [0, -1] do
        changeset =
          HealthCheck.changeset(%HealthCheck{}, %{
            path: "/health",
            interval_ms: invalid,
            deadline_ms: 3000
          })

        assert "must be greater than 0" in errors_on(changeset).interval_ms
      end
    end

    test "rejects non-positive deadline_ms" do
      changeset =
        HealthCheck.changeset(%HealthCheck{}, %{
          path: "/health",
          interval_ms: 5000,
          deadline_ms: 0
        })

      assert "must be greater than 0" in errors_on(changeset).deadline_ms
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
