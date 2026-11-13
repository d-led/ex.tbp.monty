defmodule ExTbpMontyWeb.SettingsLive do
  @moduledoc """
  The studio's settings, and the numbers this instance cannot be asked to change.

  The line down this page is the one worth drawing: a *setting* is read each time
  it is used, so saving it takes effect, and a *boot* value is read once when the
  application starts, so this page shows it and says where it comes from. Mixing
  the two is how a settings screen becomes a place where half the controls do
  nothing.

  Each setting shows the default it is measured against and the range that keeps
  the application sane, because "250" means nothing without knowing that 250 is
  what it already was and that one is not an option.
  """

  use ExTbpMontyWeb, :live_view

  alias Monty.Studio.{Settings, System}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign_page(socket, :info)}
  end

  @impl true
  def handle_event("save", %{"settings" => params}, socket) do
    results = Enum.map(Settings.known(), &Settings.put(&1.key, params[&1.key]))

    case Enum.reject(results, &match?({:ok, _value}, &1)) do
      [] ->
        {:noreply,
         socket
         |> put_flash(:info, "Saved. What you changed is used from the next page on.")
         |> assign_page(:info)}

      [{:error, message} | _] ->
        {:noreply,
         socket
         |> put_flash(:error, message)
         |> assign_page(:error)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section id="settings" class="space-y-4 py-2">
        <header class="space-y-1">
          <h1 class="text-lg font-semibold">Settings</h1>
          <p class="text-sm text-base-content/70">
            What this instance does while it runs. Values that are fixed when it
            boots are below, and are shown rather than offered.
          </p>
        </header>

        <.form for={@form} id="settings-form" phx-submit="save" class="space-y-3">
          <div :for={row <- Settings.known()} id={"setting-#{row.key}"} class="space-y-1">
            <label class="block text-sm font-medium" for={"settings_#{row.key}"}>
              {row.label}
            </label>
            <div class="flex items-center gap-2">
              <input
                type="number"
                id={"settings_#{row.key}"}
                name={"settings[#{row.key}]"}
                value={@form[String.to_atom(row.key)].value}
                min={row.range.first}
                max={row.range.last}
                step="1"
                class="input input-sm w-32 font-mono"
              />
              <span class="text-xs text-base-content/60">{row.unit}</span>
            </div>
            <p class="text-xs text-base-content/70">{row.help}</p>
            <p class="text-[11px] text-base-content/50">
              default {row.default} {row.unit} · between {row.range.first} and {row.range.last}
            </p>
          </div>

          <button type="submit" id="settings-save" class="btn btn-sm btn-primary">Save</button>
        </.form>

        <section id="system" class="space-y-1 border-t border-base-300 pt-3">
          <h2 class="text-sm font-semibold">This instance</h2>
          <dl class="grid grid-cols-1 gap-x-4 gap-y-1 text-xs sm:grid-cols-[12rem_1fr]">
            <div
              :for={fact <- System.facts()}
              id={"system-" <> String.replace(fact.label, " ", "-")}
              class="contents"
            >
              <dt class="text-base-content/60">{fact.label}</dt>
              <dd class="font-mono">
                {fact.value}
                <span :if={fact.note} class="ml-1 font-sans text-base-content/50">— {fact.note}</span>
              </dd>
            </div>
          </dl>
        </section>

        <%!-- Which nodes there are, and which build each one runs. A page cannot
        change any of it — the cluster is a start-up decision — so it is shown
        here rather than offered as a control. On a node that runs alone the
        list is one entry long and the sentence under it says what would make it
        more. --%>
        <section id="cluster" class="space-y-1 border-t border-base-300 pt-3">
          <h2 class="text-sm font-semibold">Nodes</h2>
          <p id="cluster-count" class="text-xs text-base-content/70">{@cluster.summary}</p>
          <ul id="cluster-node-list" class="space-y-0.5 text-xs">
            <li
              :for={entry <- @cluster.nodes}
              id={"node-" <> entry.name}
              class="flex flex-wrap items-baseline gap-2 font-mono"
            >
              <span class={["truncate", not entry.alive && "text-base-content/50"]}>{entry.name}</span>
              <span class="text-base-content/50">{entry.version || "no answer"}</span>
              <span :if={entry.self} class="badge badge-xs badge-ghost">this node</span>
            </li>
          </ul>
          <p :if={@cluster.why_not} id="cluster-why-not" class="text-xs text-base-content/60">
            {@cluster.why_not}
          </p>
        </section>
      </section>
    </Layouts.app>
    """
  end

  defp assign_page(socket, _flash_kind) do
    assign(socket,
      page_title: "Settings",
      form: to_form(Settings.form_values(), as: :settings),
      cluster: cluster()
    )
  end

  # The cluster as this page tells it: the nodes, why there is only one when there
  # is only one, and one sentence saying which case a reader is in.
  defp cluster do
    nodes = ExTbpMonty.Cluster.Nodes.snapshot()

    %{
      nodes: nodes,
      summary: summary(nodes),
      why_not: ExTbpMonty.Node.why_not()
    }
  end

  defp summary(nodes) do
    case {ExTbpMonty.Cluster.enabled?(), length(nodes)} do
      {false, _} ->
        "This instance runs alone: clustering is off, and MONTY_CLUSTER (with a node name) turns it on."

      {true, 1} ->
        "One node in this cluster — this one. A peer appears here as soon as it connects."

      {true, count} ->
        "#{count} nodes in this cluster, this one first."
    end
  end
end
