defmodule ExTbpMontyWeb.CadLive do
  @moduledoc """
  A CAD part: bring one, and the page says what makes it a run.

  The promise this page keeps is the one a desktop user needs — no shell, no
  YAML. A STEP file is posted to the form, `Monty.Studio.Cad.Parts` puts it where
  the worlds look and quiddity says what it is, and one click turns it into an
  experiment (`Monty.Studio.Cad.Generate`). The two clicks that follow are links,
  not instructions to type: `/prerequisites` makes the memory and the meshes, and
  the experiment's own page runs it.

  What the page does *not* do is describe every part on every mount: the
  recognition costs about sixty milliseconds a part, and a list is not worth a
  quarter of a second of everyone's page load. A part is described when a person
  asks about it, or when it has just arrived and the next question is "is this
  the part I meant?".
  """

  use ExTbpMontyWeb, :live_view

  alias Monty.Studio.Cad.{Generate, Parts}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(parts: listed(), generated: nil)
     |> assign(form: to_form(%{"name" => ""}, as: :bring))
     |> allow_upload(:step,
       # `accept` is not asked to do the checking: Phoenix validates that list
       # against the MIME table, where `.step` is not a known extension (the same
       # reason `BuildLive`'s import does it this way). The file name is checked at
       # the boundary, and the bytes are checked by the kernel.
       accept: :any,
       max_entries: 1,
       max_file_size: 20_000_000
     )}
  end

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("look", %{"part" => name}, socket) do
    {:noreply, describe(socket, name)}
  end

  def handle_event("bring", %{"bring" => %{"name" => name}}, socket) do
    case uploaded(socket) do
      {:ok, bytes} ->
        case Parts.install(String.trim(name), bytes) do
          {:ok, part} ->
            {:noreply,
             socket
             |> assign(:parts, listed())
             |> describe(part.name)
             |> put_flash(:info, "#{part.name} is here: #{part.path}.")}

          {:error, sentence} ->
            {:noreply, put_flash(socket, :error, sentence)}
        end

      :no_file ->
        {:noreply, put_flash(socket, :error, "Choose a .step or .stp file to bring.")}

      :not_a_step ->
        {:noreply, put_flash(socket, :error, "A part is a .step or .stp file.")}
    end
  end

  def handle_event("generate", %{"part" => name}, socket) do
    case Generate.generate(name) do
      {:ok, generated} ->
        {:noreply,
         socket
         |> assign(:generated, Map.put(generated, :part, name))
         |> update_part(name, &%{&1 | experiment: generated.experiment})
         |> put_flash(:info, "#{generated.experiment} is written.")}

      {:error, sentence} ->
        {:noreply, put_flash(socket, :error, sentence)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section class="mx-auto max-w-4xl space-y-6">
        <header class="space-y-2">
          <h1 class="text-3xl font-semibold tracking-tight">A CAD part</h1>
          <p class="text-base-content/70">
            Bring a STEP file, and the studio writes the two things a run reads from it:
            a memory taught on the part's own geometry, and the part as a mesh to
            recognise. Bring one below; the rest is two clicks.
          </p>
        </header>

        <article class="rounded-box border border-base-300 bg-base-100 p-4">
          <h2 class="font-semibold">1. Bring a part</h2>
          <p class="text-sm text-base-content/70">
            A part file is where a memory and a run both come from, so its name stays with
            it: the objects, the memory and the experiment are all named after it.
          </p>

          <.form
            for={@form}
            id="cad-bring-form"
            phx-change="validate"
            phx-submit="bring"
            class="mt-3 space-y-3"
          >
            <.input
              field={@form[:name]}
              label="Name"
              type="text"
              required
              hint="Letters, digits, `_` and `-` — it becomes the part's directory and its memory's name."
            />
            <div class="space-y-1">
              <.live_file_input upload={@uploads.step} class="file-input" />
              <p :for={error <- upload_errors(@uploads.step)} class="text-sm text-error">
                {upload_error(error)}
              </p>
            </div>
            <button type="submit" id="cad-bring" class="btn btn-sm btn-primary">Bring it</button>
          </.form>
        </article>

        <article id="cad-parts" class="space-y-3">
          <h2 class="font-semibold">The parts this machine has</h2>

          <div
            :for={entry <- @parts}
            id={"part-#{entry.part.name}"}
            class="rounded-box border border-base-300 bg-base-100 p-4 space-y-2"
          >
            <div class="flex flex-wrap items-baseline justify-between gap-2">
              <h3 class="font-semibold">{entry.part.name}</h3>
              <p class="font-mono text-xs text-base-content/60">
                {size_label(entry.part.bytes)}
              </p>
            </div>
            <p class="font-mono text-xs break-all text-base-content/60">{entry.part.path}</p>

            <p :if={entry.description} id={"about-#{entry.part.name}"} class="text-sm">
              {extent_label(entry.description)} · {entry.description.faces} faces · {features_label(
                entry.description.features
              )}
            </p>
            <p :if={entry.error} id={"about-#{entry.part.name}"} class="text-sm text-warning">
              {entry.error}
            </p>

            <div class="flex flex-wrap gap-2">
              <button
                :if={entry.description == nil}
                id={"look-#{entry.part.name}"}
                phx-click="look"
                phx-value-part={entry.part.name}
                class="btn btn-sm btn-ghost"
              >
                Look at it
              </button>
              <.link
                :if={entry.experiment}
                id={"run-#{entry.part.name}"}
                navigate={~p"/experiments/#{String.split(entry.experiment, "/")}"}
                class="btn btn-sm"
              >
                Open its run
              </.link>
              <button
                :if={entry.experiment == nil}
                id={"generate-#{entry.part.name}"}
                phx-click="generate"
                phx-value-part={entry.part.name}
                class="btn btn-sm btn-primary"
              >
                Make it a run
              </button>
            </div>
          </div>
        </article>

        <article
          :if={@generated}
          id="generated"
          class="rounded-box border border-base-300 bg-base-100 p-4 space-y-2"
        >
          <h2 class="font-semibold">{@generated.experiment} is written</h2>
          <p class="text-sm text-base-content/70">
            It steps {@generated.part} and loads the memory <code>{(@generated).part}_part</code>,
            which does not exist yet. Two clicks, in this order:
          </p>
          <ol class="list-decimal space-y-1 pl-5 text-sm">
            <li>
              <.link navigate={~p"/prerequisites"} class="link">Make its memory and meshes</.link>
              — the row “CAD part memories and meshes”, then Make. It teaches
              <code>{@generated.part}_part</code>
              from the STEP file and writes the part's mesh.
            </li>
            <li>
              <.link
                navigate={~p"/experiments/#{String.split(@generated.experiment, "/")}"}
                class="link"
              >
                Run it
              </.link>
              — the experiment's own page, with its episodes, its evidence and its pictures.
            </li>
          </ol>
        </article>
      </section>
    </Layouts.app>
    """
  end

  # -- the parts on the page -----------------------------------------------

  defp listed do
    Enum.map(Parts.list(), fn part ->
      %{
        part: part,
        description: nil,
        error: nil,
        experiment: Generate.experiment_for(part.name)
      }
    end)
  end

  defp describe(socket, name) do
    case Parts.describe(name) do
      {:ok, description} ->
        update_part(socket, name, &%{&1 | description: description, error: nil})

      {:error, sentence} ->
        update_part(socket, name, &%{&1 | error: sentence})
    end
  end

  defp update_part(socket, name, change) do
    assign(
      socket,
      :parts,
      Enum.map(socket.assigns.parts, fn entry ->
        if entry.part.name == name, do: change.(entry), else: entry
      end)
    )
  end

  # sobelow_skip ["Traversal.FileModule"]
  # The path is Phoenix's own: the temporary file the upload was written to
  # before this process was asked about it.
  defp uploaded(socket) do
    case consume_uploaded_entries(socket, :step, fn %{path: path}, entry ->
           {:ok, {entry.client_name, File.read!(path)}}
         end) do
      [{name, bytes}] -> if step_file?(name), do: {:ok, bytes}, else: :not_a_step
      [] -> :no_file
    end
  end

  defp step_file?(name),
    do: String.ends_with?(String.downcase(name), [".step", ".stp"])

  # -- what a person reads -------------------------------------------------

  defp extent_label(%{extent: extent}), do: Enum.map_join(extent, " × ", &number/1) <> " mm"

  defp number(value) when value == trunc(value), do: Integer.to_string(trunc(value))
  defp number(value), do: :erlang.float_to_binary(value, decimals: 1)

  # Features by family, in the recognition's own order, because the list is
  # about what the part is made of rather than about each face.
  defp features_label(features) do
    features
    |> Enum.map(& &1.family)
    |> Enum.uniq()
    |> Enum.map_join(" · ", fn family ->
      "#{family} × #{Enum.count(features, &(&1.family == family))}"
    end)
  end

  defp size_label(bytes) when bytes >= 1_000_000,
    do: :erlang.float_to_binary(bytes / 1_000_000, decimals: 1) <> " MB"

  defp size_label(bytes), do: :erlang.float_to_binary(max(bytes, 1) / 1_000, decimals: 1) <> " KB"

  defp upload_error(:too_large), do: "That file is larger than 20 MB."
  defp upload_error(error), do: "The file cannot be uploaded: #{error}"
end
