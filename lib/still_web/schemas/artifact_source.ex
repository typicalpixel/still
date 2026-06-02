defmodule StillWeb.Schemas.ArtifactSource do
  @moduledoc """
  How the agent fetches an application's release tarball at deploy time.
  Embedded inside `Application`.
  """

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "ArtifactSource",
    type: :object,
    properties: %{
      type: %OpenApiSpex.Schema{
        type: :string,
        enum: ["unauthenticated_url", "local_file"]
      }
    },
    required: [:type]
  })
end
