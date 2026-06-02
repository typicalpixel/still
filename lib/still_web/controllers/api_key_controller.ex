defmodule StillWeb.ApiKeyController do
  @moduledoc """
  Create, list, and revoke API keys for the current user.
  """

  use StillWeb, :controller

  use OpenApiSpex.ControllerSpecs

  action_fallback StillWeb.FallbackController

  plug StillWeb.Plugs.Authorize, :read when action in [:index]
  plug StillWeb.Plugs.Authorize, :admin when action in [:create, :delete]

  alias Still.Accounts
  alias Still.Audit.Actor
  alias StillWeb.ApiKeyJSON
  alias StillWeb.Schemas
  alias StillWeb.Schemas.Envelope

  tags(["ApiKeys"])

  operation(:index,
    summary: "List the current user's API keys",
    responses: [ok: {"API keys", "application/json", Envelope.list(Schemas.ApiKey)}]
  )

  @doc "Lists the current user's API keys (names and permissions only — never hashes)."
  def index(%Plug.Conn{} = conn, _params) do
    keys = Accounts.list_api_keys_for(conn.assigns.current_user)
    json(conn, ApiKeyJSON.render(keys))
  end

  operation(:create,
    summary: "Create a new API key",
    description: "The raw key (`still_...`) is returned in `data.raw_key` exactly once.",
    request_body: {"Key attributes", "application/json", Schemas.CreateApiKeyRequest},
    responses: [
      created: {"API key with raw bearer", "application/json", Schemas.ApiKeyCreatedResponse},
      unprocessable_entity: {"Validation failed", "application/json", Schemas.Error},
      forbidden: {"Admin permission required", "application/json", Schemas.Error}
    ]
  )

  @doc "Creates a new API key. The raw key is returned once and never again."
  def create(%Plug.Conn{} = conn, params) when is_map(params) do
    with {:ok, api_key} <-
           Accounts.create_api_key(Actor.from_conn(conn), conn.assigns.current_user, params) do
      conn |> put_status(:created) |> json(ApiKeyJSON.render_created(api_key))
    end
  end

  operation(:delete,
    summary: "Revoke an API key",
    description: "Returns 404 if the key does not belong to the current user.",
    parameters: [
      id: [in: :path, schema: %OpenApiSpex.Schema{type: :string, format: :uuid}, required: true]
    ],
    responses: [
      no_content: "Revoked",
      not_found: {"Unknown id or owned by a different user", "application/json", Schemas.Error},
      forbidden: {"Admin permission required", "application/json", Schemas.Error}
    ]
  )

  @doc "Revokes an API key. Returns 404 if the key doesn't belong to the current user."
  def delete(%Plug.Conn{} = conn, %{"id" => id}) do
    api_key = Accounts.get_api_key!(id)

    if api_key.user_id != conn.assigns.current_user.id do
      {:error, :not_found}
    else
      {:ok, _} = Accounts.delete_api_key(Actor.from_conn(conn), api_key)
      send_resp(conn, :no_content, "")
    end
  end
end
