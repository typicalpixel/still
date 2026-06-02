defmodule Still.Artifact.Provider do
  @moduledoc """
  Behaviour for artifact download providers.

  Each provider knows how to fetch a release tarball from one kind of
  source and write it to a local path. The deploy manager dispatches
  to the appropriate provider based on the application's
  `artifact_source.type`.

  ## Implementing a provider

  Implement the `download/2` callback. The first argument is a map
  with at least `:artifact_url` (the deploy-time URL or identifier)
  plus any provider-specific fields from the `ArtifactSource` schema
  (`:bucket`, `:region`, etc.). The second argument is the absolute
  path where the tarball should be written.

      defmodule Still.Artifact.Provider.GCS do
        @behaviour Still.Artifact.Provider

        @impl true
        def download(spec, dest) do
          # fetch from GCS bucket using spec.bucket + spec.artifact_url
          # write to dest
          :ok
        end
      end
  """

  @doc """
  Downloads the artifact described by `spec` to `dest_path`.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @callback download(spec :: map(), dest_path :: String.t()) :: :ok | {:error, term()}

  @providers %{
    unauthenticated_url: Still.Artifact.Provider.URL,
    local_file: Still.Artifact.Provider.LocalFile
  }

  @doc """
  Returns the provider module for the given artifact source type, or
  `{:error, :unsupported_provider}` if no provider is registered.
  """
  def for_type(type) when is_atom(type) do
    case Map.fetch(@providers, type) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, :unsupported_provider}
    end
  end
end
