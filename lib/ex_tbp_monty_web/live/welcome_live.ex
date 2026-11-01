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
  alias Monty.Studio.Catalog
  alias Monty.ModuleMap

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
       mapped: ported.classes
     )}
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
      <header id="welcome-hero" class="pt-2">
        <p class="text-xs font-semibold tracking-[0.18em] text-primary uppercase">
          Thousand Brains Project · Elixir
        </p>
        <h1 class="mt-2 max-w-2xl text-3xl font-semibold tracking-tight text-balance sm:text-4xl">
          Monty, running on the BEAM.
        </h1>
        <p class="mt-3 max-w-2xl text-base text-base-content/75">
          Monty learns an object by moving a sensor over it: it carries many hypotheses
          about what it is touching, gathers evidence for each, and decides when one has
          won. This is the Thousand Brains Project's reference implementation,
          reimplemented module for module in Elixir — the same configurations, the same
          numbers, and a studio for looking inside a run.
        </p>

        <div class="mt-5 flex flex-wrap items-center gap-2">
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

      <section id="welcome-ways" class="grid gap-3 sm:grid-cols-3">
        <.way
          id="welcome-way-experiments"
          navigate={~p"/experiments"}
          icon="hero-table-cells-mini"
          title="Read what ships"
          body="Monty's own configurations, narrowed by agent, module count, learning module and starting point — and the wiring of each one before anything runs."
        />
        <.way
          id="welcome-way-build"
          navigate={~p"/build"}
          icon="hero-wrench-screwdriver-mini"
          title="Compose a config"
          body="Build one from Monty's own options. The studio applies the checks Monty would make, so a config here composes against Monty's tree unchanged."
        />
        <.way
          id="welcome-way-runs"
          navigate={~p"/runs"}
          icon="hero-play-mini"
          title="Watch it run"
          body="What each module believes, step by step, with the frames its sensors actually received — and every run this instance has done."
        />
      </section>

      <section id="welcome-also" class="grid gap-3 sm:grid-cols-2">
        <.aside_link
          id="welcome-prerequisites"
          navigate={~p"/prerequisites"}
          icon="hero-arrow-down-tray-mini"
          title="Data and models"
          body="The config tree and pretrained libraries a run reads, what is already here, and what still has to be downloaded."
        />
        <.aside_link
          id="welcome-mcp"
          navigate={~p"/mcp/config"}
          icon="hero-code-bracket-mini"
          title="Ask from an editor"
          body="The same studio over MCP: the endpoint, and the configuration to paste into an editor."
        />
      </section>

      <p id="welcome-port" class="text-xs text-base-content/55">
        {@ported} of {@mapped} classes in Monty's packages have an Elixir module here. The
        rest are mapped, named, and listed as pending — nothing is guessed at.
      </p>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :body, :string, required: true

  # One of the three ways in. A whole card is the link: on a phone the pointer is
  # a thumb, and a card with a small "Open" in the corner is a target that is
  # easy to miss.
  defp way(assigns) do
    ~H"""
    <.link
      id={@id}
      navigate={@navigate}
      class="group flex flex-col gap-1 rounded-box border border-base-300 bg-base-100 p-4 transition hover:border-primary/40 hover:bg-base-200/40 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/50"
    >
      <span class="grid size-8 place-items-center rounded-field bg-primary/10 text-primary">
        <.icon name={@icon} class="size-4" />
      </span>
      <h2 class="mt-1 font-semibold">{@title}</h2>
      <p class="text-sm text-base-content/70">{@body}</p>
      <span class="mt-auto inline-flex items-center gap-1 pt-2 text-sm font-medium text-primary">
        Open
        <.icon
          name="hero-arrow-right-mini"
          class="size-3.5 transition motion-safe:group-hover:translate-x-0.5"
        />
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
      class="group flex items-start gap-3 rounded-box border border-base-300 bg-base-100 px-4 py-3 transition hover:border-primary/40 hover:bg-base-200/40 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/50"
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
