defmodule Still.Artifact.Provider.LocalFile do
  @moduledoc """
  Copies a release tarball from a local filesystem path.

  The artifact URL is expected to be a `file://` URI pointing to an
  existing file. This provider does no HTTP — it's for scenarios
  where the tarball is already on disk (CI builds that produce the
  artifact locally, shared NFS mounts, or integration tests that
  pre-stage fixtures).
  """

  @behaviour Still.Artifact.Provider

  @doc "Copies the file at `spec.artifact_url` (a `file://` URI or plain path) to `dest_path`."
  @impl true
  def download(spec, dest_path) when is_map(spec) and is_binary(dest_path) do
    source = parse_file_uri(spec.artifact_url)

    case File.cp(source, dest_path) do
      :ok -> :ok
      {:error, reason} -> {:error, "local copy failed: #{inspect(reason)}"}
    end
  end

  defp parse_file_uri("file://" <> path), do: path
  defp parse_file_uri(path), do: path
end
