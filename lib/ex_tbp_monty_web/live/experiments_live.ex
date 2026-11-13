defmodule ExTbpMontyWeb.ExperimentsLive do
  @moduledoc """
  Every experiment, a hundred of them or a thousand, arranged to be read.

  A list of experiment names is a list you scan, so this page is built for
  scanning: five facets whose counts respect each other (pick "surface agent"
  and the other counts become what is still reachable), a search box for when
  you know the name, and the values in force as chips you can click off.

  The first facet is the answer a person opens this page for: whether the
  experiment runs here at all. `Monty.Studio.Readiness` is that answer — the
  same one `Setup`'s findings refuse a run with, so a row saying "refused" and
  a page that will not start the run cannot disagree.

  The filters are this LiveView's state, not the address bar's. Choosing a tag
  re-renders the list in place — no navigation, no reload — and the text and the
  tags are both required of a row, never either. A query string is read once, on
  arrival, so a narrowed list can still be shared; nothing is written back, so
  the page a reader sees and the address they copied cannot disagree.

  The filtering itself is `Monty.Studio.Index`, which is pure; this module turns
  what a reader chose into the parameters `Index` takes.
  """

  use ExTbpMontyWeb, :live_view

  alias ExTbpMonty.Cluster.Nodes
  alias Monty.Studio.{Catalog, Drafts, Index, Readiness}

  @page_size 30
  @default_size "some"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(ExTbpMonty.PubSub, Nodes.topic())

    # The rows are streamed by `handle_params/3`, which runs before the first
    # render and is where the filters arrive. Streaming here as well would put a
    # page of unfiltered rows in the first paint and then replace it — the
    # reader sees a flash of the wrong list, and a `?ready=no` link looked like
    # it had done nothing.
    {:ok,
     socket
     |> assign(
       index: Index.build(Catalog.experiments() ++ Catalog.plugin_experiments(), labels()),
       templates: Catalog.templates(),
       drafts: Drafts.names(),
       filters: %{},
       query: "",
       size: @default_size
     )
     |> stream_configure(:experiments, dom_id: &"experiment-#{dom_id_of(&1.name)}")
     |> stream(:experiments, [])}
  end

  # Arriving from a link: the query string seeds the filters once. From then on
  # the LiveView owns them, so every click is a re-render and not a navigation.
  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(
       filters: Map.take(params, Index.facet_keys()),
       query: Map.get(params, "q", ""),
       size: Map.get(params, "size", @default_size)
     )
     |> narrow()}
  end

  # A plugin host that joins the cluster brings its experiments with it, and one
  # that leaves takes them away. The names arrive with the poll the cluster list
  # already does (`ExTbpMonty.Cluster.Nodes`), so this is a re-read of a list we
  # hold, not a request.
  @impl true
  def handle_info({:cluster_nodes, _entries}, socket) do
    {:noreply,
     socket
     |> assign(
       index: Index.build(Catalog.experiments() ++ Catalog.plugin_experiments(), labels())
     )
     |> narrow()}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle", %{"facet" => facet, "option" => option}, socket) do
    {:noreply,
     socket
     |> assign(filters: toggle(socket.assigns.filters, facet, option), size: @default_size)
     |> narrow()}
  end

  def handle_event("search", %{"q" => query}, socket) do
    {:noreply, socket |> assign(query: String.trim(query), size: @default_size) |> narrow()}
  end

  def handle_event("size", %{"size" => size}, socket) do
    {:noreply, socket |> assign(size: size) |> narrow()}
  end

  def handle_event("clear", _params, socket) do
    {:noreply, socket |> assign(filters: %{}, query: "", size: @default_size) |> narrow()}
  end

  # One place where the list is computed: whatever changed, the reader sees the
  # rows, the counts and the chips that follow from it.
  defp narrow(socket) do
    result = Index.filter(socket.assigns.index, params_of(socket.assigns))
    {entries, truncated?} = window(result.entries, socket.assigns.size)

    socket
    |> assign(
      result: result,
      truncated?: truncated?,
      truncated_when_paged?: length(result.entries) > @page_size
    )
    |> stream(:experiments, entries, reset: true)
  end

  # What each experiment is labelled with — whether it runs here, and the world
  # its config was written for — as `Monty.Studio.Readiness` answers it, through
  # the one process that composes it: the answer is cached, but the composing is
  # not, and every page open on a node that has just started used to do its own.
  defp labels, do: Monty.Studio.Readiness.Cache.survey() |> Readiness.labels()

  # The parameters `Index` takes, built from what the LiveView holds.
  defp params_of(%{filters: filters, query: query}) do
    filters
    |> Map.reject(fn {_facet, values} -> values in [nil, ""] end)
    |> Map.put("q", query)
  end

  # A value in force is released by choosing it again; the values of one facet
  # are alternatives (a surface OR a distant agent), facets are not.
  defp toggle(filters, facet, option) do
    current = values(filters, facet)

    toggled =
      if option in current, do: Enum.reject(current, &(&1 == option)), else: current ++ [option]

    Map.put(filters, facet, Enum.join(toggled, ","))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <header id="intro" class="space-y-2">
        <h1 class="text-3xl font-semibold tracking-tight">Monty experiments</h1>
        <p class="max-w-3xl text-base-content/70">
          {@result.total} configurations Monty ships. Filter by whether it runs here and in
          which world, by agent, module count, learning module or starting point, or open one to
          see what it wires together.
        </p>
      </header>

      <%!-- Three experiments Monty ships, named as Monty names them, as things
      you can pick rather than a line of text: a bordered chip is what the rest
      of the page uses for something you can choose. What each one is made of is
      on its own page, where the config is. --%>
      <section :if={not @result.filtered?} id="templates" class="space-y-1.5">
        <h2 class="text-xs font-medium tracking-wide text-base-content/50 uppercase">
          Start from
        </h2>
        <ul class="flex flex-wrap gap-2">
          <li :for={template <- @templates} id={"template-#{Path.basename(template)}"}>
            <.link
              navigate={~p"/experiments/#{segments(template)}"}
              title={"Open #{template}"}
              class="group inline-flex items-center gap-1.5 rounded-field border border-base-300 bg-base-100 px-2.5 py-1 font-mono text-xs transition hover:border-primary/50 hover:bg-base-200 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/50"
            >
              {template}
              <.icon
                name="hero-arrow-right-mini"
                class="size-3 shrink-0 text-primary opacity-60 transition motion-safe:group-hover:translate-x-0.5 group-hover:opacity-100"
              />
            </.link>
          </li>
        </ul>
      </section>

      <section :if={@drafts != []} id="drafts" class="space-y-2">
        <h2 class="text-lg font-semibold tracking-tight">Built here</h2>
        <ul class="space-y-1">
          <li :for={draft <- @drafts} id={"draft-#{draft}"}>
            <.link
              navigate={~p"/experiments/#{segments(draft)}"}
              class="font-mono text-sm link link-hover"
            >
              {draft}
            </.link>
          </li>
        </ul>
      </section>

      <%!-- Everything that narrows the list, on the list: the tags, the ones in
      force, and the box that searches it, then the rows they all act on. --%>
      <section id="results" class="space-y-3">
        <section id="facets" class="space-y-2">
          <div
            :for={facet <- @result.facets}
            id={"facet-#{facet.key}"}
            class="flex flex-wrap items-center gap-2"
          >
            <span class="w-36 shrink-0 text-xs font-medium tracking-wide text-base-content/50 uppercase">
              {facet.label}
            </span>
            <%!-- `phx-value-option`, not `phx-value-value`: a phx-value key of
            `value` collides with the element's own value and arrives empty, so
            the tag filters nothing and looks like a dead button. --%>
            <button
              :for={value <- facet.values}
              type="button"
              phx-click="toggle"
              phx-value-facet={facet.key}
              phx-value-option={value.value}
              id={"facet-#{facet.key}-#{value.value}"}
              data-active={selected?(@filters, facet.key, value.value) && "true"}
              class={[
                "inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-xs font-medium transition focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/50",
                if(selected?(@filters, facet.key, value.value),
                  do: "bg-primary text-primary-content",
                  else: "bg-base-200 text-base-content/70 hover:bg-base-300 hover:text-base-content"
                )
              ]}
            >
              {value.label}
              <span class="text-[11px] opacity-60">{value.count}</span>
            </button>
          </div>
        </section>

        <section :if={@result.filtered?} id="active-filters" class="flex flex-wrap items-center gap-2">
          <span class="text-xs text-base-content/50">filtered:</span>
          <button
            :for={chip <- chips(@result.active)}
            type="button"
            phx-click="toggle"
            phx-value-facet={chip.key}
            phx-value-option={chip.value}
            id={"chip-#{chip.key}-#{chip.value}"}
            title="release this filter"
            class="badge badge-sm gap-1 bg-primary text-primary-content"
          >
            {chip.key}: {chip.value} <.icon name="hero-x-mark-mini" class="size-3" />
          </button>
          <button
            type="button"
            phx-click="clear"
            id="clear-filters"
            class="btn btn-ghost btn-xs"
          >
            clear
          </button>
        </section>

        <form id="experiment-search" phx-change="search" class="flex flex-wrap items-center gap-2">
          <input
            type="search"
            name="q"
            value={@query}
            placeholder="Search names, agents, learning modules…"
            phx-debounce="200"
            class="input input-bordered input-sm w-full sm:w-80"
          />
        </form>
        <div class="flex flex-wrap items-baseline justify-between gap-2">
          <p id="result-count" class="text-sm text-base-content/60">
            {showing(@result.matching, @result.total)}
          </p>
          <button
            :if={@truncated?}
            type="button"
            phx-click="size"
            phx-value-size="all"
            id="show-all"
            class="btn btn-ghost btn-xs"
          >
            show all {@result.matching}
          </button>
          <button
            :if={@size == "all" and @truncated_when_paged?}
            type="button"
            phx-click="size"
            phx-value-size="some"
            id="show-fewer"
            class="btn btn-ghost btn-xs"
          >
            show fewer
          </button>
        </div>

        <%!-- A table, because these rows have columns. Four pills and no heading
        leave the reader guessing that `surf`, `1 lm`, `evidence`, `pretrained`
        are the agent, the number of learning modules, the learning-module kind
        and the memory the run starts from. The headings are the facets' own
        words, and a cell is the facet's own column, so a heading and the tag
        that filters it cannot drift apart. --%>
        <div class="overflow-x-auto rounded-box border border-base-300 bg-base-100">
          <table class="w-full text-sm">
            <thead>
              <tr class="border-b border-base-300 text-left text-xs font-medium tracking-wide text-base-content/50 uppercase">
                <th scope="col" class="py-2 pe-3 pl-3 font-medium whitespace-nowrap">Experiment</th>
                <th
                  :for={facet <- @result.facets}
                  scope="col"
                  class="py-2 pe-3 pl-0 font-medium whitespace-nowrap"
                >
                  {facet.label}
                </th>
              </tr>
            </thead>
            <tbody id="experiments" phx-update="stream" class="divide-y divide-base-300">
              <tr id="experiments-empty" class="hidden only:table-row">
                <td
                  colspan={length(@result.facets) + 1}
                  class="px-3 py-2 text-sm text-base-content/60"
                >
                  Nothing matches these filters.
                </td>
              </tr>
              <tr
                :for={{dom_id, entry} <- @streams.experiments}
                id={dom_id}
                phx-click={JS.navigate(~p"/experiments/#{segments(entry.name)}")}
                class="cursor-pointer transition-colors hover:bg-base-200/60"
              >
                <td class="py-1.5 pe-3 pl-3 align-middle">
                  <.link
                    navigate={~p"/experiments/#{segments(entry.name)}"}
                    class="font-mono text-sm link link-hover"
                  >
                    {entry.name}
                  </.link>
                </td>
                <td
                  :for={facet <- @result.facets}
                  class="py-1.5 pe-3 pl-0 align-middle whitespace-nowrap"
                >
                  <span class={badge_class(facet, entry)}>{column(entry, facet)}</span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </Layouts.app>
    """
  end

  @doc """
  Whether these parameters belong to the list rather than to a page.

  The list lived at `/` before the welcome page did, with its filters in the
  query string; `WelcomeLive` asks this to carry an old bookmark of
  `/?agent=surf` to where the list lives now.
  """
  @spec list_params?(map()) :: boolean()
  def list_params?(params) do
    Enum.any?(Index.facet_keys() ++ ["q", "size"], &Map.has_key?(params, &1))
  end

  @doc "The list at these parameters, as the string a link or a redirect needs."
  @spec list_url(map()) :: String.t()
  def list_url(params), do: patch_url(params, %{})

  @doc false
  def patch_url(params, changes) do
    query =
      params
      |> Map.take(Index.facet_keys() ++ ["q", "size"])
      |> Map.merge(changes)
      |> Enum.map(fn {key, value} -> {key, to_string(value)} end)
      |> Enum.reject(fn {key, value} -> value == "" or (key == "size" and value == "some") end)

    case query do
      [] -> ~p"/experiments"
      query -> ~p"/experiments?#{query}"
    end
  end

  defp selected?(params, facet, value), do: value in values(params, facet)

  defp values(params, facet) do
    case Map.get(params, facet) do
      nil -> []
      "" -> []
      value -> value |> to_string() |> String.split(",", trim: true)
    end
  end

  defp chips(active) do
    for {key, values} <- active, key != "q", value <- values, do: %{key: key, value: value}
  end

  defp window(entries, "all"), do: {entries, false}
  defp window(entries, _size) when length(entries) <= @page_size, do: {entries, false}
  defp window(entries, _size), do: {Enum.take(entries, @page_size), true}

  defp dom_id_of(name), do: String.replace(name, "/", "-")

  # Monty's names are paths; a glob path is built from its segments.
  defp segments(name), do: String.split(name, "/")

  # What a row shows under one of the facets' headings. The labels are
  # `Monty.Studio.Index`'s, so a column and the tag that filters it say the same
  # thing in the same words — readiness most of all, where "runs here" is the
  # whole reason the column exists.
  defp column(entry, %{key: "ready"} = facet), do: Index.label(facet.key, entry.ready)
  defp column(entry, %{key: "world"} = facet), do: Index.label(facet.key, entry.world)
  defp column(entry, %{key: "modules"}), do: modules(entry.modules)
  defp column(entry, %{key: "agent"}), do: entry.agent
  defp column(entry, %{key: "learning_module"}), do: entry.learning_module
  defp column(entry, %{key: "model"}), do: entry.model

  # A plugin's experiment is brought by the node that hosts the plugin; ours is
  # not brought by a node at all — it is a config in this release, and any node
  # may step it.
  defp column(entry, %{key: "host"}), do: entry.host || "—"

  # A count for an experiment we can read, "unknown" for one a plugin defines: the
  # number of learning modules is in a config, and a plugin's is not here.
  defp modules(count) when is_integer(count), do: "#{count} lm"
  defp modules(unknown), do: unknown

  # The readiness column is the one a reader scans, so it is the one that carries
  # a colour — pastel, because the row is information rather than a warning. The
  # other columns are facts about the config and stay neutral.
  defp badge_class(%{key: "ready"}, entry),
    do: ["badge badge-sm border", readiness_colour(entry.ready)]

  defp badge_class(_facet, _entry), do: ["badge badge-ghost badge-sm"]

  defp readiness_colour("yes"), do: "bg-emerald-100 text-emerald-900 border-emerald-200"
  defp readiness_colour("waiting"), do: "bg-amber-100 text-amber-900 border-amber-200"
  defp readiness_colour("no"), do: "bg-rose-100 text-rose-900 border-rose-200"
  defp readiness_colour("not_planned"), do: "bg-slate-100 text-slate-700 border-slate-200"
  defp readiness_colour(_unknown), do: "bg-base-200 text-base-content/70 border-base-300"

  defp showing(matching, total) when matching == total, do: "#{total} experiments"
  defp showing(matching, total), do: "#{matching} of #{total} experiments"
end
