defmodule Still.Applications.ApplicationServer do
  @moduledoc """
  Join schema between an application and a server, with blue/green port pair.
  """

  use Still.Schema

  import Ecto.Changeset

  alias Still.Applications.Application
  alias Still.Fleet.Server

  schema "application_servers" do
    field :port_blue, :integer
    field :port_green, :integer
    field :desired_version, :string

    belongs_to :application, Application
    belongs_to :server, Server

    timestamps()
  end

  @doc """
  Builds a changeset for creating an assignment.

  Validates that both ports are within the legal TCP port range and distinct
  from each other.
  """
  def assignment_changeset(%__MODULE__{} = assignment, attrs) when is_map(attrs) do
    assignment
    |> cast(attrs, [:application_id, :server_id, :port_blue, :port_green])
    |> validate_required([:application_id, :server_id, :port_blue, :port_green])
    |> validate_port(:port_blue)
    |> validate_port(:port_green)
    |> validate_distinct_ports()
    |> assoc_constraint(:application)
    |> assoc_constraint(:server)
    |> unique_constraint([:application_id, :server_id])
    |> unique_constraint(:port_blue, name: :application_servers_server_id_port_blue_index)
    |> unique_constraint(:port_green, name: :application_servers_server_id_port_green_index)
  end

  defp validate_port(changeset, field) do
    validate_number(changeset, field, greater_than: 0, less_than: 65_536)
  end

  defp validate_distinct_ports(changeset) do
    case {get_field(changeset, :port_blue), get_field(changeset, :port_green)} do
      {nil, _} -> changeset
      {_, nil} -> changeset
      {same, same} -> add_error(changeset, :port_green, "must differ from port_blue")
      _ -> changeset
    end
  end
end
