defmodule ExTbpMontyWeb.WelcomeLive do
  @moduledoc """
  The front door: what this is, and the ways into it.

  Monty ships a hundred configurations, and the studio lists every one of them
  with four facets to narrow by. That is the right page for somebody who already
  knows what they are looking for and the wrong first page for somebody who has
  just arrived, so the list lives at `/experiments` and this page says what the
  list is. It is one screen of prose and four links: read, build, watch, and the
  two shelves that feed a run.

  Every number on it is measured rather than typed — the experiments come from
  the same catalogue the list is built from (`Monty.Studio.Catalog`), and the
  port counts from the module map the rewrite is held to (`Monty.ModuleMap`), so
  a page that says "173 of 357" cannot drift away from what is actually here.
  """

  use ExTbpMontyWeb, :live_view

  # The list owns the vocabulary of its own filters — which parameters narrow it
  # and what its address is — so the old bookmark is carried there using that
  # vocabulary rather than a second copy of it.
  alias ExTbpMontyWeb.ExperimentsLive
  alias Monty.ModuleMap
  alias Monty.Prerequisites
  alias Monty.Studio.Catalog

  # Monty's own tutorial: the experiment its documentation walks a first-timer
  # through, and the one this port names as the place to start.
  @first_experiment "tutorial/first_experiment"

  @impl true
  def mount(_params, _session, socket) do
    ported = ModuleMap.load() |> ModuleMap.summary()

    {:ok,
     assign(socket,
       experiments: length(Catalog.experiments()),
       first_experiment: String.split(@first_experiment, "/"),
       ported: ported.implemented,
       mapped: ported.classes,
       # Three `stat`s, not a download: the page says what is missing without
       # asking the machine for anything it has not already got.
       missing: Prerequisites.missing()
     )}
  end

  defp missing_headline(missing) do
    bundles = if length(missing) == 1, do: "bundle", else: "bundles"
    "#{length(missing)} #{bundles} a run needs are not on this machine yet."
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # `/` used to be the list, with its facets in the query string. A bookmark of
    # `/?agent=surf` is a bookmark of the list, so it is carried to where the
    # list lives now instead of landing on a page that ignores its parameters.
    if ExperimentsLive.list_params?(params) do
      {:noreply, push_navigate(socket, to: ExperimentsLive.list_url(params))}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <%!-- The studio starts before its data does, so the first thing a visitor
      needs to know is what a run would not find yet. --%>
      <section
        :if={@missing != []}
        id="welcome-missing-data"
        class="rounded-box border border-warning/40 bg-warning/10 px-4 py-3"
      >
        <p class="text-sm font-medium">
          {missing_headline(@missing)}
        </p>
        <p class="mt-1 max-w-2xl text-sm text-base-content/70">
          A run reads its object meshes and its pretrained memory from this machine, and
          neither travels in the image. Downloading them takes a while, so it is a click rather
          than a wait in front of the page — until it is done, an experiment cannot recognise
          anything.
        </p>
        <p class="mt-2 flex flex-wrap items-center gap-2">
          <.link navigate={~p"/prerequisites"} id="welcome-missing-data-link" class="btn btn-sm">
            <.icon name="hero-arrow-down-tray-mini" class="size-4" /> Prerequisites
          </.link>
          <span class="text-xs text-base-content/60">
            {Enum.map_join(@missing, ", ", & &1.title)}
          </span>
        </p>
      </section>

      <header id="welcome-hero">
        <p class="text-[11px] font-semibold tracking-[0.18em] text-primary uppercase">
          Thousand Brains Project · Elixir
        </p>
        <h1 class="mt-1 text-2xl font-semibold tracking-tight text-balance sm:text-3xl">
          Monty, running on the BEAM.
        </h1>
        <p class="mt-2 max-w-2xl text-sm text-base-content/70">
          Monty recognises objects by moving a sensor over them. This is the Thousand Brains
          Project's implementation, reimplemented module for module in Elixir — the same
          configurations, the same numbers — with a studio for looking inside a run.
        </p>

        <div class="mt-3 flex flex-wrap items-center gap-2">
          <.link navigate={~p"/experiments"} id="welcome-browse" class="btn btn-primary btn-sm">
            <.icon name="hero-beaker-mini" class="size-4" /> Browse {@experiments} experiments
          </.link>
          <.link
            navigate={~p"/experiments/#{@first_experiment}"}
            id="welcome-first"
            class="btn btn-sm"
          >
            <.icon name="hero-play-mini" class="size-4" /> Start with the tutorial
          </.link>
        </div>
      </header>

      <section id="welcome-ways" class="grid gap-2 sm:grid-cols-3">
        <.way
          id="welcome-way-experiments"
          navigate={~p"/experiments"}
          icon="hero-table-cells-mini"
          title="Pre-configured experiments"
          body="Monty's own configurations, with agent, module count, learning module and starting point."
        />
        <.way
          id="welcome-way-build"
          navigate={~p"/build"}
          icon="hero-wrench-screwdriver-mini"
          title="Build an experiment"
          body="A configuration from Monty's own options, checked before it is saved."
        />
        <.way
          id="welcome-way-runs"
          navigate={~p"/runs"}
          icon="hero-play-mini"
          title="Runs"
          body="Every run, with each module's beliefs and the sensor frames it recorded."
        />
      </section>

      <section id="welcome-also" class="grid gap-2 sm:grid-cols-2">
        <.aside_link
          id="welcome-prerequisites"
          navigate={~p"/prerequisites"}
          icon="hero-arrow-down-tray-mini"
          title="Prerequisites"
          body="What a run reads from disk, and what is still missing."
        />
        <.aside_link
          id="welcome-mcp"
          navigate={~p"/mcp/config"}
          icon="hero-code-bracket-mini"
          title="MCP"
          body="The same studio over MCP, for an editor."
        />
      </section>

      <p id="welcome-port" class="text-xs text-base-content/55">
        {@ported} of {@mapped} classes in Monty's packages have an Elixir module here; the rest
        are listed as pending.
      </p>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :body, :string, required: true

  # One of the three ways in. The whole row is the link — a card with a small
  # "Open" in the corner is a target that is easy to miss and a line of height
  # nobody needs — and the icon sits with the title instead of in a box of its
  # own.
  defp way(assigns) do
    ~H"""
    <.link
      id={@id}
      navigate={@navigate}
      class="group flex items-start gap-2.5 rounded-box border border-base-300 bg-base-100 p-3 transition hover:border-primary/40 hover:bg-base-200/40 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/50"
    >
      <.icon
        name={@icon}
        class="mt-0.5 size-4 shrink-0 text-primary transition motion-safe:group-hover:translate-x-0.5"
      />
      <span class="min-w-0">
        <span class="block text-sm font-semibold">{@title}</span>
        <span class="block text-sm text-base-content/70">{@body}</span>
      </span>
    </.link>
    """
  end

  attr :id, :string, required: true
  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :body, :string, required: true

  # The shelves beside the three ways in: real places, but not the reason
  # anybody came, so they are one line each rather than a third of the page.
  defp aside_link(assigns) do
    ~H"""
    <.link
      id={@id}
      navigate={@navigate}
      class="group flex items-start gap-2.5 rounded-box border border-base-300 bg-base-100 px-3 py-2 transition hover:border-primary/40 hover:bg-base-200/40 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/50"
    >
      <.icon name={@icon} class="mt-0.5 size-4 shrink-0 opacity-70" />
      <span class="min-w-0">
        <span class="block text-sm font-medium">{@title}</span>
        <span class="block text-sm text-base-content/65">{@body}</span>
      </span>
    </.link>
    """
  end
end
