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

  alias ExTbpMonty.Cluster.Capabilities
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

        <%!-- Which nodes there are, which build each one runs, and what each
        one can do — the nodes of this application and the nodes that bring
        plugins, as two chapters. A page cannot change any of it — the cluster is
        a start-up decision — so it is shown here rather than offered as a
        control. The list itself is a component because it changes while the page
        is open: a peer joining or leaving moves it without anybody reloading.
        What stays here is read once, at boot. --%>
        <section id="cluster" class="space-y-1 border-t border-base-300 pt-3">
          <h2 class="text-sm font-semibold">Cluster</h2>
          <.live_component module={ExTbpMontyWeb.ClusterNodes} id="cluster-nodes" />
          <p :if={@cluster.why_not} id="cluster-why-not" class="text-xs text-base-content/60">
            {@cluster.why_not}
          </p>
          <p id="cluster-capability-source" class="text-xs text-base-content/50">
            {@cluster.capability_source}
          </p>
          <p id="cluster-cookie" class="text-xs text-base-content/60">
            cookie: {@cluster.cookie}
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

  # What this page says about the cluster that is fixed at boot: whether this node
  # could be one at all, where its cookie came from, and where its own tags came
  # from. The list of nodes is not here — it changes while the page is open, and
  # `ExTbpMontyWeb.ClusterNodes` is the component that follows it.
  defp cluster do
    %{
      capability_source: capability_source(),
      why_not: ExTbpMonty.Node.why_not(),
      cookie: ExTbpMonty.Node.cookie_source()
    }
  end

  # Where the tags came from, which is the part a reader can act on when a tag
  # they expected is not in the list above: the built-in one is not a setting,
  # and the rest arrive through one variable that has to be spelled exactly.
  defp capability_source do
    case Capabilities.from_environment() do
      [] ->
        "every node advertises monty; MONTY_CAPABILITIES adds what a machine has"

      tags ->
        "this node adds " <> Enum.join(tags, ", ") <> " through MONTY_CAPABILITIES"
    end
  end
end
