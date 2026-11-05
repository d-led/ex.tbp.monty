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
  alias Monty.Prerequisites.Saga
  alias Monty.Studio.Pretrained
  alias Monty.Studio.Storage

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(ExTbpMonty.PubSub, Saga.topic())

    prerequisites = Prerequisites.all()

    {:ok,
     assign(socket,
       prerequisites: prerequisites,
       # Asked, not assumed: a download that finished while the socket was down
       # has nothing left to announce, and a page that started every row at
       # "nothing happening" would show a stale badge until a refresh.
       statuses: Map.new(prerequisites, &{&1.id, current_status(&1.id)}),
       present: Map.new(prerequisites, &{&1.id, Prerequisites.present?(&1)}),
       # An archive can be here with nothing to read beside it: the pickles
       # arrived, the libraries a run reads did not. That is not "present" to a
       # reader whose run needs the memory.
       pending: Map.new(prerequisites, &{&1.id, memory_pending?(&1)}),
       # Read off the disk rather than out of a download's counters: a bundle that
       # was here before this page existed still has a size worth knowing.
       sizes: Map.new(prerequisites, &{&1.id, Prerequisites.size(&1)}),
       python: EmbeddedPython.version(),
       wandb: EmbeddedPython.wandb_mode(),
       engines: Prerequisites.engines(),
       storage: storage(prerequisites)
     )}
  end

  # Where these downloads land: what each directory already holds, and what is
  # left on the volumes behind them. The two are different facts — the first
  # belongs to a directory, the second to a filesystem, and both roots usually
  # sit on one filesystem — so the room is said once rather than twice.
  #
  # The figure for a directory is the *directory's*, because a root keeps more
  # than this page lists: releases an older config named, archives someone
  # unpacked by hand. A number that read as "what the entries below cost" would
  # be the page hiding gigabytes it has no row for.
  defp storage(prerequisites) do
    roots =
      prerequisites
      |> Enum.map(& &1.root)
      |> Enum.uniq()
      |> Enum.map(&root_usage/1)

    %{roots: roots, volumes: roots |> Enum.map(& &1.device) |> Enum.uniq_by(&device_key/1)}
  end

  defp root_usage(root) do
    path = Prerequisites.root_path(root)
    Map.merge(Storage.usage(path), %{root: root, occupied: Prerequisites.directory_size(path)})
  end

  defp device_key(nil), do: nil
  defp device_key(device), do: device.mount

  # What the downloader says about this id right now, if there is one.
  #
  # A fetch that has finished is *history*: what is true now is what is on the
  # disk, and the row says so from the bundle's own state. Answering "done" for
  # a machine that ended ten minutes ago was a badge that only changed when the
  # page was reloaded.
  defp current_status(id) do
    case Saga.lookup(id) do
      nil ->
        nil

      server ->
        with %{status: status} = progress <- Saga.status(server),
             true <- status in [:queued, :downloading, :extracting, :exporting],
             do: progress,
             else: (_ -> nil)
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
          <div id="free-space" class="space-y-1">
            <p
              :for={root <- @storage.roots}
              id={"occupied-#{root.root}"}
              class="text-sm text-base-content/70"
            >
              {occupied_label(root)}
            </p>
            <p id="free-space-volume" class="text-sm text-base-content/70">
              {room_label(@storage.volumes)}
            </p>
          </div>
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
                <p
                  id={"size-#{prerequisite.id}"}
                  class="font-mono text-xs text-base-content/50"
                >
                  {size_label(@sizes[prerequisite.id])}
                </p>
              </div>

              <div class="flex items-center gap-2">
                <span class={[
                  "badge",
                  badge_class(
                    status(@statuses, prerequisite.id),
                    @present[prerequisite.id],
                    @pending[prerequisite.id]
                  )
                ]}>
                  {status_label(
                    status(@statuses, prerequisite.id),
                    @present[prerequisite.id],
                    @pending[prerequisite.id]
                  )}
                </span>
                <button
                  :if={
                    downloadable?(
                      @statuses,
                      prerequisite.id,
                      @present[prerequisite.id],
                      @pending[prerequisite.id]
                    )
                  }
                  id={"download-#{prerequisite.id}"}
                  phx-click="download"
                  phx-value-id={prerequisite.id}
                  class="btn btn-primary btn-sm"
                >
                  <.icon name="hero-arrow-down-tray-mini" class="size-4" />
                  {if @present[prerequisite.id], do: "Export memory", else: "Download"}
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
              <%!--
                Bytes belong to the transfer, and only to it. Unpacking and
                reading the memory move no bytes through this page, so a row that
                kept the counter showed "0 B / —" for a fetch that had finished —
                a number about a download that was not happening. What the row is
                worth knowing after that is on the disk: the sizes above.
              --%>
              <p
                :if={status(@statuses, prerequisite.id) == :downloading}
                class="font-mono text-xs text-base-content/60"
              >
                {bytes(progress(@statuses, prerequisite.id).bytes)} / {bytes(
                  progress(@statuses, prerequisite.id).total
                )}
              </p>
              <%!--
                Reading the memory out of the pickles is the one phase with no
                bytes to count: the archive has arrived, and what is left is the
                exporter working through the models in it.
              --%>
              <%= case reading(progress(@statuses, prerequisite.id)) do %>
                <% nil -> %>
                <% reading -> %>
                  <div id={"reading-#{prerequisite.id}"} class="space-y-1 pt-1">
                    <progress
                      class="progress progress-secondary w-full"
                      value={reading.index}
                      max={reading.total}
                    ></progress>
                    <p class="font-mono text-xs text-base-content/60">
                      reading memory {reading.index}/{reading.total} · {reading.model}
                    </p>
                  </div>
              <% end %>
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
    case Saga.lookup(id) do
      nil ->
        {:noreply, socket}

      server ->
        Saga.cancel(server)
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:download, %{id: id} = progress}, socket) do
    # A finished fetch is the moment a bundle *is* here — and the moment the row
    # stops being about a download and becomes about a bundle. Everything the row
    # says from then on is re-read from the disk: present, whether the memory was
    # read, and how much room it takes. Leaving the machine's "done" on screen
    # was a badge that did not change until the next visit.
    if progress.status == :done do
      {:noreply, settled(socket, id)}
    else
      {:noreply, assign(socket, statuses: Map.put(socket.assigns.statuses, id, progress))}
    end
  end

  # The row after a fetch finished: nothing is happening to it any more, so what
  # it says is read off the disk — present, whether the memory was read, and how
  # much room it takes.
  defp settled(socket, id) do
    case Enum.find(socket.assigns.prerequisites, &(&1.id == id)) do
      nil ->
        socket

      prerequisite ->
        assign(socket,
          statuses: Map.delete(socket.assigns.statuses, id),
          present: Map.put(socket.assigns.present, id, Prerequisites.present?(prerequisite)),
          pending: Map.put(socket.assigns.pending, id, memory_pending?(prerequisite)),
          sizes: Map.put(socket.assigns.sizes, id, Prerequisites.size(prerequisite))
        )
    end
  end

  defp start(socket, prerequisite) do
    case Saga.start(prerequisite) do
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

  # What the exporter is reading right now: a model by name, and where it is in
  # the list of models this archive holds.
  defp reading(%{status: :exporting, export: %{} = export}), do: export
  defp reading(_progress), do: nil

  # Which of the archive's memories could not be read, by `release/model`. The
  # archive is untouched and can be fetched again; what the person needs is the
  # name of the model their run would be missing.
  defp unread_libraries(%{libraries: %{failed: failed}}) when is_list(failed),
    do: Enum.map(failed, fn {model, _reason} -> model end)

  defp unread_libraries(_progress), do: []

  # A row is clickable when nothing is happening to it and there is work: either
  # it is not here, or its memories were never read. The second is the state a
  # restored volume is in, and the one a reader with a run to start cannot see
  # from the badge alone.
  defp downloadable?(statuses, id, present?, pending?) do
    status(statuses, id) not in [:downloading, :extracting, :exporting, :done] and
      (not present? or pending?)
  end

  defp memory_pending?(%{extract: true} = prerequisite) do
    Prerequisites.present?(prerequisite) and
      Pretrained.pending?(Prerequisites.where_it_lands(prerequisite))
  end

  defp memory_pending?(_prerequisite), do: false

  defp status_label(nil, true, true), do: "memory not read"
  defp status_label(nil, true, false), do: "present"
  defp status_label(nil, false, _pending?), do: "not downloaded"
  defp status_label(:queued, _present, _pending?), do: "queued"
  defp status_label(:downloading, _present, _pending?), do: "downloading"
  defp status_label(:extracting, _present, _pending?), do: "unpacking"
  defp status_label(:exporting, _present, _pending?), do: "reading memory"
  defp status_label(:done, _present, _pending?), do: "done"
  defp status_label(:failed, _present, _pending?), do: "failed"
  defp status_label(:cancelled, _present, _pending?), do: "cancelled"

  defp badge_class(nil, true, true), do: "badge-warning"
  defp badge_class(nil, true, false), do: "badge-success"
  defp badge_class(nil, false, _pending?), do: "badge-ghost"
  defp badge_class(:done, _present, _pending?), do: "badge-success"
  defp badge_class(:failed, _present, _pending?), do: "badge-error"
  defp badge_class(:downloading, _present, _pending?), do: "badge-info"
  defp badge_class(:extracting, _present, _pending?), do: "badge-info"
  defp badge_class(:exporting, _present, _pending?), do: "badge-info"
  defp badge_class(_other, _present, _pending?), do: "badge-ghost"

  defp max_bytes(%{total: nil, bytes: bytes}), do: max(bytes, 1)
  defp max_bytes(%{total: total}), do: total

  # What is on the disk, said in the two things it can be: the archive that
  # arrived, and what it unpacked to. A prerequisite that is not here yet says
  # so rather than showing zero bytes, which reads like an empty bundle.
  defp size_label(%{archive: nil, unpacked: nil}), do: "nothing on disk yet"
  defp size_label(%{archive: archive, unpacked: nil}), do: "#{bytes(archive)} archive"
  defp size_label(%{archive: nil, unpacked: unpacked}), do: "#{bytes(unpacked)} unpacked"

  defp size_label(%{archive: archive, unpacked: unpacked}),
    do: "#{bytes(archive)} archive · #{bytes(unpacked)} unpacked"

  defp bytes(nil), do: "—"
  defp bytes(value), do: Humanizer.bytes(value, system: :binary)

  # What a root already holds. A download that fills the disk is the failure
  # this page exists to make visible, so "is there room for another" is answered
  # before the click rather than by an error afterwards; and "what is already
  # there" is answered about the whole directory, not only about the rows below.
  defp occupied_label(%{path: path, occupied: occupied}) when occupied in [nil, 0],
    do: "nothing in #{path} yet"

  # Said out loud, because a directory that holds 3.4 GiB while the rows add up
  # to 1 GiB is not a contradiction: the rest is releases this page does not
  # offer, and the number is about the directory.
  defp occupied_label(%{path: path, occupied: occupied}),
    do: "#{bytes(occupied)} in #{path} (everything in that directory, not only the entries below)"

  defp room_label(volumes) do
    case Enum.reject(volumes, &is_nil/1) do
      [] -> "the operating system did not say how much room is left where they land."
      answered -> Enum.map_join(answered, " ", &volume_label/1)
    end
  end

  defp volume_label(device) do
    "#{bytes(device.free_bytes)} free of #{bytes(device.total_bytes)} on #{device.mount}, " <>
      "#{device.percent}% used."
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
