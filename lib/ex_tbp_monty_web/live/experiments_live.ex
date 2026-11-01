defmodule ExTbpMontyWeb.ExperimentsLive do
  @moduledoc """
  Every experiment, a hundred of them or a thousand, arranged to be read.

  A list of experiment names is a list you scan, so this page is built for
  scanning: four facets whose counts respect each other (pick "surface agent"
  and the other counts become what is still reachable), a search box for when
  you know the name, and the values in force as chips you can click off.

  The filters are this LiveView's state, not the address bar's. Choosing a tag
  re-renders the list in place — no navigation, no reload — and the text and the
  tags are both required of a row, never either. A query string is read once, on
  arrival, so a narrowed list can still be shared; nothing is written back, so
  the page a reader sees and the address they copied cannot disagree.

  The filtering itself is `Monty.Studio.Index`, which is pure; this module turns
  what a reader chose into the parameters `Index` takes.
  """

  use ExTbpMontyWeb, :live_view

  alias Monty.Studio.{Catalog, Drafts, Index}

  @page_size 30
  @default_size "some"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       index: Index.build(Catalog.experiments()),
       templates: Catalog.templates(),
       drafts: Drafts.names(),
       filters: %{},
       query: "",
       size: @default_size
     )
     |> stream_configure(:experiments, dom_id: &"experiment-#{dom_id_of(&1.name)}")
     |> stream(:experiments, [])
     |> narrow()}
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
          {@result.total} configurations Monty ships. Filter by agent, module count, learning
          module or starting point, or open one to see what it wires together.
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
                class="size-3 shrink-0 text-primary-content opacity-60 transition motion-safe:group-hover:translate-x-0.5 group-hover:opacity-100"
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

        <ul
          id="experiments"
          phx-update="stream"
          class="divide-y divide-base-300 overflow-hidden rounded-box border border-base-300 bg-base-100"
        >
          <li id="experiments-empty" class="hidden only:block px-3 py-2 text-sm text-base-content/60">
            Nothing matches these filters.
          </li>
          <li
            :for={{dom_id, entry} <- @streams.experiments}
            id={dom_id}
            class="flex flex-wrap items-center gap-x-2 gap-y-0.5 px-3 py-1.5"
          >
            <.link
              navigate={~p"/experiments/#{segments(entry.name)}"}
              class="font-mono text-sm link link-hover"
            >
              {entry.name}
            </.link>
            <span class="ms-auto flex flex-wrap items-center gap-1.5">
              <span class="badge badge-ghost badge-sm">{entry.agent}</span>
              <span class="badge badge-ghost badge-sm">{entry.modules} lm</span>
              <span class="badge badge-ghost badge-sm">{entry.learning_module}</span>
              <span class="badge badge-ghost badge-sm">{entry.model}</span>
            </span>
          </li>
        </ul>
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

  defp showing(matching, total) when matching == total, do: "#{total} experiments"
  defp showing(matching, total), do: "#{matching} of #{total} experiments"
end
