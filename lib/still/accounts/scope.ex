defmodule Still.Accounts.Scope do
  @moduledoc """
  Request scope — the current user plus any parent resources loaded from the
  URL, plus the API key that authenticated the request (when applicable).

  Context functions that touch scope-owned data (anything nested under an
  application, anything tied to a user) take `%Scope{}` as their first
  argument and filter their queries through the scope's fields. This is how
  Still enforces nested-resource parent scoping and per-user ownership: the
  query itself refuses to return rows that don't match the scope.

  The `api_key` field carries the actual `%ApiKey{}` when the request came
  in with a bearer API key. Session-token requests leave it `nil`. The
  authorization plug uses it — when an api_key is present, effective
  permissions come from `api_key.permissions`; otherwise from the user's
  `role`.

  Controllers read `conn.assigns.current_scope`, which `StillWeb.Plugs.Auth`
  installs after authenticating the request. Routes that nest under an
  application run `StillWeb.Plugs.LoadApplicationScope` to enrich the scope
  with the parent `%Application{}`.

  For backend callers that operate without a request (the Orchestrator, the
  reconciliation loop), `for_system/0` returns a scope with no user — any
  application is layered on via `put_application/2`.
  """

  alias Still.Accounts.ApiKey
  alias Still.Accounts.User
  alias Still.Applications.Application

  defstruct user: nil, application: nil, api_key: nil

  @doc "Builds a scope for an authenticated user."
  def for_user(%User{} = user), do: %__MODULE__{user: user}
  def for_user(nil), do: nil

  @doc """
  Builds a scope for backend/system callers — no user, no parent. The caller
  typically enriches it with `put_application/2` before handing it to a
  context function.
  """
  def for_system, do: %__MODULE__{}

  @doc "Attaches a parent application to the scope."
  def put_application(%__MODULE__{} = scope, %Application{} = application) do
    %{scope | application: application}
  end

  @doc "Attaches the API key that authenticated the request to the scope."
  def put_api_key(%__MODULE__{} = scope, %ApiKey{} = api_key) do
    %{scope | api_key: api_key}
  end

  def put_api_key(%__MODULE__{} = scope, nil), do: scope

  @doc """
  Returns `true` if the scope is authorized for the given permission.

  Permissions are ordered `:read < :rollback < :deploy < :admin`. When the
  scope has an API key attached, effective permissions come from the
  key's `permissions` list — a key with `"deploy"` covers `:deploy`,
  `:rollback`, and `:read`, and so on. Without an API key, permissions
  come from the user's role:

    * `:admin` — everything
    * `:deployer` — `:read`, `:rollback`, `:deploy` (not `:admin`)
    * `:viewer` — `:read` only

  An empty scope (no user, no api_key) always returns `false`.
  """
  def can?(%__MODULE__{api_key: %ApiKey{} = api_key}, permission) when is_atom(permission) do
    permission_in_api_key?(api_key, permission)
  end

  def can?(%__MODULE__{user: %User{} = user}, permission) when is_atom(permission) do
    permission_in_role?(user.role, permission)
  end

  def can?(_scope, _permission), do: false

  defp permission_in_role?(:admin, _), do: true
  defp permission_in_role?(:deployer, :admin), do: false
  defp permission_in_role?(:deployer, _), do: true
  defp permission_in_role?(:viewer, :read), do: true
  defp permission_in_role?(:viewer, _), do: false

  defp permission_in_api_key?(%ApiKey{permissions: perms}, :admin), do: "admin" in perms

  defp permission_in_api_key?(%ApiKey{permissions: perms}, :deploy) do
    "admin" in perms or "deploy" in perms
  end

  defp permission_in_api_key?(%ApiKey{permissions: perms}, :rollback) do
    "admin" in perms or "deploy" in perms or "rollback" in perms
  end

  defp permission_in_api_key?(%ApiKey{permissions: perms}, :read) do
    "admin" in perms or "deploy" in perms or "rollback" in perms or "read" in perms
  end
end
