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
    <div class="flex min-h-screen flex-col">
      <header class="border-b border-base-300 bg-base-100/80 backdrop-blur">
        <div class="mx-auto flex max-w-6xl flex-wrap items-center gap-2 px-4 py-2 sm:px-6 lg:px-8">
          <.link navigate={~p"/"} class="flex items-center gap-2 rounded-field px-1 py-1">
            <span class="grid size-8 place-items-center rounded-field bg-primary/15 text-primary">
              <.icon name="hero-cpu-chip-mini" class="size-5" />
            </span>
            <span class="text-sm font-semibold tracking-tight">Monty on the BEAM</span>
          </.link>

          <nav class="ms-auto flex flex-wrap items-center gap-1">
            <.nav_link navigate={~p"/"} label="Experiments" icon="hero-beaker-mini" />
            <.nav_link navigate={~p"/build"} label="Build" icon="hero-wrench-screwdriver-mini" />
            <.nav_link
              navigate={~p"/prerequisites"}
              label="Prerequisites"
              icon="hero-arrow-down-tray-mini"
            />
            <.nav_link navigate={~p"/runs/demo"} label="Runtime" icon="hero-play-mini" />
          </nav>
        </div>
      </header>

      <main class="flex-1 px-4 py-6 sm:px-6 lg:px-8">
        <div class="mx-auto max-w-6xl space-y-6">
          {render_slot(@inner_block)}
        </div>
      </main>

      <.footer build={BuildInfo.info()} repo={source_repo()} />

      <.flash_group flash={@flash} />
    </div>
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

  @doc """
  One item in the application bar.
  """
  attr :navigate, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true

  def nav_link(assigns) do
    ~H"""
    <.link navigate={@navigate} class="btn btn-ghost btn-sm gap-1.5 font-normal">
      <.icon name={@icon} class="size-4 opacity-70" />
      {@label}
    </.link>
    """
  end
end
