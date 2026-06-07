defmodule StillWeb.RouteComponents do
  @moduledoc """
  Presentation for the routing registry — one card per application listing the
  upstream host:port dials an external load balancer needs.
  """

  use StillWeb, :html

  import StillWeb.ApplicationComponents, only: [application_display: 1]

  @doc "The routing registry: one card per application, or an empty notice."
  attr :routes, :list, required: true

  def routes_list(assigns) do
    ~H"""
    <div :if={@routes != []} class="space-y-3">
      <article :for={route <- @routes} class="card-surface overflow-hidden rounded-2xl">
        <header class="hairline flex flex-wrap items-center justify-between gap-2 border-b bg-paper-100/60 px-5 py-3 dark:bg-ink-700/40">
          <div class="flex flex-wrap items-center gap-2">
            <.link
              navigate={~p"/applications/#{route.name}"}
              class="font-mono font-medium text-paper-900 hover:underline dark:text-ink-50"
            >
              {route.name}
            </.link>
            <.application_display type={route.type} />
          </div>
          <div class="font-mono text-[12.5px] text-paper-500 dark:text-ink-300">
            {route.domain}<span :if={route.path_prefix}>{route.path_prefix}</span>
          </div>
        </header>

        <ul class="divide-y divide-paper-200 dark:divide-ink-700">
          <li
            :for={upstream <- route.upstreams}
            class="flex items-center justify-between gap-4 px-5 py-3"
          >
            <.link
              navigate={~p"/servers/#{upstream.server_id}"}
              class="font-mono text-[13px] text-paper-800 hover:underline dark:text-ink-50"
            >
              {upstream.server_name}
            </.link>
            <code class="hairline select-all rounded border bg-paper-100 px-2 py-0.5 font-mono text-[12px] text-paper-700 dark:bg-ink-900 dark:text-ink-100">
              {upstream.dial}
            </code>
          </li>
        </ul>
      </article>
    </div>

    <p
      :if={@routes == []}
      class="card-surface rounded-2xl px-5 py-6 text-center text-[13px] text-paper-500 dark:text-ink-300"
    >
      No routes yet. Create an application and assign servers to populate this view.
    </p>
    """
  end
end
