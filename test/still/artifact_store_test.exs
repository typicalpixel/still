defmodule Still.ArtifactStoreTest do
  use ExUnit.Case, async: false

  alias Still.ArtifactStore

  setup do
    dir = Path.join(System.tmp_dir!(), "still-store-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    original_dir = Application.get_env(:still, :artifacts_dir)
    original_url = Application.get_env(:still, :artifact_base_url)
    Application.put_env(:still, :artifacts_dir, dir)
    Application.put_env(:still, :artifact_base_url, "http://controller:9090")

    on_exit(fn ->
      File.rm_rf!(dir)

      if original_dir,
        do: Application.put_env(:still, :artifacts_dir, original_dir),
        else: Application.delete_env(:still, :artifacts_dir)

      if original_url,
        do: Application.put_env(:still, :artifact_base_url, original_url),
        else: Application.delete_env(:still, :artifact_base_url)
    end)

    %{dir: dir}
  end

  describe "stage/3" do
    test "downloads the artifact and returns the local path", %{dir: dir} do
      src = Path.join(dir, "source.tar.gz")
      File.write!(src, "artifact-content")

      assert {:ok, path} =
               ArtifactStore.stage("my-app", "1.0.0",
                 source_type: :local_file,
                 spec: %{artifact_url: src}
               )

      assert File.read!(path) == "artifact-content"
      assert path == Path.join([dir, "my-app", "1.0.0.tar.gz"])
    end

    test "skips download when the artifact is already staged", %{dir: dir} do
      staged = Path.join([dir, "my-app", "1.0.0.tar.gz"])
      File.mkdir_p!(Path.dirname(staged))
      File.write!(staged, "already-here")

      assert {:ok, ^staged} =
               ArtifactStore.stage("my-app", "1.0.0",
                 source_type: :local_file,
                 spec: %{artifact_url: "/nonexistent"}
               )

      assert File.read!(staged) == "already-here"
    end

    test "cleans up the destination on download failure", %{dir: dir} do
      assert {:error, _} =
               ArtifactStore.stage("my-app", "2.0.0",
                 source_type: :local_file,
                 spec: %{artifact_url: "/nonexistent/source.tar.gz"}
               )

      refute File.exists?(Path.join([dir, "my-app", "2.0.0.tar.gz"]))
    end

    test "returns an error for an unsupported provider type" do
      assert {:error, :unsupported_provider} =
               ArtifactStore.stage("my-app", "3.0.0",
                 source_type: :gcs,
                 spec: %{artifact_url: "gs://bucket/path"}
               )
    end
  end

  describe "artifact_url/2" do
    test "returns the internal HTTP URL for the given app and version" do
      assert ArtifactStore.artifact_url("my-app", "1.0.0") ==
               "http://controller:9090/artifacts/my-app/1.0.0.tar.gz"
    end
  end

  describe "artifact_path/2" do
    test "returns the filesystem path for the given app and version", %{dir: dir} do
      assert ArtifactStore.artifact_path("my-app", "1.0.0") ==
               Path.join([dir, "my-app", "1.0.0.tar.gz"])
    end
  end

  describe "prune/2" do
    test "keeps the most recent N versions and deletes the rest", %{dir: dir} do
      app_dir = Path.join(dir, "prunable")
      File.mkdir_p!(app_dir)

      for i <- 1..5 do
        path = Path.join(app_dir, "v#{i}.tar.gz")
        File.write!(path, "v#{i}")
        mtime = {{2026, 1, i}, {0, 0, 0}}
        File.touch!(path, mtime)
      end

      deleted = ArtifactStore.prune("prunable", 3)

      assert length(deleted) == 2
      remaining = File.ls!(app_dir) |> Enum.sort()
      assert length(remaining) == 3
    end

    test "returns an empty list when the app directory does not exist" do
      assert ArtifactStore.prune("nonexistent-app", 5) == []
    end

    test "returns an empty list when fewer versions exist than the retention limit", %{dir: dir} do
      app_dir = Path.join(dir, "few")
      File.mkdir_p!(app_dir)
      File.write!(Path.join(app_dir, "v1.tar.gz"), "v1")

      assert ArtifactStore.prune("few", 5) == []
    end

    test "uses the configured default retention when called without an explicit limit", %{
      dir: dir
    } do
      app_dir = Path.join(dir, "default-retention")
      File.mkdir_p!(app_dir)

      for i <- 1..3 do
        path = Path.join(app_dir, "v#{i}.tar.gz")
        File.write!(path, "v#{i}")
        File.touch!(path, {{2026, 1, i}, {0, 0, 0}})
      end

      assert ArtifactStore.prune("default-retention") == []
    end
  end
end
