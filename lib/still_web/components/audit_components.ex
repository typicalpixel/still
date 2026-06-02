defmodule StillWeb.AuditComponents do
  @moduledoc """
  Presentation for the durable audit log — an expandable row per event with the
  actor, type, subject, and (on expand) the before/after/payload detail. Shared
  by the settings page and the per-resource detail views.
  """

  use StillWeb, :html

  @doc "Status-dot tone for an audit actor kind."
  def actor_dot(:user), do: :info
  def actor_dot(:anonymous), do: :warn
  def actor_dot(_kind), do: :neutral

  @doc "Humanizes an audit type atom-string — underscores become spaces."
  def humanize_audit_type(type) when is_binary(type), do: String.replace(type, "_", " ")

  @doc """
  The audit log: a list of events, each expandable to its detail. `expanded` is
  a `MapSet` of event ids; rows toggle via the `toggle_audit` event. Hide the
  subject column on scoped logs with `show_subject={false}`.
  """
  attr :events, :list, required: true
  attr :expanded, :any, required: true
  attr :show_subject, :boolean, default: true
  attr :empty, :string, default: "No audit events."

  def audit_log(assigns) do
    ~H"""
    <div class="hairline overflow-hidden rounded-lg border">
      <div :for={event <- @events} class="hairline border-b last:border-b-0">
        <button
          type="button"
          disabled={!has_detail?(event)}
          class={[
            "flex w-full items-center gap-4 px-5 py-3 text-left text-[13px]",
            has_detail?(event) && "hover:bg-paper-100/40 dark:hover:bg-ink-700/20"
          ]}
          phx-click={has_detail?(event) && "toggle_audit"}
          phx-value-id={event.id}
        >
          <span class="w-16 shrink-0 font-mono text-[11px] text-paper-500 dark:text-ink-300">
            {relative_time(event.inserted_at)}
          </span>
          <span class="flex shrink-0 items-center gap-2">
            <.status_dot status={actor_dot(event.actor_kind)} />
            <span class="w-32 truncate font-mono text-[11px] text-paper-600 dark:text-ink-200">
              {event.actor_label}
            </span>
          </span>
          <span class="min-w-0 flex-1"><.chip>{humanize_audit_type(event.type)}</.chip></span>
          <span
            :if={@show_subject}
            class="shrink-0 font-mono text-[11px] text-paper-500 dark:text-ink-300"
          >
            {subject_label(event)}
          </span>
          <span
            :if={has_detail?(event)}
            class="w-4 shrink-0 text-right font-mono text-[11px] text-paper-400 dark:text-ink-500"
          >
            {if MapSet.member?(@expanded, event.id), do: "▾", else: "▸"}
          </span>
        </button>

        <div
          :if={MapSet.member?(@expanded, event.id) and has_detail?(event)}
          class="hairline border-t bg-paper-100/40 px-5 py-3 dark:bg-ink-700/20"
        >
          <dl class="grid grid-cols-[100px_1fr] gap-x-4 gap-y-2 text-[12px]">
            <%= if event.ip do %>
              <dt class="text-paper-500 dark:text-ink-300">IP</dt>
              <dd class="font-mono text-paper-800 dark:text-ink-50">{event.ip}</dd>
            <% end %>
            <%= if event.user_agent do %>
              <dt class="text-paper-500 dark:text-ink-300">UA</dt>
              <dd class="truncate font-mono text-paper-800 dark:text-ink-50" title={event.user_agent}>
                {event.user_agent}
              </dd>
            <% end %>
            <%= if event.before do %>
              <dt class="text-paper-500 dark:text-ink-300">Before</dt>
              <dd><pre class="hairline overflow-auto rounded-md border bg-paper-50 p-2 font-mono text-[12px] text-paper-700 dark:bg-ink-900 dark:text-ink-100">{json_preview(event.before)}</pre></dd>
            <% end %>
            <%= if event.after do %>
              <dt class="text-paper-500 dark:text-ink-300">After</dt>
              <dd><pre class="hairline overflow-auto rounded-md border bg-paper-50 p-2 font-mono text-[12px] text-paper-700 dark:bg-ink-900 dark:text-ink-100">{json_preview(event.after)}</pre></dd>
            <% end %>
            <%= if map_size(event.payload || %{}) > 0 do %>
              <dt class="text-paper-500 dark:text-ink-300">Payload</dt>
              <dd><pre class="hairline overflow-auto rounded-md border bg-paper-50 p-2 font-mono text-[12px] text-paper-700 dark:bg-ink-900 dark:text-ink-100">{json_preview(event.payload)}</pre></dd>
            <% end %>
          </dl>
        </div>
      </div>

      <div :if={@events == []} class="px-5 py-6 text-center text-[13px] text-paper-500 dark:text-ink-300">
        {@empty}
      </div>
    </div>
    """
  end

  defp subject_label(%{subject_type: nil}), do: "—"
  defp subject_label(%{subject_type: type, subject_id: nil}), do: type

  defp subject_label(%{subject_type: type, subject_id: id}),
    do: "#{type} · #{String.slice(id, 0, 8)}"

  defp has_detail?(event) do
    event.before != nil or event.after != nil or map_size(event.payload || %{}) > 0 or
      event.ip != nil or event.user_agent != nil
  end

  defp json_preview(value), do: Jason.encode!(value, pretty: true)
end
