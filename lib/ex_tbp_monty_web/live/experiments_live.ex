defmodule ExTbpMontyWeb.ExperimentsLive do
  @moduledoc """
  Every experiment, a hundred of them or a thousand, arranged to be read.

  A list of experiment names is a list you scan, so this page is built for
  scanning: four facets whose counts respect each other (pick "surface agent"
  and the other counts become what is still reachable), a search box for when
  you know the name, and active filters as chips you can click off. The whole
  state lives in the URL — `/?agent=surf&modules=5` — so a filtered view can be
  bookmarked, shared, or walked back with the browser's back button.

  The filtering itself is `Monty.Studio.Index`, which is pure; this module only
  turns parameters into pill state and pill state back into parameters.
  """

  use ExTbpMontyWeb, :live_view

  alias Monty.Studio.{Catalog, Drafts, Index}

  @page_size 30

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       index: Index.build(Catalog.experiments()),
       templates: Catalog.templates(),
       drafts: Drafts.names()
     )
     |> stream_configure(:experiments, dom_id: &"experiment-#{dom_id_of(&1.name)}")
     |> stream(:experiments, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    result = Index.filter(socket.assigns.index, params)
    size = Map.get(params, "size", "some")
    {entries, truncated?} = window(result.entries, size)

    {:noreply,
     socket
     |> assign(
       result: result,
       params: params,
       size: size,
       truncated?: truncated?,
       truncated_when_paged?: length(result.entries) > @page_size
     )
     |> stream(:experiments, entries, reset: true)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <header class="space-y-2">
        <h1 class="text-3xl font-semibold tracking-tight">Monty experiments</h1>
        <p class="max-w-3xl text-base-content/70">
          {@result.total} experiments, each one of Monty's own configs. Narrow the list by
          agent, module count, learning module or starting point — or open one to see how it
          is wired before it runs.
        </p>

        <form id="experiment-search" phx-change="search" class="flex flex-wrap items-center gap-2">
          <input
            type="search"
            name="q"
            value={@params["q"]}
            placeholder="Search names and components…"
            phx-debounce="200"
            class="input input-bordered input-sm w-full sm:w-80"
          />
          <.link navigate={~p"/build"} class="btn btn-primary btn-sm">
            <.icon name="hero-wrench-screwdriver-mini" class="size-4" /> Build
          </.link>
        </form>
      </header>

      <section id="facets" class="space-y-2">
        <div
          :for={facet <- @result.facets}
          id={"facet-#{facet.key}"}
          class="flex flex-wrap items-baseline gap-2"
        >
          <span class="w-36 shrink-0 text-xs font-medium tracking-wide text-base-content/50 uppercase">
            {facet.label}
          </span>
          <button
            :for={value <- facet.values}
            id={"facet-#{facet.key}-#{value.value}"}
            phx-click="toggle"
            phx-value-facet={facet.key}
            phx-value-value={value.value}
            class={[
              "btn btn-xs gap-1.5",
              if(selected?(@params, facet.key, value.value), do: "btn-primary", else: "btn-ghost")
            ]}
          >
            {value.label}
            <span class="opacity-50">{value.count}</span>
          </button>
        </div>
      </section>

      <section :if={@result.filtered?} id="active-filters" class="flex flex-wrap items-center gap-2">
        <span class="text-xs text-base-content/50">filtered:</span>
        <button
          :for={chip <- chips(@result.active)}
          id={"chip-#{chip.key}-#{chip.value}"}
          phx-click="toggle"
          phx-value-facet={chip.key}
          phx-value-value={chip.value}
          class="badge badge-primary badge-sm gap-1"
        >
          {chip.key}: {chip.value} <.icon name="hero-x-mark-mini" class="size-3" />
        </button>
        <.link patch={~p"/"} id="clear-filters" class="btn btn-ghost btn-xs">clear</.link>
      </section>

      <section class="space-y-2">
        <div class="flex flex-wrap items-baseline justify-between gap-2">
          <p id="result-count" class="text-sm text-base-content/60">
            {showing(@result.matching, @result.total)}
          </p>
          <.link
            :if={@truncated?}
            patch={patch_url(@params, %{"size" => "all"})}
            id="show-all"
            class="btn btn-ghost btn-xs"
          >
            show all {@result.matching}
          </.link>
          <.link
            :if={@size == "all" and @truncated_when_paged?}
            patch={patch_url(@params, %{"size" => "some"})}
            id="show-fewer"
            class="btn btn-ghost btn-xs"
          >
            show fewer
          </.link>
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

      <section :if={not @result.filtered?} class="space-y-2">
        <h2 class="text-lg font-semibold tracking-tight">Start from</h2>
        <div class="grid gap-3 sm:grid-cols-3">
          <article
            :for={template <- @templates}
            id={"template-#{Path.basename(template.base)}"}
            class="flex flex-col gap-1.5 rounded-box border border-base-300 bg-base-100 p-3"
          >
            <h3 class="font-semibold">{template.label}</h3>
            <p class="text-sm text-base-content/70">{template.why}</p>
            <p class="mt-auto font-mono text-xs text-base-content/50">{template.base}</p>
            <.link
              navigate={~p"/experiments/#{segments(template.base)}"}
              class="btn btn-sm btn-outline"
            >
              Open
            </.link>
          </article>
        </div>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("search", %{"q" => query}, socket) do
    {:noreply, patch(socket, %{"q" => String.trim(query)})}
  end

  def handle_event("toggle", %{"facet" => facet, "value" => value}, socket) do
    current = values(socket.assigns.params, facet)

    toggled =
      if value in current, do: Enum.reject(current, &(&1 == value)), else: current ++ [value]

    {:noreply, patch(socket, %{facet => Enum.join(toggled, ",")})}
  end

  # Narrowing a list and being shown the first page of it is right, so a new
  # filter resets the window unless the window is what changed.
  defp patch(socket, changes) do
    changes =
      if Map.has_key?(changes, "size"), do: changes, else: Map.put(changes, "size", "some")

    push_patch(socket, to: patch_url(socket.assigns.params, changes))
  end

  @doc false
  def patch_url(params, changes) do
    query =
      params
      |> Map.take(Index.facet_keys() ++ ["q", "size"])
      |> Map.merge(changes)
      |> Enum.map(fn {key, value} -> {key, to_string(value)} end)
      |> Enum.reject(fn {key, value} -> value == "" or (key == "size" and value == "some") end)

    case query do
      [] -> ~p"/"
      query -> ~p"/?#{query}"
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
