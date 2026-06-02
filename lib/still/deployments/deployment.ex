defmodule Still.Deployments.Deployment do
  @moduledoc """
  Deployment schema, with creation changeset.
  """

  use Still.Schema

  import Ecto.Changeset

  alias Still.Applications.Application
  alias Still.Deployments.DeploymentStep

  @statuses [:pending, :in_progress, :completed, :failed, :rolled_back]

  schema "deployments" do
    field :version, :string
    field :artifact_url, :string
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :initiated_by, :string
    field :source, :string
    field :error, :string
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    belongs_to :application, Application

    has_many :steps, DeploymentStep,
      preload_order: [asc_nulls_last: :started_at, asc: :inserted_at, asc: :id]

    timestamps()
  end

  @doc """
  Returns the list of valid deployment statuses.
  """
  def statuses, do: @statuses

  @doc """
  Wall-clock duration of a deployment in milliseconds, or `nil` when the
  deployment hasn't both started and completed.
  """
  def duration_ms(%__MODULE__{started_at: %DateTime{} = s, completed_at: %DateTime{} = c}),
    do: DateTime.diff(c, s, :millisecond)

  def duration_ms(%__MODULE__{}), do: nil

  @doc """
  Per-server step progress for a deployment with `:steps` preloaded.
  Returns `%{completed_steps, total_steps, pct}`. A step counts as
  "completed" once it hits a terminal status (`:completed` or `:failed`).
  """
  def progress(%__MODULE__{steps: steps}) when is_list(steps) do
    total = length(steps)
    completed = Enum.count(steps, &(&1.status in [:completed, :failed]))

    %{
      completed_steps: completed,
      total_steps: total,
      pct: pct(completed, total)
    }
  end

  defp pct(_completed, 0), do: 0
  defp pct(completed, total), do: round(completed * 100 / total)

  @doc """
  Builds a changeset for creating a deployment.
  """
  def creation_changeset(%__MODULE__{} = deployment, attrs) when is_map(attrs) do
    deployment
    |> cast(attrs, [:version, :artifact_url, :initiated_by, :source])
    |> validate_required([:version, :artifact_url, :initiated_by])
    |> validate_length(:version, min: 1, max: 255)
    |> validate_length(:artifact_url, min: 1, max: 2048)
    |> validate_length(:initiated_by, min: 1, max: 255)
    |> validate_length(:source, min: 1, max: 255)
    |> assoc_constraint(:application)
  end
end
