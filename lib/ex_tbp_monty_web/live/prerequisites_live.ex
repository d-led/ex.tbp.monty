defmodule ExTbpMontyWeb.PrerequisitesLive do
  @moduledoc """
  The files an experiment needs, and their download progress.

  Monty's prerequisites are large archives; the page shows them arriving
  instead of a silent `curl`. Each row is one manifest entry, its Monty target
  path, and a progress bar fed by PubSub from the download process.

  The page never blocks: a download is a supervised process, and the row simply
  reflects the last progress it broadcast.
  """

  use ExTbpMontyWeb, :live_view

  alias ExTbpMonty.EmbeddedPython
  alias Monty.Prerequisites
  alias Monty.Prerequisites.Download
  alias Monty.Studio.Storage

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(ExTbpMonty.PubSub, Download.topic())

    prerequisites = Prerequisites.all()

    {:ok,
     assign(socket,
       prerequisites: prerequisites,
       # Asked, not assumed: a download that finished while the socket was down
       # has nothing left to announce, and a page that started every row at
       # "nothing happening" would show a stale badge until a refresh.
       statuses: Map.new(prerequisites, &{&1.id, current_status(&1.id)}),
       present: Map.new(prerequisites, &{&1.id, Prerequisites.present?(&1)}),
       python: EmbeddedPython.version(),
       wandb: EmbeddedPython.wandb_mode(),
       engines: Prerequisites.engines(),
       storage: Storage.usage(Prerequisites.root_path("MONTY_DATA"))
     )}
  end

  # What the downloader says about this id right now, if there is one.
  defp current_status(id) do
    case Download.lookup(id) do
      nil -> nil
      server -> Download.status(server)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section class="mx-auto max-w-4xl space-y-6">
        <header class="space-y-2">
          <h1 class="text-3xl font-semibold tracking-tight">Prerequisites</h1>
          <p class="text-base-content/70">
            Datasets and models an experiment needs, written to the paths Monty's own
            environment variables point at. Downloads stream to <code>.part</code> files
            and move into place only when they are complete.
          </p>
          <p id="free-space" class="text-sm text-base-content/70">
            {free_space(@storage)}
          </p>
        </header>

        <div class="space-y-3">
          <article
            :for={prerequisite <- @prerequisites}
            id={"prereq-#{prerequisite.id}"}
            class="rounded-box border border-base-300 bg-base-100 p-4"
          >
            <div class="flex flex-wrap items-start justify-between gap-4">
              <div class="space-y-1">
                <h2 class="font-semibold">{prerequisite.title}</h2>
                <p :if={prerequisite.description} class="text-sm text-base-content/70">
                  {prerequisite.description}
                </p>
                <p class="font-mono text-xs break-all text-base-content/60">
                  {Prerequisites.target_path(prerequisite)}
                </p>
              </div>

              <div class="flex items-center gap-2">
                <span class={[
                  "badge",
                  badge_class(status(@statuses, prerequisite.id), @present[prerequisite.id])
                ]}>
                  {status_label(status(@statuses, prerequisite.id), @present[prerequisite.id])}
                </span>
                <button
                  :if={downloadable?(@statuses, prerequisite.id)}
                  id={"download-#{prerequisite.id}"}
                  phx-click="download"
                  phx-value-id={prerequisite.id}
                  class="btn btn-primary btn-sm"
                >
                  <.icon name="hero-arrow-down-tray-mini" class="size-4" /> Download
                </button>
                <button
                  :if={downloading?(@statuses, prerequisite.id)}
                  id={"cancel-#{prerequisite.id}"}
                  phx-click="cancel"
                  phx-value-id={prerequisite.id}
                  class="btn btn-ghost btn-sm"
                >
                  Cancel
                </button>
              </div>
            </div>

            <div :if={progress(@statuses, prerequisite.id)} class="mt-3 space-y-1">
              <progress
                class="progress progress-primary w-full"
                value={progress(@statuses, prerequisite.id).bytes}
                max={max_bytes(progress(@statuses, prerequisite.id))}
              ></progress>
              <p class="font-mono text-xs text-base-content/60">
                {bytes(progress(@statuses, prerequisite.id).bytes)} / {bytes(
                  progress(@statuses, prerequisite.id).total
                )}
              </p>
              <p
                :if={unread_libraries(progress(@statuses, prerequisite.id)) != []}
                class="text-xs text-error"
              >
                Some of the memory in this archive was not read: {unread_libraries(
                  progress(@statuses, prerequisite.id)
                )
                |> Enum.join(", ")}. A run of a model in this list has no memory to recognise with.
              </p>
            </div>
          </article>
        </div>

        <%!--
          The one dependency that is not a download. Monty's loggers call wandb
          through a CPython this build carries, so a page answering "am I ready
          to run?" has to say whether that interpreter answered and where a run
          would send its numbers — an absent interpreter would only surface as a
          logger that quietly did nothing.
        --%>
        <article
          id="embedded-python"
          class="rounded-box border border-base-300 bg-base-100 p-4"
        >
          <div class="flex flex-wrap items-start justify-between gap-4">
            <div class="space-y-1">
              <h2 class="font-semibold">Embedded Python</h2>
              <p class="text-sm text-base-content/70">
                Installed at build time by uv and started with the application. It carries
                <code>wandb</code>
                (Monty's loggers) and <code>mujoco</code>
                (the physics engine a MuJoCo experiment's world steps).
              </p>
              <p id="embedded-python-version" class="font-mono text-xs text-base-content/60">
                {version_label(@python)}
              </p>

              <div id="embedded-engines" class="flex flex-wrap items-center gap-2">
                <span
                  :for={{engine, installed?} <- @engines}
                  id={"embedded-engine-#{engine}"}
                  class={["badge", (installed? && "badge-success") || "badge-ghost"]}
                >
                  {engine_label(engine)}: {installed_label(installed?)}
                </span>
              </div>
            </div>

            <span id="embedded-python-wandb" class={["badge", wandb_badge(@wandb)]}>
              {wandb_label(@wandb)}
            </span>
          </div>
        </article>
        <%!--
          Last, because it depends on the card above: a run's world steps in the
          interpreter this application carries.
        --%>
        <article id="world" class="rounded-box border border-base-300 bg-base-100 p-4">
          <div class="space-y-1">
            <h2 class="font-semibold">The world</h2>
            <p class="text-sm text-base-content/70">
              A run steps one of two worlds: the <strong>built-in scene</strong>, part of
              this application, or <strong>Monty's simulator</strong>, which steps in the
              interpreter above.
            </p>
            <p id="world-python" class="font-mono text-xs break-all text-base-content/60">
              {version_label(@python)} — this application's own interpreter
            </p>
          </div>
        </article>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("download", %{"id" => id}, socket) do
    case Prerequisites.get(id) do
      nil -> {:noreply, put_flash(socket, :error, "Unknown prerequisite #{id}")}
      prerequisite -> start(socket, prerequisite)
    end
  end

  def handle_event("cancel", %{"id" => id}, socket) do
    case Download.lookup(id) do
      nil ->
        {:noreply, socket}

      server ->
        Download.cancel(server)
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:download, %{id: id} = progress}, socket) do
    {:noreply, assign(socket, statuses: Map.put(socket.assigns.statuses, id, progress))}
  end

  defp start(socket, prerequisite) do
    case Download.start(prerequisite) do
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, start_error(reason))}

      _started ->
        {:noreply, socket}
    end
  end

  # A download that cannot even make its folder is a permissions problem or a
  # wrong `MONTY_MODELS`; saying which is more useful than a tuple.
  defp start_error({:cannot_create, directory, reason}) do
    "Cannot create #{directory} (#{reason}). Check the folder's permissions, or where " <>
      "MONTY_DATA / MONTY_MODELS / MONTY_LOGS point."
  end

  defp start_error(other), do: "Could not start: #{inspect(other)}"

  defp status(statuses, id), do: statuses |> Map.get(id) |> then(&(&1 && &1.status))

  defp downloading?(statuses, id),
    do: status(statuses, id) in [:downloading, :extracting, :exporting]

  defp progress(statuses, id), do: Map.get(statuses, id)

  # Which of the archive's memories could not be read, by `release/model`. The
  # archive is untouched and can be fetched again; what the person needs is the
  # name of the model their run would be missing.
  defp unread_libraries(%{libraries: %{failed: failed}}) when is_list(failed),
    do: Enum.map(failed, fn {model, _reason} -> model end)

  defp unread_libraries(_progress), do: []

  defp downloadable?(statuses, id) do
    status(statuses, id) not in [:downloading, :extracting, :exporting, :done]
  end

  defp status_label(nil, true), do: "present"
  defp status_label(nil, false), do: "not downloaded"
  defp status_label(:queued, _present), do: "queued"
  defp status_label(:downloading, _present), do: "downloading"
  defp status_label(:extracting, _present), do: "unpacking"
  defp status_label(:exporting, _present), do: "reading memory"
  defp status_label(:done, _present), do: "done"
  defp status_label(:failed, _present), do: "failed"
  defp status_label(:cancelled, _present), do: "cancelled"

  defp badge_class(nil, true), do: "badge-success"
  defp badge_class(nil, false), do: "badge-ghost"
  defp badge_class(:done, _present), do: "badge-success"
  defp badge_class(:failed, _present), do: "badge-error"
  defp badge_class(:downloading, _present), do: "badge-info"
  defp badge_class(:extracting, _present), do: "badge-info"
  defp badge_class(:exporting, _present), do: "badge-info"
  defp badge_class(_other, _present), do: "badge-ghost"

  defp max_bytes(%{total: nil, bytes: bytes}), do: max(bytes, 1)
  defp max_bytes(%{total: total}), do: total

  defp bytes(nil), do: "—"
  defp bytes(value), do: Humanizer.bytes(value, system: :binary)

  # The room these downloads land in: a download that fills the disk is the
  # failure this page exists to make visible, so "is there room for the next
  # one" is answered before the click rather than by an error afterwards.
  defp free_space(%{device: nil, path: path}),
    do: "#{path} is where they land; the operating system did not say how much room is left."

  defp free_space(%{device: device, path: path}) do
    "#{bytes(device.free_bytes)} free of #{bytes(device.total_bytes)} where they land " <>
      "(#{path}) — #{device.percent}% of #{device.mount} used."
  end

  defp engine_label(:mujoco), do: "MuJoCo"
  defp engine_label(:habitat), do: "Habitat-Sim"

  defp installed_label(true), do: "installed"
  defp installed_label(false), do: "not available here"

  defp version_label({:ok, version}), do: "Python #{version} · answered"

  defp version_label({:error, reason}),
    do: "the interpreter did not answer: #{reason}"

  defp wandb_label("disabled"), do: "wandb disabled"
  defp wandb_label("offline"), do: "wandb offline"
  defp wandb_label(mode), do: "wandb #{mode}"

  defp wandb_badge("disabled"), do: "badge-ghost"
  defp wandb_badge(_mode), do: "badge-info"
end
