defmodule StillWeb.NavAssigns do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  alias Still.Applications
  alias Still.Fleet

  @doc "on_mount hook: assigns the sidebar counts `%{apps:, servers:}` once at mount."
  def on_mount(:default, _params, _session, %Phoenix.LiveView.Socket{} = socket) do
    nav = %{apps: length(Applications.list_applications()), servers: length(Fleet.list_servers())}
    {:cont, assign(socket, :nav, nav)}
  end
end
