defmodule StillWeb.DeploymentLive do
  @moduledoc """
  Deployment detail: status, the application and version, overall progress, and
  per-host steps. Subscribes to `deployments:<app>` and reloads as steps
  transition.

  Pause / roll back / log streaming land in follow-up passes.
  """

  use StillWeb, :live_view

  import StillWeb.DeploymentComponents

  alias Still.Deployments
  alias Still.Deployments.Deployment
  alias Still.Events
  alias Still.Fleet

  @doc "Mounts the deployment detail and subscribes to its application's deploy stream."
  @impl true
  def mount(%{"id" => id}, _session, socket) do
    socket = socket |> assign(:id, id) |> assign(:page_title, "Deployment") |> load()

    if connected?(socket) and socket.assigns.deployment do
      Events.subscribe("deployments:#{socket.assigns.app_name}")
    end

    {:ok, socket}
  end

  @doc "Renders the deployment detail, or a not-found notice."
  @impl true
  def render(%{deployment: nil} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} nav={@nav} active_nav={:deployments}>
      <.header>Deployment not found</.header>
      <.link navigate={~p"/deployments"} class="link text-sm">← Back to deployments</.link>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      nav={@nav}
      active_nav={:deployments}
      breadcrumbs={[
        %{label: "Deployments", navigate: ~p"/deployments"},
        %{label: String.slice(@deployment.id, 0, 8)}
      ]}
    >
      <.deployment_header deployment={@deployment} app_name={@app_name} eta_at={@eta_at} />

      <section class="mt-6">
        <.deployment_progress progress={@progress} status={@deployment.status} />
      </section>

      <section class="mt-8">
        <.section_heading>Per-host steps</.section_heading>
        <.deployment_steps steps={@steps} />
      </section>

      <section class="mt-8">
        <.deployment_log deployment={@deployment} log={@deploy_log} />
      </section>
    </Layouts.app>
    """
  end

  @doc "Reloads the deployment as its steps transition; ignores sibling deploys on the same app."
  @impl true
  def handle_info({:deployment_updated, %{deployment_id: id}}, socket) do
    {:noreply, if(id == socket.assigns.id, do: load(socket), else: socket)}
  end

  defp load(socket) do
    case Deployments.get_deployment(socket.assigns.id) do
      nil ->
        assign(socket, deployment: nil, app_name: nil)

      deployment ->
        servers_by_id = Map.new(Fleet.list_servers(), &{&1.id, &1})

        socket
        |> assign(:deployment, deployment)
        |> assign(:app_name, deployment.application.name)
        |> assign(:steps, build_steps(deployment, servers_by_id))
        |> assign(:progress, Deployment.progress(deployment))
        |> assign(:eta_at, Deployments.eta_at(deployment))
        |> assign(:deploy_log, demo_deploy_log(deployment.id))
    end
  end

  # Captured deploy-log text per PLAN_deployment_logs.md. Until journal capture
  # lands the source is empty in prod; a dev demo seed may populate it via the
  # :demo_deploy_logs app env (keyed by deployment id) for marketing screenshots.
  defp demo_deploy_log(id) do
    :still |> Application.get_env(:demo_deploy_logs, %{}) |> Map.get(id)
  end

  defp build_steps(deployment, servers_by_id) do
    for step <- deployment.steps do
      # A step's server can't be deleted without cascading the step away
      # (FK on_delete: :delete_all), so the lookup always hits.
      server = Map.fetch!(servers_by_id, step.server_id)

      %{
        id: step.id,
        server_id: step.server_id,
        server_name: server.name,
        host: server.host,
        status: step.status,
        error: step.error,
        started_at: step.started_at,
        completed_at: step.completed_at
      }
    end
  end
end
