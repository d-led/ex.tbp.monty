defmodule ExTbpMontyWeb.Router do
  use ExTbpMontyWeb, :router

  # The dashboard is one app on one origin: everything it needs is served from
  # here, plus the LiveView socket on the same host. `'unsafe-inline'` for
  # scripts is what Phoenix's own layout and LiveView bootstrap need; the
  # policy still blocks third-party script and frame origins.
  @content_security_policy [
                             "default-src 'self'",
                             "img-src 'self' data:",
                             "style-src 'self' 'unsafe-inline'",
                             "script-src 'self' 'unsafe-inline'",
                             "connect-src 'self' ws: wss:",
                             "frame-ancestors 'self'"
                           ]
                           |> Enum.join("; ")

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ExTbpMontyWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, %{"content-security-policy" => @content_security_policy}
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", ExTbpMontyWeb do
    pipe_through :browser

    get "/", PageController, :home
    live "/runs/demo", RunsLive, :demo
    live "/prerequisites", PrerequisitesLive, :index
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
