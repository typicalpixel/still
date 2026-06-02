defmodule Still.Applications.HookTest do
  use Still.DataCase, async: false

  alias Still.Applications.Hook

  describe "creation_changeset/2" do
    test "is valid with all required fields" do
      changeset =
        Hook.creation_changeset(%Hook{}, %{
          event: :pre_deploy,
          script: "#!/bin/bash\necho hello",
          timeout_ms: 30_000
        })

      assert changeset.valid?
    end

    test "requires event and script" do
      changeset = Hook.creation_changeset(%Hook{}, %{})

      errors = errors_on(changeset)
      assert "can't be blank" in errors.event
      assert "can't be blank" in errors.script
      # timeout_ms has a schema default of 60_000 so it's not blank
      refute Map.has_key?(errors, :timeout_ms)
    end

    test "rejects unknown events" do
      changeset =
        Hook.creation_changeset(%Hook{}, %{
          event: :pre_lunch,
          script: "echo",
          timeout_ms: 1_000
        })

      assert "is invalid" in errors_on(changeset).event
    end

    test "accepts each valid event" do
      for event <- Hook.events() do
        changeset =
          Hook.creation_changeset(%Hook{}, %{
            event: event,
            script: "echo #{event}",
            timeout_ms: 1_000
          })

        assert changeset.valid?, "expected #{event} to be valid"
      end
    end

    test "rejects an empty script" do
      changeset =
        Hook.creation_changeset(%Hook{}, %{
          event: :pre_deploy,
          script: "",
          timeout_ms: 1_000
        })

      assert "can't be blank" in errors_on(changeset).script
    end

    test "rejects a script over the size cap" do
      changeset =
        Hook.creation_changeset(%Hook{}, %{
          event: :pre_deploy,
          script: String.duplicate("a", 100_001),
          timeout_ms: 1_000
        })

      assert "should be at most 100000 character(s)" in errors_on(changeset).script
    end

    test "rejects non-positive timeout_ms" do
      for invalid <- [0, -1] do
        changeset =
          Hook.creation_changeset(%Hook{}, %{
            event: :pre_deploy,
            script: "echo",
            timeout_ms: invalid
          })

        assert "must be greater than 0" in errors_on(changeset).timeout_ms
      end
    end

    test "rejects timeout_ms above the 1-hour cap" do
      changeset =
        Hook.creation_changeset(%Hook{}, %{
          event: :pre_deploy,
          script: "echo",
          timeout_ms: 3_600_001
        })

      assert "must be less than or equal to 3600000" in errors_on(changeset).timeout_ms
    end
  end

  describe "update_changeset/2" do
    test "casts only script and timeout_ms" do
      hook = %Hook{
        event: :pre_deploy,
        script: "old",
        timeout_ms: 1_000,
        application_id: Ecto.UUID.generate()
      }

      changeset =
        Hook.update_changeset(hook, %{
          script: "new",
          timeout_ms: 2_000,
          event: :post_deploy,
          application_id: Ecto.UUID.generate()
        })

      assert changeset.valid?
      assert get_change(changeset, :script) == "new"
      assert get_change(changeset, :timeout_ms) == 2_000
      refute get_change(changeset, :event)
      refute get_change(changeset, :application_id)
    end
  end

  describe "events/0" do
    test "returns the known event set" do
      assert Hook.events() == [:pre_deploy, :release, :post_deploy, :pre_rollback, :post_rollback]
    end
  end
end
