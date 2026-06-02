defmodule Still.Applications.HealthCheck do
  @moduledoc """
  Embedded health check config for an application.
  """

  use Ecto.Schema

  import Ecto.Changeset

  embedded_schema do
    field :path, :string
    field :interval_ms, :integer, default: 5000
    field :deadline_ms, :integer, default: 3000
  end

  @doc """
  Builds a changeset for the embedded health check.
  """
  def changeset(%__MODULE__{} = health_check, attrs) when is_map(attrs) do
    health_check
    |> cast(attrs, [:path, :interval_ms, :deadline_ms])
    |> validate_required([:path])
    |> validate_format(:path, ~r{^/}, message: "must start with /")
    |> validate_length(:path, max: 255)
    |> validate_number(:interval_ms, greater_than: 0)
    |> validate_number(:deadline_ms, greater_than: 0)
  end
end
