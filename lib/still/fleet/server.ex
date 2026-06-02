defmodule Still.Fleet.Server do
  @moduledoc """
  Server schema, with creation and update changesets and host format validation.
  """

  use Still.Schema

  import Ecto.Changeset

  alias Still.Hostname

  @valid_roles ~w(controller ingress application)

  schema "servers" do
    field :name, :string
    field :host, :string
    field :roles, {:array, :string}
    field :last_seen_at, :utc_datetime_usec
    field :metadata, :map, default: %{}

    timestamps()
  end

  @doc """
  Returns the list of role strings accepted by the changesets.
  """
  def valid_roles, do: @valid_roles

  @doc """
  Builds a changeset for creating a new server.

  Casts only the user-settable fields (`:name`, `:host`, `:roles`). Status,
  metadata, and `last_seen_at` are agent-controlled and cannot be set
  directly — the schema provides safe defaults.
  """
  def creation_changeset(%__MODULE__{} = server, attrs) when is_map(attrs) do
    server
    |> cast(attrs, [:name, :host, :roles])
    |> common_validations()
  end

  @doc """
  Builds a changeset for updating an existing server's user-editable fields.

  Same surface as `creation_changeset/2`: only `:name`, `:host`, and `:roles`
  may be changed. Status and runtime fields are agent-controlled.
  """
  def update_changeset(%__MODULE__{} = server, attrs) when is_map(attrs) do
    server
    |> cast(attrs, [:name, :host, :roles])
    |> common_validations()
  end

  defp common_validations(changeset) do
    changeset
    |> validate_required([:name, :host, :roles])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_length(:host, min: 1, max: 255)
    |> validate_host_format()
    |> validate_subset(:roles, @valid_roles)
    |> validate_roles_not_empty()
    |> unique_constraint(:name)
    |> unique_constraint(:host)
  end

  defp validate_host_format(changeset) do
    validate_change(changeset, :host, fn :host, host ->
      if Hostname.valid?(host), do: [], else: [host: "must be a valid IP address or hostname"]
    end)
  end

  defp validate_roles_not_empty(changeset) do
    case get_field(changeset, :roles) do
      [] -> add_error(changeset, :roles, "must include at least one role")
      _ -> changeset
    end
  end
end
