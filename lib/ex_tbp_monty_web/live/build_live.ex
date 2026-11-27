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
  alias Monty.Studio.{Blueprint, Catalog, Drafts, Yaml}

  # The groups worth exposing: they change what the experiment *is*. Monty's
  # env_interface, positioning and logging groups are plumbing the base
  # experiment already gets right.
  @choices ~w(environment monty monty/sensor_module monty/learning_module monty/connectivity monty/motor_system_config)

  # What each group decides, in words a person who has never opened Monty's
  # conf can act on. The group's own name stays on the page beside it, because
  # that is what an expert looks for in the written config.
  @group_labels %{
    "environment" =>
      {"World and task", "The scene the agent steps in, and what it is asked to recognise."},
    "monty" => {"Agent", "How the agent is put together."},
    "monty/sensor_module" => {"Sensors", "What the agent sees with."},
    "monty/learning_module" =>
      {"Recognising", "How what it sees is matched to what it remembers."},
    "monty/connectivity" =>
      {"Wired together", "How many sensors feed how many learning modules."},
    "monty/motor_system_config" => {"Movement", "How the agent chooses where to look next."}
  }

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
          Start from an experiment that already works, then change any part below.
          What you have is drawn as you change it, and saving gives it a name you
          can run. Every field is one of Monty's own components, so the config that
          comes out is what Monty would run.
        </p>
      </header>

      <%!-- One compose per paused keystroke, not one per keystroke: the
      preview is a whole config tree, and typing a name is not a reason to build
      it forty times. --%>
      <.form
        for={@form}
        id="blueprint-form"
        phx-change="change"
        phx-debounce="400"
        phx-submit="save"
        class="space-y-3"
      >
        <div class="grid gap-2 sm:grid-cols-2">
          <.input
            field={@form[:name]}
            label="Name"
            type="text"
            required
            hint="The name you will run it as, and the file it is saved under."
          />
          <.input
            field={@form[:base]}
            label="Start from"
            type="select"
            options={base_options()}
            required
            hint="An experiment that already runs; everything below starts as its values."
          />
        </div>

        <div class="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
          <.input
            :for={{group, options} <- @choices}
            field={@form[field_name(group)]}
            label={group_label(group)}
            hint={group_hint(group)}
            type="select"
            options={options}
          />
        </div>

        <div class="grid gap-2 sm:grid-cols-3">
          <.input
            field={@form[:n_train_epochs]}
            label="Training epochs"
            type="number"
            min="0"
            hint="How many times it learns. 0 skips training."
          />
          <.input
            field={@form[:n_eval_epochs]}
            label="Evaluation epochs"
            type="number"
            min="0"
            placeholder={@preview.setup && to_string(@preview.setup.epochs.eval)}
            hint="How many rotations the memory is judged over."
          />
          <.input
            field={@form[:seed]}
            label="Seed"
            type="number"
            min="0"
            hint="The same seed replays the same run."
          />
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

      <%!-- The written config is a whole file, and the diagram and the facts
      above it are what a reader builds with: the file is what comes out. So it
      sits in a `details` — closed until asked for, the browser's own control.

      Ignored, and re-keyed by the file it holds: every keystroke in the builder
      patches this page, and a `details` the server re-sends is a `details` the
      browser closes. The id carries the file's hash, so a new draft is a new box
      with the new text while the patches of the same draft leave it alone. --%>
      <div id="blueprint-config-box">
        <details
          id={"blueprint-config-#{:erlang.phash2(@preview.yaml)}"}
          phx-update="ignore"
          class="space-y-2"
        >
          <summary class="cursor-pointer text-lg font-semibold tracking-tight">The config</summary>
          <pre
            id="blueprint-config"
            class="max-h-80 overflow-auto rounded-box border border-base-300 bg-base-100 p-3 font-mono text-xs"
          ><code>{Yaml.colour(@preview.yaml)}</code></pre>
        </details>
      </div>
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

        <%!-- Two captioned fields and one action: the name and the file each sit
        in a column of their own, captioned above the field the way `<.input>`
        captions its own, and the button lines up with their bottom edge. In one
        wrapping row they shared a line with the button, so the caption floated
        beside the picker and the three heights disagreed. --%>
        <.form
          for={@import_form}
          id="import-form"
          phx-change="validate-import"
          phx-submit="import"
          class="grid items-end gap-3 sm:grid-cols-[minmax(0,18rem)_minmax(0,22rem)_max-content]"
        >
          <.input
            field={@import_form[:name]}
            label="Name for the draft"
            type="text"
            required
            class="w-full input input-sm"
          />

          <div class="fieldset mb-2">
            <label class="block">
              <span class="label mb-1">File</span>
              <.live_file_input
                upload={@uploads.yaml}
                class="w-full file-input file-input-sm"
              />
            </label>
          </div>

          <button type="submit" class="btn btn-sm btn-primary mb-2">Import</button>
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
      # A draft that cannot be written — a full disk, a folder this process may not
      # write in — is not a crash: the form is what the page is for, and the person
      # keeps theirs. Matching `{:ok, _}` here took the LiveView down and lost it
      # (soundcheck SC603).
      case Drafts.save(blueprint) do
        {:ok, _path} ->
          {:noreply,
           push_navigate(socket, to: ~p"/experiments/#{String.split(blueprint.name, "/")}")}

        {:error, reason} ->
          {:noreply,
           socket
           |> assign(blueprint: blueprint, preview: preview)
           |> assign_forms()
           |> put_flash(:error, "Could not save the draft: #{:file.format_error(reason)}.")}
      end
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
      |> with_base_file()

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

  # A draft is an experiment file this application wrote, not one in Monty's
  # conf tree. Adjusting one reads that file, so the page shows the choices the
  # draft made rather than the template's.
  defp with_base_file(%{"base" => base} = attrs) do
    if Drafts.exists?(base), do: Map.put(attrs, "base_file", Drafts.path(base)), else: attrs
  end

  defp with_base_file(attrs), do: attrs

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
    Map.new(@choices, fn group -> {group, Catalog.options(group, conf_dir: roots())} end)
  end

  # What a builder offers is what a run page can open: the experiment sets this
  # application carries, over the groups they share, over Monty's own tree
  # (`Monty.Studio.Catalog.conf_dirs/0` — first root holding a file wins, so ours
  # replace Monty's where they name the same group option).
  defp roots, do: Catalog.conf_dirs()

  defp base_options do
    templates = Catalog.templates() |> Enum.map(&{&1, &1})
    others = Catalog.experiments(conf_dir: roots()) |> Enum.map(&{&1.name, &1.name})
    drafts = Drafts.names() |> Enum.map(&{&1, &1})

    Enum.uniq(templates ++ others ++ drafts)
  end

  defp group_label(group), do: @group_labels |> Map.fetch!(group) |> elem(0)

  defp group_hint(group) do
    {_label, hint} = Map.fetch!(@group_labels, group)
    "#{hint} Monty's group: #{group}."
  end

  # A draft is a config file, and whether this application can *run* it is a
  # different question from whether it can be written: `Setup.valid?/1` is the
  # second one, and it now refuses an experiment built from classes this port has
  # not written. Blocking the save on that would mean the builder could not write
  # a draft from any experiment Monty ships, including the refused tutorials the
  # catalogue still lists — and the draft's page is where "this cannot run here"
  # belongs, said in the same words as everywhere else. What does block it is a
  # config that would not compose.
  defp saveable?(%{setup: setup}), do: setup != nil
end
