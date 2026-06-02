defmodule Still.Applications.ArtifactSource do
  @moduledoc """
  Embedded artifact source config for an application.

  Determines how the agent fetches the application's release tarball
  at deploy time. The `:type` maps to a `Still.Artifact.Provider`
  implementation that handles the actual download.
  """

  use Ecto.Schema

  import Ecto.Changeset

  embedded_schema do
    field :type, Ecto.Enum, values: [:unauthenticated_url, :local_file]
  end

  @doc """
  Builds a changeset for the embedded artifact source.
  """
  def changeset(%__MODULE__{} = source, attrs) when is_map(attrs) do
    source
    |> cast(attrs, [:type])
    |> validate_required([:type])
  end
end
