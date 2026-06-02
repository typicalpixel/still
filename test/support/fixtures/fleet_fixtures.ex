defmodule Still.FleetFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Still.Fleet` context.

  All fixtures accept an optional attrs map that will override the generated defaults.
  """

  alias Still.Audit.Actor

  @doc """
  Generate a server.
  """
  def server_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, server} =
      attrs
      |> Enum.into(%{
        name: "server-#{n}",
        host: "server-#{n}.test",
        roles: ["application"]
      })
      |> then(&Still.Fleet.create_server(Actor.system(), &1))

    server
  end
end
