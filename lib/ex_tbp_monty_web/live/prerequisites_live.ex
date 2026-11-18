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

  # What a row's badge says, by where the row stands. `:extracting` and
  # `:exporting` are said in the words of what they do to the file: unpacking an
  # archive, reading a memory out of one.
  @said_of_standing %{
    not_built: "not built",
    partly_built: "partly built",
    memory_not_read: "memory not read",
    present: "present",
    not_downloaded: "not downloaded",
    queued: "queued",
    downloading: "downloading",
    building: "building",
    extracting: "unpacking",
    exporting: "reading memory",
    done: "done",
    failed: "failed",
    cancelled: "cancelled"
  }

  # Work in progress is blue, an ending is green or red, and a quiet row that is
  # not ready is grey — the default, since that is most of the table on a first
  # visit.
  @colour_of_standing %{
    memory_not_read: "badge-warning",
    present: "badge-success",
    done: "badge-success",
    failed: "badge-error",
    downloading: "badge-info",
    building: "badge-info",
    extracting: "badge-info",
    exporting: "badge-info"
  }

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(ExTbpMonty.PubSub, Saga.topic())

    prerequisites = Prerequisites.all()

    socket =
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
        # What each root already holds is a walk of the tree, and that costs what
        # the disk costs, not what the page costs: it is answered in a task, so the
        # page is usable — downloads included — while it is measured.
        storage: room(prerequisites)
      )

    {:ok, start_async(socket, :space, fn -> held(prerequisites) end)}
  end

  # Where these downloads land: what each directory already holds, and what is
  # left on the volumes behind them. The two are different facts — the first
  # belongs to a directory, the second to a filesystem, and both roots usually
  # sit on one filesystem — so the room is said once rather than twice.
  #
  # The room is asked for while the page is drawn: it is one `df` per root, and
  # how much space is left is the one thing a person wants to know *before*
  # starting a download that is meant to fit in it. A page that answered it only
  # after its task finished answered nothing to anybody reading the HTML.
  defp room(prerequisites) do
    roots =
      prerequisites
      |> Enum.map(& &1.root)
      |> Enum.uniq()
      |> Enum.map(&root_usage/1)

    %{roots: roots, volumes: roots |> Enum.map(& &1.device) |> Enum.uniq_by(&device_key/1)}
  end

  # What each root holds, measured in a task and merged into the room it was
  # drawn beside.
  defp held(prerequisites) do
    Map.new(prerequisites, fn prerequisite ->
      path = Prerequisites.root_path(prerequisite.root)
      {prerequisite.root, Prerequisites.directory_size(path)}
    end)
  end

  # A root's room is known when the page is drawn and what the root *holds* is
  # not: the walk that answers it is in flight, and saying "nothing in it yet"
  # while it runs would be the page answering a question it has not asked.
  defp root_usage(root) do
    path = Prerequisites.root_path(root)
    Map.merge(Storage.usage(path), %{root: root, occupied: :measuring})
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
             true <- status in [:queued, :downloading, :building, :extracting, :exporting],
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
              :for={root <- (@storage && @storage.roots) || []}
              id={"occupied-#{root.root}"}
              class="text-sm text-base-content/70"
            >
              {occupied_label(root)}
            </p>
            <p :if={@storage} id="free-space-volume" class="text-sm text-base-content/70">
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
                  {size_label(prerequisite, @sizes[prerequisite.id])}
                </p>
                <%!-- A memory this application makes is one of a set, and the
                question a person has is whether *their* experiment's file is
                one of the ones written: a directory with the part's memory in it
                answers no run of the plate's features. --%>
                <p
                  :if={missing_provided(prerequisite) != []}
                  id={"missing-#{prerequisite.id}"}
                  class="font-mono text-xs text-warning"
                >
                  not written yet: {Enum.join(missing_provided(prerequisite), ", ")}
                </p>
                <%!-- Where it comes from, on what terms, and which bytes. A
                person about to wait for two gigabytes is entitled to the three,
                and the checksum is the one the fetch verifies what it received
                against. --%>
                <p
                  id={"provenance-#{prerequisite.id}"}
                  class="text-xs text-base-content/50"
                  title={prerequisite[:sha256]}
                >
                  {provenance_label(prerequisite)}
                </p>
              </div>

              <div class="flex items-center gap-2">
                <span class={[
                  "badge",
                  badge_class(
                    prerequisite,
                    status(@statuses, prerequisite.id),
                    @present[prerequisite.id],
                    @pending[prerequisite.id]
                  )
                ]}>
                  {status_label(
                    prerequisite,
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
                  id={"#{if prerequisite[:build], do: "build", else: "download"}-#{prerequisite.id}"}
                  phx-click={if prerequisite[:build], do: "build", else: "download"}
                  phx-value-id={prerequisite.id}
                  class="btn btn-primary btn-sm"
                >
                  <.icon
                    name={
                      if prerequisite[:build],
                        do: "hero-wrench-screwdriver-mini",
                        else: "hero-arrow-down-tray-mini"
                    }
                    class="size-4"
                  />
                  {action_label(prerequisite, @present[prerequisite.id])}
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
              <%!--
                A build moves no bytes: an empty byte bar is a download that
                never started, so that row has the step counter below and nothing
                else.
              --%>
              <progress
                :if={is_nil(making(progress(@statuses, prerequisite.id)))}
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
              <%!--
                A build is a step at a time — this part, this dog — and that is
                the thing a person waiting wants to read.
              --%>
              <div
                :if={making(progress(@statuses, prerequisite.id))}
                id={"making-#{prerequisite.id}"}
                class="space-y-1 pt-1"
              >
                <progress
                  class="progress progress-secondary w-full"
                  value={making(progress(@statuses, prerequisite.id)).index}
                  max={making(progress(@statuses, prerequisite.id)).total}
                ></progress>
                <p class="font-mono text-xs text-base-content/60">
                  step {making(progress(@statuses, prerequisite.id)).index}/{making(
                    progress(@statuses, prerequisite.id)
                  ).total} · {making(progress(@statuses, prerequisite.id)).what}
                </p>
              </div>
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
              A run steps one of three worlds: the <strong>built-in scene</strong>, part of
              this application, or one of <strong>two MuJoCo worlds</strong>
              — Monty's own
              simulator, stepped in Python through the interpreter above, or the same scene <strong>compiled in</strong>, stepped by the
              <code class="font-mono text-xs">ex_mujoco</code>
              binding with no interpreter in
              the process at all. The Python one needs the interpreter above; the compiled
              one needs nothing but the application.
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

  # What the directories hold, measured by the task `mount/3` started. A walk
  # that failed says nothing about the files, so the page says nothing about the
  # space rather than showing a nought.
  @impl true
  def handle_async(:space, {:ok, held}, socket) do
    roots =
      Enum.map(socket.assigns.storage.roots, fn root ->
        %{root | occupied: Map.get(held, root.root)}
      end)

    {:noreply, assign(socket, storage: %{socket.assigns.storage | roots: roots})}
  end

  def handle_async(:space, {:exit, _reason}, socket), do: {:noreply, socket}

  # Arriving with a prerequisite named is a link that starts the download it
  # points at — a finding that says a run is waiting for an archive offers the
  # click, not the page it lives on. Nothing is started that a click could not
  # have started: the same conditions the row's button answers to.
  @impl true
  def handle_params(%{"fetch" => id}, _uri, socket) do
    case Enum.find(socket.assigns.prerequisites, &(&1.id == id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Unknown prerequisite #{id}")}

      prerequisite ->
        if downloadable?(
             socket.assigns.statuses,
             id,
             socket.assigns.present[id],
             socket.assigns.pending[id]
           ),
           do: start(socket, prerequisite),
           else: {:noreply, socket}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("download", %{"id" => id}, socket), do: start_row(socket, id)

  # A build is the same click as a download: the row, the badge, the progress and
  # Cancel are the machine's, and only what it runs differs
  # (`Monty.Prerequisites.Build`).
  def handle_event("build", %{"id" => id}, socket), do: start_row(socket, id)

  def handle_event("cancel", %{"id" => id}, socket) do
    case Saga.lookup(id) do
      nil ->
        {:noreply, socket}

      server ->
        Saga.cancel(server)
        {:noreply, socket}
    end
  end

  defp start_row(socket, id) do
    case Prerequisites.get(id) do
      nil -> {:noreply, put_flash(socket, :error, "Unknown prerequisite #{id}")}
      prerequisite -> start(socket, prerequisite)
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

  defp start_error(other), do: "Could not start: #{Monty.Studio.Failure.sentence(other)}"

  defp status(statuses, id), do: statuses |> Map.get(id) |> then(&(&1 && &1.status))

  defp downloading?(statuses, id),
    do: status(statuses, id) in [:downloading, :building, :extracting, :exporting]

  defp progress(statuses, id), do: Map.get(statuses, id)

  # What a build is doing: a part, a dog, a step of the ones this entry has.
  defp making(%{built: %{} = built}), do: built
  defp making(_progress), do: nil

  # The word on the button says what the click does: an archive is downloaded, a
  # memory inside one is exported out of it, and an input this application
  # produces is made.
  # A row's button says what the click does: fetch an archive, read a memory out
  # of one that arrived, or make what this application can only make itself.
  defp action_label(%{build: build}, _present?) when is_binary(build), do: "Make"
  defp action_label(_prerequisite, true), do: "Export memory"
  defp action_label(_prerequisite, _absent), do: "Download"

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
    status(statuses, id) not in [:downloading, :building, :extracting, :exporting, :done] and
      (not present? or pending?)
  end

  defp memory_pending?(%{extract: true} = prerequisite) do
    Prerequisites.present?(prerequisite) and
      Pretrained.pending?(Prerequisites.where_it_lands(prerequisite))
  end

  defp memory_pending?(_prerequisite), do: false

  # The badge says where the entry stands: what the machine is doing to it, or —
  # with nothing running — what the disk already holds. A memory this application
  # writes itself is never "not downloaded": there is nothing to download.
  defp status_label(prerequisite, phase, present?, pending?),
    do: Map.fetch!(@said_of_standing, standing(prerequisite, phase, present?, pending?))

  defp badge_class(prerequisite, phase, present?, pending?) do
    Map.get(
      @colour_of_standing,
      standing(prerequisite, phase, present?, pending?),
      "badge-ghost"
    )
  end

  # The one decision the label and the colour both read: what this row is, right
  # now. A running phase speaks for itself; a quiet one is answered by the disk.
  defp standing(_prerequisite, phase, _present?, _pending?) when not is_nil(phase), do: phase

  # A build's badge is exactly what it still owes, in three states: nothing
  # written, some of what it promises, or all of it. `present?/1` is already
  # "every memory it promises is on disk", so a directory that exists is the
  # only question left — and a build that wrote half is not "present", which is
  # what sent a person to a run page saying no memory can be read.
  defp standing(%{build: build} = prerequisite, nil, present?, _pending?)
       when is_binary(build) do
    cond do
      present? -> :present
      File.dir?(Prerequisites.target_path(prerequisite)) -> :partly_built
      true -> :not_built
    end
  end

  defp standing(_prerequisite, nil, true, true), do: :memory_not_read
  defp standing(_prerequisite, nil, true, false), do: :present
  defp standing(_prerequisite, nil, false, _pending?), do: :not_downloaded

  defp max_bytes(%{total: nil, bytes: bytes}), do: max(bytes, 1)
  defp max_bytes(%{total: total}), do: total

  # What is on the disk, said in the two things it can be: the archive that
  # arrived, and what it unpacked to. A build has no archive — what is there is
  # what Make wrote, and "unpacked" would name an unpacking nobody did. A
  # prerequisite that is not here yet says so rather than showing zero bytes,
  # which reads like an empty bundle.
  defp size_label(%{build: build}, %{unpacked: nil}) when is_binary(build),
    do: "nothing on disk yet"

  defp size_label(%{build: build}, %{unpacked: unpacked}) when is_binary(build),
    do: "#{bytes(unpacked)} written"

  defp size_label(_prerequisite, %{archive: nil, unpacked: nil}), do: "nothing on disk yet"

  defp size_label(_prerequisite, %{archive: archive, unpacked: nil}),
    do: "#{bytes(archive)} archive"

  defp size_label(_prerequisite, %{archive: nil, unpacked: unpacked}),
    do: "#{bytes(unpacked)} unpacked"

  defp size_label(_prerequisite, %{archive: archive, unpacked: unpacked}),
    do: "#{bytes(archive)} archive · #{bytes(unpacked)} unpacked"

  # What a *build* promises, said against the disk. A row that reports only bytes
  # leaves a reader guessing whether the file their config names is one of them,
  # which is exactly the question a stale build raises: the directory is there,
  # the experiment's own memory is not.
  #
  # Only a build: an archive's `provides` is the list of models it *carries*, and
  # what is not exported yet from an unpacked archive is a state that row already
  # has a word for (`memory_not_read`) — saying "not written yet" underneath it
  # would be the same fact twice in two vocabularies.
  # What a build still owes, asked of the same rule the run asks before it steps
  # (`Monty.Prerequisites.absent_memories/1`): a row and a run that disagreed
  # about "is it finished" is how a page said "present" while a run said it had
  # no memory.
  defp missing_provided(prerequisite), do: Prerequisites.absent_memories(prerequisite)

  # Where an archive comes from, whose it is, on what terms, and which bytes —
  # read off the manifest rather than written here, so a page cannot say
  # something about a download that the download's own record does not.
  defp provenance_label(prerequisite) do
    [prerequisite[:upstream], prerequisite[:licence], checksum_label(prerequisite[:sha256])]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp checksum_label(nil), do: nil

  defp checksum_label(sha256),
    do: "sha256 #{String.slice(sha256, 0, 8)}…#{String.slice(sha256, -8, 8)}"

  defp bytes(nil), do: "—"
  defp bytes(value), do: Humanizer.bytes(value, system: :binary)

  # What a root already holds. A download that fills the disk is the failure
  # this page exists to make visible, so "is there room for another" is answered
  # before the click rather than by an error afterwards; and "what is already
  # there" is answered about the whole directory, not only about the rows below.
  defp occupied_label(%{path: path, occupied: :measuring}),
    do: "measuring what is in #{path}…"

  # Nothing there yet — or a directory the walk could not read, which for this
  # sentence is the same thing: there is no size to report.
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
