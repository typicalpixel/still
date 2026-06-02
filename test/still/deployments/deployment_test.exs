defmodule Still.Deployments.DeployTest do
  use Still.DataCase, async: false

  alias Still.Deployments.Deployment

  describe "creation_changeset/2" do
    test "is valid with all required fields" do
      changeset =
        Deployment.creation_changeset(%Deployment{}, %{
          version: "0.0.1+abc123",
          artifact_url: "https://example.com/app.tar.gz",
          initiated_by: "user:jane@example.com"
        })

      assert changeset.valid?
    end

    test "requires version, artifact_url, initiated_by" do
      changeset = Deployment.creation_changeset(%Deployment{}, %{})

      errors = errors_on(changeset)
      assert "can't be blank" in errors.version
      assert "can't be blank" in errors.artifact_url
      assert "can't be blank" in errors.initiated_by
    end

    test "validates version length" do
      changeset =
        Deployment.creation_changeset(%Deployment{}, %{
          version: String.duplicate("a", 256),
          artifact_url: "https://example.com/app.tar.gz",
          initiated_by: "user:test"
        })

      assert "should be at most 255 character(s)" in errors_on(changeset).version
    end

    test "validates artifact_url length" do
      changeset =
        Deployment.creation_changeset(%Deployment{}, %{
          version: "1.0.0",
          artifact_url: String.duplicate("a", 2049),
          initiated_by: "user:test"
        })

      assert "should be at most 2048 character(s)" in errors_on(changeset).artifact_url
    end

    test "validates initiated_by length" do
      changeset =
        Deployment.creation_changeset(%Deployment{}, %{
          version: "1.0.0",
          artifact_url: "https://example.com/app.tar.gz",
          initiated_by: String.duplicate("a", 256)
        })

      assert "should be at most 255 character(s)" in errors_on(changeset).initiated_by
    end

    test "accepts an optional source provenance string" do
      changeset =
        Deployment.creation_changeset(%Deployment{}, %{
          version: "1.0.0",
          artifact_url: "https://example.com/app.tar.gz",
          initiated_by: "user:jane",
          source: "git:main@abc1234"
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :source) == "git:main@abc1234"
    end

    test "validates source length" do
      changeset =
        Deployment.creation_changeset(%Deployment{}, %{
          version: "1.0.0",
          artifact_url: "https://example.com/app.tar.gz",
          initiated_by: "user:jane",
          source: String.duplicate("a", 256)
        })

      assert "should be at most 255 character(s)" in errors_on(changeset).source
    end

    test "defaults status to :pending on a fresh struct" do
      assert %Deployment{status: :pending} = %Deployment{}
    end
  end

  describe "statuses/0" do
    test "returns the known status set" do
      assert Deployment.statuses() ==
               [:pending, :in_progress, :completed, :failed, :rolled_back]
    end
  end

  describe "duration_ms/1" do
    test "returns the millisecond delta when both timestamps are set" do
      started = ~U[2026-04-20 12:00:00.000000Z]
      completed = DateTime.add(started, 2_345, :millisecond)

      assert Deployment.duration_ms(%Deployment{
               started_at: started,
               completed_at: completed
             }) == 2_345
    end

    test "returns nil when started_at is missing" do
      assert is_nil(
               Deployment.duration_ms(%Deployment{
                 completed_at: DateTime.utc_now()
               })
             )
    end

    test "returns nil when completed_at is missing" do
      assert is_nil(
               Deployment.duration_ms(%Deployment{
                 started_at: DateTime.utc_now()
               })
             )
    end

    test "returns nil on a fresh struct" do
      assert is_nil(Deployment.duration_ms(%Deployment{}))
    end
  end

  describe "progress/1" do
    alias Still.Deployments.DeploymentStep

    test "returns zero progress when no steps are present" do
      assert %{completed_steps: 0, total_steps: 0, pct: 0} =
               Deployment.progress(%Deployment{steps: []})
    end

    test "counts :completed and :failed steps against the total" do
      steps = [
        %DeploymentStep{status: :completed},
        %DeploymentStep{status: :completed},
        %DeploymentStep{status: :failed},
        %DeploymentStep{status: :pending}
      ]

      assert %{completed_steps: 3, total_steps: 4, pct: 75} =
               Deployment.progress(%Deployment{steps: steps})
    end

    test "rounds the percentage to the nearest whole number" do
      steps = [
        %DeploymentStep{status: :completed},
        %DeploymentStep{status: :pending},
        %DeploymentStep{status: :pending}
      ]

      # 1/3 = 33.33% → 33
      assert %{pct: 33} = Deployment.progress(%Deployment{steps: steps})
    end
  end
end
