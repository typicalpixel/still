defmodule StillWeb.ApplicationsLive do
  @moduledoc """
  Applications list: type, domain, common version, live/total hosts, 24h
  traffic, and last-deploy time. Admins can create an application here. Reloads
  on deploy/health/fleet changes.
  """

  use StillWeb, :live_view

  import StillWeb.ApplicationComponents

  alias Still.Accounts.Scope
  alias Still.Applications
  alias Still.Audit.Actor
  alias Still.Deployments
  alias Still.Events
  alias Still.Status
  alias StillWeb.EnvRows

  @doc "Mounts the applications list and subscribes to live topics."
  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Events.subscribe("events:lobby")
      Events.subscribe("servers:lobby")
      Events.subscribe("fleet:changes")
    end

    {:ok,
     socket
     |> assign(:page_title, "Applications")
     |> assign(:can_admin, Scope.can?(socket.assigns.current_scope, :admin))
     |> assign(:create_open, false)
     |> assign(:create_type, "elixir_release")
     |> assign(:create_error, nil)
     |> assign(:create_form, create_form())
     |> assign(:env_rows, [])
     |> load_apps()}
  end

  @doc "Renders the applications list."
  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} nav={@nav} active_nav={:applications}>
      <.header>
        Applications
        <:subtitle>{length(@apps)} applications · {@healthy_count} healthy</:subtitle>
        <:actions>
          <button
            :if={@can_admin}
            type="button"
            class="btn btn-sm btn-primary"
            phx-click="open_create"
          >
            Add application
          </button>
        </:actions>
      </.header>

      <.applications_table apps={@apps} last_deploys={@last_deploys} />

      <.application_create_dialog
        show={@create_open}
        form={@create_form}
        type={@create_type}
        env_rows={@env_rows}
        error={@create_error}
      />
    </Layouts.app>
    """
  end

  @doc "Reloads the list on deploy/health, server connect/disconnect, and fleet changes."
  @impl true
  def handle_info({:event_recorded, event}, socket) do
    {:noreply,
     if(event.type in [:deployment_updated, :health_transition],
       do: load_apps(socket),
       else: socket
     )}
  end

  def handle_info({:server_connected, _payload}, socket), do: {:noreply, load_apps(socket)}
  def handle_info({:server_disconnected, _payload}, socket), do: {:noreply, load_apps(socket)}
  def handle_info(:fleet_changed, socket), do: {:noreply, load_apps(socket)}

  @doc "Drives the create-application dialog."
  @impl true
  def handle_event("open_create", _params, socket) do
    if authorized?(socket, :admin) do
      {:noreply,
       socket
       |> assign(:create_open, true)
       |> assign(:create_type, "elixir_release")
       |> assign(:create_error, nil)
       |> assign(:create_form, create_form())
       |> assign(:env_rows, [])}
    else
      {:noreply, put_flash(socket, :error, "Admin permission required.")}
    end
  end

  def handle_event("close_create", _params, socket),
    do: {:noreply, assign(socket, :create_open, false)}

  def handle_event("select_create_type", %{"type" => type}, socket) do
    if authorized?(socket, :admin) do
      {:noreply, assign(socket, :create_type, type)}
    else
      {:noreply, put_flash(socket, :error, "Admin permission required.")}
    end
  end

  def handle_event("validate_create", params, socket) do
    if authorized?(socket, :admin) do
      {:noreply, assign(socket, :env_rows, EnvRows.from_params(Map.get(params, "env", %{})))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("add_env_row", _params, socket) do
    if authorized?(socket, :admin) do
      {:noreply, update(socket, :env_rows, &(&1 ++ [%{key: "", value: ""}]))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("remove_env_row", %{"index" => index}, socket) do
    if authorized?(socket, :admin) do
      {:noreply, update(socket, :env_rows, &List.delete_at(&1, String.to_integer(index)))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("create_app", %{"app" => params} = all, socket) do
    if authorized?(socket, :admin) do
      create_app(socket, params, EnvRows.from_params(Map.get(all, "env", %{})))
    else
      {:noreply, put_flash(socket, :error, "Admin permission required.")}
    end
  end

  defp create_app(socket, params, rows) do
    case EnvRows.to_env_vars(rows) do
      {:error, message} ->
        {:noreply, socket |> assign(:env_rows, rows) |> assign(:create_error, message)}

      {:ok, env_vars} ->
        attrs =
          params |> create_attrs(socket.assigns.create_type) |> Map.put("env_vars", env_vars)

        case Applications.create_application(
               Actor.from_scope(socket.assigns.current_scope),
               attrs
             ) do
          {:ok, app} ->
            {:noreply,
             socket
             |> put_flash(:info, "#{app.name} created")
             |> push_navigate(to: ~p"/applications/#{app.name}")}

          {:error, changeset} ->
            {:noreply,
             socket
             |> assign(:create_form, to_form(params, as: :app))
             |> assign(:env_rows, rows)
             |> assign(:create_error, humanize_changeset(changeset))}
        end
    end
  end

  defp authorized?(socket, permission) do
    Scope.can?(socket.assigns.current_scope, permission)
  end

  defp load_apps(socket) do
    apps = Status.applications_with_reports()

    socket
    |> assign(:apps, apps)
    |> assign(:healthy_count, Enum.count(apps, &(row_health(&1) in [:healthy, :na])))
    |> assign(:last_deploys, last_deploys())
  end

  defp last_deploys do
    %{limit: 50}
    |> Deployments.list_deployments()
    |> Enum.reduce(%{}, fn d, acc -> Map.put_new(acc, d.application.name, d.inserted_at) end)
  end

  defp create_form do
    to_form(
      %{
        "name" => "",
        "domain" => "",
        "path_prefix" => "",
        "exec_command" => "",
        "min_healthy" => "1",
        "hc_path" => "/health",
        "hc_interval" => "5000",
        "hc_deadline" => "3000",
        "artifact_type" => "unauthenticated_url"
      },
      as: :app
    )
  end

  defp create_attrs(params, type) do
    %{
      "name" => params["name"],
      "type" => type,
      "domain" => params["domain"],
      "path_prefix" => blank_to_nil(params["path_prefix"]),
      "min_healthy" => params["min_healthy"],
      "artifact_source" => %{"type" => params["artifact_type"]}
    }
    |> put_exec(type, params)
    |> put_health(type, params)
  end

  defp put_exec(attrs, type, params) when type in ["elixir_release", "process"],
    do: Map.put(attrs, "exec_command", params["exec_command"])

  defp put_exec(attrs, _type, _params), do: attrs

  defp put_health(attrs, "static_site", _params), do: attrs

  defp put_health(attrs, _type, params) do
    Map.put(attrs, "health_check", %{
      "path" => params["hc_path"],
      "interval_ms" => params["hc_interval"],
      "deadline_ms" => params["hc_deadline"]
    })
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp humanize_changeset(changeset) do
    Enum.map_join(changeset.errors, " · ", fn {field, {msg, opts}} ->
      "#{field} #{interpolate(msg, opts)}"
    end)
  end

  defp interpolate(msg, opts) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end
end
