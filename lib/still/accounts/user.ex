defmodule Still.Accounts.User do
  @moduledoc """
  User schema, with registration changeset and password verification.
  """

  use Still.Schema

  import Ecto.Changeset

  schema "users" do
    field :email, :string
    field :name, :string
    field :role, Ecto.Enum, values: [:admin, :deployer, :viewer]
    field :hashed_password, :string, redact: true
    field :password, :string, virtual: true, redact: true

    timestamps()
  end

  @doc """
  Builds a registration changeset.

  ## Options

    * `:hash_password` — when `false`, skips password hashing. Default `true`.
    * `:validate_email` — when `false`, skips email format and length
      validation. Default `true`.
  """
  def registration_changeset(%__MODULE__{} = user, attrs, opts \\ []) when is_list(opts) do
    user
    |> cast(attrs, [:email, :name, :role, :password])
    |> validate_required([:email, :name, :role, :password])
    |> validate_email(opts)
    |> validate_name()
    |> validate_password(opts)
  end

  @doc """
  Builds a changeset for admin-driven user updates. Allows changing
  email, name, and role. Password rotation goes through
  `password_changeset/2` instead.
  """
  def update_changeset(%__MODULE__{} = user, attrs) when is_map(attrs) do
    user
    |> cast(attrs, [:email, :name, :role])
    |> validate_required([:email, :name, :role])
    |> validate_email([])
    |> validate_name()
  end

  @doc """
  Builds a changeset for self-service profile updates. Only `name` is
  cast — email/role/password require admin or a dedicated endpoint.
  """
  def profile_changeset(%__MODULE__{} = user, attrs) when is_map(attrs) do
    user
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> validate_name()
  end

  @doc """
  Builds a changeset for password rotation. Hashes the new password
  before commit. The same changeset serves both admin-driven resets
  and self-service changes — the caller is responsible for verifying
  the user's current password when applicable.
  """
  def password_changeset(%__MODULE__{} = user, attrs) when is_map(attrs) do
    user
    |> cast(attrs, [:password])
    |> validate_required([:password])
    |> validate_password([])
  end

  @doc """
  Verifies a plaintext password against the user's hash.

  Always runs an Argon2 verification step, even when there is no user or
  stored hash, so response time does not leak whether the account exists.
  """
  def valid_password?(%__MODULE__{hashed_password: hashed_password}, password)
      when is_binary(hashed_password) and is_binary(password) and byte_size(password) > 0 do
    Argon2.verify_pass(password, hashed_password)
  end

  def valid_password?(_user, _password) do
    Argon2.no_user_verify()
    false
  end

  defp validate_email(changeset, opts) do
    if Keyword.get(opts, :validate_email, true) do
      changeset
      |> update_change(:email, &normalize_email/1)
      |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/,
        message: "must have the @ sign and no spaces"
      )
      |> validate_length(:email, max: 160)
      |> unique_constraint(:email)
    else
      update_change(changeset, :email, &normalize_email/1)
    end
  end

  defp validate_name(changeset) do
    validate_length(changeset, :name, min: 1, max: 100)
  end

  defp validate_password(changeset, opts) do
    changeset
    |> validate_length(:password, min: 12, max: 72)
    |> maybe_hash_password(opts)
  end

  defp maybe_hash_password(changeset, opts) do
    hash_password? = Keyword.get(opts, :hash_password, true)
    password = get_change(changeset, :password)

    if (hash_password? and password) && changeset.valid? do
      changeset
      |> put_change(:hashed_password, Argon2.hash_pwd_salt(password))
      |> delete_change(:password)
    else
      changeset
    end
  end

  defp normalize_email(email) when is_binary(email), do: String.downcase(email)
end
