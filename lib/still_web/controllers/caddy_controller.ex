defmodule StillWeb.CaddyController do
  @moduledoc """
  Read-only inspection of the live Caddy JSON config a node is running.
  Admin-only — it exposes routing internals for diagnosing why traffic is (or
  isn't) reaching an app.
  """

  use StillWeb, :controller

  use OpenApiSpex.ControllerSpecs

  action_fallback StillWeb.FallbackController

  plug StillWeb.Plugs.Authorize, :admin

  alias OpenApiSpex.Schema
  alias Still.CaddyInspector
  alias StillWeb.Schemas
  alias StillWeb.Schemas.Envelope

  tags(["Caddy"])

  @config_schema %Schema{
    type: :object,
    additionalProperties: true,
    description: "The raw Caddy JSON config as returned by Caddy's admin API."
  }

  operation(:show,
    summary: "Inspect the controller's live Caddy config",
    description:
      "Returns the Caddy JSON config running on the node serving this API. Admin only.",
    responses: [
      ok: {"Config", "application/json", Envelope.single(@config_schema)},
      forbidden: {"Admin permission required", "application/json", Schemas.Error},
      bad_gateway: {"Could not reach Caddy on this node", "application/json", Schemas.Error}
    ]
  )

  @doc "Returns the local node's live Caddy config."
  def show(%Plug.Conn{} = conn, _params) do
    respond(conn, CaddyInspector.local_config())
  end

  operation(:show_server,
    summary: "Inspect a fleet server's live Caddy config",
    parameters: [id: [in: :path, type: :string, description: "Server id"]],
    responses: [
      ok: {"Config", "application/json", Envelope.single(@config_schema)},
      forbidden: {"Admin permission required", "application/json", Schemas.Error},
      service_unavailable: {"Agent not connected", "application/json", Schemas.Error},
      bad_gateway: {"Could not reach Caddy on the target node", "application/json", Schemas.Error}
    ]
  )

  @doc "Returns a connected agent's live Caddy config, fetched over distribution."
  def show_server(%Plug.Conn{} = conn, %{"id" => server_id}) do
    respond(conn, CaddyInspector.config_for_server(server_id))
  end

  defp respond(conn, {:ok, config}), do: json(conn, %{data: config})
  defp respond(_conn, {:error, _reason} = error), do: error
end
