defmodule Still.Deployments.DeploymentStep do
  @moduledoc """
  Per-server deployment step schema. Mirrors the agent's DeploymentManager state machine.
  """

  use Still.Schema

  import Ecto.Changeset

  alias Still.Deployments.Deployment
  alias Still.Fleet.Server

  @statuses [
    :pending,
    :downloading,
    :unpacking,
    :starting,
    :health_checking,
    :switching,
    :stopping_old,
    :cleanup,
    :completed,
    :failed
  ]

  schema "deployment_steps" do
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :error, :string
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    belongs_to :deployment, Deployment
    belongs_to :server, Server

    timestamps()
  end

  @doc """
  Returns the list of valid deployment step statuses.
  """
  def statuses, do: @statuses

  @doc """
  Builds a changeset for creating a deployment step.
  """
  def creation_changeset(%__MODULE__{} = step, attrs) when is_map(attrs) do
    step
    |> cast(attrs, [:deployment_id, :server_id])
    |> validate_required([:deployment_id, :server_id])
    |> assoc_constraint(:deployment)
    |> assoc_constraint(:server)
    |> unique_constraint([:deployment_id, :server_id])
  end
end
