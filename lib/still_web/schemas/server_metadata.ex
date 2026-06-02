defmodule StillWeb.Schemas.ServerMetadata do
  @moduledoc """
  Static host facts the agent reports on connect. Stored verbatim on
  the server row; absent on servers that have never connected.
  """

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "ServerMetadata",
    type: :object,
    additionalProperties: true,
    properties: %{
      hostname: %OpenApiSpex.Schema{type: :string, nullable: true},
      os: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description: "PRETTY_NAME from /etc/os-release, or an :os.type tuple fallback."
      },
      cpu_count: %OpenApiSpex.Schema{type: :integer, nullable: true},
      memory_mb: %OpenApiSpex.Schema{type: :integer, nullable: true},
      disk_free_mb: %OpenApiSpex.Schema{
        type: :integer,
        nullable: true,
        description: "Free megabytes on the filesystem holding the applications directory."
      },
      agent_version: %OpenApiSpex.Schema{type: :string, nullable: true}
    }
  })
end
