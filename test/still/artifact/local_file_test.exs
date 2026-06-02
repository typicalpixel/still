defmodule Still.Artifact.LocalFileTest do
  use ExUnit.Case, async: true

  alias Still.Artifact.Provider.LocalFile

  describe "download/2 with a file:// URI" do
    test "copies the source file to the destination path" do
      {src, dest} = setup_paths()
      File.write!(src, "tarball-data")

      assert :ok = LocalFile.download(%{artifact_url: "file://#{src}"}, dest)
      assert File.read!(dest) == "tarball-data"
    end

    test "returns an error when the source does not exist" do
      {_src, dest} = setup_paths()

      assert {:error, "local copy failed:" <> _} =
               LocalFile.download(%{artifact_url: "file:///nonexistent/path.tar.gz"}, dest)
    end
  end

  describe "download/2 with a plain path" do
    test "copies the file without requiring the file:// prefix" do
      {src, dest} = setup_paths()
      File.write!(src, "plain-path-data")

      assert :ok = LocalFile.download(%{artifact_url: src}, dest)
      assert File.read!(dest) == "plain-path-data"
    end
  end

  defp setup_paths do
    id = System.unique_integer([:positive])
    src = Path.join(System.tmp_dir!(), "still-lf-src-#{id}")
    dest = Path.join(System.tmp_dir!(), "still-lf-dest-#{id}")

    on_exit(fn ->
      File.rm(src)
      File.rm(dest)
    end)

    {src, dest}
  end
end
