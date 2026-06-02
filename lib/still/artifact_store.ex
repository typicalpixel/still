defmodule Still.ArtifactStore do
  @moduledoc """
  Controller-side artifact storage.

  When a deploy is triggered, the orchestrator calls `stage/3` to
  download the tarball from the external source (using the
  appropriate `Still.Artifact.Provider`) and store it locally at
  `<artifacts_dir>/<application>/<version>.tar.gz`. Caddy serves
  this directory as a static file server on `/artifacts/*`, so
  agents fetch from the controller over internal HTTP.

  Artifacts are retained for rollback — `prune/2` keeps the most
  recent N versions per application and deletes the rest.
  """

  alias Still.Artifact.Provider

  @default_retention 10

  @doc """
  Stages an artifact for the given application and version. Downloads
  from the external source using the provider resolved from `source_type`,
  writing to `<artifacts_dir>/<application>/<version>.tar.gz`.

  Returns `{:ok, local_path}` if the artifact is already staged or
  was successfully downloaded, or `{:error, reason}` on failure.
  """
  def stage(application_name, version, opts)
      when is_binary(application_name) and is_binary(version) do
    source_type = Keyword.fetch!(opts, :source_type)
    spec = Keyword.fetch!(opts, :spec)

    dest = artifact_path(application_name, version)

    if File.exists?(dest) do
      {:ok, dest}
    else
      File.mkdir_p!(Path.dirname(dest))

      with {:ok, provider} <- Provider.for_type(source_type),
           :ok <- provider.download(spec, dest) do
        {:ok, dest}
      else
        {:error, _} = error ->
          File.rm(dest)
          error
      end
    end
  end

  @doc """
  Returns the URL an agent should use to fetch the artifact from
  the controller's Caddy. The base URL comes from the
  `:artifact_base_url` application config.
  """
  def artifact_url(application_name, version)
      when is_binary(application_name) and is_binary(version) do
    base = Application.fetch_env!(:still, :artifact_base_url)
    "#{base}/artifacts/#{application_name}/#{version}.tar.gz"
  end

  @doc """
  Returns the absolute filesystem path where an artifact is (or
  would be) stored.
  """
  def artifact_path(application_name, version)
      when is_binary(application_name) and is_binary(version) do
    Path.join([artifacts_dir(), application_name, "#{version}.tar.gz"])
  end

  @doc """
  Prunes old artifacts for the given application, keeping the most
  recent `retention` versions (by file modification time). Returns
  the list of deleted paths.
  """
  def prune(application_name, retention \\ nil)
      when is_binary(application_name) do
    retention = retention || Application.get_env(:still, :artifact_retention, @default_retention)
    app_dir = Path.join(artifacts_dir(), application_name)

    case File.ls(app_dir) do
      {:ok, files} ->
        files
        |> Enum.map(&Path.join(app_dir, &1))
        |> Enum.filter(&String.ends_with?(&1, ".tar.gz"))
        |> Enum.sort_by(&file_mtime/1, :desc)
        |> Enum.drop(retention)
        |> Enum.map(fn path ->
          File.rm!(path)
          path
        end)

      {:error, :enoent} ->
        []
    end
  end

  defp file_mtime(path) do
    case File.stat(path) do
      {:ok, %{mtime: mtime}} -> mtime
      # six:ignore:next
      _ -> {{1970, 1, 1}, {0, 0, 0}}
    end
  end

  defp artifacts_dir do
    Application.get_env(:still, :artifacts_dir, "/var/lib/still/artifacts")
  end
end
