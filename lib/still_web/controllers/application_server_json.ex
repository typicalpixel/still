defmodule StillWeb.ApplicationServerJSON do
  @moduledoc """
  JSON serialization for application-to-server assignments.
  """

  alias Still.Applications.ApplicationServer

  @doc "Renders a list of assignments for the index endpoint."
  def render(assignments) when is_list(assignments) do
    %{data: Enum.map(assignments, &assignment/1)}
  end

  @doc "Renders a single assignment for the create endpoint."
  def render_one(%ApplicationServer{} = assignment) do
    %{data: assignment(assignment)}
  end

  @doc "Base shape for an assignment row."
  def assignment(%ApplicationServer{} = as) do
    %{
      id: as.id,
      application_id: as.application_id,
      server_id: as.server_id,
      port_blue: as.port_blue,
      port_green: as.port_green,
      desired_version: as.desired_version,
      inserted_at: as.inserted_at,
      updated_at: as.updated_at
    }
  end
end
