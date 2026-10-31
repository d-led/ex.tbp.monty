defmodule ExTbpMontyWeb.Router do
  use ExTbpMontyWeb, :router

  # The dashboard is one app on one origin: everything it needs is served from
  # here, plus the LiveView socket on the same host. `'unsafe-inline'` for
  # scripts is what Phoenix's own layout and LiveView bootstrap need; the
  # policy still blocks third-party script and frame origins.
  #
  # The policy is one literal, not a list joined at compile time: what a reader
  # (or a scanner) needs to be able to check is the exact header that is sent,
  # and a value assembled at run time is one they have to assemble themselves.
  @secure_headers %{
    "content-security-policy" =>
      "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; connect-src 'self' ws: wss:; frame-ancestors 'self'"
  }

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ExTbpMontyWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, @secure_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # What a container runtime or a load balancer polls. It answers 200 and says
  # nothing else: a probe that reports trouble by answering 503 is a probe whose
  # absence from the request log means the application is up.
  scope "/", ExTbpMontyWeb do
    pipe_through :api

    get "/health", HealthController, :show

    # The MCP server: one JSON-RPC message in, one answer out. `GET` and
    # `DELETE` are answered 405 by the controller, which is how a server
    # declines the transport's optional stream and its sessions.
    post "/mcp", McpController, :handle
    get "/mcp", McpController, :stream
    delete "/mcp", McpController, :terminate
  end

  scope "/", ExTbpMontyWeb do
    pipe_through :browser

    # The studio is the application: the first thing you see is the list of
    # experiments you can open, build or run.
    live "/", ExperimentsLive, :index
    live "/build", BuildLive, :new
    # A glob: Monty names experiments by path (`tutorial/first_experiment`).
    live "/experiments/*name", ExperimentLive, :show
    live "/runs", RunHistoryLive, :index
    live "/runs/:id", RunHistoryLive, :show
    # A file the run wrote — its log, its CSV, its detailed JSON — as it is, so
    # it can be read, diffed or plotted outside this page.
    get "/runs/:id/files/:name", RunFileController, :show
    # The queue a run waits in before it has anything to report.
    # One page for runs: a queued run is a run, and the old address still opens
    # the list a colleague was sent.
    live "/jobs", RunHistoryLive, :index
    live "/prerequisites", PrerequisitesLive, :index
    # Not `/mcp`: that address is the server itself (POST is a JSON-RPC message,
    # GET is declined with 405). This is the page that says how to point a client
    # at it, with the port this instance actually answers on.
    live "/mcp/config", McpLive, :index
  end

  # Other scopes may use custom stacks.
  # scope "/api", ExTbpMontyWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:ex_tbp_monty, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: ExTbpMontyWeb.Telemetry
    end
  end
end
