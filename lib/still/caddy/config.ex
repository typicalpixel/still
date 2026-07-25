defmodule Still.Caddy.Config do
  @moduledoc """
  Constructors for the slice of Caddy's JSON config that Still produces.

  Returns plain maps (string keys, ready for `Jason.encode!/1`) rather
  than typed structs — Caddy is the authoritative validator, so what
  we need locally is typo-proofing, argument-shape guards, and a
  single place to search when a Caddy field is renamed. A parallel
  type system would be cost without return.

  Use these constructors instead of hand-rolling map literals in the
  call sites. Every Caddy JSON key we emit lives in one file, so a
  misspelled `"upstreams"` fails every caller at once in CI instead
  of breaking one code path silently in production.
  """

  @lb_policies ~w(random round_robin ip_hash cookie first least_conn header uri_hash)a

  @doc """
  Builds a Caddy route map.

    * `:id` — optional stable `@id` for upsert-by-id. Required for
      routes that live at the top level of a server; inner routes of
      a subroute typically omit it.
    * `:match` — list of matcher maps. Optional for catch-all routes.
    * `:handle` — required, non-empty list of handler maps.
    * `:terminal` — when true, emits `"terminal": true` so route
      evaluation stops at this route. The right default for Still's
      per-app and per-domain routes.
  """
  def route(opts) when is_list(opts) do
    id = Keyword.get(opts, :id)
    match = Keyword.get(opts, :match)
    handle = Keyword.fetch!(opts, :handle)
    terminal = Keyword.get(opts, :terminal, false)

    unless is_list(handle) and handle != [] do
      raise ArgumentError, "route :handle must be a non-empty list"
    end

    if not is_nil(match) and (not is_list(match) or match == []) do
      raise ArgumentError, "route :match, if given, must be a non-empty list"
    end

    if not is_nil(id) and not is_binary(id) do
      raise ArgumentError, "route :id, if given, must be a string"
    end

    %{"handle" => handle}
    |> maybe_put("@id", id)
    |> maybe_put("match", match)
    |> maybe_put("terminal", if(terminal, do: true, else: nil))
  end

  @doc """
  Builds a single Caddy request matcher map. At least one of `:host`
  or `:path` must be given; both may be set to combine the two
  conditions (the route fires only when both match).

  `:host` and `:path` are expected to be non-empty lists of strings —
  Caddy's matcher syntax is always list-valued.
  """
  def match(opts) when is_list(opts) do
    host = Keyword.get(opts, :host)
    path = Keyword.get(opts, :path)

    if is_nil(host) and is_nil(path) do
      raise ArgumentError, "match/1 requires at least one of :host or :path"
    end

    validate_string_list!(:host, host)
    validate_string_list!(:path, path)

    %{}
    |> maybe_put("host", host)
    |> maybe_put("path", path)
  end

  @doc """
  Builds a `reverse_proxy` handler map.

  Options:
    * `:dial` — a single `host:port` upstream string (convenience for
      one-upstream routes).
    * `:dials` — a non-empty list of `host:port` upstreams. Exactly one
      of `:dial` or `:dials` must be given.
    * `:health_check` — optional active health check map
      `%{path: "/health", interval_ms: 10_000, deadline_ms: 5_000}`.
      Caddy runs these out-of-band and takes unhealthy upstreams out
      of rotation automatically; skip it for apps without a health
      endpoint (e.g. static_sites).
    * `:lb_policy` — optional upstream selection policy atom. One of
      `:random`, `:round_robin`, `:ip_hash`, `:cookie`, `:first`,
      `:least_conn`, `:header`, `:uri_hash`. Omitted means Caddy's
      default (random).
  """
  def reverse_proxy(opts) when is_list(opts) do
    dials = dials_from_opts(opts)
    health = Keyword.get(opts, :health_check)
    lb_policy = Keyword.get(opts, :lb_policy)

    %{
      "handler" => "reverse_proxy",
      "upstreams" => Enum.map(dials, &%{"dial" => &1})
    }
    |> maybe_put_health(health)
    |> maybe_put_lb_policy(lb_policy)
  end

  defp maybe_put_health(map, nil), do: map

  defp maybe_put_health(map, %{} = h) do
    Map.put(map, "health_checks", %{"active" => active_health_check(h)})
  end

  defp maybe_put_lb_policy(map, nil), do: map

  defp maybe_put_lb_policy(map, policy) when policy in @lb_policies do
    Map.put(map, "load_balancing", %{
      "selection_policy" => %{"policy" => Atom.to_string(policy)}
    })
  end

  defp maybe_put_lb_policy(_map, policy) do
    raise ArgumentError,
          "reverse_proxy :lb_policy must be one of #{inspect(@lb_policies)}, got #{inspect(policy)}"
  end

  defp dials_from_opts(opts) do
    case {Keyword.get(opts, :dial), Keyword.get(opts, :dials)} do
      {nil, nil} -> raise ArgumentError, "reverse_proxy/1 requires :dial or :dials"
      {dial, nil} when is_binary(dial) and dial != "" -> [dial]
      {nil, [_ | _] = dials} -> validate_dials!(dials)
      {_, _} -> raise ArgumentError, "reverse_proxy/1 takes :dial or :dials, not both"
    end
  end

  defp validate_dials!(dials) do
    if Enum.all?(dials, &(is_binary(&1) and &1 != "")) do
      dials
    else
      raise ArgumentError, "reverse_proxy :dials must be non-empty strings"
    end
  end

  defp active_health_check(%{path: path, interval_ms: interval_ms, deadline_ms: deadline_ms})
       when is_binary(path) and is_integer(interval_ms) and is_integer(deadline_ms) do
    %{
      "uri" => path,
      "interval" => "#{interval_ms}ms",
      "timeout" => "#{deadline_ms}ms"
    }
  end

  @doc """
  Builds a `tracing` handler map. Caddy opens a span named `span` for the
  request and propagates W3C `traceparent` to the upstream, so an
  instrumented application's own trace nests under it. Where spans are
  exported is configured with the standard `OTEL_*` environment variables
  on the Caddy process, not here.
  """
  def tracing(span: span) when is_binary(span) and span != "" do
    %{"handler" => "tracing", "span" => span}
  end

  @doc """
  Builds a `file_server` handler map. The filesystem root is typically
  set by a preceding `vars/1` handler in the same subroute so that the
  request's file matcher and the file_server share a root.
  """
  def file_server, do: %{"handler" => "file_server"}

  @doc """
  Builds an `encode` handler map enabling response compression. Caddy
  negotiates the encoding per request from `Accept-Encoding`, preferring
  zstd then gzip, and skips responses already compressed or below its
  minimum size.
  """
  def encode do
    %{
      "handler" => "encode",
      "encodings" => %{"zstd" => %{}, "gzip" => %{}},
      "prefer" => ["zstd", "gzip"]
    }
  end

  @doc """
  Builds a `headers` handler map that sets a single response header,
  overwriting any existing value. Used to stamp `Cache-Control` onto
  static responses.
  """
  def response_header(name, value)
      when is_binary(name) and name != "" and is_binary(value) and value != "" do
    %{"handler" => "headers", "response" => %{"set" => %{name => [value]}}}
  end

  @doc """
  Builds a `static_response` handler map: Caddy answers the request itself
  with a fixed status and body instead of proxying. Used for the root
  catch-all, and the same primitive a future maintenance mode will swap in
  for an app's `reverse_proxy` handle. `:status` defaults to 200, `:body`
  to "".
  """
  def static_response(opts \\ []) when is_list(opts) do
    status = Keyword.get(opts, :status, 200)
    body = Keyword.get(opts, :body, "")

    unless is_integer(status) and status in 100..599 do
      raise ArgumentError, "static_response :status must be an HTTP status integer"
    end

    unless is_binary(body) do
      raise ArgumentError, "static_response :body must be a string"
    end

    %{"handler" => "static_response", "status_code" => status, "body" => body}
  end

  @default_maintenance_body "This application is temporarily down for maintenance."

  @doc """
  Builds the handler for an application parked in maintenance mode: a `503`
  `static_response` carrying the operator's message (or a default). 503 tells
  clients and crawlers the outage is temporary. `message` may be nil/blank.
  """
  def maintenance_response(message \\ nil) do
    body = if is_binary(message) and message != "", do: message, else: @default_maintenance_body
    static_response(status: 503, body: body)
  end

  @doc """
  Builds a `vars` handler map that sets the request's `root` directory.
  Used in combination with `file_server/0` inside a `subroute/1` so
  that SPA try_files fallback and the file server serve from the same
  directory.
  """
  def vars(root: root) when is_binary(root) and root != "" do
    %{"handler" => "vars", "root" => root}
  end

  @doc """
  Builds a `rewrite` handler map. Accepts either `:uri` (replace the
  full request URI) or `:strip_path_prefix` (remove a leading path
  segment so file_server sees a root-relative path).
  """
  def rewrite(uri: uri) when is_binary(uri) and uri != "" do
    %{"handler" => "rewrite", "uri" => uri}
  end

  def rewrite(strip_path_prefix: prefix) when is_binary(prefix) and prefix != "" do
    %{"handler" => "rewrite", "strip_path_prefix" => prefix}
  end

  @doc """
  Builds a `subroute` handler map wrapping a list of inner routes.
  Inner routes are themselves plain maps with `handle` and optional
  `match` keys — they do not typically carry an `@id`.
  """
  def subroute(routes: routes) when is_list(routes) and routes != [] do
    %{"handler" => "subroute", "routes" => routes}
  end

  # A content-hashed Vite asset's bytes never change under a given name, so
  # it can be cached indefinitely. The unhashed app shell must not be.
  @immutable_cache "public, max-age=31536000, immutable"

  @doc """
  Builds the handle list for a static_site application: a single
  `subroute` that

    * sets the filesystem root and enables response compression,
    * tries the requested file and falls back to `/index.html` so SPA
      deep links don't 404,
    * stamps `Cache-Control` — content-hashed `/assets/*` are immutable
      and cached for a year, everything else (the unhashed app shell,
      including the `index.html` served for a deep-link fallback) is
      `no-cache` so a deploy is never masked by a stale shell,
    * serves the result via `file_server`.

  The cache rules run after the try_files rewrite so they match the
  final path: a deep link rewritten to `/index.html` gets `no-cache`,
  not the immutable asset header.
  """
  def static_site_handle(root: root) when is_binary(root) and root != "" do
    [
      subroute(
        routes: [
          %{"handle" => [vars(root: root), encode()]},
          %{
            "match" => [
              %{"file" => %{"try_files" => ["{http.request.uri.path}", "/index.html"]}}
            ],
            "handle" => [rewrite(uri: "{http.matchers.file.relative}")]
          },
          %{
            "match" => [%{"path" => ["/assets/*"]}],
            "handle" => [response_header("Cache-Control", @immutable_cache)]
          },
          %{
            "match" => [%{"not" => [%{"path" => ["/assets/*"]}]}],
            "handle" => [response_header("Cache-Control", "no-cache")]
          },
          %{"handle" => [file_server()]}
        ]
      )
    ]
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp validate_string_list!(_field, nil), do: :ok

  defp validate_string_list!(field, value) do
    unless is_list(value) and value != [] and Enum.all?(value, &(is_binary(&1) and &1 != "")) do
      raise ArgumentError, "match #{inspect(field)} must be a non-empty list of non-empty strings"
    end
  end
end
