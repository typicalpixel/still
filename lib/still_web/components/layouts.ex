defmodule StillWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use StillWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @nav_labels %{
    dashboard: "Dashboard",
    applications: "Applications",
    servers: "Servers",
    deployments: "Deployments",
    routes: "Routes",
    api_keys: "API keys",
    users: "Users",
    caddy: "Caddy",
    settings: "Settings",
    account: "Account"
  }

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :active_nav, :atom, default: nil, doc: "the active sidebar nav item"

  attr :breadcrumbs, :list,
    default: [],
    doc: "trail of `%{label:, navigate?:}` maps; the last entry is the current page"

  attr :nav, :map,
    default: nil,
    doc: "sidebar counts `%{apps:, servers:}`, assigned once at mount by NavAssigns"

  slot :inner_block, required: true

  def app(assigns) do
    server_count = assigns.nav[:servers]

    assigns =
      assigns
      |> assign(:app_count, assigns.nav[:apps])
      |> assign(:server_count, server_count)
      |> assign(:mode, mode_label(server_count))
      |> assign(:crumbs, crumbs(assigns))

    ~H"""
    <div class="flex min-h-screen bg-paper-50 text-paper-900 dark:bg-ink-800 dark:text-ink-50">
      <aside
        :if={@current_scope}
        class="hairline sticky top-0 z-20 flex h-screen w-14 shrink-0 flex-col border-r bg-paper-50 md:w-52 dark:bg-ink-900"
      >
        <div class="px-4 pt-5 pb-4 md:px-5">
          <.link navigate={~p"/"} class="flex items-center gap-2">
            <span class="hidden text-lg font-semibold lowercase md:inline">still</span>
          </.link>
        </div>

        <div :if={@mode} class="hidden px-3 pb-2 md:block">
          <span class="mono flex w-full items-center gap-1 rounded-sm bg-paper-200 px-1.5 py-px text-[11.5px] font-medium tracking-[-0.005em] text-paper-700 dark:bg-ink-600 dark:text-ink-100">
            <.status_dot status={if @server_count <= 1, do: :neutral, else: :plum} />
            {@mode}
          </span>
        </div>

        <nav class="flex flex-1 flex-col gap-0.5 px-2 py-2">
          <.nav_link
            navigate={~p"/"}
            icon="hero-squares-2x2"
            label="Dashboard"
            active={@active_nav == :dashboard}
          />
          <.nav_link
            navigate={~p"/applications"}
            icon="hero-cube"
            label="Applications"
            count={@app_count}
            active={@active_nav == :applications}
          />
          <.nav_link
            navigate={~p"/servers"}
            icon="hero-server-stack"
            label="Servers"
            count={@server_count}
            active={@active_nav == :servers}
          />
          <.nav_link
            navigate={~p"/deployments"}
            icon="hero-rocket-launch"
            label="Deployments"
            active={@active_nav == :deployments}
          />
          <.nav_link
            navigate={~p"/routes"}
            icon="hero-arrows-right-left"
            label="Routes"
            active={@active_nav == :routes}
          />
          <.nav_link
            navigate={~p"/api-keys"}
            icon="hero-key"
            label="API keys"
            active={@active_nav == :api_keys}
          />
          <.nav_link
            :if={Still.Accounts.Scope.can?(@current_scope, :admin)}
            navigate={~p"/users"}
            icon="hero-users"
            label="Users"
            active={@active_nav == :users}
          />
          <.nav_link
            :if={Still.Accounts.Scope.can?(@current_scope, :admin)}
            navigate={~p"/caddy"}
            icon="hero-document-magnifying-glass"
            label="Caddy"
            active={@active_nav == :caddy}
          />
          <.nav_link
            navigate={~p"/settings"}
            icon="hero-cog-6-tooth"
            label="Settings"
            active={@active_nav == :settings}
          />
        </nav>

        <div
          class="hairline relative border-t p-3"
          phx-click-away={JS.add_class("hidden", to: "#user-menu")}
        >
          <button
            type="button"
            phx-click={JS.toggle_class("hidden", to: "#user-menu")}
            aria-haspopup="true"
            class="flex w-full cursor-pointer items-center gap-2 rounded-[5px] p-1 text-left transition-colors hover:bg-paper-100 dark:hover:bg-ink-700"
          >
            <span class="flex h-7 w-7 shrink-0 items-center justify-center rounded-full bg-paper-800 text-[11.5px] font-medium text-paper-50 dark:bg-ink-100 dark:text-ink-900">
              {user_initial(@current_scope.user)}
            </span>
            <span class="hidden min-w-0 flex-1 truncate text-[12.5px] text-paper-800 md:block dark:text-ink-50">
              {user_display_name(@current_scope.user)}
            </span>
          </button>

          <div
            id="user-menu"
            role="menu"
            class="hairline absolute bottom-full left-3 z-30 mb-2 hidden w-56 overflow-hidden rounded-lg border bg-paper-50 shadow-lg dark:bg-ink-800"
          >
            <div class="hairline border-b px-3 py-2">
              <div class="truncate text-[12.5px] text-paper-800 dark:text-ink-50">
                {user_display_name(@current_scope.user)}
              </div>
              <div class="mono truncate text-[11px] text-paper-500 dark:text-ink-300">
                {@current_scope.user.email}
              </div>
            </div>
            <.link
              navigate={~p"/account"}
              role="menuitem"
              class="block px-3 py-2 text-[13px] text-paper-700 transition-colors hover:bg-paper-100 dark:text-ink-100 dark:hover:bg-ink-700"
            >
              Account
            </.link>
            <.link
              href={~p"/users/log-out"}
              method="delete"
              role="menuitem"
              class="block px-3 py-2 text-[13px] text-paper-700 transition-colors hover:bg-paper-100 dark:text-ink-100 dark:hover:bg-ink-700"
            >
              Sign out
            </.link>
          </div>
        </div>
      </aside>

      <main class="flex min-w-0 flex-1 flex-col">
        <div
          :if={@current_scope && @crumbs != []}
          class="hairline flex items-center gap-1.5 border-b px-5 py-3 md:px-7"
        >
          <span :for={{bc, i} <- Enum.with_index(@crumbs)} class="flex items-center gap-1.5">
            <span :if={i > 0} class="text-paper-400 dark:text-ink-400">/</span>
            <.link
              :if={bc[:navigate]}
              navigate={bc.navigate}
              class="text-[12.5px] text-paper-500 transition-colors hover:text-paper-700 dark:text-ink-300 dark:hover:text-ink-100"
            >
              {bc.label}
            </.link>
            <span :if={!bc[:navigate]} class="text-[12.5px] text-paper-800 dark:text-ink-50">
              {bc.label}
            </span>
          </span>
        </div>

        <div class="mx-auto w-full max-w-7xl px-5 py-6 md:px-7">
          {render_slot(@inner_block)}
        </div>
      </main>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  defp user_initial(user) do
    (user.name || user.email || "?") |> String.first() |> String.upcase()
  end

  defp user_display_name(user), do: user.name || user.email

  defp mode_label(nil), do: nil
  defp mode_label(count) when count <= 1, do: "standalone"
  defp mode_label(_count), do: "multi-node"

  defp crumbs(assigns) do
    cond do
      assigns.breadcrumbs != [] -> assigns.breadcrumbs
      assigns.active_nav -> [%{label: nav_label(assigns.active_nav)}]
      true -> []
    end
  end

  defp nav_label(nav), do: Map.get(@nav_labels, nav)

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
