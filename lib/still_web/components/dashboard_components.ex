defmodule StillWeb.DashboardComponents do
  @moduledoc """
  Display primitives shared across the dashboard LiveViews. Form, table,
  and button components live in `StillWeb.CoreComponents`.
  """

  use Phoenix.Component
  use StillWeb, :verified_routes

  import StillWeb.CoreComponents, only: [icon: 1]

  @doc """
  A small colored dot signalling a connection or health status, with an
  optional text label. Recognised statuses map to semantic colors;
  anything else renders neutral.

  ## Examples

      <.status_dot status={:connected} />
      <.status_dot status="healthy" label="Healthy" />
  """
  attr :status, :any, required: true, doc: "a tone (:healthy/:warn/:danger/:info/:neutral)"
  attr :label, :string, default: nil, doc: "optional text rendered beside the dot"
  attr :rest, :global

  def status_dot(assigns) do
    assigns = assign(assigns, :color, status_color(assigns.status))

    ~H"""
    <span class="inline-flex items-center gap-1.5" {@rest}>
      <span class={["inline-block size-2 rounded-full", @color]} aria-hidden="true"></span>
      <span :if={@label} class="text-sm">{@label}</span>
    </span>
    """
  end

  # Maps both the dashboard's tone vocabulary (healthy/warn/danger/info/neutral)
  # and the domain words callers pass directly onto daisyUI semantic colors.
  defp status_color(status) do
    case status |> to_string() |> String.downcase() do
      s when s in ~w(connected healthy up running active ok) -> "bg-success"
      s when s in ~w(disconnected unhealthy down failed error danger stopped) -> "bg-error"
      s when s in ~w(degraded pending starting deploying warn) -> "bg-warning"
      "info" -> "bg-info"
      "plum" -> "bg-plum-500"
      _ -> "bg-paper-400 dark:bg-ink-400"
    end
  end

  @doc """
  A horizontal utilization bar (value is a percentage, 0–100), colored by
  threshold: green under 70%, amber under 90%, red at or above.

  ## Examples

      <.meter value={42.5} />
  """
  attr :value, :any, required: true, doc: "utilization percentage, 0–100"
  attr :rest, :global

  def meter(assigns) do
    ~H"""
    <div class="h-1.5 w-full overflow-hidden rounded-full bg-paper-200 dark:bg-ink-700" {@rest}>
      <div class={["h-full rounded-full", meter_color(@value)]} style={"width: #{@value}%"}></div>
    </div>
    """
  end

  defp meter_color(value) when value >= 90, do: "bg-error"
  defp meter_color(value) when value >= 70, do: "bg-warning"
  defp meter_color(_value), do: "bg-success"

  @doc """
  Renders a `meter` for a utilization value, or an em dash when the value is
  absent (a disconnected host, or no sample yet).

  ## Examples

      <.metric_bar value={42} />
      <.metric_bar value={nil} />
  """
  attr :value, :any, required: true, doc: "a percentage, or nil"

  def metric_bar(assigns) do
    ~H"""
    <.meter :if={@value} value={@value} />
    <span :if={is_nil(@value)} class="opacity-50">—</span>
    """
  end

  @doc """
  Formats a UTC timestamp as a short relative string ("just now", "5s ago",
  "3m ago", "2h ago", "4d ago"), falling back to a "Mon D" date past a week.
  `nil` renders as an em dash.
  """
  def relative_time(nil), do: "—"

  def relative_time(%DateTime{} = at) do
    seconds = max(0, DateTime.diff(DateTime.utc_now(), at, :second))
    minutes = round(seconds / 60)
    hours = round(minutes / 60)
    days = round(hours / 24)

    cond do
      seconds < 5 -> "just now"
      seconds < 60 -> "#{seconds}s ago"
      minutes < 60 -> "#{minutes}m ago"
      hours < 24 -> "#{hours}h ago"
      days <= 7 -> "#{days}d ago"
      true -> Calendar.strftime(at, "%b ") <> Integer.to_string(at.day)
    end
  end

  @doc """
  An inline SVG sparkline for a numeric series. A single point draws a flat
  midline; an empty series draws an empty path.

  ## Examples

      <.sparkline points={[1, 4, 2, 8, 5]} />
  """
  attr :points, :list, required: true, doc: "the numeric series"
  attr :width, :integer, default: 120
  attr :height, :integer, default: 20
  attr :stroke_width, :any, default: 1.25

  def sparkline(assigns) do
    assigns =
      assign(
        assigns,
        :path,
        sparkline_path(assigns.points, assigns.width, assigns.height, assigns.stroke_width)
      )

    ~H"""
    <svg
      width="100%"
      height={@height}
      viewBox={"0 0 #{@width} #{@height}"}
      preserveAspectRatio="none"
      fill="none"
      aria-hidden="true"
      class="block w-full overflow-visible"
    >
      <path
        d={@path}
        stroke="currentColor"
        stroke-width={@stroke_width}
        stroke-linecap="round"
        stroke-linejoin="round"
        vector-effect="non-scaling-stroke"
      />
    </svg>
    """
  end

  defp sparkline_path([], _width, _height, _stroke_width), do: ""

  defp sparkline_path([_one], width, height, _stroke_width) do
    y = coord(height / 2)
    "M 0 #{y} L #{coord(width)} #{y}"
  end

  defp sparkline_path(points, width, height, stroke_width) do
    min = Enum.min(points)
    range = max(Enum.max(points) - min, 1)
    avail_y = height - stroke_width * 2
    step_x = width / (length(points) - 1)

    points
    |> Enum.with_index()
    |> Enum.map_join(" ", fn {v, i} ->
      x = i * step_x
      y = stroke_width + avail_y - (v - min) / range * avail_y
      "#{if i == 0, do: "M", else: "L"} #{coord(x)} #{coord(y)}"
    end)
  end

  defp coord(n), do: :erlang.float_to_binary(n * 1.0, decimals: 2)

  @doc "An inline label chip — e.g. a version or slot tag."
  slot :inner_block, required: true

  def chip(assigns) do
    ~H"""
    <span class="mono inline-flex items-center gap-1 rounded-sm bg-paper-200 px-1.5 py-px text-[11.5px] font-medium tracking-[-0.005em] text-paper-700 dark:bg-ink-600 dark:text-ink-100">
      {render_slot(@inner_block)}
    </span>
    """
  end

  @doc """
  A bordered content panel with an optional header (title / subtitle / actions).

  ## Examples

      <.panel>
        <:title>Profile</:title>
        <:subtitle>Your info on this instance.</:subtitle>
        <:actions><.button>Edit</.button></:actions>
        body
      </.panel>
  """
  attr :class, :string, default: nil
  attr :body_class, :string, default: "p-6"
  slot :title
  slot :subtitle
  slot :actions
  slot :inner_block

  def panel(assigns) do
    ~H"""
    <section class={["hairline rounded-lg border bg-paper-50 dark:bg-ink-800", @class]}>
      <div
        :if={@title != []}
        class={[
          "hairline flex items-start justify-between gap-4 px-6 py-4",
          @inner_block != [] && "border-b"
        ]}
      >
        <div>
          <div class="text-[13px] font-medium text-paper-800 dark:text-ink-50">
            {render_slot(@title)}
          </div>
          <div :if={@subtitle != []} class="mt-0.5 text-[11.5px] text-paper-500 dark:text-ink-300">
            {render_slot(@subtitle)}
          </div>
        </div>
        <div :if={@actions != []} class="flex shrink-0 items-center gap-2">
          {render_slot(@actions)}
        </div>
      </div>
      <div :if={@inner_block != []} class={["text-[13px] text-paper-700 dark:text-ink-100", @body_class]}>
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end

  @doc """
  A section heading — an uppercase label with an optional right-aligned action.

  ## Examples

      <.section_heading>Fleet<:actions><.button>Assign</.button></:actions></.section_heading>
  """
  attr :class, :string, default: nil
  slot :actions
  slot :inner_block, required: true

  def section_heading(assigns) do
    ~H"""
    <div class={["mb-2 flex items-center justify-between gap-3", @class]}>
      <h2 class="text-[11px] font-medium tracking-[0.08em] text-paper-500 uppercase dark:text-ink-300">
        {render_slot(@inner_block)}
      </h2>
      <div :if={@actions != []} class="flex items-center gap-2">{render_slot(@actions)}</div>
    </div>
    """
  end

  @doc "A bordered stat tile — an uppercase label over a value (a number, status, etc.)."
  attr :label, :string, required: true
  slot :inner_block, required: true

  def stat_card(assigns) do
    ~H"""
    <div class="hairline rounded-lg border bg-paper-50 p-4 dark:bg-ink-800">
      <div class="text-[11px] font-medium tracking-[0.06em] text-paper-500 uppercase dark:text-ink-300">
        {@label}
      </div>
      <div class="mt-1">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  @doc """
  An inline text link with a trailing arrow, for "see all" / cross-section
  navigation. Resets inherited case/tracking/weight so it reads identically
  regardless of the heading it sits in.

  ## Examples

      <.arrow_link navigate={~p"/events"}>View all</.arrow_link>
  """
  attr :navigate, :string, required: true
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def arrow_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class={[
        "inline-flex items-center gap-1 text-[12px] font-normal tracking-normal normal-case",
        "text-paper-500 transition-colors hover:text-paper-700 dark:text-ink-300 dark:hover:text-ink-100",
        @class
      ]}
    >
      {render_slot(@inner_block)} <.icon name="hero-arrow-right-micro" class="size-3.5" />
    </.link>
    """
  end

  @doc """
  A sidebar navigation link with a leading icon, highlighted when active.

  ## Examples

      <.nav_link navigate={~p"/"} icon="hero-squares-2x2" label="Dashboard" active />
  """
  attr :navigate, :string, required: true, doc: "the route to navigate to"
  attr :icon, :string, required: true, doc: "a hero-* icon name"
  attr :label, :string, required: true, doc: "the visible link text"
  attr :active, :boolean, default: false, doc: "whether this links to the current page"
  attr :count, :integer, default: nil, doc: "optional right-aligned count"

  def nav_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class={[
        "flex items-center gap-2.5 rounded-[5px] px-2.5 py-1.5 text-[13px] transition-colors",
        @active && "bg-paper-100 font-medium text-paper-900 dark:bg-ink-700 dark:text-ink-50",
        !@active &&
          "text-paper-600 hover:bg-paper-100/60 dark:text-ink-200 dark:hover:bg-ink-700/60"
      ]}
    >
      <.icon name={@icon} class="size-4 shrink-0 opacity-80" />
      <span class="hidden truncate md:inline">{@label}</span>
      <span
        :if={@count != nil}
        class="mono ml-auto hidden text-[10.5px] text-paper-500 md:inline dark:text-ink-300"
      >
        {@count}
      </span>
    </.link>
    """
  end

  @doc """
  Maps a raw fleet event into the per-row activity shape every activity surface
  uses — `%{id, at, status, label, text, link_to}` — or `nil` for events we
  drop (per-step deployment pings, too chatty for an aggregated feed).
  `server_names` resolves server uuids to names for connect/disconnect rows.
  """
  def event_activity(%{type: :deployment_updated, payload: payload} = event, _server_names) do
    if step_ping?(payload) do
      nil
    else
      status = payload[:status]

      %{
        id: event.id,
        at: event.at,
        status: deploy_status(status),
        label: deploy_label(status),
        text: deploy_text(payload[:application_name] || payload[:application], status),
        link_to: deployment_link(payload[:deployment_id])
      }
    end
  end

  def event_activity(%{type: :health_transition, payload: payload} = event, _server_names) do
    app = payload[:application_name] || payload[:application]

    %{
      id: event.id,
      at: event.at,
      status: health_status(payload[:to]),
      label: health_label(payload[:to]),
      text: health_text(app, payload[:from], payload[:to]),
      link_to: app && ~p"/applications/#{app}"
    }
  end

  def event_activity(%{type: type, payload: payload} = event, server_names)
      when type in [:server_connected, :server_disconnected] do
    server_id = payload[:server_id]
    name = server_id && Map.get(server_names, server_id)
    up = type == :server_connected

    %{
      id: event.id,
      at: event.at,
      status: if(up, do: :healthy, else: :danger),
      label: if(up, do: "online", else: "offline"),
      text: "#{name || server_prefix(server_id)} #{if up, do: "connected", else: "disconnected"}",
      link_to: name && ~p"/servers/#{server_id}"
    }
  end

  def event_activity(_event, _server_names), do: nil

  # Per-step pings carry step_status but no top-level status; the aggregated
  # feed shows deployment-level transitions only.
  defp step_ping?(payload), do: payload[:step_status] != nil and payload[:status] == nil

  defp deploy_status(status) do
    case to_string(status) do
      "completed" -> :healthy
      "failed" -> :danger
      "rolled_back" -> :warn
      _ -> :info
    end
  end

  defp deploy_label(status) do
    case to_string(status) do
      "completed" -> "ok"
      "failed" -> "failed"
      "rolled_back" -> "rollback"
      _ -> "deploy"
    end
  end

  defp deploy_text(nil, status), do: "deploy #{status_word(status)}"
  defp deploy_text(app, status), do: "#{app} deploy #{status_word(status)}"

  defp status_word(nil), do: "updated"
  defp status_word(status), do: to_string(status)

  defp health_status(to) do
    case to_string(to) do
      "healthy" -> :healthy
      "degraded" -> :warn
      "unhealthy" -> :danger
      _ -> :neutral
    end
  end

  defp health_label(to) do
    label = norm(to)
    if label == "healthy", do: "healthy", else: label
  end

  defp health_text(nil, from, to), do: "health #{norm(from)} → #{norm(to)}"
  defp health_text(app, from, to), do: "#{app} health #{norm(from)} → #{norm(to)}"

  defp norm(value), do: to_string(value || "?")

  defp deployment_link(nil), do: nil
  defp deployment_link(id), do: ~p"/deployments/#{id}"

  defp server_prefix(nil), do: "server"
  defp server_prefix(id), do: String.slice(id, 0, 8)

  @doc """
  Renders the recent-activity stream — one row per derived activity (relative
  time, status dot, label, text, and an optional deep link). Falls back to an
  empty notice.

  ## Examples

      <.activity_feed activities={@activity} />
  """
  attr :activities, :list, required: true, doc: "derived activity maps, newest first"
  attr :empty, :string, default: "No activity yet.", doc: "shown when there are none"

  def activity_feed(assigns) do
    ~H"""
    <div :if={@activities != []} class="hairline overflow-hidden rounded-lg border">
      <div
        :for={activity <- @activities}
        id={"event-#{activity.id}"}
        class="hairline flex items-center gap-4 border-b px-5 py-3 text-[13px] last:border-b-0"
      >
        <span class="w-16 shrink-0 font-mono text-[11px] text-paper-500 dark:text-ink-300">
          {relative_time(activity.at)}
        </span>
        <div class="flex shrink-0 items-center gap-2">
          <.status_dot status={activity.status} />
          <span class="w-16 text-[11px] text-paper-500 dark:text-ink-300">{activity.label}</span>
        </div>
        <div class="min-w-0 flex-1 truncate text-paper-700 dark:text-ink-100">{activity.text}</div>
        <.link
          :if={activity.link_to}
          navigate={activity.link_to}
          class="shrink-0 text-[11px] text-paper-500 transition-colors hover:text-paper-800 dark:text-ink-300 dark:hover:text-ink-50"
        >
          open →
        </.link>
      </div>
    </div>
    <p :if={@activities == []} class="text-[13px] text-paper-500 dark:text-ink-300">{@empty}</p>
    """
  end

  @doc """
  A centered modal dialog, rendered only while `show` is true. `on_cancel` is
  the event the close button, the backdrop, and the Escape key fire.

  ## Examples

      <.modal id="confirm" show={@open} on_cancel="close">
        <:title>Are you sure?</:title>
        <p>This can't be undone.</p>
      </.modal>
  """
  attr :id, :string, required: true
  attr :show, :boolean, default: false
  attr :on_cancel, :string, default: nil, doc: "phx-click event that closes the modal"
  slot :title
  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <div
      :if={@show}
      id={@id}
      class="modal modal-open"
      role="dialog"
      aria-modal="true"
      phx-window-keydown={@on_cancel}
      phx-key="escape"
    >
      <div class="modal-box hairline border p-0 shadow-2xl">
        <div
          :if={@title != []}
          class="hairline flex items-center justify-between gap-4 border-b px-5 py-4"
        >
          <h3 class="text-[14px] font-medium text-paper-800 dark:text-ink-50">
            {render_slot(@title)}
          </h3>
          <button
            :if={@on_cancel}
            type="button"
            class="-mr-1 rounded p-1 text-paper-500 transition-colors hover:bg-paper-100 hover:text-paper-800 dark:text-ink-300 dark:hover:bg-ink-700 dark:hover:text-ink-50"
            phx-click={@on_cancel}
            aria-label="Close"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>
        <div class="px-5 py-4 text-[13px] text-paper-700 dark:text-ink-100">
          {render_slot(@inner_block)}
        </div>
      </div>
      <button
        :if={@on_cancel}
        type="button"
        class="modal-backdrop"
        phx-click={@on_cancel}
        aria-label="Close"
      />
    </div>
    """
  end
end
