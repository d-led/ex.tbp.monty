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

    # What the page in the window drew, reported by the page and asked by
    # `scripts/smoke-window.sh`. Both verbs are 404 unless this process is a
    # window's sidecar, which is the only thing that can answer them — see
    # `ExTbpMontyWeb.PaintController`.
    post "/__painted", PaintController, :record
    get "/__painted", PaintController, :show

    # The MCP server: one JSON-RPC message in, one answer out. `GET` and
    # `DELETE` are answered 405 by the controller, which is how a server
    # declines the transport's optional stream and its sessions.
    post "/mcp", McpController, :handle
    get "/mcp", McpController, :stream
    delete "/mcp", McpController, :terminate
  end

  scope "/", ExTbpMontyWeb do
    pipe_through :browser

    # The front door: what Monty is, and the ways into it. The list of every
    # experiment is one link away rather than the first thing a visitor sees —
    # a hundred configurations is a good index and a poor welcome.
    live "/", WelcomeLive, :index
    live "/experiments", ExperimentsLive, :index
    live "/build", BuildLive, :new
    # A glob: Monty names experiments by path (`tutorial/first_experiment`).
    live "/experiments/*name", ExperimentLive, :show
    live "/runs", RunHistoryLive, :index
    live "/runs/:id", RunHistoryLive, :show
    # Two runs of one experiment beside each other — the page a lever is read on
    # (`Monty.Studio.Comparison`).
    live "/compare", RunCompareLive, :compare
    # What this instance does while it runs, and what it cannot be asked to
    # change without a restart (`Monty.Studio.Settings`, `Monty.Studio.System`).
    live "/settings", SettingsLive, :show
    # A file the run wrote — its log, its CSV, its detailed JSON — as it is, so
    # it can be read, diffed or plotted outside this page.
    get "/runs/:id/files/:name", RunFileController, :show
    # One picture of one step, kept on disk rather than in the record: a glob
    # because a step's pictures live under `frames/<step>/` in the run's own
    # directory.
    get "/runs/:id/frames/*path", RunFramesController, :show
    # The same directory's videos: a run is also something a person watches, and
    # a player seeks by asking for byte ranges of the file.
    get "/runs/:id/videos/*path", RunFramesController, :watch
    # The queue a run waits in before it has anything to report.
    # One page for runs: a queued run is a run, and the old address still opens
    # the list a colleague was sent.
    live "/jobs", RunHistoryLive, :index
    live "/prerequisites", PrerequisitesLive, :index
    # Parts a person brought: the one page whose first step is a file rather than
    # a button, because a STEP part is the only input this studio cannot name in
    # advance (`docs/cad.md`).
    live "/cad", CadLive, :index
    # Monty's classes and this application's, from the generated map: the one
    # page that answers "what is written and what still has to be".
    live "/modules", ModulesLive, :index
    # Not `/mcp`: that address is the server itself (POST is a JSON-RPC message,
    # GET is declined with 405). This is the page that says how to point a client
    # at it, with the port this instance actually answers on.
    live "/mcp/config", McpLive, :index
    # The experiment as a file. A glob of its own rather than a suffix of
    # `/experiments/*name`, which is the LiveView's address.
    get "/export/experiments/*name", ExperimentExportController, :show
  end

  # Other scopes may use custom stacks.
  # scope "/api", ExTbpMontyWeb do
  #   pipe_through :api
  # end

  # The dashboard, where this instance is one reader's: development, and the
  # desktop window — a sidecar on loopback with a single client
  # (`docs/desktop.md`). A deployment leaves `dev_routes` off, because the
  # dashboard lists every process, every query and every byte of memory this node
  # holds, and it has no authentication of its own: putting it behind a login
  # would mean `Plug.BasicAuth` and SSL with it.
  if Application.compile_env(:ex_tbp_monty, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    # The two things the dashboard cannot say for itself: whose window this is,
    # and how to leave the screen. The second one is not a nicety — the desktop
    # build has no address bar to type the studio's address into.
    pipeline :dashboard do
      plug ExTbpMontyWeb.DashboardWayBack, back: "/", label: "Monty on the BEAM"
    end

    scope "/dev" do
      pipe_through [:browser, :dashboard]

      live_dashboard "/dashboard",
        metrics: ExTbpMontyWeb.Telemetry,
        home_app: {"Monty on the BEAM", :ex_tbp_monty}
    end
  end
end
