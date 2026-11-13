defmodule ExTbpMontyWeb do
  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, components, channels, and so on.

  This can be used in your application as:

      use ExTbpMontyWeb, :controller
      use ExTbpMontyWeb, :html

  The definitions below will be executed for every controller,
  component, etc, so keep them short and clean, focused
  on imports, uses and aliases.

  Do NOT define functions inside the quoted expressions
  below. Instead, define additional modules and import
  those modules here.
  """

  def static_paths, do: ~w(assets fonts images favicon.ico robots.txt)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      # Import common connection and controller functions to use in pipelines
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      # `log: false`: LiveView logs every mount, every event and every reply at
      # `:debug` — two lines a keystroke — and a development console now shows
      # `:debug`. What a reader of this console needs to know about a page is
      # here already and at `:info`: one line when it opens, one when its
      # connection opens and one when it closes, and the reason if it closes
      # badly (`ExTbpMontyWeb.Telemetry.ConnectionLog`). A page being debugged
      # says the same by putting `log: :debug` back on its own module.
      #
      # `on_mount`: every page hears the cluster change, so the footer's node
      # count follows a peer joining or leaving without anybody reloading. A
      # component cannot subscribe by itself — the parent has to receive and
      # `send_update/3` — and this is that parent clause, once, for every page.
      #
      # Spelled as the `on_mount` macro rather than `use Phoenix.LiveView,
      # on_mount: [...]`: the macro appends to the attribute `__live__/0` reads,
      # while the `use` option is shadowed by that same attribute list — a page
      # with no other hook would silently run nothing.
      use Phoenix.LiveView, log: false
      on_mount {ExTbpMontyWeb.ClusterLive, :default}

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      # Import convenience functions from controllers
      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      # Include general helpers for rendering HTML
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      # HTML escaping functionality
      import Phoenix.HTML
      # Core UI components
      import ExTbpMontyWeb.CoreComponents

      # Common modules used in templates
      alias ExTbpMontyWeb.Layouts
      alias Phoenix.LiveView.JS

      # Routes generation with the ~p sigil
      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: ExTbpMontyWeb.Endpoint,
        router: ExTbpMontyWeb.Router,
        statics: ExTbpMontyWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/live_view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
