defmodule Still.CaddyBootstrap do
  @moduledoc """
  Builds and reconciles the Caddy JSON config that the installer writes
  when it first provisions the local Caddy for a controller or
  standalone install.

  The installer calls `reconcile/1` via `still eval` so the JSON shape
  and the merge semantics live in one place and can be unit-tested
  without a real Caddy.

  ## Domain and TLS

  Two independent knobs:

    * `:controller_domain` — the hostname Caddy host-matches on for the
      controller route (the whole Phoenix app: dashboard at `/`, API at
      `/api`). Any shape: public DNS, Tailscale name, private DNS. When
      blank, falls back to `:fallback_host` (the installer passes the
      machine's detected address) so the controller route is always
      host-scoped — requests on any other `Host` fall through to the
      catch-all page rather than reaching the dashboard. Operators behind
      an edge that forwards a public hostname (Cloudflare, a cloud LB)
      must set this explicitly to that hostname.

    * `:fallback_host` — host used for the controller route when
      `:controller_domain` is blank. Optional; if both are blank the
      controller route matches any host (last-resort for unit tests).

    * `:tls_mode` — `:auto` or `:off` (default `:off`).
      `:auto` listens on `:80` and `:443` with Caddy's automatic HTTPS,
      which handles ACME provisioning for the controller domain and any
      per-application domain added at deploy time. `:off` listens on the
      configured `:http_port` and leaves TLS to whatever's in front
      (Cloudflare, cloud LB, private network, etc.).

  The two knobs are independent on purpose: operators using a private
  Tailscale name for the dashboard shouldn't have Caddy trying to ACME
  a domain that can't be DNS-validated. Operators behind Cloudflare
  don't want origin ACME either. The installer prompts for both
  explicitly; the code doesn't try to guess from the domain shape.

  ## Servers

  The config defines two HTTP servers. The public `still` server carries
  the system routes plus per-app routes and is the only one that ever
  participates in TLS. The internal `still_internal` server serves build
  artifacts on a loopback port and keeps automatic HTTPS disabled in
  every mode — otherwise Caddy would open a shared `:80` ACME/redirect
  listener on its behalf, binding a port the operator may have declined.
  """

  require Logger

  alias Still.Agent.CaddyManager
  alias Still.Caddy.Config, as: CaddyConfig

  @controller_route_id "still_controller"
  @catchall_route_id "still_catchall"
  @system_route_ids [@controller_route_id, @catchall_route_id]
  @still_servers ["still", "still_internal"]

  # Root the OS Caddy packages' default Caddyfile serves its welcome page
  # from. That server (`srv0` after Caddyfile adaptation) binds :80 and is
  # the one thing we'll evict to take a port — see drop_default_welcome_server/2.
  @default_web_root "/usr/share/caddy"

  @doc """
  Reconciles the local Caddy's "still" server with the desired system
  routes and listen array, preserving any per-application routes that
  were added at deploy time. Called by the installer on every run.

  Returns `:ok` on success or `{:error, reason}` if Caddy's admin API
  is unreachable or rejects the config.
  """
  def reconcile(opts) when is_list(opts) do
    with {:ok, config} <- CaddyManager.get_config() do
      CaddyManager.load_config(rebuild(config, opts))
    end
  end

  @doc """
  Pure function: takes the current Caddy config map and returns a new
  map with the "still" server rebuilt to match `opts`. Per-application
  routes in the current config are preserved; the system routes are
  replaced in place. Any other fields on the still server
  (`automatic_https`, `tls_connection_policies`, etc.) are preserved
  — we only overwrite `listen` and `routes`, and remove the deprecated
  per-server `metrics` field. Unrelated top-level keys (`admin`) and
  other HTTP servers are untouched.

  The one exception: the OS Caddy package's default welcome-page server
  (a `file_server` rooted at `/usr/share/caddy`, named `srv0` after
  Caddyfile adaptation) is removed when it binds a port the still server
  needs — typically :80 under `tls_mode: :auto`. Caddy refuses to run two
  servers on one listener, so on a stock box the choice is evict that
  placeholder or fail the whole config load; we evict it and log it. A
  server an operator configured themselves is never touched — if it
  collides, Caddy rejects the load and the operator resolves it (free the
  port, or install with `STILL_SKIP_CADDY_SETUP=1`).
  """
  def rebuild(current_config, opts) when is_map(current_config) and is_list(opts) do
    current_routes =
      current_config
      |> get_in(["apps", "http", "servers", "still", "routes"])
      |> List.wrap()

    app_routes = Enum.reject(current_routes, &system_route?/1)
    new_routes = with_catchall_last(system_route_list(opts) ++ app_routes)
    new_listen = listen(opts)

    internal_port = Keyword.get(opts, :internal_port, 9090)
    artifacts_dir = Keyword.get(opts, :artifacts_dir, artifacts_dir_default())

    tls_mode = Keyword.get(opts, :tls_mode, :off)

    owned_ports = listen_ports(new_listen ++ [":#{internal_port}"])

    current_config
    |> ensure_servers_path()
    |> put_in(["apps", "http", "metrics"], metrics_config())
    |> update_in(["apps", "http", "servers", "still"], fn existing ->
      (existing || %{})
      |> Map.put("listen", new_listen)
      |> Map.put("routes", new_routes)
      |> Map.delete("metrics")
      |> apply_automatic_https(tls_mode)
    end)
    |> put_in(
      ["apps", "http", "servers", "still_internal"],
      internal_server(internal_port, artifacts_dir)
    )
    |> drop_default_welcome_server(owned_ports)
  end

  # Evict the OS Caddy package's default welcome-page server when it sits on
  # a port the still server needs. On a stock box `caddy run --config
  # /etc/caddy/Caddyfile` adapts to a `srv0` file_server on :80; under
  # tls_mode :auto the still server also wants :80, and Caddy rejects the
  # whole config rather than run two servers on one listener. We only ever
  # remove that recognizable placeholder — a server the operator configured
  # themselves is left for Caddy to reject so they resolve it deliberately.
  defp drop_default_welcome_server(config, owned_ports) do
    update_in(config, ["apps", "http", "servers"], fn servers ->
      {kept, dropped} =
        Enum.split_with(servers, fn {name, server} ->
          name in @still_servers or not removable_welcome_server?(server, owned_ports)
        end)

      Enum.each(dropped, fn {name, _server} ->
        Logger.warning(
          "Still.CaddyBootstrap: removed Caddy's default welcome-page server " <>
            "#{inspect(name)} — it bound a port the still server needs " <>
            "(#{Enum.join(owned_ports, ", ")})"
        )
      end)

      Map.new(kept)
    end)
  end

  defp removable_welcome_server?(server, owned_ports) do
    default_welcome_server?(server) and port_collision?(server, owned_ports)
  end

  # The default Caddyfile's welcome page is a `file_server` rooted at the
  # package web root; after adaptation the root rides on a `vars` handler.
  # Matching that root is the surest "untouched OS default" signal — it
  # won't false-match an operator's own static site on a custom root.
  defp default_welcome_server?(server) when is_map(server) do
    server
    |> Map.get("routes", [])
    |> List.wrap()
    |> Enum.any?(fn route ->
      route
      |> Map.get("handle", [])
      |> List.wrap()
      |> Enum.any?(&(&1["root"] == @default_web_root))
    end)
  end

  defp default_welcome_server?(_server), do: false

  defp port_collision?(server, owned_ports) when is_map(server) do
    server
    |> Map.get("listen", [])
    |> List.wrap()
    |> listen_ports()
    |> Enum.any?(&(&1 in owned_ports))
  end

  defp port_collision?(_server, _owned_ports), do: false

  # Reduce Caddy listen addresses to the bare port they bind. Handles the
  # shapes Still and the stock Caddyfile emit (":80", "0.0.0.0:80",
  # "localhost:2019", "udp/:443"); the port is the segment after the last
  # colon, with any "network/" prefix stripped first.
  defp listen_ports(listen) when is_list(listen) do
    listen
    |> Enum.map(&listen_port/1)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  defp listen_port(addr) when is_binary(addr) do
    addr
    |> String.split("/")
    |> List.last()
    |> String.split(":")
    |> List.last()
  end

  defp listen_port(_addr), do: nil

  # Caddy's default is to manage TLS for any server whose routes match a
  # real domain name, regardless of listener port. Under tls_mode=:off
  # that kicks in anyway for :8080 and the server rejects plain HTTP
  # with "Client sent an HTTP request to an HTTPS server". Explicitly
  # disable it here so the operator's external edge owns TLS entirely.
  # Under :auto we drop the key so Caddy's default behavior returns.
  defp apply_automatic_https(server, :off) do
    Map.put(server, "automatic_https", %{"disable" => true})
  end

  defp apply_automatic_https(server, _auto) do
    Map.delete(server, "automatic_https")
  end

  # Caddy 2.11 deprecates per-server metrics; app-level metrics applies to
  # all HTTP servers. `per_host` labels counters with the matched host, which
  # maps 1:1 to `application.domain`. `observe_catchall_hosts` stays off: it
  # would add visibility for system routes in HTTP-only installs, but at the
  # cost of unbounded host-label cardinality from arbitrary `Host` headers.
  defp metrics_config do
    %{"per_host" => true}
  end

  # Loopback artifacts server — always off the TLS path.
  defp internal_server(port, artifacts_dir) do
    %{
      "listen" => [":#{port}"],
      "routes" => [
        CaddyConfig.route(
          id: "still_artifacts",
          match: [CaddyConfig.match(path: ["/artifacts/*"])],
          handle: [
            CaddyConfig.vars(root: artifacts_dir),
            CaddyConfig.rewrite(strip_path_prefix: "/artifacts"),
            CaddyConfig.file_server()
          ]
        )
      ]
    }
    |> apply_automatic_https(:off)
  end

  @doc """
  Returns the `listen` array for the "still" HTTP server. Exposed for
  unit testing and for callers that want to inspect the listener
  decision without building the full config. `:tls_mode` decides the
  ports; `:controller_domain` doesn't affect listeners anymore.
  """
  def listen(opts) when is_list(opts) do
    http_port = Keyword.fetch!(opts, :http_port)
    tls_mode = Keyword.get(opts, :tls_mode, :off)
    listen_for(tls_mode, http_port)
  end

  @doc """
  Returns the system route list: a single host-scoped route that proxies
  the whole controller host to Phoenix. The catch-all is appended
  separately (see `with_catchall_last/1`) so it always stays last.
  """
  def system_route_list(opts) when is_list(opts) do
    backend = Keyword.fetch!(opts, :backend)
    [controller_route(backend, controller_host(opts))]
  end

  @doc """
  The catch-all route: answers any unmatched host with a 200 "Still"
  page so a bare IP / unknown `Host` doesn't fall through to Caddy's
  empty default. Must always be the last route in the server — use
  `with_catchall_last/1` rather than placing it by hand.
  """
  def catchall_route do
    CaddyConfig.route(
      id: @catchall_route_id,
      handle: [CaddyConfig.static_response(status: 200, body: "Still")],
      terminal: true
    )
  end

  @doc "Returns true if the route map is the catch-all route."
  def catchall_route?(%{"@id" => @catchall_route_id}), do: true
  def catchall_route?(_), do: false

  @doc """
  Returns `routes` with exactly one catch-all route, positioned last.
  Every place that mutates the "still" server's route array funnels
  through this so the catch-all can never end up shadowing an app route
  appended after it.
  """
  def with_catchall_last(routes) when is_list(routes) do
    Enum.reject(routes, &catchall_route?/1) ++ [catchall_route()]
  end

  defp controller_route(backend, host) do
    CaddyConfig.route(
      id: @controller_route_id,
      match: controller_match(host),
      handle: [CaddyConfig.reverse_proxy(dial: backend)],
      terminal: true
    )
  end

  defp controller_match(nil), do: nil
  defp controller_match(host), do: [CaddyConfig.match(host: [host])]

  defp controller_host(opts) do
    blank_to_nil(Keyword.get(opts, :controller_domain)) ||
      blank_to_nil(Keyword.get(opts, :fallback_host))
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(host) when is_binary(host), do: host

  defp ensure_servers_path(config) do
    config
    |> Map.put_new("apps", %{})
    |> update_in(["apps"], &Map.put_new(&1, "http", %{}))
    |> update_in(["apps", "http"], &Map.put_new(&1, "servers", %{}))
  end

  defp system_route?(%{"@id" => id}) when is_binary(id), do: id in @system_route_ids
  defp system_route?(_), do: false

  defp artifacts_dir_default do
    Application.get_env(:still, :artifacts_dir, "/var/lib/still/artifacts")
  end

  defp listen_for(:auto, _http_port), do: [":80", ":443"]
  defp listen_for(_off, http_port), do: [":#{http_port}"]
end
