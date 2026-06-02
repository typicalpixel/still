defmodule StillWeb.FallbackController do
  @moduledoc """
  Translates controller action errors into JSON responses.

  Controllers declare `action_fallback StillWeb.FallbackController` and return
  `{:error, ...}` tuples — this module pattern-matches and renders the
  appropriate status + body.
  """

  use StillWeb, :controller

  @doc "Renders an error response for the given `{:error, reason}` tuple."
  def call(%Plug.Conn{} = conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{message: "Validation failed", detail: format_errors(changeset)}})
  end

  def call(%Plug.Conn{} = conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{error: %{message: "Not found"}})
  end

  def call(%Plug.Conn{} = conn, {:error, :deployment_in_progress}) do
    conn
    |> put_status(:conflict)
    |> json(%{error: %{message: "A deployment is already in progress for this application"}})
  end

  def call(%Plug.Conn{} = conn, {:error, :no_servers_assigned}) do
    conn
    |> put_status(:conflict)
    |> json(%{error: %{message: "No servers are assigned to this application"}})
  end

  def call(%Plug.Conn{} = conn, {:error, :insufficient_healthy_agents}) do
    conn
    |> put_status(:conflict)
    |> json(%{error: %{message: "Not enough healthy agents are connected"}})
  end

  def call(%Plug.Conn{} = conn, {:error, :no_available_ports}) do
    conn
    |> put_status(:conflict)
    |> json(%{error: %{message: "No available port pair on this server"}})
  end

  def call(%Plug.Conn{} = conn, {:error, :port_in_use}) do
    conn
    |> put_status(:conflict)
    |> json(%{error: %{message: "A chosen port is already in use on this server"}})
  end

  def call(%Plug.Conn{} = conn, {:error, :unauthorized}) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: %{message: "Invalid email or password"}})
  end

  def call(%Plug.Conn{} = conn, {:error, :bad_request}) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: %{message: "Bad request"}})
  end

  def call(%Plug.Conn{} = conn, {:error, :bootstrap_already_complete}) do
    conn
    |> put_status(:conflict)
    |> json(%{error: %{message: "Bootstrap is already complete"}})
  end

  def call(%Plug.Conn{} = conn, {:error, :server_has_assignments}) do
    conn
    |> put_status(:conflict)
    |> json(%{error: %{message: "Server has applications assigned — remove them first"}})
  end

  def call(%Plug.Conn{} = conn, {:error, :application_has_assignments}) do
    conn
    |> put_status(:conflict)
    |> json(%{error: %{message: "Application has servers assigned — remove them first"}})
  end

  def call(%Plug.Conn{} = conn, {:error, :no_rollback_target}) do
    conn
    |> put_status(:conflict)
    |> json(%{error: %{message: "No previous successful deployment to roll back to"}})
  end

  def call(%Plug.Conn{} = conn, {:error, :last_admin}) do
    conn
    |> put_status(:conflict)
    |> json(%{error: %{message: "Refusing to remove the last admin"}})
  end

  def call(%Plug.Conn{} = conn, {:error, :cannot_delete_self}) do
    conn
    |> put_status(:conflict)
    |> json(%{error: %{message: "You cannot delete your own account"}})
  end

  def call(%Plug.Conn{} = conn, {:error, :current_password_invalid}) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: %{message: "Current password is incorrect"}})
  end

  def call(%Plug.Conn{} = conn, {:error, :agent_disconnected}) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{error: %{message: "Agent is not connected"}})
  end

  def call(%Plug.Conn{} = conn, {:error, :caddy_unreachable}) do
    conn
    |> put_status(:bad_gateway)
    |> json(%{error: %{message: "Could not reach Caddy on the target node"}})
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
