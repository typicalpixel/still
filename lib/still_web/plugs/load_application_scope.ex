defmodule StillWeb.Plugs.LoadApplicationScope do
  @moduledoc """
  Loads the parent `%Application{}` named by the URL's `application_name`
  path parameter and puts it on `conn.assigns.current_scope`.

  Nested-resource routes (everything under `/api/applications/:application_name/*`)
  run this plug so controller actions can pass `conn.assigns.current_scope`
  straight into context functions. The context functions filter their
  queries through the scope's application, which turns stale or
  cross-application child ids into `Ecto.NoResultsError` — the
  `FallbackController` renders that as a 404.

  Requires `StillWeb.Plugs.Auth` to have already installed a scope on
  `:current_scope`.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Still.Accounts.Scope
  alias Still.Applications

  @doc "Plug init — no options."
  def init(opts) when is_list(opts), do: opts

  @doc "Plug call — enrich the scope with the parent application or 404."
  def call(%Plug.Conn{path_params: %{"application_name" => name}} = conn, _opts) do
    case fetch_application(name) do
      nil -> not_found(conn)
      application -> put_application_on_scope(conn, application)
    end
  end

  defp fetch_application(name) do
    Applications.get_application_by_name(name)
  end

  defp put_application_on_scope(conn, application) do
    scope = Map.get(conn.assigns, :current_scope) || Scope.for_system()
    assign(conn, :current_scope, Scope.put_application(scope, application))
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: %{message: "Application not found"}})
    |> halt()
  end
end
