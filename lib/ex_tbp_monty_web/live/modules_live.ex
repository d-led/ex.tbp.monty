defmodule ExTbpMontyWeb.ModulesLive do
  @moduledoc """
  Monty's classes and this application's, side by side — the module map as a
  page rather than a table in a document.

  Every row is generated (`lib/monty/module_map/data.ex`, written by `mix
  monty.module_map.gen`), so the three columns a reader checks — the Monty
  class, the Elixir module the naming rule gives it, and whether it exists — are
  the same facts `mix monty.module_map.verify` asserts. The fourth column is the
  one the map carries beyond the rule: what runs in its place, where the runtime
  or the carried world stands in for a class Monty has and this application does
  not. It is empty for a class nothing replaces, and a config naming one of those
  is refused rather than faked.

  Both filters are URL state (`?q=…&status=…`): a reader who has narrowed the
  table to "what still has to be written" can send that view to somebody.
  """

  use ExTbpMontyWeb, :live_view

  alias ExTbpMonty.BuildInfo
  alias Monty.ModuleMap
  alias Monty.ModuleMap.Table

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       rows: Table.rows(repo: repo(), revision: revision()),
       summary: ModuleMap.summary(ModuleMap.load()),
       sources: ModuleMap.sources(),
       status: :all,
       query: ""
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    query = params["q"] || ""
    status = Table.status(params["status"])

    rows = Table.filter(socket.assigns.rows, query, status)

    {:noreply,
     socket
     |> assign(query: query, status: status, shown: length(rows))
     |> stream(:modules, rows, reset: true)}
  end

  # A keystroke re-filters the table by rewriting the query string, so the URL
  # always says what is on screen. The slow work — reading the map, building
  # 360 rows — happened once, in `mount/3`.
  @impl true
  def handle_event("filter", params, socket) do
    {:noreply, push_patch(socket, to: modules_path(params["q"] || "", socket.assigns.status))}
  end

  def handle_event("status", %{"status" => status}, socket) do
    {:noreply, push_patch(socket, to: modules_path(socket.assigns.query, Table.status(status)))}
  end

  defp modules_path(query, status) do
    params =
      [{"q", String.trim(query)}, {"status", if(status == :all, do: nil, else: status)}]
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)

    case params do
      [] -> ~p"/modules"
      params -> to_string(~p"/modules") <> "?" <> URI.encode_query(params)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="mx-auto max-w-7xl px-4 py-6 sm:px-6 lg:px-8">
        <.header>
          What of Monty is written here
          <:subtitle>
            Every class the packages of Monty name, and the module this application gives
            it. {@summary.implemented} of {@summary.classes} are written; the rest are
            named by a config that cannot run yet, unless the fourth column says what
            replaces them.
          </:subtitle>
        </.header>

        <div class="mt-4 flex flex-wrap items-baseline gap-x-4 gap-y-1 font-mono text-xs text-base-content/60">
          <.package_count
            :for={{package, count} <- Enum.sort(@summary.by_package)}
            package={package}
            count={count}
            commit={commit_of(assigns, package)}
          />
        </div>

        <form id="modules-filter" phx-change="filter" class="mt-4 flex flex-wrap items-end gap-3">
          <label class="flex-1 min-w-64">
            <span class="block pb-1 text-xs text-base-content/60">any words from the row</span>
            <input
              type="search"
              name="q"
              value={@query}
              placeholder="eg. graph_matching planned"
              autocomplete="off"
              class="input input-sm w-full font-mono"
            />
          </label>

          <div id="modules-status" class="flex items-center gap-1" role="group" aria-label="status">
            <button
              :for={status <- [:all | Table.statuses()]}
              type="button"
              phx-click="status"
              phx-value-status={status}
              class={[
                "rounded-field border px-2 py-1 font-mono text-[11px] transition-colors",
                @status == status && "border-primary bg-primary text-primary-content",
                @status != status &&
                  "border-base-300 text-base-content/70 hover:border-primary hover:text-primary"
              ]}
              aria-pressed={to_string(@status == status)}
            >
              {status} {count_of(assigns, status)}
            </button>
          </div>
        </form>

        <p class="mt-3 font-mono text-xs text-base-content/60" id="modules-shown">
          {@shown} of {@summary.classes} classes
        </p>

        <div class="mt-2 overflow-x-auto rounded-field border border-base-300">
          <table class="w-full table-fixed text-left text-sm" id="modules-table">
            <colgroup>
              <col class="w-[26%]" />
              <col class="w-[34%]" />
              <col class="w-[10%]" />
              <col class="w-[30%]" />
            </colgroup>
            <thead class="bg-base-200/60 font-mono text-[11px] uppercase tracking-wide text-base-content/60">
              <tr>
                <th class="px-3 py-2">Monty Class</th>
                <th class="px-3 py-2">Elixir Module</th>
                <th class="px-3 py-2">Status</th>
                <th class="px-3 py-2">Stand-In Elixir Module</th>
              </tr>
            </thead>
            <tbody id="modules" phx-update="stream" class="divide-y divide-base-200">
              <tr :for={{id, row} <- @streams.modules} id={id} class="align-top hover:bg-base-200/40">
                <.monty_cell row={row} />
                <.elixir_cell row={row} />
                <td class="px-3 py-2">
                  <.status_badge status={row.status} />
                  <p :if={row.reason} class="pt-1 text-xs text-base-content/60">{row.reason}</p>
                </td>
                <td class="px-3 py-2 font-mono text-[11px] break-words">
                  <p :if={row.stand_ins == []} class="text-base-content/40">—</p>
                  <p :for={stand_in <- row.stand_ins} class="pb-0.5" title={stand_in.why}>
                    <.link
                      :if={stand_in.url}
                      href={stand_in.url}
                      target="_blank"
                      rel="noopener noreferrer"
                      class="underline decoration-base-300 decoration-1 underline-offset-2 hover:text-primary"
                    >
                      {Table.describe(stand_in)}
                    </.link>
                    <span :if={is_nil(stand_in.url)}>{Table.describe(stand_in)}</span>
                  </p>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :row, :map, required: true

  defp monty_cell(assigns) do
    ~H"""
    <td class="px-3 py-2 font-mono text-xs break-words">
      <span class="rounded border border-base-300 bg-base-200 px-1 py-0.5 text-[10px] uppercase text-base-content/70">
        {@row.package}
      </span>
      <.link
        :if={@row.python_url}
        href={@row.python_url}
        target="_blank"
        rel="noopener noreferrer"
        class="pl-1 font-semibold underline decoration-base-300 decoration-1 underline-offset-2 hover:text-primary"
      >
        {@row.class}
      </.link>
      <span :if={is_nil(@row.python_url)} class="pl-1 font-semibold">{@row.class}</span>
      <p class="text-[11px] text-base-content/50">{@row.file}</p>
    </td>
    """
  end

  attr :row, :map, required: true

  defp elixir_cell(assigns) do
    ~H"""
    <td class="px-3 py-2 font-mono text-[11px] break-words">
      <%!-- Every module is a link, including one that is only named: the name is
      the contract, and the file it will live in follows from it. A written
      module reads at full strength; a planned one is dimmer, which is the only
      difference a reader has to be able to see. --%>
      <.link
        :if={@row.elixir_url}
        href={@row.elixir_url}
        target="_blank"
        rel="noopener noreferrer"
        class={[
          "underline decoration-base-300 decoration-1 underline-offset-2 hover:text-primary",
          @row.status != :implemented && "text-base-content/50"
        ]}
      >
        {@row.elixir}
      </.link>
      <span :if={is_nil(@row.elixir_url)} class="text-base-content/40">{@row.elixir}</span>
    </td>
    """
  end

  attr :status, :atom, required: true

  defp status_badge(assigns) do
    ~H"""
    <span
      class={[
        "rounded border px-1.5 py-0.5 font-mono text-[10px] font-semibold uppercase tracking-wide",
        @status == :implemented && "border-success/60 bg-success text-success-content",
        @status == :planned && "border-warning/60 bg-warning text-warning-content",
        @status == :excluded && "border-base-300 bg-base-300 text-base-content/70"
      ]}
      data-status={@status}
    >
      {@status}
    </span>
    """
  end

  attr :package, :string, required: true
  attr :count, :integer, required: true
  attr :commit, :string, default: nil

  defp package_count(assigns) do
    ~H"""
    <span>
      {@package}: {@count} classes<span :if={@commit}> at <span class="text-base-content/40">{String.slice(
        @commit,
        0,
        7
      )}</span></span>
    </span>
    """
  end

  defp commit_of(assigns, package) do
    case Map.get(assigns.sources, package) do
      %{"commit" => commit} -> commit
      _none -> nil
    end
  end

  # What each status filter would show, so the number beside it is the answer and
  # not a click away.
  defp count_of(assigns, :all), do: assigns.summary.classes
  defp count_of(assigns, status), do: Map.get(assigns.summary, status, 0)

  defp repo do
    :ex_tbp_monty |> Application.get_env(:source, []) |> Keyword.get(:repo)
  end

  # Which commit our files are linked at: the release's own, when it was built
  # from one, and `main` for a checkout that says only `dev`.
  defp revision, do: BuildInfo.info().revision
end
