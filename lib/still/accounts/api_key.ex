defmodule Still.Accounts.ApiKey do
  @moduledoc """
  API key schema, with creation changeset and SHA256 hashing.
  """

  use Still.Schema

  import Ecto.Changeset

  @rand_size 32
  @prefix "still_"
  @valid_permissions ~w(admin deploy rollback read)

  schema "api_keys" do
    field :name, :string
    field :hashed_key, :binary, redact: true
    field :permissions, {:array, :string}
    field :last_used_at, :utc_datetime_usec
    field :raw_key, :string, virtual: true, redact: true

    belongs_to :user, Still.Accounts.User

    timestamps(updated_at: false)
  end

  @doc """
  Returns the list of permission strings accepted by `creation_changeset/2`.
  """
  def valid_permissions, do: @valid_permissions

  @doc """
  Builds a creation changeset and generates a fresh raw key.

  The raw key is stored on the changeset's virtual `:raw_key` field — the
  caller pulls it from the inserted struct, shows it to the user once, and
  it's never persisted. Only the SHA256 hash lands in the database.
  """
  def creation_changeset(%__MODULE__{} = api_key, attrs) when is_map(attrs) do
    {raw_key, hashed_key} = generate_key()

    api_key
    |> cast(attrs, [:name, :permissions])
    |> put_change(:raw_key, raw_key)
    |> put_change(:hashed_key, hashed_key)
    |> validate_required([:name, :permissions])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_subset(:permissions, @valid_permissions)
    |> validate_permissions_not_empty()
    |> assoc_constraint(:user)
    |> unique_constraint(:hashed_key)
  end

  @doc """
  Builds a changeset for stamping `last_used_at` to the given UTC timestamp.
  """
  def touch_changeset(%__MODULE__{} = api_key, %DateTime{} = timestamp) do
    change(api_key, last_used_at: timestamp)
  end

  @doc """
  Returns the SHA256 hash of a raw API key, ready for DB lookup.
  """
  def hash_key(raw_key) when is_binary(raw_key) do
    :crypto.hash(:sha256, raw_key)
  end

  defp generate_key do
    raw =
      @prefix <>
        Base.url_encode64(:crypto.strong_rand_bytes(@rand_size), padding: false)

    {raw, hash_key(raw)}
  end

  defp validate_permissions_not_empty(changeset) do
    case get_field(changeset, :permissions) do
      [] -> add_error(changeset, :permissions, "must include at least one permission")
      _ -> changeset
    end
  end
end
