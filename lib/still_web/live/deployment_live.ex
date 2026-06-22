defmodule StillWeb.DeploymentLive do
  @moduledoc """
  Deployment detail: status, the application and version, overall progress,
  per-host steps, and the captured deploy log. Subscribes to `deployments:<app>`
  and reloads as steps transition, and to `deploy_logs:<id>` to stream the
  captured journal live.

  Pause / roll back land in follow-up passes.
  """

  use StillWeb, :live_view

  import StillWeb.DeploymentComponents

  alias Still.Accounts.Scope
  alias Still.DeployLogCollector
  alias Still.Deployments
  alias Still.Deployments.Deployment
  alias Still.Deployments.LogHints
  alias Still.Events
  alias Still.Fleet

  @doc "Mounts the deployment detail and subscribes to its application's deploy stream."
  @impl true
  def mount(%{"id" => id}, _session, socket) do
    socket = socket |> assign(:id, id) |> assign(:page_title, "Deployment") |> load()

    if connected?(socket) and socket.assigns.deployment do
      Events.subscribe("deployments:#{socket.assigns.app_name}")
      Events.subscribe("deploy_logs:#{socket.assigns.id}")
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
        <.deployment_log
          deployment={@deployment}
          log={@deploy_log}
          hint={@log_hint}
          can_view={@can_view_log}
          app_type={@deployment.application.type}
        />
      </section>
    </Layouts.app>
    """
  end

  # Reloads the deployment as its steps transition (ignoring sibling deploys on
  # the same app), and re-reads the captured log as agents report new journal.
  @impl true
  def handle_info({:deployment_updated, %{deployment_id: id}}, socket) do
    {:noreply, if(id == socket.assigns.id, do: load(socket), else: socket)}
  end

  def handle_info({:deploy_log_updated, %{deployment_id: id}}, socket) do
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
        |> assign(:servers_by_id, servers_by_id)
        |> assign(:steps, build_steps(deployment, servers_by_id))
        |> assign(:progress, Deployment.progress(deployment))
        |> assign(:eta_at, Deployments.eta_at(deployment))
        |> assign(:can_view_log, Scope.can?(socket.assigns.current_scope, :deploy))
        |> assign_log(deployment)
    end
  end

  # Deploy logs can carry secrets (DB URLs, env dumps), so they're gated behind
  # :deploy. The live ETS buffer fronts the capture while a deploy runs; the
  # stored step log takes over once it finalizes. The failure-signature hint is
  # only meaningful on a failed deploy — don't second-guess a healthy boot.
  defp assign_log(socket, deployment) do
    if socket.assigns.can_view_log do
      log = build_deploy_log(deployment, socket.assigns.servers_by_id)
      hint = if deployment.status == :failed, do: LogHints.hint_for(log), else: nil

      socket
      |> assign(:deploy_log, log)
      |> assign(:log_hint, hint)
    else
      socket |> assign(:deploy_log, nil) |> assign(:log_hint, nil)
    end
  end

  defp build_deploy_log(deployment, servers_by_id) do
    blocks =
      for step <- deployment.steps,
          text = step_log_text(deployment.id, step),
          is_binary(text) and text != "" do
        # The step's server can't be deleted without cascading the step away
        # (see build_steps/2), so the lookup always hits.
        {Map.fetch!(servers_by_id, step.server_id).name, text}
      end

    case blocks do
      [] -> nil
      [{_name, text}] -> text
      many -> Enum.map_join(many, "\n\n", fn {name, text} -> "── #{name} ──\n#{text}" end)
    end
  end

  # Live capture (ETS) wins while the deploy runs; the persisted step log is the
  # source of truth once it's done.
  defp step_log_text(deployment_id, step) do
    DeployLogCollector.text_for(deployment_id, step.server_id) || step.log
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
