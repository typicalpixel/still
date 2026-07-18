defmodule StillWeb.Router do
  use StillWeb, :router

  import StillWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {StillWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :authenticated do
    plug StillWeb.Plugs.Auth
  end

  pipeline :application_scope do
    plug StillWeb.Plugs.LoadApplicationScope
  end

  # Unauthenticated
  scope "/api", StillWeb do
    pipe_through :api

    post "/auth/login", AuthController, :login
    post "/bootstrap", BootstrapController, :create
    get "/status", StatusController, :index
    get "/openapi", SpecController, :show
  end

  # Authenticated
  scope "/api", StillWeb do
    pipe_through [:api, :authenticated]

    post "/auth/logout", AuthController, :logout
    get "/auth/me", AuthController, :me
    patch "/auth/me", AuthController, :update_me
    post "/auth/me/password", AuthController, :update_my_password

    get "/users", UserController, :index
    post "/users", UserController, :create
    get "/users/:id", UserController, :show
    patch "/users/:id", UserController, :update
    post "/users/:id/password", UserController, :update_password
    delete "/users/:id", UserController, :delete

    get "/servers", ServerController, :index
    post "/servers", ServerController, :create
    get "/servers/:id", ServerController, :show
    patch "/servers/:id", ServerController, :update
    delete "/servers/:id", ServerController, :delete

    get "/applications", ApplicationController, :index
    post "/applications", ApplicationController, :create
    get "/applications/:name", ApplicationController, :show
    patch "/applications/:name", ApplicationController, :update
    delete "/applications/:name", ApplicationController, :delete
  end

  # Authenticated + application-scoped.
  # Routes that nest under /api/applications/:application_name/* load the
  # parent application onto conn.assigns.current_scope so controllers can
  # pass the scope straight into context functions.
  scope "/api", StillWeb do
    pipe_through [:api, :authenticated, :application_scope]

    get "/applications/:application_name/servers", ApplicationServerController, :index
    post "/applications/:application_name/servers", ApplicationServerController, :create
    delete "/applications/:application_name/servers/:id", ApplicationServerController, :delete

    get "/applications/:application_name/hooks", HookController, :index
    post "/applications/:application_name/hooks", HookController, :create
    patch "/applications/:application_name/hooks/:id", HookController, :update
    delete "/applications/:application_name/hooks/:id", HookController, :delete

    post "/applications/:application_name/deployments", DeploymentController, :create
    post "/applications/:application_name/rollback", DeploymentController, :rollback
    post "/applications/:application_name/restart", DeploymentController, :restart
  end

  # Authenticated (remaining top-level resources).
  scope "/api", StillWeb do
    pipe_through [:api, :authenticated]

    get "/api_keys", ApiKeyController, :index
    post "/api_keys", ApiKeyController, :create
    delete "/api_keys/:id", ApiKeyController, :delete

    get "/deployments", DeploymentController, :index
    get "/deployments/:id", DeploymentController, :show

    get "/events", EventController, :index
    get "/audit", AuditController, :index

    get "/status/servers", StatusController, :servers
    get "/status/applications", StatusController, :applications

    get "/caddy", CaddyController, :show
    get "/servers/:id/caddy", CaddyController, :show_server

    get "/routes", RouteController, :index

    post "/webhooks/deploy", WebhookController, :deploy
  end

  # Browser dashboard (LiveView). Only served where the endpoint runs —
  # controller and standalone modes; agents have no web endpoint. Mounted at
  # the root — Caddy host-scopes the controller route, so nothing else shares
  # this origin and the app doesn't need to know it lives under a prefix.
  scope "/", StillWeb do
    pipe_through :browser

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete

    live_session :current_user,
      on_mount: [{StillWeb.UserAuth, :mount_current_scope}] do
      live "/users/log-in", UserLive.Login, :new
      live "/bootstrap", BootstrapLive, :new
    end

    live_session :require_authenticated,
      on_mount: [{StillWeb.UserAuth, :require_authenticated}, {StillWeb.NavAssigns, :default}] do
      live "/", DashboardLive, :index
      live "/applications", ApplicationsLive, :index
      live "/applications/:name", ApplicationLive, :show
      live "/servers", ServersLive, :index
      live "/servers/:id", ServerLive, :show
      live "/deployments", DeploymentsLive, :index
      live "/deployments/:id", DeploymentLive, :show
      live "/routes", RoutesLive, :index
      live "/events", EventsLive, :index
      live "/api-keys", ApiKeysLive, :index
      live "/users", UsersLive, :index
      live "/caddy", CaddyLive, :index
      live "/account", AccountLive, :show
      live "/settings", SettingsLive, :index
      live "/settings/audit", AuditLive, :index
    end

    live_session :console,
      on_mount: [
        {StillWeb.UserAuth, :require_authenticated},
        {StillWeb.UserAuth, :require_deploy},
        {StillWeb.NavAssigns, :default}
      ] do
      live "/applications/:name/console", ConsoleLive, :show
    end
  end

  if Application.compile_env(:still, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: StillWeb.Telemetry
    end
  end
end
