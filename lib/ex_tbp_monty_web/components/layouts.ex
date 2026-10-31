defmodule ExTbpMontyWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use ExTbpMontyWeb, :html

  alias ExTbpMonty.BuildInfo

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

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
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="flex min-h-screen">
      <div
        data-sidebar-backdrop
        hidden
        aria-hidden="true"
        class="fixed inset-0 z-40 bg-base-content/40 backdrop-blur-sm lg:hidden"
      >
      </div>

      <.sidebar />

      <div class="flex min-w-0 flex-1 flex-col">
        <header class="sticky top-0 z-30 border-b border-base-300 bg-base-100/85 backdrop-blur">
          <div class="flex items-center gap-2 px-3 py-2 sm:px-5">
            <button
              id="sidebar-toggle"
              type="button"
              data-sidebar-toggle
              aria-controls="app-sidebar"
              aria-expanded="true"
              aria-label="Collapse the sidebar"
              title="Collapse the sidebar"
              class="group grid size-9 shrink-0 place-items-center rounded-field text-base-content/70 transition hover:bg-base-200 hover:text-base-content focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/50"
            >
              <%!-- A panel with a divider, and a chevron pointing the way it is
              about to move: right when the sidebar is closed, left when it is
              open. `sidebar.js` keeps `aria-expanded` in step, and these two
              variants follow it, so the button never states the wrong action. --%>
              <svg
                aria-hidden="true"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                stroke-width="1.5"
                stroke-linecap="round"
                stroke-linejoin="round"
                class="size-5 group-aria-expanded:hidden"
              >
                <rect x="3" y="3" width="18" height="18" rx="2" />
                <path d="M9 3v18" />
                <path d="m14 9 3 3-3 3" />
              </svg>
              <svg
                aria-hidden="true"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                stroke-width="1.5"
                stroke-linecap="round"
                stroke-linejoin="round"
                class="hidden size-5 group-aria-expanded:block"
              >
                <rect x="3" y="3" width="18" height="18" rx="2" />
                <path d="M9 3v18" />
                <path d="m14 15-3-3 3-3" />
              </svg>
            </button>

            <.link navigate={~p"/"} class="flex items-center gap-2 rounded-field px-1 py-1 lg:hidden">
              <span class="text-sm font-semibold tracking-tight">Monty on the BEAM</span>
            </.link>
          </div>
        </header>

        <main class="flex-1 px-3 py-5 sm:px-5 lg:px-6">
          <div class="mx-auto max-w-6xl space-y-6">
            {render_slot(@inner_block)}
          </div>
        </main>

        <.footer build={BuildInfo.info()} repo={source_repo()} />
      </div>

      <.flash_group flash={@flash} />
    </div>
    """
  end

  @doc """
  The way around the application, as a column beside the content.

  A column rather than a row of tabs because these are places, not modes: a
  reader who is on the fourth page of a run should still see where else they can
  go, and five entries with icons fit in a rail when the column is collapsed.

  Server-rendered and usable without JavaScript — a column on a laptop, a drawer
  on a phone — and `assets/js/sidebar.js` adds the toggle, the remembered
  preference and the drawer's focus handling.
  """
  def sidebar(assigns) do
    ~H"""
    <aside
      id="app-sidebar"
      tabindex="-1"
      aria-label="Main"
      class="group fixed inset-y-0 left-0 z-50 flex w-64 max-w-[85vw] -translate-x-full flex-col border-r border-base-300 bg-base-100 shadow-lg transition-transform duration-200 focus:outline-none motion-reduce:transition-none data-[open]:translate-x-0 lg:sticky lg:top-0 lg:z-auto lg:h-screen lg:translate-x-0 lg:self-start lg:overflow-y-auto lg:shadow-none lg:transition-[width] lg:data-[collapsed]:w-16"
    >
      <div class="flex h-full flex-col gap-1 p-2">
        <div class="flex items-center gap-2">
          <.link
            navigate={~p"/"}
            class="flex min-w-0 flex-1 items-center gap-2 rounded-field px-2 py-2 hover:bg-base-200"
          >
            <span class="grid size-8 shrink-0 place-items-center rounded-field bg-primary/15 text-primary">
              <.icon name="hero-cpu-chip-mini" class="size-5" />
            </span>
            <span class="truncate text-sm font-semibold tracking-tight group-data-[collapsed]:hidden">
              Monty on the BEAM
            </span>
          </.link>

          <%!-- On a phone the drawer slides over the toggle, so it carries its own
          way out; on a laptop the toggle is always visible. --%>
          <button
            id="sidebar-close"
            type="button"
            data-sidebar-toggle
            aria-label="Close the sidebar"
            title="Close the sidebar"
            class="grid size-9 shrink-0 place-items-center rounded-field text-base-content/60 hover:bg-base-200 hover:text-base-content lg:hidden"
          >
            <.icon name="hero-x-mark-mini" class="size-5" />
          </button>
        </div>

        <nav class="mt-2 flex flex-col gap-0.5" aria-label="Sections">
          <.sidebar_link
            id="nav-experiments"
            navigate={~p"/"}
            label="Experiments"
            icon="hero-beaker-mini"
          />
          <.sidebar_link
            id="nav-build"
            navigate={~p"/build"}
            label="Build"
            icon="hero-wrench-screwdriver-mini"
          />
          <.sidebar_link
            id="nav-prerequisites"
            navigate={~p"/prerequisites"}
            label="Prerequisites"
            icon="hero-arrow-down-tray-mini"
          />
          <.sidebar_link id="nav-runs" navigate={~p"/runs"} label="Runs" icon="hero-play-mini" />
          <%!-- An editor is the other way in: the same application answering an
          assistant over MCP, with the configuration to hand. --%>
          <.sidebar_link
            id="nav-mcp"
            navigate={~p"/mcp/config"}
            label="MCP"
            icon="hero-code-bracket-mini"
          />
        </nav>

        <div class="mt-auto flex flex-col gap-0.5 border-t border-base-300 pt-2">
          <%!-- The walkthrough, on every page rather than on the one it describes:
          a help button nobody can find is not help. driver.js skips the steps
          whose target a page does not have. --%>
          <button
            id="tour-start"
            type="button"
            phx-hook="StudioTour"
            phx-update="ignore"
            data-steps={ExTbpMontyWeb.Tour.payload()}
            data-seen-key={ExTbpMontyWeb.Tour.seen_key()}
            class="flex w-full items-center gap-2.5 rounded-field px-2 py-2 text-sm font-normal text-base-content/70 transition hover:bg-base-200 hover:text-base-content"
            title="Show the walkthrough"
          >
            <.icon name="hero-question-mark-circle-mini" class="size-4 shrink-0 opacity-70" />
            <span class="truncate group-data-[collapsed]:hidden">help</span>
          </button>
        </div>
      </div>
    </aside>
    """
  end

  attr :navigate, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :id, :string, default: nil

  defp sidebar_link(assigns) do
    ~H"""
    <.link
      id={@id}
      navigate={@navigate}
      data-nav
      title={@label}
      class="flex items-center gap-2.5 rounded-field px-2 py-2 text-sm text-base-content/75 transition hover:bg-base-200 hover:text-base-content data-[active]:bg-primary/10 data-[active]:font-medium data-[active]:text-primary"
    >
      <.icon name={@icon} class="size-4 shrink-0 opacity-70" />
      <span class="truncate group-data-[collapsed]:hidden">{@label}</span>
    </.link>
    """
  end

  @doc """
  The strip at the bottom of every page: which build is running, and where the
  source of that build lives.

  The build is an attribute rather than something this component reads itself,
  so a test can ask what the footer says about a release this checkout is not
  (a checkout that no build has touched says `dev`).
  """
  attr :build, :map,
    required: true,
    doc: "what the release was built from, an `ExTbpMonty.BuildInfo.t/0`"

  attr :repo, :string, default: nil, doc: "the repository the octocat links to"

  def footer(assigns) do
    ~H"""
    <footer class="border-t border-base-300 bg-base-100/60">
      <div class="mx-auto flex max-w-6xl flex-col gap-2 px-4 py-4 text-xs text-base-content/60 sm:flex-row sm:items-center sm:justify-between sm:px-6 lg:px-8">
        <span class="font-medium text-base-content/70">Monty on the BEAM</span>

        <div class="flex flex-wrap items-center gap-x-4 gap-y-1">
          <%!--
            The whole build as one sentence in the tooltip, the short label in
            the strip: nobody wants to read a UUID on every page, and somebody
            reporting a bug needs to say which commit they saw.
          --%>
          <span
            id="build-info"
            class="inline-flex items-center gap-1"
            title={BuildInfo.description(@build)}
          >
            <.icon name="hero-code-bracket-mini" class="size-3.5" />
            <span class="font-mono">{BuildInfo.label(@build)}</span>
            <a
              :if={ci_run_url(@build)}
              href={ci_run_url(@build)}
              class="font-mono text-primary hover:underline"
              target="_blank"
              rel="noopener noreferrer"
            >
              {BuildInfo.ci_label(@build)}
            </a>
          </span>

          <a
            :if={@repo}
            id="source-repo"
            href={@repo}
            aria-label="Source code on GitHub"
            class="inline-flex items-center gap-1 hover:text-primary"
            target="_blank"
            rel="noopener noreferrer"
          >
            <%!-- The GitHub mark, which heroicons (having no brand icons) leaves to us. --%>
            <svg aria-hidden="true" viewBox="0 0 16 16" fill="currentColor" class="size-3.5">
              <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.012 8.012 0 0 0 16 8c0-4.42-3.58-8-8-8z" />
            </svg>
            <span>Source</span>
          </a>
        </div>
      </div>
    </footer>
    """
  end

  # Where this software lives, for the footer's source link. A fork that does
  # not want the upstream link drops the config key and gets no link.
  defp source_repo do
    :ex_tbp_monty
    |> Application.get_env(:source, [])
    |> Keyword.get(:repo)
  end

  # The run that built this release, when a pipeline did. A footer link to a
  # build nobody can look at would be noise, so the label and the link come from
  # the same value.
  defp ci_run_url(build) do
    case BuildInfo.ci(build) do
      %{run_url: url} when is_binary(url) -> url
      _no_pipeline -> nil
    end
  end

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
        title="We can't find the internet"
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
