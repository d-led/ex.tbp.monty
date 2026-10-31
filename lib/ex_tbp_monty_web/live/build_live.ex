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
     |> assign_forms()
     |> assign(import_form: to_form(%{"name" => ""}, as: :import))
     |> allow_upload(:yaml,
       # `accept` is not asked to do the checking: Phoenix validates that list
       # against the MIME table, where `.yaml` is not a known extension, so the
       # file name is checked here instead — one error message, in one place.
       accept: :any,
       max_entries: 1,
       max_file_size: 1_000_000
     )}
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
      <%!-- The other direction: a file from elsewhere becomes a draft here. It is
      composed before it is saved, so a file that is not a Hydra config is
      refused instead of becoming a draft nobody can open. --%>
      <section id="import" class="space-y-2 border-t border-base-300 pt-4">
        <h2 class="text-lg font-semibold tracking-tight">Import an experiment file</h2>
        <p class="max-w-3xl text-sm text-base-content/70">
          A config from another machine, or one of Monty's own that you saved and
          changed. It is composed first; anything that would stop it running is
          reported on the experiment's page.
        </p>

        <.form
          for={@import_form}
          id="import-form"
          phx-change="validate-import"
          phx-submit="import"
          class="flex flex-wrap items-end gap-2"
        >
          <.input field={@import_form[:name]} label="Name for the draft" type="text" required />
          <div class="space-y-1">
            <span class="text-sm font-medium">File</span>
            <.live_file_input upload={@uploads.yaml} class="file-input file-input-sm" />
          </div>
          <button type="submit" class="btn btn-primary btn-sm">Import</button>
        </.form>

        <p :for={error <- upload_errors(@uploads.yaml)} class="text-sm text-error">
          {upload_error_message(error)}
        </p>
        <p :for={entry <- @uploads.yaml.entries} class="text-xs text-base-content/60">
          {entry.client_name}
        </p>
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

  @impl true
  def handle_event("validate-import", _params, socket), do: {:noreply, socket}

  def handle_event("import", %{"import" => %{"name" => name}}, socket) do
    case read_upload(socket) do
      {:ok, text, socket} ->
        case Drafts.import(name, text) do
          {:ok, imported} ->
            {:noreply,
             push_navigate(socket,
               to: ~p"/experiments/#{String.split(imported.name, "/")}"
             )}

          {:error, message} ->
            {:noreply, put_flash(socket, :error, message)}
        end

      {:error, :no_file, socket} ->
        {:noreply, put_flash(socket, :error, "Choose a .yaml file to import.")}

      {:error, :not_yaml, socket} ->
        {:noreply, put_flash(socket, :error, "That file is not a .yaml file.")}
    end
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

  # `path` is the temporary file Phoenix wrote for this upload, not anything the
  # browser named; the client's file name is only classified, never opened.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_upload(socket) do
    case consume_uploaded_entries(socket, :yaml, fn %{path: path}, entry ->
           {:ok, {entry.client_name, File.read!(path)}}
         end) do
      [{file_name, text}] -> classify(file_name, text, socket)
      [] -> {:error, :no_file, socket}
    end
  end

  defp classify(file_name, text, socket) do
    if String.ends_with?(String.downcase(file_name), [".yaml", ".yml"]),
      do: {:ok, text, socket},
      else: {:error, :not_yaml, socket}
  end

  defp upload_error_message(:too_large), do: "That file is larger than 1 MB."

  defp upload_error_message(error) do
    "The file cannot be uploaded: #{error}"
  end

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
