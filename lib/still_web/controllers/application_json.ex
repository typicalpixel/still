defmodule StillWeb.ApplicationJSON do
  @moduledoc """
  JSON serialization for the applications API.
  """

  alias Still.Applications.Application

  @doc "Renders a list of applications for the index endpoint."
  def render(applications) when is_list(applications) do
    %{data: Enum.map(applications, &application/1)}
  end

  @doc "Renders a single application for show/create/update."
  def render_one(%Application{} = application) do
    %{data: application(application)}
  end

  @doc "Base shape for an application row."
  def application(%Application{} = app) do
    %{
      id: app.id,
      name: app.name,
      type: app.type,
      domain: app.domain,
      path_prefix: app.path_prefix,
      exec_command: app.exec_command,
      exec_start_pre: app.exec_start_pre,
      exec_stop: app.exec_stop,
      env_vars: app.env_vars,
      min_healthy: app.min_healthy,
      health_check: embed(app.health_check),
      artifact_source: embed(app.artifact_source),
      maintenance: app.maintenance,
      maintenance_message: app.maintenance_message,
      inserted_at: app.inserted_at,
      updated_at: app.updated_at
    }
  end

  @doc """
  Flattens an Ecto embedded schema to a map, dropping the opaque `:id`
  field that Ecto generates for embeds. `nil` passes through unchanged.
  """
  def embed(nil), do: nil

  def embed(%{__struct__: _} = struct) do
    struct |> Map.from_struct() |> Map.delete(:id)
  end
end
