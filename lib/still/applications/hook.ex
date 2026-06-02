defmodule Still.Applications.Hook do
  @moduledoc """
  Lifecycle hook schema, with creation and update changesets.
  """

  use Still.Schema

  import Ecto.Changeset

  alias Still.Applications.Application

  @events [:pre_deploy, :release, :post_deploy, :pre_rollback, :post_rollback]

  schema "hooks" do
    field :event, Ecto.Enum, values: @events
    field :script, :string
    field :timeout_ms, :integer, default: 60_000

    belongs_to :application, Application

    timestamps()
  end

  @doc """
  Returns the list of valid hook events.
  """
  def events, do: @events

  @doc """
  Builds a changeset for creating a hook.
  """
  def creation_changeset(%__MODULE__{} = hook, attrs) when is_map(attrs) do
    hook
    |> cast(attrs, [:event, :script, :timeout_ms])
    |> validate_required([:event, :script, :timeout_ms])
    |> common_validations()
    |> assoc_constraint(:application)
    |> unique_constraint([:application_id, :event])
  end

  @doc """
  Builds a changeset for updating a hook's script and timeout. The event and
  parent application are not cast — they cannot be changed after creation.
  """
  def update_changeset(%__MODULE__{} = hook, attrs) when is_map(attrs) do
    hook
    |> cast(attrs, [:script, :timeout_ms])
    |> validate_required([:script, :timeout_ms])
    |> common_validations()
  end

  defp common_validations(changeset) do
    changeset
    |> validate_length(:script, min: 1, max: 100_000)
    |> validate_number(:timeout_ms, greater_than: 0, less_than_or_equal_to: 3_600_000)
  end
end
