defmodule StillWeb.DeploymentsLive do
  @moduledoc """
  Cross-application deployments list, newest first. Honors `?application=` and
  `?status=` (all/in flight/failed) so links from an application or the in-flight
  banner deep-link into a filtered view. Reloads on deploy lifecycle events.
  Users with deploy permission can start a deploy here against any application.
  """

  use StillWeb, :live_view

  import StillWeb.DeploymentComponents

  alias Still.Accounts.Scope
  alias Still.Applications
  alias Still.Audit.Actor
  alias Still.Deployments
  alias Still.Events
  alias Still.Orchestrator

  # Long enough to see recent context, short enough that the list doesn't read
  # like an audit log (the API caps at 500 for a future "show more").
  @limit 15
  @reload_on [:deploy_initiated, :rollback_initiated, :restart_initiated, :deployment_updated]

  @doc "Mounts the deployments list and subscribes to the event stream."
  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Events.subscribe("events:lobby")

    {:ok,
     socket
     |> assign(:page_title, "Deployments")
     |> assign(:can_deploy, Scope.can?(socket.assigns.current_scope, :deploy))
     |> assign(:deploy_open, false)
     |> assign(:deploy_error, nil)
     |> assign(:deploy_form, deploy_form())
     |> assign(:app_names, Enum.map(Applications.list_applications(), & &1.name))}
  end

  @doc "Reads the application/status filters from the URL and loads the matching deployments."
  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:app_filter, parse_app(params))
     |> assign(:status_filter, parse_status(params))
     |> load()}
  end

  @doc "Renders the deployments list with its status tabs and application filter."
  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} nav={@nav} active_nav={:deployments}>
      <.header>
        Deployments
        <:subtitle>
          showing {length(@deployments)} most recent · {@in_flight_count} in flight
        </:subtitle>
        <:actions>
          <button
            :if={@can_deploy}
            type="button"
            class="btn btn-sm btn-primary"
            phx-click="open_deploy"
          >
            Start deploy
          </button>
        </:actions>
      </.header>

      <div class="mt-4 mb-3 flex flex-wrap items-center gap-2">
        <.link
          :for={{value, label} <- [all: "All", in_flight: "In flight", failed: "Failed"]}
          patch={filter_path(@app_filter, value)}
          class={["badge", if(@status_filter == value, do: "badge-neutral", else: "badge-ghost")]}
        >
          {label}
        </.link>

        <.link
          :if={@app_filter}
          patch={filter_path(nil, @status_filter)}
          class="badge badge-ghost gap-1"
          title={"Clear #{@app_filter} filter"}
        >
          application: {@app_filter} <.icon name="hero-x-mark-micro" class="size-3" />
        </.link>
      </div>

      <.deployments_table deployments={@deployments} />

      <.deploy_start_dialog
        show={@deploy_open}
        form={@deploy_form}
        apps={@app_names}
        error={@deploy_error}
      />
    </Layouts.app>
    """
  end

  @doc "Reloads the list on deploy lifecycle events; ignores unrelated activity."
  @impl true
  def handle_info({:event_recorded, event}, socket) do
    {:noreply, if(event.type in @reload_on, do: load(socket), else: socket)}
  end

  @doc "Drives the start-deploy dialog and triggers the rolling deploy."
  @impl true
  def handle_event("open_deploy", _params, socket) do
    if Scope.can?(socket.assigns.current_scope, :deploy) do
      {:noreply,
       socket
       |> assign(:deploy_open, true)
       |> assign(:deploy_error, nil)
       |> assign(:deploy_form, deploy_form())}
    else
      {:noreply, put_flash(socket, :error, "Deploy permission required.")}
    end
  end

  def handle_event("close_deploy", _params, socket),
    do: {:noreply, assign(socket, :deploy_open, false)}

  def handle_event("deploy", %{"deploy" => params}, socket) do
    if Scope.can?(socket.assigns.current_scope, :deploy) do
      case Applications.get_application_by_name(params["application"]) do
        nil ->
          {:noreply, assign(socket, :deploy_error, "Pick an application.")}

        app ->
          start_deploy(socket, app, params)
      end
    else
      {:noreply, put_flash(socket, :error, "Deploy permission required.")}
    end
  end

  defp start_deploy(socket, app, params) do
    attrs = %{
      version: params["version"],
      artifact_url: params["artifact_url"],
      source: blank_to_nil(params["source"]),
      initiated_by: "user:#{socket.assigns.current_scope.user.email}"
    }

    case Orchestrator.trigger_deployment(
           Actor.from_scope(socket.assigns.current_scope),
           app,
           attrs
         ) do
      {:ok, deployment} ->
        {:noreply, push_navigate(socket, to: ~p"/deployments/#{deployment.id}")}

      {:error, :no_servers_assigned} ->
        {:noreply, assign(socket, :deploy_error, "Assign a server to that application first.")}

      {:error, _other} ->
        {:noreply,
         assign(socket, :deploy_error, "Couldn't start the deploy — check the version and URL.")}
    end
  end

  defp deploy_form do
    to_form(%{"application" => "", "version" => "", "artifact_url" => "", "source" => ""},
      as: :deploy
    )
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp load(socket) do
    raw = list(socket.assigns.app_filter, socket.assigns.status_filter)

    socket
    |> assign(:deployments, display(raw, socket.assigns.status_filter))
    |> assign(:in_flight_count, Enum.count(raw, &in_flight?/1))
  end

  defp list(app, status) do
    %{limit: @limit}
    |> put_filter(:application, app)
    |> put_filter(:status, api_status(status))
    |> Deployments.list_deployments()
  end

  defp put_filter(filters, _key, nil), do: filters
  defp put_filter(filters, key, value), do: Map.put(filters, key, value)

  # "in flight" spans pending + in_progress, which the API can't express as a
  # single status, so we filter that case client-side; "failed" is a concrete
  # status the API handles.
  defp api_status(:failed), do: "failed"
  defp api_status(_status), do: nil

  defp display(raw, :in_flight), do: Enum.filter(raw, &in_flight?/1)
  defp display(raw, _status), do: raw

  defp filter_path(app, status) do
    query = Enum.reject([application: app, status: status_param(status)], &(elem(&1, 1) == nil))
    ~p"/deployments?#{query}"
  end

  defp status_param(:all), do: nil
  defp status_param(status), do: status

  defp parse_app(%{"application" => app}) when is_binary(app) and app != "", do: app
  defp parse_app(_params), do: nil

  defp parse_status(%{"status" => "in_flight"}), do: :in_flight
  defp parse_status(%{"status" => "failed"}), do: :failed
  defp parse_status(_params), do: :all
end
