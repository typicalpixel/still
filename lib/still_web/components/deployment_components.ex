defmodule StillWeb.DeploymentComponents do
  @moduledoc """
  Presentation for deployments — status/trigger/duration derivations, the
  deploy-history and deployments-list tables, and the detail sections
  (header, progress, per-host steps, log).
  """

  use StillWeb, :html

  @doc "Status-dot tone for a deployment status."
  def deployment_dot(:completed), do: :healthy
  def deployment_dot(:rolled_back), do: :warn
  def deployment_dot(:failed), do: :danger
  def deployment_dot(_status), do: :info

  @doc ~S(Human label for a deployment status — "completed" reads as "succeeded".)
  def deployment_label(:completed), do: "succeeded"

  def deployment_label(status) when is_atom(status),
    do: status |> to_string() |> String.replace("_", " ")

  @doc "Whether a deployment is still running (pending or in progress)."
  def in_flight?(%{status: status}), do: status in [:pending, :in_progress]

  @doc "Trigger label: the source ref when set, otherwise the initiating actor."
  def trigger_label(%{source: source} = deployment), do: source || actor(deployment)

  @doc "Initiating actor, with the `user:`/`api:` prefix stripped."
  def actor(%{initiated_by: initiated_by}),
    do: Regex.replace(~r/^(?:user|api):/, initiated_by, "")

  @doc "Wall-clock duration between start and completion, or an em dash if unfinished."
  def duration_label(%{started_at: nil}), do: "—"
  def duration_label(%{completed_at: nil}), do: "—"

  def duration_label(%{started_at: started, completed_at: completed}),
    do: format_duration(DateTime.diff(completed, started, :second))

  @doc "Status-dot tone for a per-host step status (ports stepDot)."
  def step_dot(:completed), do: :healthy
  def step_dot(:failed), do: :danger
  def step_dot(:pending), do: :neutral
  def step_dot(_status), do: :info

  @doc "Human label for a step status — underscores become spaces."
  def step_label(status) when is_atom(status),
    do: status |> to_string() |> String.replace("_", " ")

  @doc """
  Duration of a per-host step (ports stepDuration): the finished duration, the
  elapsed time when still running, or an em dash before it starts.
  """
  def step_duration(%{started_at: nil}), do: "—"

  def step_duration(%{started_at: started, completed_at: nil}),
    do: "#{DateTime.diff(DateTime.utc_now(), started, :second)}s elapsed"

  def step_duration(%{started_at: started, completed_at: completed}) do
    case DateTime.diff(completed, started, :second) do
      seconds when seconds < 0 -> "—"
      seconds -> format_duration(seconds)
    end
  end

  @doc "Progress-bar fill class for a deployment status (ports progressBarClass)."
  def progress_bar_class(:completed), do: "bg-success"
  def progress_bar_class(:failed), do: "bg-error"
  def progress_bar_class(:rolled_back), do: "bg-warning"
  def progress_bar_class(_status), do: "bg-info"

  defp format_duration(seconds) when seconds < 60, do: "#{seconds}s"

  defp format_duration(seconds),
    do: "#{div(seconds, 60)}m #{String.pad_leading(to_string(rem(seconds, 60)), 2, "0")}s"

  @doc "The deploy-history table for one application: id, version, trigger, result, duration, time."
  attr :deployments, :list, required: true

  def deploy_table(assigns) do
    ~H"""
    <.table
      :if={@deployments != []}
      id="deploys"
      rows={@deployments}
      row_id={fn d -> "deploy-#{d.id}" end}
    >
      <:col :let={d} label="Deploy">
        <.link navigate={~p"/deployments/#{d.id}"} class="font-mono text-[12px] text-paper-500 dark:text-ink-300 hover:underline">
          {String.slice(d.id, 0, 8)}
        </.link>
      </:col>
      <:col :let={d} label="Version"><.chip>{d.version}</.chip></:col>
      <:col :let={d} label="Trigger">{trigger_label(d)} · {actor(d)}</:col>
      <:col :let={d} label="Result">
        <span class="inline-flex items-center gap-2">
          <.status_dot status={deployment_dot(d.status)} />{deployment_label(d.status)}
        </span>
      </:col>
      <:col :let={d} label="Duration">{duration_label(d)}</:col>
      <:col :let={d} label="When">{relative_time(d.inserted_at)}</:col>
    </.table>
    <p :if={@deployments == []} class="text-[13px] text-paper-500 dark:text-ink-300">No deploys yet.</p>
    """
  end

  @doc "The cross-application deployments list: application, status, version, duration, actor, time."
  attr :deployments, :list, required: true

  def deployments_table(assigns) do
    ~H"""
    <.table
      :if={@deployments != []}
      id="deployments"
      rows={@deployments}
      row_id={fn d -> "deployment-#{d.id}" end}
    >
      <:col :let={d} label="Application">
        <.link navigate={~p"/deployments/#{d.id}"} class="hover:underline">
          <div class="font-mono">{d.application.name}</div>
          <div class="font-mono text-[12px] text-paper-500 dark:text-ink-300">{String.slice(d.id, 0, 8)}</div>
        </.link>
      </:col>
      <:col :let={d} label="Status">
        <span class="inline-flex items-center gap-2">
          <.status_dot status={deployment_dot(d.status)} />{deployment_label(d.status)}
        </span>
      </:col>
      <:col :let={d} label="Version"><.chip>{d.version}</.chip></:col>
      <:col :let={d} label="Duration">{duration_label(d)}</:col>
      <:col :let={d} label="Actor">{actor(d)}</:col>
      <:col :let={d} label="When">{relative_time(d.inserted_at)}</:col>
    </.table>
    <p :if={@deployments == []} class="text-[13px] text-paper-500 dark:text-ink-300">No deployments match this filter.</p>
    """
  end

  @doc "Deployment-detail header: status, application, version, trigger, and timing."
  attr :deployment, :map, required: true
  attr :app_name, :string, default: nil
  attr :eta_at, :any, default: nil

  def deployment_header(assigns) do
    ~H"""
    <.header>
      <span class="inline-flex items-center gap-2">
        <.status_dot status={deployment_dot(@deployment.status)} />
        <.link
          :if={@app_name}
          navigate={~p"/applications/#{@app_name}"}
          class="font-mono hover:underline"
        >
          {@app_name}
        </.link>
        <span :if={!@app_name} class="font-mono">—</span>
      </span>
      <:subtitle>
        {deployment_label(@deployment.status)} · <span class="font-mono">{String.slice(@deployment.id, 0, 8)}</span>
        · <.chip>{@deployment.version}</.chip>
        · {trigger_label(@deployment)} · {actor(@deployment)} · started {relative_time(
          @deployment.started_at
        )}<span :if={in_flight?(@deployment) and @eta_at}> · ETA {relative_time(@eta_at)}</span><span :if={
          not in_flight?(@deployment) and finished?(@deployment)
        }> · took {duration_label(@deployment)}</span>
      </:subtitle>
    </.header>
    """
  end

  @doc "Overall progress bar: completed/total hosts and percent complete."
  attr :progress, :map, required: true
  attr :status, :atom, required: true

  def deployment_progress(assigns) do
    ~H"""
    <div class="rounded-lg hairline border p-4">
      <div class="mb-2 flex items-baseline justify-between gap-4">
        <span class="text-[13px] font-medium text-paper-800 dark:text-ink-50">Overall progress</span>
        <span class="font-mono text-[12px] tabular-nums text-paper-500 dark:text-ink-300">
          {@progress.completed_steps} / {@progress.total_steps} hosts · {@progress.pct}% complete
        </span>
      </div>
      <div class="h-1.5 overflow-hidden rounded-full bg-paper-200 dark:bg-ink-700">
        <div
          class={["h-full rounded-full transition-[width]", progress_bar_class(@status)]}
          style={"width: #{@progress.pct}%"}
        />
      </div>
    </div>
    """
  end

  @doc "Per-host step rows: host, status, duration, and start time."
  attr :steps, :list, required: true

  def deployment_steps(assigns) do
    ~H"""
    <.table :if={@steps != []} id="steps" rows={@steps} row_id={fn s -> "step-#{s.id}" end}>
      <:col :let={s} label="Host">
        <.link navigate={~p"/servers/#{s.server_id}"} class="hover:underline">
          <div class="font-mono">{s.server_name}</div>
          <div class="font-mono text-[12px] text-paper-500 dark:text-ink-300">{s.host}</div>
        </.link>
        <div :if={s.error} class="mt-1 text-xs text-rust-700 dark:text-rust-300" title={s.error}>{s.error}</div>
      </:col>
      <:col :let={s} label="Status">
        <span class="inline-flex items-center gap-2">
          <.status_dot status={step_dot(s.status)} />{step_label(s.status)}
        </span>
      </:col>
      <:col :let={s} label="Duration">{step_duration(s)}</:col>
      <:col :let={s} label="Started">{relative_time(s.started_at)}</:col>
    </.table>
    <p :if={@steps == []} class="text-[13px] text-paper-500 dark:text-ink-300">No steps recorded yet.</p>
    """
  end

  @doc "The deploy log section — a placeholder until streaming lands in v0.2.0."
  attr :deployment, :map, required: true

  def deployment_log(assigns) do
    ~H"""
    <div class="mb-2 flex items-baseline justify-between gap-4">
      <h2 class="text-[13px] font-medium text-paper-800 dark:text-ink-50">
        {if in_flight?(@deployment), do: "Live log", else: "Log"}
      </h2>
      <span class="font-mono text-[11px] text-paper-400 italic dark:text-ink-500">
        streaming arrives in v0.2.0
      </span>
    </div>
    <pre class="max-h-80 min-h-40 overflow-auto rounded-lg bg-neutral p-4 font-mono text-xs text-neutral-content"><span :if={in_flight?(@deployment)} class="animate-pulse text-info">▌</span></pre>
    <p :if={last_seen(@deployment) && not in_flight?(@deployment)} class="mt-2 text-[12px] text-paper-500 dark:text-ink-300">
      last activity {relative_time(last_seen(@deployment))}
    </p>
    """
  end

  @doc "The start-deploy dialog for the deployments index — pick an application, then version/artifact."
  attr :show, :boolean, required: true
  attr :form, :any, required: true
  attr :apps, :list, required: true
  attr :error, :string, default: nil

  def deploy_start_dialog(assigns) do
    ~H"""
    <.modal id="start-deploy" show={@show} on_cancel="close_deploy">
      <:title>Start a deploy</:title>

      <.form for={@form} id="start-deploy-form" phx-submit="deploy" class="space-y-3">
        <p class="text-[12.5px] text-paper-500 dark:text-ink-300">
          Triggers a rolling deploy across the application's hosts.
        </p>
        <.input
          field={@form[:application]}
          type="select"
          label="Application"
          prompt="Choose an application…"
          options={@apps}
        />
        <.input field={@form[:version]} label="Version" placeholder="v143 or 0.0.42" />
        <.input
          field={@form[:artifact_url]}
          label="Artifact URL"
          placeholder="https://…/release.tar.gz"
        />
        <.input field={@form[:source]} label="Source (optional)" placeholder="git:main@abc1234" />
        <p :if={@error} class="text-[12px] text-rust-700 dark:text-rust-300">{@error}</p>

        <div class="modal-action">
          <button type="button" class="btn btn-sm" phx-click="close_deploy">Cancel</button>
          <button type="submit" class="btn btn-sm btn-primary">Start deploy</button>
        </div>
      </.form>
    </.modal>
    """
  end

  defp finished?(%{started_at: %DateTime{}, completed_at: %DateTime{}}), do: true
  defp finished?(_deployment), do: false

  defp last_seen(%{completed_at: completed, started_at: started}), do: completed || started
end
