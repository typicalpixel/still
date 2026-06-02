defmodule Still.Accounts do
  @moduledoc """
  The Accounts context — users, authentication, and authorization.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Still.Accounts.ApiKey
  alias Still.Accounts.User
  alias Still.Accounts.UserToken
  alias Still.Audit
  alias Still.Audit.Actor
  alias Still.Repo

  @doc """
  Authenticates a bearer token. Tries the API key path first, then the
  session token path.

  Returns `{:ok, %User{}, %ApiKey{} | nil}` on success — the api_key is
  non-nil when the bearer was a raw API key, `nil` when it was a session
  token. Returns `:error` when neither path matches.
  """
  def authenticate_bearer(token) when is_binary(token) do
    case get_api_key_by_raw(token) do
      %ApiKey{user: %User{} = user} = api_key ->
        {:ok, user, api_key}

      nil ->
        case authenticate_session_token(token) do
          %User{} = user -> {:ok, user, nil}
          nil -> :error
        end
    end
  end

  defp authenticate_session_token(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded} ->
        case get_user_by_session_token(decoded) do
          {%User{} = user, _inserted_at} -> user
          nil -> nil
        end

      :error ->
        nil
    end
  end

  @doc """
  Looks up an API key by its raw bearer value, preloading the owning user.
  Returns the `%ApiKey{}` struct or `nil`.
  """
  def get_api_key_by_raw(raw_key) when is_binary(raw_key) do
    hashed = ApiKey.hash_key(raw_key)

    Repo.one(
      from ak in ApiKey,
        where: ak.hashed_key == ^hashed,
        preload: :user
    )
  end

  @doc """
  Returns `true` if any user exists in the database.
  """
  def has_users? do
    Repo.exists?(User)
  end

  @doc """
  Creates a user. Returns `{:ok, user}` or `{:error, changeset}`.
  """
  def create_user(%Actor{} = actor, attrs) when is_map(attrs) do
    Multi.new()
    |> Multi.insert(:user, User.registration_changeset(%User{}, attrs))
    |> Audit.multi(actor, fn %{user: user} ->
      [
        type: :user_created,
        subject_type: :user,
        subject_id: user.id,
        payload: %{user_id: user.id, email: user.email, role: user.role},
        after: Audit.snapshot(user)
      ]
    end)
    |> Repo.transaction()
    |> finalize(:user)
  end

  @doc """
  Lists all users, ordered by email.
  """
  def list_users do
    Repo.all(from u in User, order_by: u.email)
  end

  @doc """
  Fetches a user by id. Raises `Ecto.NoResultsError` if not found.
  """
  def get_user!(id) when is_binary(id) do
    Repo.get!(User, id)
  end

  @doc """
  Updates a user's email, name, or role. Refuses to demote the last
  remaining admin to a non-admin role — that would lock the system out.
  Returns `{:error, :last_admin}` in that case, `{:error, changeset}`
  on validation failure, `{:ok, user}` on success.
  """
  def update_user(%Actor{} = actor, %User{} = user, attrs) when is_map(attrs) do
    with :ok <- assert_admin_floor_for_update(user, attrs) do
      before_snapshot = Audit.snapshot(user)

      Multi.new()
      |> Multi.update(:user, User.update_changeset(user, attrs))
      |> Audit.multi(actor, fn %{user: updated} ->
        [
          type: :user_updated,
          subject_type: :user,
          subject_id: updated.id,
          payload: %{user_id: updated.id, email: updated.email, role: updated.role},
          before: before_snapshot,
          after: Audit.snapshot(updated)
        ]
      end)
      |> Repo.transaction()
      |> finalize(:user)
    end
  end

  @doc """
  Updates a user's profile (currently just `:name`). Used by the
  self-service `PATCH /api/auth/me` endpoint.
  """
  def update_user_profile(%Actor{} = actor, %User{} = user, attrs) when is_map(attrs) do
    before_snapshot = Audit.snapshot(user)

    Multi.new()
    |> Multi.update(:user, User.profile_changeset(user, attrs))
    |> Audit.multi(actor, fn %{user: updated} ->
      [
        type: :user_profile_updated,
        subject_type: :user,
        subject_id: updated.id,
        payload: %{user_id: updated.id, email: updated.email},
        before: before_snapshot,
        after: Audit.snapshot(updated)
      ]
    end)
    |> Repo.transaction()
    |> finalize(:user)
  end

  @doc """
  Rotates a user's password. The new password is in `attrs` under
  `:password`. The caller (controller / plug) is responsible for any
  current-password verification before invoking this.

  Deletes every session token the user holds in the same transaction so a
  password change logs out all existing sessions. Returns
  `{:ok, {user, expired_tokens}}`; hand `expired_tokens` to
  `StillWeb.UserAuth.disconnect_sessions/1` to drop their live sockets.
  """
  def update_user_password(%Actor{} = actor, %User{} = user, attrs) when is_map(attrs) do
    Multi.new()
    |> Multi.update(:user, User.password_changeset(user, attrs))
    |> Multi.run(:expired_tokens, fn repo, %{user: updated} ->
      tokens = repo.all_by(UserToken, user_id: updated.id)
      repo.delete_all(from t in UserToken, where: t.user_id == ^updated.id)
      {:ok, tokens}
    end)
    |> Audit.multi(actor, fn %{user: updated} ->
      [
        type: :user_password_changed,
        subject_type: :user,
        subject_id: updated.id,
        payload: %{user_id: updated.id, email: updated.email}
      ]
    end)
    |> Repo.transaction()
    |> finalize_password_change()
  end

  @doc """
  Deletes a user. Refuses to delete the last remaining admin
  (`{:error, :last_admin}`) or the actor's own account
  (`{:error, :cannot_delete_self}`) — the former would lock the system
  out, the latter would lock the operator out mid-request.
  """
  def delete_user(%Actor{} = actor, %User{} = user) do
    with :ok <- assert_not_self(actor, user),
         :ok <- assert_not_last_admin(user) do
      before_snapshot = Audit.snapshot(user)

      Multi.new()
      |> Multi.delete(:user, user)
      |> Audit.multi(actor, fn %{user: deleted} ->
        [
          type: :user_deleted,
          subject_type: :user,
          subject_id: deleted.id,
          payload: %{user_id: deleted.id, email: deleted.email, role: deleted.role},
          before: before_snapshot
        ]
      end)
      |> Repo.transaction()
      |> finalize(:user)
    end
  end

  defp assert_not_self(%Actor{user_id: actor_id}, %User{id: user_id}) when actor_id == user_id,
    do: {:error, :cannot_delete_self}

  defp assert_not_self(_actor, _user), do: :ok

  # The update path needs to reject demotions away from :admin if this
  # is the only admin left. We let role:admin -> role:admin or unrelated
  # field updates pass through. The query excludes the user-being-updated
  # so we don't double-count them.
  defp assert_admin_floor_for_update(%User{role: :admin} = user, attrs) do
    new_role = attrs |> Map.get(:role, attrs["role"]) |> to_role_atom()

    if new_role && new_role != :admin do
      assert_not_last_admin(user)
    else
      :ok
    end
  end

  defp assert_admin_floor_for_update(_user, _attrs), do: :ok

  defp assert_not_last_admin(%User{role: :admin, id: user_id}) do
    other_admins =
      Repo.aggregate(
        from(u in User, where: u.role == :admin and u.id != ^user_id),
        :count
      )

    if other_admins == 0, do: {:error, :last_admin}, else: :ok
  end

  defp assert_not_last_admin(_user), do: :ok

  defp to_role_atom(role) when role in [:admin, :deployer, :viewer], do: role
  defp to_role_atom("admin"), do: :admin
  defp to_role_atom("deployer"), do: :deployer
  defp to_role_atom("viewer"), do: :viewer
  defp to_role_atom(_), do: nil

  @doc """
  Looks up a user by email and verifies the password. Returns the user or `nil`.
  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: String.downcase(email))
    if User.valid_password?(user, password), do: user
  end

  @doc """
  Generates a session token for the given user, persists it, and returns the raw token.
  """
  def generate_user_session_token(%User{} = user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Returns `{user, token_inserted_at}` for the given session token, or `nil` if
  expired/invalid. The timestamp lets the web layer reissue an aging token.
  """
  def get_user_by_session_token(token) when is_binary(token) do
    Repo.one(UserToken.verify_session_token_query(token))
  end

  @doc """
  Deletes the given session token. Always returns `:ok`.
  """
  def delete_user_session_token(token) when is_binary(token) do
    Repo.delete_all(UserToken.by_token_and_context_query(token, "session"))
    :ok
  end

  @doc """
  Creates an API key for the given user. Returns `{:ok, api_key}` with the
  raw key on the virtual `:raw_key` field — show it to the user once and
  discard it.
  """
  def create_api_key(%Actor{} = actor, %User{} = user, attrs) when is_map(attrs) do
    changeset =
      %ApiKey{}
      |> ApiKey.creation_changeset(attrs)
      |> Ecto.Changeset.put_change(:user_id, user.id)

    Multi.new()
    |> Multi.insert(:api_key, changeset)
    |> Audit.multi(actor, fn %{api_key: api_key} ->
      [
        type: :api_key_created,
        subject_type: :api_key,
        subject_id: api_key.id,
        payload: %{
          api_key_id: api_key.id,
          api_key_name: api_key.name,
          owner_user_id: user.id,
          owner_email: user.email,
          permissions: api_key.permissions
        },
        after: Audit.snapshot(api_key)
      ]
    end)
    |> Repo.transaction()
    |> finalize(:api_key)
  end

  @doc """
  Lists API keys belonging to the given user, newest first. Hashed keys are
  returned but raw keys are not — they only exist at creation time.
  """
  def list_api_keys_for(%User{} = user) do
    Repo.all(from ak in ApiKey, where: ak.user_id == ^user.id, order_by: [desc: ak.inserted_at])
  end

  @doc """
  Looks up the user that owns the given raw API key, or `nil` if no key matches.
  """
  def get_user_by_api_key(raw_key) when is_binary(raw_key) do
    hashed = ApiKey.hash_key(raw_key)

    Repo.one(
      from ak in ApiKey,
        where: ak.hashed_key == ^hashed,
        join: u in assoc(ak, :user),
        select: u
    )
  end

  @doc """
  Fetches an API key by id. Raises if not found.
  """
  def get_api_key!(id) when is_binary(id) do
    Repo.get!(ApiKey, id)
  end

  @doc """
  Deletes the given API key.
  """
  def delete_api_key(%Actor{} = actor, %ApiKey{} = api_key) do
    api_key = Repo.preload(api_key, :user)
    before_snapshot = Audit.snapshot(api_key)

    Multi.new()
    |> Multi.delete(:api_key, api_key)
    |> Audit.multi(actor, fn %{api_key: deleted} ->
      [
        type: :api_key_deleted,
        subject_type: :api_key,
        subject_id: deleted.id,
        payload: %{
          api_key_id: deleted.id,
          api_key_name: deleted.name,
          owner_user_id: api_key.user.id,
          owner_email: api_key.user.email
        },
        before: before_snapshot
      ]
    end)
    |> Repo.transaction()
    |> finalize(:api_key)
  end

  # Unwraps the multi result and emits the audit event live (after commit).
  # Mirrors the pattern in Still.Applications and Still.Fleet.
  defp finalize({:ok, %{audit: event} = changes}, key) do
    Audit.emit_live(event)
    {:ok, Map.fetch!(changes, key)}
  end

  defp finalize({:error, _failed_op, value, _changes}, _key), do: {:error, value}

  # Password changes return the deleted session tokens alongside the user so
  # the web layer can disconnect their live sockets.
  defp finalize_password_change({:ok, %{audit: event, user: user, expired_tokens: tokens}}) do
    Audit.emit_live(event)
    {:ok, {user, tokens}}
  end

  defp finalize_password_change({:error, _failed_op, value, _changes}), do: {:error, value}

  @doc """
  Stamps the API key's `last_used_at` field with the current UTC timestamp.
  """
  def touch_api_key_used(%ApiKey{} = api_key) do
    api_key
    |> ApiKey.touch_changeset(DateTime.utc_now())
    |> Repo.update()
  end
end
