defmodule StillWeb.ApplicationComponents do
  @moduledoc """
  Presentation for the application pages — health/version/host derivations
  and the applications table. Imported by the LiveViews that show
  application status.
  """

  use StillWeb, :html

  @doc """
  The applications table: name, common version, live/total hosts (tinted by
  health), health state, and a 24h traffic sparkline. Rows are keyed by
  application name. Takes `Still.Status.applications_with_reports/0` entries.
  """
  attr :apps, :list, required: true

  def app_table(assigns) do
    ~H"""
    <.table
      :if={@apps != []}
      id="apps"
      rows={@apps}
      row_id={fn entry -> "app-#{entry.application.name}" end}
      row_item={&app_row/1}
      row_click={fn entry -> JS.navigate(~p"/applications/#{entry.application.name}") end}
    >
      <:col :let={r} label="Application">
        <.link navigate={~p"/applications/#{r.name}"} class="font-medium hover:underline">
          {r.name}
        </.link>
      </:col>
      <:col :let={r} label="Type"><.application_display type={r.type} /></:col>
      <:col :let={r} label="Version"><.chip>{r.version}</.chip></:col>
      <:col :let={r} label="Hosts">
        <span class={["tabular-nums", r.hosts_class]}>{r.live}/{r.total}</span>
      </:col>
      <:col :let={r} label="State">
        <span class="inline-flex items-center gap-2">
          <.status_dot status={r.dot} />{r.label}
        </span>
      </:col>
      <:col :let={r} label="Traffic · 24h">
        <.sparkline :if={r.traffic} points={r.traffic} width={140} height={20} />
        <span :if={is_nil(r.traffic)} class="opacity-50">—</span>
      </:col>
    </.table>
    <p :if={@apps == []} class="text-[12.5px] text-paper-500 dark:text-ink-300">No applications yet.</p>
    """
  end

  @doc """
  The full applications index table: name, type, domain, version, live/total
  hosts, 24h traffic, and last-deploy time. `last_deploys` maps an application
  name to the timestamp of its most recent deploy.
  """
  attr :apps, :list, required: true
  attr :last_deploys, :map, required: true

  def applications_table(assigns) do
    ~H"""
    <.table
      :if={@apps != []}
      id="applications"
      rows={@apps}
      row_id={fn entry -> "app-#{entry.application.name}" end}
      row_item={fn entry -> index_row(entry, @last_deploys) end}
      row_click={fn entry -> JS.navigate(~p"/applications/#{entry.application.name}") end}
    >
      <:col :let={r} label="Application">
        <span class="inline-flex items-center gap-2">
          <.status_dot status={r.dot} />
          <.link navigate={~p"/applications/#{r.name}"} class="font-medium hover:underline">
            {r.name}
          </.link>
        </span>
      </:col>
      <:col :let={r} label="Type"><.application_display type={r.type} /></:col>
      <:col :let={r} label="Domain">
        <span class="mono text-[12px] text-paper-500 dark:text-ink-300">{r.domain}</span>
      </:col>
      <:col :let={r} label="Version"><.chip>{r.version}</.chip></:col>
      <:col :let={r} label="Health">
        <span class={["tabular-nums", r.hosts_class]}>{r.live}/{r.total}</span>
      </:col>
      <:col :let={r} label="Traffic · 24h">
        <.sparkline :if={r.traffic} points={r.traffic} width={140} height={20} />
        <span :if={is_nil(r.traffic)} class="opacity-50">—</span>
      </:col>
      <:col :let={r} label="Last deploy">{r.last_deploy}</:col>
    </.table>
    <p :if={@apps == []} class="text-[12.5px] text-paper-500 dark:text-ink-300">No applications yet.</p>
    """
  end

  defp index_row(entry, last_deploys) do
    health = row_health(entry)

    %{
      name: entry.application.name,
      type: entry.application.type,
      domain: entry.application.domain || "—",
      version: common_version(entry),
      live: live_count(entry),
      total: length(slots(entry)),
      dot: health_dot(health),
      hosts_class: hosts_color_class(health),
      traffic: traffic(entry),
      last_deploy: relative_time(Map.get(last_deploys, entry.application.name))
    }
  end

  @doc "A type chip — runtime label + icon."
  attr :type, :atom, required: true

  def application_display(assigns) do
    assigns = assign(assigns, :variant, type_variant(assigns.type))

    ~H"""
    <span
      title={@variant.title}
      class={[
        "mono inline-flex items-center gap-1 rounded-sm px-1.5 py-px text-[11.5px] font-medium tracking-[-0.005em]",
        @variant.tone
      ]}
    >
      <.icon name={@variant.icon} class="size-3 opacity-90" />{@variant.label}
    </span>
    """
  end

  # Type chips earn distinct tones so the runtime reads at a glance: plum for
  # the BEAM lineage, pink for static (far enough from rust/red not to read as
  # an error), neutral for process until it earns a signature of its own.
  defp type_variant(:elixir_release),
    do: %{
      label: "Elixir",
      title: "Elixir release · managed via mix release",
      icon: "hero-cpu-chip",
      tone: "bg-plum-50 text-plum-700 dark:bg-plum-500/25 dark:text-plum-100"
    }

  defp type_variant(:static_site),
    do: %{
      label: "Static",
      title: "Static site · served by Caddy",
      icon: "hero-globe-alt",
      tone: "bg-pink-100 text-pink-700 dark:bg-pink-500/25 dark:text-pink-200"
    }

  defp type_variant(:process),
    do: %{
      label: "Process",
      title: "Long-running process · run as a systemd unit",
      icon: "hero-command-line",
      tone: "bg-paper-200 text-paper-700 dark:bg-ink-600 dark:text-ink-100"
    }

  @doc "Humanizes a hook event atom/string — `pre_deploy` becomes `Pre-deploy`."
  def humanize_event(event) when is_atom(event) or is_binary(event),
    do: event |> to_string() |> String.replace("_", "-") |> String.capitalize()

  @doc "The configuration card for an application detail page."
  attr :app, :map, required: true

  def app_config(assigns) do
    ~H"""
    <.detail_list>
      <.detail_row label="Type">{@app.type}</.detail_row>
      <.detail_row :if={@app.exec_command} label="Exec" mono>{@app.exec_command}</.detail_row>
      <.detail_row :if={@app.exec_start_pre} label="Exec start pre" mono>
        {@app.exec_start_pre}
      </.detail_row>
      <.detail_row :if={@app.exec_stop} label="Exec stop" mono>{@app.exec_stop}</.detail_row>
      <.detail_row :if={@app.path_prefix} label="Path prefix" mono>{@app.path_prefix}</.detail_row>
      <.detail_row :if={@app.health_check} label="Health check" mono>
        GET {@app.health_check.path} · {@app.health_check.interval_ms}ms interval · {@app.health_check.deadline_ms}ms deadline
      </.detail_row>
      <.detail_row label="Min healthy">{@app.min_healthy}</.detail_row>
      <.detail_row label="Artifact source">{@app.artifact_source.type}</.detail_row>
      <.detail_row label="Created">{relative_time(@app.inserted_at)}</.detail_row>
      <.detail_row label="Updated">{relative_time(@app.updated_at)}</.detail_row>
    </.detail_list>
    """
  end

  @doc "A card wrapper of aligned label/value rows — shared by the app-detail sections."
  slot :inner_block, required: true

  def detail_list(assigns) do
    ~H"""
    <dl class="card-surface grid grid-cols-[max-content_1fr] gap-x-6 divide-y divide-paper-200 overflow-hidden rounded-2xl text-[13px] dark:divide-ink-700">
      {render_slot(@inner_block)}
    </dl>
    """
  end

  @doc "One aligned label/value row inside a `detail_list`. `mono` renders the value monospaced."
  attr :label, :string, required: true
  attr :mono, :boolean, default: false
  slot :inner_block, required: true

  def detail_row(assigns) do
    ~H"""
    <div class="col-span-2 grid grid-cols-subgrid items-baseline px-4 py-2.5">
      <dt class="font-medium text-paper-700 dark:text-ink-100">{@label}</dt>
      <dd class={["min-w-0 text-paper-600 dark:text-ink-300", @mono && "font-mono"]}>
        {render_slot(@inner_block)}
      </dd>
    </div>
    """
  end

  @doc "The environment-variables list for an application detail page."
  attr :app, :map, required: true

  def app_env(assigns) do
    assigns = assign(assigns, :entries, env_entries(assigns.app))

    ~H"""
    <dl
      :if={@entries != []}
      class="card-surface grid grid-cols-[max-content_1fr] gap-x-6 divide-y divide-paper-200 overflow-hidden rounded-2xl text-[13px] dark:divide-ink-700"
    >
      <div
        :for={{key, value} <- @entries}
        class="col-span-2 grid grid-cols-subgrid items-baseline px-4 py-2.5"
      >
        <dt class="font-mono font-medium text-paper-800 dark:text-ink-50">{key}</dt>
        <dd class="min-w-0 truncate font-mono text-paper-500 dark:text-ink-300" title={value}>
          {value}
        </dd>
      </div>
    </dl>
    <p :if={@entries == []} class="text-[13px] text-paper-500 italic dark:text-ink-300">
      No environment variables set.
    </p>
    """
  end

  @doc "The lifecycle-hooks list for an application detail page."
  attr :hooks, :list, required: true
  attr :can_admin, :boolean, default: false

  def app_hooks(assigns) do
    ~H"""
    <div
      :if={@hooks != []}
      class="card-surface divide-y divide-paper-200 overflow-hidden rounded-2xl dark:divide-ink-700"
    >
      <div :for={hook <- @hooks} id={"hook-#{hook.id}"} class="space-y-2 px-4 py-3">
        <div class="flex flex-wrap items-center justify-between gap-2 text-[13px]">
          <div class="flex flex-wrap items-baseline gap-2">
            <span class="font-medium text-paper-800 dark:text-ink-50">{humanize_event(hook.event)}</span>
            <span class="text-[12px] text-paper-500 dark:text-ink-300">
              timeout {hook.timeout_ms}ms · updated {relative_time(hook.updated_at)}
            </span>
          </div>
          <div :if={@can_admin} class="flex items-center gap-1.5">
            <button
              type="button"
              class="btn btn-ghost btn-xs"
              phx-click="open_hook_edit"
              phx-value-id={hook.id}
            >
              Edit
            </button>
            <button
              type="button"
              class="btn btn-ghost btn-xs"
              phx-click="open_hook_delete"
              phx-value-id={hook.id}
            >
              Delete
            </button>
          </div>
        </div>
        <pre class="code-surface max-h-40 overflow-auto rounded-lg px-3 py-2 font-mono text-[12px] ring-1 ring-white/[0.06]">{hook.script}</pre>
      </div>
    </div>
    <p :if={@hooks == []} class="text-[13px] text-paper-500 italic dark:text-ink-300">
      No lifecycle hooks configured.
    </p>
    """
  end

  defp env_entries(app), do: app.env_vars |> Map.to_list() |> Enum.sort_by(&elem(&1, 0))

  defp app_row(entry) do
    health = row_health(entry)

    %{
      name: entry.application.name,
      type: entry.application.type,
      version: common_version(entry),
      live: live_count(entry),
      total: length(slots(entry)),
      dot: health_dot(health),
      label: row_health_label(health),
      hosts_class: hosts_color_class(health),
      traffic: traffic(entry)
    }
  end

  @doc "Row health for an application: `:healthy`, `:degraded`, `:unhealthy`, `:na`, or `:undeployed`."
  def row_health(entry) when is_map(entry) do
    slots = slots(entry)
    min = entry.application.min_healthy

    cond do
      not deployed?(slots) -> :undeployed
      health_checked?(slots) -> probed_health(slots, min)
      true -> inferred_health(slots, min)
    end
  end

  defp deployed?(slots), do: Enum.any?(slots, &(&1.desired_version != nil))

  defp probed_health(slots, min) do
    healthy = Enum.count(slots, &(&1.health == :healthy))

    cond do
      healthy >= min and Enum.all?(slots, &(&1.health == :healthy)) -> :healthy
      healthy >= min -> :degraded
      true -> :unhealthy
    end
  end

  defp inferred_health(slots, min) do
    live = Enum.count(slots, &live_slot?/1)

    cond do
      Enum.all?(slots, &live_slot?/1) and live >= min -> :na
      live >= min -> :degraded
      true -> :unhealthy
    end
  end

  @doc "Count of hosts the app is live on — healthy probes, or deployed bits for no-probe apps."
  def live_count(entry) when is_map(entry) do
    slots = slots(entry)

    if health_checked?(slots) do
      Enum.count(slots, &(&1.health == :healthy))
    else
      Enum.count(slots, &live_slot?/1)
    end
  end

  @doc "Maps a row health to a `status_dot` tone."
  def health_dot(:healthy), do: :healthy
  def health_dot(:na), do: :healthy
  def health_dot(:undeployed), do: :neutral
  def health_dot(:degraded), do: :warn
  def health_dot(:unhealthy), do: :danger
  def health_dot(_other), do: :neutral

  @doc ~S|Human label for a row health (`:na` reads as "running", `:undeployed` as "not deployed").|
  def row_health_label(:na), do: "running"
  def row_health_label(:undeployed), do: "not deployed"
  def row_health_label(health) when is_atom(health), do: to_string(health)

  @doc "Tailwind text color tinting the host count to match the row's health."
  def hosts_color_class(health) when is_atom(health) do
    case health_dot(health) do
      :warn -> "text-warning"
      :danger -> "text-error"
      _ok -> ""
    end
  end

  @doc "Most-common per-server current version across the fleet, or an em dash."
  def common_version(entry) when is_map(entry) do
    versions = entry |> slots() |> Enum.map(& &1.current_version) |> Enum.reject(&is_nil/1)

    case versions do
      [] -> "—"
      _ -> versions |> Enum.frequencies() |> Enum.max_by(&elem(&1, 1)) |> elem(0)
    end
  end

  @doc "24 hourly traffic buckets for the sparkline, or nil when there are no samples."
  def traffic(entry) when is_map(entry), do: bucket_traffic(entry.metrics.samples)

  # An app's per-server slots, derived from a applications_with_reports entry.
  defp slots(%{assigned: assigned}) do
    Enum.map(assigned, fn {row, report, live} ->
      %{
        health: live && live.health,
        current_version: live && live.current_version,
        desired_version: row.desired_version,
        connected: report != nil
      }
    end)
  end

  defp health_checked?(slots), do: Enum.any?(slots, &(&1.health != nil))

  defp live_slot?(slot) do
    slot.connected and slot.current_version != nil and
      slot.current_version == slot.desired_version
  end

  defp bucket_traffic([]), do: nil

  defp bucket_traffic(samples) do
    recent = samples |> Enum.reverse() |> Enum.take(24 * 60)

    recent
    |> Enum.with_index()
    |> Enum.reduce(List.duplicate(0, 24), fn {sample, i}, buckets ->
      List.update_at(buckets, 23 - div(i, 60), &(&1 + sample.delta))
    end)
  end

  @doc "The create-application dialog. `type` drives which type-specific fields show."
  attr :show, :boolean, required: true
  attr :form, :any, required: true
  attr :type, :string, required: true
  attr :env_rows, :list, required: true
  attr :error, :string, default: nil

  def application_create_dialog(assigns) do
    ~H"""
    <.modal id="create-app" show={@show} on_cancel="close_create" class="max-w-2xl">
      <:title>Create an application</:title>

      <.form
        for={@form}
        id="create-app-form"
        phx-change="validate_create"
        phx-submit="create_app"
        class="space-y-3"
      >
        <div class="grid grid-cols-1 items-start gap-x-4 sm:grid-cols-2">
          <.input field={@form[:name]} label="Name" placeholder="orchard-api" class="input w-full font-mono" />
          <div class="fieldset mb-2">
            <span class="mb-1 block text-[12px] font-medium text-paper-600 dark:text-ink-200">
              Type
            </span>
            <div class="flex flex-wrap gap-1">
              <button
                :for={
                  {value, label} <- [
                    {"elixir_release", "Elixir release"},
                    {"static_site", "Static site"},
                    {"process", "Process"}
                  ]
                }
                type="button"
                phx-click="select_create_type"
                phx-value-type={value}
                class={["btn btn-sm", if(value == @type, do: "btn-neutral", else: "btn-ghost")]}
              >
                {label}
              </button>
            </div>
          </div>
        </div>

        <div class="grid grid-cols-1 gap-x-4 sm:grid-cols-2">
          <.input
            field={@form[:domain]}
            label="Domain"
            placeholder="api.orchard.io"
            class="input w-full font-mono"
          />
          <.input
            field={@form[:path_prefix]}
            label="Path prefix (optional)"
            placeholder="/api"
            class="input w-full font-mono"
          />
        </div>

        <.input
          :if={@type != "static_site"}
          field={@form[:exec_command]}
          label="Exec command"
          placeholder="bin/orchard start"
          class="input w-full font-mono"
        />
        <div :if={@type != "static_site"} class="grid grid-cols-1 gap-x-4 sm:grid-cols-2">
          <.input
            field={@form[:exec_start_pre]}
            label="Exec start pre (optional)"
            placeholder="bin/orchard eval Orchard.Release.migrate"
            class="input w-full font-mono"
          />
          <.input
            field={@form[:exec_stop]}
            label="Exec stop (optional)"
            placeholder="bin/orchard stop"
            class="input w-full font-mono"
          />
        </div>

        <div class="grid grid-cols-1 gap-x-4 sm:grid-cols-2">
          <.input field={@form[:min_healthy]} type="number" label="Min healthy" min="1" />
          <.input
            field={@form[:artifact_type]}
            type="select"
            label="Artifact source"
            options={[{"Public URL", "unauthenticated_url"}, {"Local file", "local_file"}]}
          />
        </div>

        <fieldset :if={@type != "static_site"} class="well-surface rounded-lg p-3">
          <p class="mb-2 text-[13px] font-semibold text-paper-800 dark:text-ink-50">Health check</p>
          <div class="grid grid-cols-1 gap-x-4 sm:grid-cols-[2fr_1fr_1fr]">
            <.input field={@form[:hc_path]} label="Path" placeholder="/health" class="input w-full font-mono" />
            <.input field={@form[:hc_interval]} type="number" min="1" label="Interval (ms)" />
            <.input field={@form[:hc_deadline]} type="number" min="1" label="Deadline (ms)" />
          </div>
        </fieldset>

        <fieldset class="well-surface rounded-lg p-3">
          <p class="mb-1 text-[13px] font-semibold text-paper-800 dark:text-ink-50">Environment</p>
          <p class="mb-2 text-[12px] text-paper-500 dark:text-ink-300">
            Variables the app needs at first boot — a database URL, secret key base, and so on.
          </p>
          <.env_var_rows rows={@env_rows} />
        </fieldset>

        <p :if={@error} class="text-[12px] text-rust-700 dark:text-rust-300">{@error}</p>

        <div class="modal-action">
          <button type="button" class="btn btn-sm" phx-click="close_create">Cancel</button>
          <button type="submit" class="btn btn-sm btn-primary">Create</button>
        </div>
      </.form>
    </.modal>
    """
  end

  @doc "The delete-application confirmation dialog."
  attr :app, :map, required: true
  attr :show, :boolean, required: true
  attr :error, :string, default: nil

  def app_delete_dialog(assigns) do
    ~H"""
    <.modal id="delete-app" show={@show} on_cancel="close_delete">
      <:title>Delete {@app.name}?</:title>

      <p class="text-sm">
        The application record, deploy history, hook scripts, and server-assignment metadata are
        removed from the controller. Running processes on assigned hosts are not stopped.
      </p>
      <p :if={@error} class="mt-3 text-sm text-rust-700 dark:text-rust-300">{@error}</p>

      <div class="modal-action">
        <button type="button" class="btn btn-sm" phx-click="close_delete">Cancel</button>
        <button type="button" class="btn btn-sm btn-error" phx-click="delete_app">Delete</button>
      </div>
    </.modal>
    """
  end

  @doc "The assign-a-server dialog — a picker over the eligible (application-role, unassigned) hosts."
  attr :show, :boolean, required: true
  attr :app_name, :string, required: true
  attr :servers, :list, required: true
  attr :error, :string, default: nil

  def assign_server_dialog(assigns) do
    ~H"""
    <.modal id="assign-server" show={@show} on_cancel="close_assign">
      <:title>Assign a server to {@app_name}</:title>

      <form id="assign-server-form" phx-submit="assign_server" class="space-y-3">
        <div :if={@servers != []}>
          <label class="mb-1 block text-[12px] font-medium text-paper-600 dark:text-ink-200">Server</label>
          <select name="server_id" class="select select-bordered w-full">
            <option value="">Choose a server…</option>
            <option :for={server <- @servers} value={server.id}>{server.name} · {server.host}</option>
          </select>
        </div>
        <p :if={@servers == []} class="text-sm text-rust-700 dark:text-rust-300">
          No eligible servers. Every application-role host is already assigned.
        </p>
        <p :if={@error} class="text-xs text-rust-700 dark:text-rust-300">{@error}</p>

        <div class="modal-action">
          <button type="button" class="btn btn-sm" phx-click="close_assign">Cancel</button>
          <button type="submit" class="btn btn-sm btn-primary" disabled={@servers == []}>Assign</button>
        </div>
      </form>
    </.modal>
    """
  end

  @doc "The unassign-server confirmation dialog."
  attr :target, :any, default: nil
  attr :error, :string, default: nil

  def unassign_dialog(assigns) do
    ~H"""
    <.modal id="unassign-server" show={@target != nil} on_cancel="close_unassign">
      <:title>Unassign {@target && @target.name}?</:title>

      <p class="text-sm">
        The agent on this host stops receiving deploy steps for this application. Existing processes
        keep running until the next deploy or rollback.
      </p>
      <p :if={@error} class="mt-3 text-sm text-rust-700 dark:text-rust-300">{@error}</p>

      <div class="modal-action">
        <button type="button" class="btn btn-sm" phx-click="close_unassign">Cancel</button>
        <button type="button" class="btn btn-sm btn-error" phx-click="unassign_server">Unassign</button>
      </div>
    </.modal>
    """
  end

  @doc "The edit-configuration dialog — name and type are immutable; everything else can change."
  attr :show, :boolean, required: true
  attr :app, :map, required: true
  attr :error, :string, default: nil

  def app_edit_dialog(assigns) do
    ~H"""
    <.modal id="edit-config" show={@show} on_cancel="close_config">
      <:title>Edit {@app.name}</:title>

      <form id="edit-config-form" phx-submit="save_config" class="space-y-3">
        <p class="text-[12.5px] text-paper-500 dark:text-ink-300">
          Name and type are immutable. Everything below can change without recreating the app.
        </p>

        <label class="block">
          <span class="mb-1 block text-[12px] font-medium text-paper-600 dark:text-ink-200">Domain</span>
          <input name="domain" value={@app.domain} class="input input-bordered w-full" />
        </label>

        <label class="block">
          <span class="mb-1 block text-[12px] font-medium text-paper-600 dark:text-ink-200">
            Path prefix (optional)
          </span>
          <input name="path_prefix" value={@app.path_prefix} class="input input-bordered w-full" />
        </label>

        <label :if={@app.type != :static_site} class="block">
          <span class="mb-1 block text-[12px] font-medium text-paper-600 dark:text-ink-200">Exec command</span>
          <input name="exec_command" value={@app.exec_command} class="input input-bordered w-full" />
        </label>

        <label :if={@app.type != :static_site} class="block">
          <span class="mb-1 block text-[12px] font-medium text-paper-600 dark:text-ink-200">Exec start pre (optional)</span>
          <input name="exec_start_pre" value={@app.exec_start_pre} class="input input-bordered w-full" />
        </label>

        <label :if={@app.type != :static_site} class="block">
          <span class="mb-1 block text-[12px] font-medium text-paper-600 dark:text-ink-200">Exec stop (optional)</span>
          <input name="exec_stop" value={@app.exec_stop} class="input input-bordered w-full" />
        </label>

        <div class="grid grid-cols-2 gap-3">
          <label class="block">
            <span class="mb-1 block text-[12px] font-medium text-paper-600 dark:text-ink-200">Min healthy</span>
            <input
              name="min_healthy"
              type="number"
              min="1"
              value={@app.min_healthy}
              class="input input-bordered w-full"
            />
          </label>
          <label class="block">
            <span class="mb-1 block text-[12px] font-medium text-paper-600 dark:text-ink-200">Artifact source</span>
            <select name="artifact_type" class="select select-bordered w-full">
              <option value="unauthenticated_url" selected={@app.artifact_source.type == :unauthenticated_url}>
                Public URL
              </option>
              <option value="local_file" selected={@app.artifact_source.type == :local_file}>
                Local file
              </option>
            </select>
          </label>
        </div>

        <fieldset :if={@app.type != :static_site} class="well-surface rounded-lg p-3">
          <p class="mb-2 text-[13px] font-semibold text-paper-800 dark:text-ink-50">Health check</p>
          <div class="space-y-2">
            <input
              name="hc_path"
              value={@app.health_check && @app.health_check.path}
              placeholder="/health"
              class="input input-bordered w-full"
            />
            <div class="grid grid-cols-2 gap-3">
              <input
                name="hc_interval"
                type="number"
                min="1"
                value={@app.health_check && @app.health_check.interval_ms}
                class="input input-bordered w-full"
              />
              <input
                name="hc_deadline"
                type="number"
                min="1"
                value={@app.health_check && @app.health_check.deadline_ms}
                class="input input-bordered w-full"
              />
            </div>
          </div>
        </fieldset>

        <p :if={@error} class="text-xs text-rust-700 dark:text-rust-300">{@error}</p>

        <div class="modal-action">
          <button type="button" class="btn btn-sm" phx-click="close_config">Cancel</button>
          <button type="submit" class="btn btn-sm btn-primary">Save</button>
        </div>
      </form>
    </.modal>
    """
  end

  @doc """
  The key/value env-var row list shared by the create and edit dialogs. Keys
  are normalized to uppercase-with-underscores as you type. Requires
  `add_env_row` and `remove_env_row` handlers on the LiveView.
  """
  attr :rows, :list, required: true

  def env_var_rows(assigns) do
    ~H"""
    <div :if={@rows != []} class="space-y-2">
      <div
        :for={{row, index} <- Enum.with_index(@rows)}
        class="grid grid-cols-[1fr_1.4fr_auto] items-center gap-2"
      >
        <input
          id={"env-key-#{index}"}
          name={"env[#{index}][key]"}
          value={row.key}
          placeholder="KEY"
          phx-hook="EnvKey"
          class="input input-bordered input-sm w-full font-mono"
        />
        <input
          name={"env[#{index}][value]"}
          value={row.value}
          placeholder="value"
          class="input input-bordered input-sm w-full font-mono"
        />
        <button
          type="button"
          class="btn btn-ghost btn-sm"
          phx-click="remove_env_row"
          phx-value-index={index}
          aria-label="Remove row"
        >
          ×
        </button>
      </div>
    </div>
    <p :if={@rows == []} class="text-[13px] text-paper-500 italic dark:text-ink-300">
      No variables. Add one below.
    </p>

    <button type="button" class="btn btn-ghost btn-sm" phx-click="add_env_row">
      + Add variable
    </button>
    """
  end

  @doc "The environment-variables editor — a key/value row list. Saving replaces the whole set."
  attr :show, :boolean, required: true
  attr :app_name, :string, required: true
  attr :rows, :list, required: true
  attr :error, :string, default: nil

  def app_env_dialog(assigns) do
    ~H"""
    <.modal id="edit-env" show={@show} on_cancel="close_env">
      <:title>Environment for {@app_name}</:title>

      <form id="edit-env-form" phx-change="validate_env" phx-submit="save_env" class="space-y-3">
        <p class="text-[12.5px] text-paper-500 dark:text-ink-300">
          Saving replaces the whole set — remove every row to clear all variables.
        </p>

        <.env_var_rows rows={@rows} />

        <p :if={@error} class="text-xs text-rust-700 dark:text-rust-300">{@error}</p>

        <div class="modal-action">
          <button type="button" class="btn btn-sm" phx-click="close_env">Cancel</button>
          <button type="submit" class="btn btn-sm btn-primary">Save</button>
        </div>
      </form>
    </.modal>
    """
  end

  @doc "The hook create/edit dialog. `editing` is nil for create, or the hook being edited."
  attr :show, :boolean, required: true
  attr :editing, :any, default: nil
  attr :form, :any, required: true
  attr :event, :string, default: nil
  attr :available_events, :list, required: true
  attr :error, :string, default: nil

  def hook_dialog(assigns) do
    ~H"""
    <.modal id="hook-form" show={@show} on_cancel="close_hook">
      <:title>{if @editing, do: "Edit #{humanize_event(@editing.event)} hook", else: "Add a lifecycle hook"}</:title>

      <.form for={@form} id="hook-form-form" phx-submit="save_hook" class="space-y-3">
        <p class="text-[12.5px] text-paper-500 dark:text-ink-300">
          Hooks run on every host, scoped to a deploy or rollback step. A non-zero exit fails it.
        </p>

        <div>
          <label class="mb-1 block text-[12px] font-medium text-paper-600 dark:text-ink-200">Event</label>
          <div :if={@editing} class="text-sm">
            <span class="font-medium">{humanize_event(@editing.event)}</span>
            <span class="text-paper-400 italic dark:text-ink-500">(immutable after create)</span>
          </div>
          <div :if={!@editing} class="flex flex-wrap gap-1">
            <button
              :for={event <- @available_events}
              type="button"
              phx-click="select_hook_event"
              phx-value-event={event}
              class={["btn btn-xs", if(event == @event, do: "btn-neutral", else: "btn-ghost")]}
            >
              {humanize_event(event)}
            </button>
          </div>
          <p :if={!@editing and @available_events == []} class="text-[12px] text-paper-400 italic dark:text-ink-500">
            Every event already has a hook. Edit an existing one instead.
          </p>
        </div>

        <.input field={@form[:script]} type="textarea" label="Script" />
        <.input field={@form[:timeout_ms]} type="number" label="Timeout (ms)" />

        <p :if={@error} class="text-xs text-rust-700 dark:text-rust-300">{@error}</p>

        <div class="modal-action">
          <button type="button" class="btn btn-sm" phx-click="close_hook">Cancel</button>
          <button
            type="submit"
            class="btn btn-sm btn-primary"
            disabled={!@editing and @available_events == []}
          >
            {if @editing, do: "Save", else: "Add hook"}
          </button>
        </div>
      </.form>
    </.modal>
    """
  end

  @doc "The delete-hook confirmation dialog."
  attr :target, :any, default: nil
  attr :error, :string, default: nil

  def hook_delete_dialog(assigns) do
    ~H"""
    <.modal id="delete-hook" show={@target != nil} on_cancel="close_hook_delete">
      <:title>Delete {@target && humanize_event(@target.event)} hook?</:title>

      <p class="text-sm">
        The hook script is removed from this application. Future deploys and rollbacks won't run it.
      </p>
      <p :if={@error} class="mt-3 text-sm text-rust-700 dark:text-rust-300">{@error}</p>

      <div class="modal-action">
        <button type="button" class="btn btn-sm" phx-click="close_hook_delete">Cancel</button>
        <button type="button" class="btn btn-sm btn-error" phx-click="delete_hook">Delete</button>
      </div>
    </.modal>
    """
  end

  @doc "The deploy dialog — version, artifact URL, and an optional source ref."
  attr :show, :boolean, required: true
  attr :app_name, :string, required: true
  attr :form, :any, required: true
  attr :error, :string, default: nil

  def deploy_dialog(assigns) do
    ~H"""
    <.modal id="deploy" show={@show} on_cancel="close_deploy">
      <:title>Deploy {@app_name}</:title>

      <.form for={@form} id="deploy-form" phx-submit="deploy" class="space-y-3">
        <p class="text-[12.5px] text-paper-500 dark:text-ink-300">Triggers a rolling deploy across this application's hosts.</p>
        <.input field={@form[:version]} label="Version" placeholder="v143 or 0.0.42" />
        <.input field={@form[:artifact_url]} label="Artifact URL" placeholder="https://…/release.tar.gz" />
        <.input field={@form[:source]} label="Source (optional)" placeholder="git:main@abc1234" />
        <p :if={@error} class="text-xs text-rust-700 dark:text-rust-300">{@error}</p>

        <div class="modal-action">
          <button type="button" class="btn btn-sm" phx-click="close_deploy">Cancel</button>
          <button type="submit" class="btn btn-sm btn-primary">Start deploy</button>
        </div>
      </.form>
    </.modal>
    """
  end

  @doc "The rollback confirmation dialog."
  attr :show, :boolean, required: true
  attr :app_name, :string, required: true
  attr :version, :string, required: true
  attr :error, :string, default: nil

  def rollback_dialog(assigns) do
    ~H"""
    <.modal id="rollback" show={@show} on_cancel="close_rollback">
      <:title>Roll back {@app_name}?</:title>

      <p class="text-sm">
        The previous successful version is redeployed across this app's hosts. In-flight requests
        are allowed to finish.
      </p>
      <p class="mt-2 text-sm">Current version: <.chip>{@version}</.chip></p>
      <p :if={@error} class="mt-3 text-sm text-rust-700 dark:text-rust-300">{@error}</p>

      <div class="modal-action">
        <button type="button" class="btn btn-sm" phx-click="close_rollback">Cancel</button>
        <button type="button" class="btn btn-sm btn-warning" phx-click="rollback">Roll back</button>
      </div>
    </.modal>
    """
  end

  @doc "The restart confirmation dialog."
  attr :show, :boolean, required: true
  attr :app_name, :string, required: true
  attr :version, :string, required: true
  attr :error, :string, default: nil

  def restart_dialog(assigns) do
    ~H"""
    <.modal id="restart" show={@show} on_cancel="close_restart">
      <:title>Restart {@app_name}?</:title>

      <p class="text-sm">
        The current version is re-booted into the standby slot and health-checked before traffic
        moves — applying any changed environment variables or secrets. If the new boot fails its
        health check, traffic stays on the running instance.
      </p>
      <p class="mt-2 text-sm">Current version: <.chip>{@version}</.chip></p>
      <p :if={@error} class="mt-3 text-sm text-rust-700 dark:text-rust-300">{@error}</p>

      <div class="modal-action">
        <button type="button" class="btn btn-sm" phx-click="close_restart">Cancel</button>
        <button type="button" class="btn btn-sm btn-primary" phx-click="restart">Restart</button>
      </div>
    </.modal>
    """
  end

  @doc "The enter-maintenance dialog with an optional message."
  attr :show, :boolean, required: true
  attr :app_name, :string, required: true
  attr :message, :string, default: nil
  attr :error, :string, default: nil

  def maintenance_dialog(assigns) do
    ~H"""
    <.modal id="maintenance" show={@show} on_cancel="close_maintenance">
      <:title>Put {@app_name} into maintenance?</:title>

      <form phx-submit="enter_maintenance" class="space-y-3">
        <p class="text-[12.5px] text-paper-500 dark:text-ink-300">
          Visitors get a 503 page on this app's domain until you exit maintenance. Deploys still work.
        </p>
        <label class="block">
          <span class="text-[12px] text-paper-500 dark:text-ink-300">Message (optional)</span>
          <textarea
            name="message"
            rows="3"
            class="textarea textarea-bordered mt-1 w-full text-[13px]"
            placeholder="Back at 5pm UTC"
          ><%= @message %></textarea>
        </label>
        <p :if={@error} class="text-xs text-rust-700 dark:text-rust-300">{@error}</p>

        <div class="modal-action">
          <button type="button" class="btn btn-sm" phx-click="close_maintenance">Cancel</button>
          <button type="submit" class="btn btn-sm btn-primary">Enter maintenance</button>
        </div>
      </form>
    </.modal>
    """
  end
end
