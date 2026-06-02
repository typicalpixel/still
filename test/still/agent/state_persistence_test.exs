defmodule Still.Agent.StatePersistenceTest do
  use ExUnit.Case, async: false

  alias Still.Agent.ApplicationState
  alias Still.Agent.StatePersistence

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "still-state-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    original = Application.get_env(:still, :applications_dir)
    Application.put_env(:still, :applications_dir, tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)

      if is_nil(original) do
        Application.delete_env(:still, :applications_dir)
      else
        Application.put_env(:still, :applications_dir, original)
      end
    end)

    %{tmp_dir: tmp_dir}
  end

  describe "read/1" do
    test "returns :not_found when no state file exists" do
      assert {:error, :not_found} = StatePersistence.read("nope")
    end

    test "returns the persisted state when the file exists" do
      state = %ApplicationState{
        type: "elixir_release",
        active_slot: "blue",
        active_port: 4000,
        current_version: "0.0.1+abc",
        previous_version: "0.0.1+def",
        last_health_check_at: "2026-04-10T03:00:00.000000Z"
      }

      :ok = StatePersistence.write("my-api", state)

      assert {:ok, ^state} = StatePersistence.read("my-api")
    end

    test "returns :corrupted when the file is not valid JSON", %{tmp_dir: tmp_dir} do
      app_dir = Path.join(tmp_dir, "broken")
      File.mkdir_p!(app_dir)
      File.write!(Path.join(app_dir, "state.json"), "this is not json {")

      assert {:error, :corrupted} = StatePersistence.read("broken")
    end

    test "propagates non-:enoent file errors", %{tmp_dir: tmp_dir} do
      # Create a regular file where a directory is expected. Reading
      # `<tmp_dir>/foo/state.json` returns :enotdir because `foo` is a file.
      File.write!(Path.join(tmp_dir, "foo"), "")

      assert {:error, :enotdir} = StatePersistence.read("foo")
    end
  end

  describe "write/2" do
    test "creates the application directory if it doesn't exist", %{tmp_dir: tmp_dir} do
      refute File.exists?(Path.join(tmp_dir, "fresh"))

      :ok =
        StatePersistence.write("fresh", %ApplicationState{
          type: "elixir_release",
          active_slot: "blue",
          active_port: 4000,
          current_version: "1.0.0"
        })

      assert File.exists?(Path.join([tmp_dir, "fresh", "state.json"]))
    end

    test "is atomic — no .tmp file is left behind on success", %{tmp_dir: tmp_dir} do
      :ok = StatePersistence.write("atomic", %ApplicationState{type: "static_site"})

      app_dir = Path.join(tmp_dir, "atomic")
      assert File.exists?(Path.join(app_dir, "state.json"))
      refute File.exists?(Path.join(app_dir, "state.json.tmp"))
    end

    test "overwrites an existing state file" do
      :ok = StatePersistence.write("over", %ApplicationState{current_version: "1.0.0"})
      :ok = StatePersistence.write("over", %ApplicationState{current_version: "2.0.0"})

      assert {:ok, %ApplicationState{current_version: "2.0.0"}} = StatePersistence.read("over")
    end

    test "round-trips all known fields" do
      original = %ApplicationState{
        type: "process",
        active_slot: "green",
        active_port: 4001,
        current_version: "0.5.0+xyz",
        previous_version: "0.4.9+abc",
        last_health_check_at: "2026-04-10T12:34:56.789012Z"
      }

      :ok = StatePersistence.write("round", original)
      assert {:ok, ^original} = StatePersistence.read("round")
    end

    test "propagates underlying write errors", %{tmp_dir: tmp_dir} do
      # Pre-create state.json.tmp as a directory so File.write fails with :eisdir.
      app_dir = Path.join(tmp_dir, "blocked")
      File.mkdir_p!(app_dir)
      File.mkdir!(Path.join(app_dir, "state.json.tmp"))

      assert {:error, :eisdir} =
               StatePersistence.write("blocked", %ApplicationState{type: "process"})
    end
  end

  describe "list_applications/0" do
    test "returns an empty list when the applications dir is empty" do
      assert [] == StatePersistence.list_applications()
    end

    test "returns an empty list when the applications dir does not exist", %{tmp_dir: tmp_dir} do
      File.rm_rf!(tmp_dir)
      assert [] == StatePersistence.list_applications()
    end

    test "returns only directories that contain a state.json", %{tmp_dir: tmp_dir} do
      :ok = StatePersistence.write("with-state", %ApplicationState{type: "elixir_release"})

      File.mkdir_p!(Path.join(tmp_dir, "without-state"))

      assert ["with-state"] == StatePersistence.list_applications()
    end

    test "returns multiple apps in arbitrary order" do
      :ok = StatePersistence.write("alpha", %ApplicationState{type: "static_site"})
      :ok = StatePersistence.write("bravo", %ApplicationState{type: "static_site"})
      :ok = StatePersistence.write("charlie", %ApplicationState{type: "static_site"})

      result = Enum.sort(StatePersistence.list_applications())
      assert result == ["alpha", "bravo", "charlie"]
    end
  end

  describe "delete/1" do
    test "removes an existing state file", %{tmp_dir: tmp_dir} do
      :ok = StatePersistence.write("doomed", %ApplicationState{type: "process"})
      assert File.exists?(Path.join([tmp_dir, "doomed", "state.json"]))

      assert :ok = StatePersistence.delete("doomed")
      refute File.exists?(Path.join([tmp_dir, "doomed", "state.json"]))
    end

    test "returns :ok when the state file is already gone" do
      assert :ok = StatePersistence.delete("never-existed")
    end

    test "propagates underlying delete errors", %{tmp_dir: tmp_dir} do
      # Pre-create state.json as a directory so File.rm fails (rm cannot
      # delete a directory; the exact errno varies but it's never :ok or :enoent).
      app_dir = Path.join(tmp_dir, "weird")
      File.mkdir_p!(app_dir)
      File.mkdir!(Path.join(app_dir, "state.json"))

      assert {:error, _} = StatePersistence.delete("weird")
    end
  end
end
