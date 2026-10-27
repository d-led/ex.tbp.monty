defmodule ExTbpMontyWeb.BuildLive do
  @moduledoc """
  Build an experiment from Monty's components, with as little input as possible.

  The form opens already complete: a name is the only thing a person has to
  provide, because everything else is inherited from a Monty experiment that
  works. Each choice is a group option Monty ships — the selects are filled from
  Monty's own `conf/` tree — so what comes out is a config Monty could run, and
  the page proves it by composing it on every change.

  The preview is the same diagram the experiment page shows, for the same
  reason: the point of choosing a sensor module and a learning module is the
  wiring you get, and that is easier to see than to infer from two dropdowns.
  """

  use ExTbpMontyWeb, :live_view

  alias Monty.Studio
  alias Monty.Studio.{Blueprint, Catalog, Drafts, Setup}

  # The groups worth exposing: they change what the experiment *is*. Monty's
  # env_interface, positioning and logging groups are plumbing the base
  # experiment already gets right.
  @choices ~w(environment monty monty/sensor_module monty/learning_module monty/connectivity monty/motor_system_config)

  @impl true
  def mount(params, _session, socket) do
    blueprint = blueprint_from(params)

    {:ok,
     socket
     |> assign(blueprint: blueprint, preview: Studio.preview(blueprint), choices: choices())
     |> assign_forms()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <header class="space-y-1.5">
        <h1 class="text-3xl font-semibold tracking-tight">Build an experiment</h1>
        <p class="max-w-3xl text-base-content/70">
          Every field is a component Monty ships. A name is enough — the rest is
          inherited from <span class="font-mono text-xs">{@blueprint.base}</span> — and the
          config below is composed from the same Hydra groups Monty runs.
        </p>
      </header>

      <.form for={@form} id="blueprint-form" phx-change="change" phx-submit="save" class="space-y-3">
        <div class="grid gap-2 sm:grid-cols-2">
          <.input field={@form[:name]} label="Name" type="text" required />
          <.input
            field={@form[:base]}
            label="Start from"
            type="select"
            options={base_options()}
            required
          />
        </div>

        <div class="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
          <.input
            :for={{group, options} <- @choices}
            field={@form[field_name(group)]}
            label={group}
            type="select"
            options={options}
          />
        </div>

        <div class="grid gap-2 sm:grid-cols-3">
          <.input field={@form[:n_train_epochs]} label="Training epochs" type="number" min="0" />
          <.input field={@form[:n_eval_epochs]} label="Evaluation epochs" type="number" min="0" />
          <.input field={@form[:seed]} label="Seed" type="number" min="0" />
        </div>

        <div class="flex flex-wrap items-center gap-2">
          <button
            id="save-blueprint"
            type="submit"
            class="btn btn-primary btn-sm"
            disabled={not saveable?(@preview)}
          >
            <.icon name="hero-bookmark-mini" class="size-4" /> Save and open
          </button>
          <span class="text-xs text-base-content/60">
            Saved as an experiment file in {Drafts.dir()}.
          </span>
        </div>
      </.form>

      <ExTbpMontyWeb.StudioComponents.findings id="blueprint-findings" findings={@preview.findings} />

      <section :if={@preview.setup} class="space-y-2">
        <h2 class="text-lg font-semibold tracking-tight">What you built</h2>
        <ExTbpMontyWeb.StudioComponents.diagram
          id="blueprint-diagram"
          diagram={@preview.diagram}
        />
        <dl class="grid gap-2 sm:grid-cols-4">
          <ExTbpMontyWeb.StudioComponents.fact
            label="sensors"
            value={Enum.map_join(@preview.setup.sensors, ", ", & &1.id)}
          />
          <ExTbpMontyWeb.StudioComponents.fact
            label="learning modules"
            value={Enum.map_join(@preview.setup.learning_modules, ", ", & &1.id)}
          />
          <ExTbpMontyWeb.StudioComponents.fact
            label="epochs"
            value={"train #{@preview.setup.epochs.train} · eval #{@preview.setup.epochs.eval}"}
          />
          <ExTbpMontyWeb.StudioComponents.fact label="seed" value={to_string(@preview.setup.seed)} />
        </dl>
      </section>

      <section class="space-y-2">
        <h2 class="text-lg font-semibold tracking-tight">The config</h2>
        <pre
          id="blueprint-config"
          phx-no-curly-interpolation
          class="max-h-80 overflow-auto rounded-box border border-base-300 bg-base-100 p-3 font-mono text-xs"
        ><code><%= @preview.yaml %></code></pre>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("change", %{"blueprint" => params}, socket) do
    blueprint = blueprint_from(params)

    {:noreply,
     socket
     |> assign(blueprint: blueprint, preview: Studio.preview(blueprint))
     |> assign_forms()}
  end

  def handle_event("save", %{"blueprint" => params}, socket) do
    blueprint = blueprint_from(params)
    preview = Studio.preview(blueprint)

    if saveable?(preview) do
      {:ok, _path} = Drafts.save(blueprint)

      {:noreply, push_navigate(socket, to: ~p"/experiments/#{String.split(blueprint.name, "/")}")}
    else
      {:noreply,
       socket
       |> assign(blueprint: blueprint, preview: preview)
       |> assign_forms()
       |> put_flash(:error, "Fix the errors above before saving.")}
    end
  end

  defp blueprint_from(params) when map_size(params) == 0,
    do: Blueprint.new(%{"name" => "my_experiment"})

  defp blueprint_from(params) do
    attrs =
      params
      # A form field name cannot carry a slash, so a group comes back from the
      # field it was rendered as.
      |> Map.new(fn {key, value} -> {group_of(key), value} end)
      |> Map.take(["name", "base" | @choices] ++ Blueprint.builder_config_keys())
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new(fn {key, value} -> {key, coerce(key, value)} end)

    blueprint =
      case Map.pop(attrs, "base") do
        {nil, attrs} -> Blueprint.new(attrs)
        {base, attrs} -> Blueprint.new(Map.put(attrs, "base", base))
      end

    Blueprint.put_name(blueprint, Map.get(attrs, "name", blueprint.name))
  end

  defp coerce(key, value) when key in ~w(n_train_epochs n_eval_epochs seed) do
    case Integer.parse(to_string(value)) do
      {number, ""} -> number
      _not_a_number -> value
    end
  end

  defp coerce(_key, value), do: value

  defp assign_forms(socket) do
    blueprint = socket.assigns.blueprint

    values =
      Map.new(@choices, fn group -> {field_name(group), blueprint.groups[group]} end)
      |> Map.merge(%{
        "name" => blueprint.name,
        "base" => blueprint.base,
        "n_train_epochs" => blueprint.config["n_train_epochs"],
        "n_eval_epochs" => blueprint.config["n_eval_epochs"],
        "seed" => blueprint.config["seed"]
      })

    assign(socket, form: to_form(values, as: :blueprint))
  end

  # A field name cannot carry a slash, and a group name is a path.
  defp field_name(group), do: String.replace(group, "/", "_")

  defp group_of(field), do: Enum.find(@choices, field, &(field_name(&1) == field))

  defp choices do
    Map.new(@choices, fn group -> {group, Catalog.options(group)} end)
  end

  defp base_options do
    templates = Enum.map(Catalog.templates(), &{&1.label <> " (" <> &1.base <> ")", &1.base})
    others = Catalog.experiments() |> Enum.map(&{&1.name, &1.name})
    templates ++ others
  end

  defp saveable?(%{setup: setup, findings: findings}) do
    setup != nil and Setup.valid?(%{setup | findings: findings})
  end
end
