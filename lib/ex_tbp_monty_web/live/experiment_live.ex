defmodule ExTbpMontyWeb.ExperimentLive do
  @moduledoc """
  One experiment: what it is before it runs, and what happened while it did.

  The page has three states and they are the same page. Before: the wiring
  diagram, the checks, and the modules it names. During: sensor views and a log,
  streamed as the run reports them. After: the run's counts, including any
  learning module that never received input — the failure that otherwise looks
  like success.

  The page does not run anything itself. Pressing Run enqueues a job
  (`Monty.Studio.Jobs.Run`) and the page watches that job's topic, so closing
  the page does not close the run and reloading it picks the run back up. The
  log on screen is the same text as the log file on disk.

  The filter applies to the whole log rather than to arriving lines, and every
  word typed must appear in a line for it to be shown.
  """

  use ExTbpMontyWeb, :live_view

  alias Monty.Studio
  alias Monty.Studio.{Jobs, LogFilter, RunHistory, RunLog, Setup}

  # A log is a thing a person reads back, not a database: the last few thousand
  # lines are enough to scroll through a run and bounded enough that a runaway
  # experiment cannot take the page with it.
  @log_limit 2_000

  @impl true
  def mount(params, _session, socket) do
    case Studio.open(name_of(params)) do
      {:ok, opened} ->
        {:ok, follow_running(assign_opened(socket, opened, steps(params)))}

      {:error, reason} ->
        {:ok, assign(socket, opened: nil, error: reason, run_id: nil, lines: [], filter: "")}
    end
  end

  defp assign_opened(socket, opened, steps) do
    socket
    |> assign(
      opened: opened,
      error: nil,
      steps: steps,
      run_id: nil,
      status: nil,
      progress: {0, steps},
      lines: [],
      filter: "",
      summary: nil,
      log_path: nil
    )
    |> stream_configure(:frames, dom_id: &"frame-#{&1.sensor_id}")
    |> stream(:frames, [])
  end

  # A run outlives its page, so a page that loads must find the run its
  # experiment is in the middle of instead of pretending nothing is happening.
  defp follow_running(%{assigns: %{opened: %{name: name}}} = socket) do
    case RunHistory.running_for(name) do
      nil -> socket
      record -> follow(socket, record)
    end
  end

  defp follow(socket, record) do
    if connected?(socket),
      do: Phoenix.PubSub.subscribe(ExTbpMonty.PubSub, Jobs.Run.topic(record.id))

    socket
    |> assign(
      run_id: record.id,
      status: record.status,
      progress: {length(record.timeline), record.steps},
      log_path: record.log_path
    )
    |> seed_log(record)
  end

  # The lines a run already printed are in the record; showing the log from the
  # beginning beats showing it from the moment this page opened.
  defp seed_log(socket, record) do
    lines =
      record.log
      |> Enum.map(fn entry -> line(entry["step"], RunLog.line(entry)) end)
      |> Enum.take(-@log_limit)

    assign(socket, lines: lines)
  end

  @impl true
  def render(%{opened: nil} = assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section id="experiment-missing" class="space-y-3">
        <h1 class="text-2xl font-semibold tracking-tight">That experiment will not open</h1>
        <p class="text-base-content/70">
          This config does not compose from Monty's conf tree: <code>{inspect(@error)}</code>
        </p>
        <.link navigate={~p"/"} class="btn btn-sm btn-outline">Back to the experiments</.link>
      </section>
    </Layouts.app>
    """
  end

  def render(assigns) do
    assigns = assign(assigns, shown: LogFilter.apply(assigns.lines, assigns.filter))

    ~H"""
    <Layouts.app flash={@flash}>
      <header class="space-y-2">
        <div class="flex flex-wrap items-center gap-2">
          <h1 class="font-mono text-2xl font-semibold tracking-tight">{@opened.name}</h1>
          <span :if={@opened.source == :draft} class="badge badge-primary badge-sm">built here</span>
          <span :if={@opened.source == :monty} class="badge badge-ghost badge-sm">
            from Monty's conf
          </span>
        </div>
        <p class="max-w-3xl text-base-content/70">
          {@opened.setup.experiment_class.class} · {@opened.setup.monty_class.class}
        </p>
      </header>

      <dl class="grid gap-2 sm:grid-cols-2 lg:grid-cols-4">
        <ExTbpMontyWeb.StudioComponents.fact
          label="sensors"
          value={sensor_summary(@opened.setup)}
        />
        <ExTbpMontyWeb.StudioComponents.fact
          label="learning modules"
          value={learning_module_summary(@opened.setup)}
        />
        <ExTbpMontyWeb.StudioComponents.fact label="epochs" value={epochs(@opened.setup)} />
        <ExTbpMontyWeb.StudioComponents.fact label="ported here" value={ported(@opened.setup)} />
      </dl>

      <ExTbpMontyWeb.StudioComponents.diagram :if={@opened.diagram} diagram={@opened.diagram} />

      <ExTbpMontyWeb.StudioComponents.findings findings={@opened.setup.findings} />

      <section class="space-y-2">
        <header class="flex flex-wrap items-center gap-3">
          <h2 class="text-lg font-semibold tracking-tight">Run it</h2>
          <button
            id="run"
            phx-click="run"
            class="btn btn-primary btn-sm"
            disabled={!runable?(assigns)}
          >
            <.icon name="hero-play-mini" class="size-4" /> Run {@steps} steps
          </button>
          <button id="step" phx-click="step" class="btn btn-sm" disabled={!runable?(assigns)}>
            <.icon name="hero-forward-mini" class="size-4" /> One step
          </button>
          <button :if={@run_id} id="stop" phx-click="stop" class="btn btn-ghost btn-sm">Stop</button>
          <span :if={@run_id} id="run-progress" class="badge badge-ghost">
            step {elem(@progress, 0)} / {elem(@progress, 1)}
          </span>
          <.link
            :if={@run_id}
            navigate={~p"/runs/#{@run_id}"}
            id="open-history"
            class="btn btn-ghost btn-xs"
          >
            History
          </.link>
        </header>

        <p :if={not runable?(assigns)} id="run-blocked" class="text-sm text-error">
          Fix the errors above before running: this config would not start in Monty either.
        </p>

        <p :if={@run_id == nil and runable?(assigns)} class="text-sm text-base-content/60">
          A run is a job: it keeps going if this page is closed, and its log and history are
          written as it goes. It uses stand-in modules until the ported ones land.
        </p>

        <div id="frames" phx-update="stream" class="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
          <p id="frames-empty" class="hidden only:block text-xs text-base-content/50">
            Sensor views appear here as the run steps.
          </p>
          <figure
            :for={{dom_id, frame} <- @streams.frames}
            id={dom_id}
            class="rounded-field border border-base-300 bg-base-100 p-1.5 text-base-content"
          >
            <figcaption class="flex items-baseline justify-between px-0.5 pb-1 text-[11px] text-base-content/60">
              <span class="font-mono">{frame.sensor_id}</span>
              <span>{frame.note}</span>
            </figcaption>
            <%!-- The frame is an SVG string this application generated, not
            content from a request. --%>
            <div class="text-base-content/80">{Phoenix.HTML.raw(frame.data)}</div>
          </figure>
        </div>

        <div :if={@run_id} id="run-log-panel" class="space-y-1">
          <div class="flex flex-wrap items-center gap-2">
            <h3 class="text-sm font-medium">Log</h3>
            <form id="log-filter" phx-change="filter" phx-debounce="150" class="flex-1">
              <input
                type="search"
                name="filter"
                value={@filter}
                placeholder="filter: every word must match"
                class="input input-xs w-full max-w-sm font-mono"
                aria-label="Filter the log: every word must appear in a line"
              />
            </form>
            <span id="log-count" class="text-[11px] text-base-content/50">
              {length(@shown)} of {length(@lines)} lines
            </span>
            <span :if={@log_path} class="font-mono text-[11px] text-base-content/40">
              {@log_path}
            </span>
          </div>

          <ul
            id="run-log"
            class="max-h-56 overflow-auto rounded-field border border-base-300 bg-base-100 p-2 font-mono text-[11px] leading-5"
          >
            <li id="run-log-empty" class="text-base-content/50">
              {if @lines == [], do: "no lines yet", else: "no line matches this filter"}
            </li>
            <li :for={line <- @shown} id={"log-#{line.id}"} class={line_class(line)}>
              {line.text}
            </li>
          </ul>
        </div>

        <ExTbpMontyWeb.StudioComponents.summary :if={@summary} summary={@summary} />
      </section>

      <section :if={@opened.yaml} class="space-y-2">
        <h2 class="text-lg font-semibold tracking-tight">The config</h2>
        <pre
          id="experiment-config"
          phx-no-curly-interpolation
          class="max-h-96 overflow-auto rounded-box border border-base-300 bg-base-100 p-3 font-mono text-xs"
        ><code><%= @opened.yaml %></code></pre>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("run", _params, %{assigns: %{opened: opened, steps: steps}} = socket) do
    if Setup.valid?(opened.setup), do: start(socket, opened, steps), else: {:noreply, socket}
  end

  # One step is a run of one step: a person clicking it twice wants two runs to
  # look at, not one run that pretends to have done two.
  def handle_event("step", _params, %{assigns: %{opened: opened}} = socket) do
    if Setup.valid?(opened.setup), do: start(socket, opened, 1), else: {:noreply, socket}
  end

  def handle_event("stop", _params, %{assigns: %{run_id: nil}} = socket), do: {:noreply, socket}

  def handle_event("stop", _params, %{assigns: %{run_id: run_id}} = socket) do
    case Jobs.Run.stop(run_id) do
      :ok ->
        {:noreply, push(socket, nil, "stopping: the run stops at its next step", :info)}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> push(nil, "that run is not running any more", :warning)
         |> settle(run_id)}
    end
  end

  def handle_event("filter", %{"filter" => text}, socket) do
    {:noreply, assign(socket, filter: text)}
  end

  @impl true
  def handle_info({:studio, run_id, event}, %{assigns: %{run_id: run_id}} = socket) do
    {:noreply, handle_studio(event, socket)}
  end

  def handle_info({:studio, _other_run, _event}, socket), do: {:noreply, socket}

  defp handle_studio({:started, steps}, socket) do
    assign(socket, status: "running", progress: {0, steps})
  end

  defp handle_studio({:step, %{line: text, step: step, frames: frames}}, socket) do
    socket
    |> push(step, text, :info)
    |> assign(progress: {step + 1, elem(socket.assigns.progress, 1)})
    |> then(fn socket -> Enum.reduce(frames, socket, &stream_insert(&2, :frames, &1)) end)
  end

  defp handle_studio({:finished, %{status: status, summary: summary}}, socket) do
    assign(socket, status: status, summary: summary)
  end

  defp handle_studio({:failed, %{reason: reason}}, socket) do
    socket
    |> assign(status: "failed")
    |> push(nil, "the run failed: #{inspect(reason)}", :error)
  end

  # -- starting a run --------------------------------------------------------

  defp start(socket, opened, steps) do
    case RunHistory.start(RunLog.attributes(opened, steps)) do
      {:ok, record} ->
        case Jobs.Run.enqueue_run(record) do
          {:ok, _job} ->
            Phoenix.PubSub.subscribe(ExTbpMonty.PubSub, Jobs.Run.topic(record.id))

            {:noreply,
             socket
             |> assign(
               run_id: record.id,
               status: "running",
               progress: {0, steps},
               summary: nil,
               lines: [],
               log_path: record.log_path
             )
             |> push(nil, "queued: #{steps} step(s) of #{opened.name}", :info)}

          {:error, reason} ->
            not_queued(socket, record, reason)
        end

      {:error, changeset} ->
        {:noreply, push(socket, nil, "cannot record this run: #{describe(changeset)}", :error)}
    end
  end

  # A run that cannot be queued is not a run: say so where the log is, because
  # that is where somebody would look, and close the record with the reason.
  defp not_queued(socket, record, reason) do
    {:ok, _} = RunHistory.finish(record, %{"reason" => inspect(reason)}, "failed")
    {:noreply, push(socket, nil, "could not queue the run: #{inspect(reason)}", :error)}
  end

  # -- the log ---------------------------------------------------------------

  defp push(socket, step, text, level) do
    line = line(step, text, level)
    assign(socket, lines: Enum.take(socket.assigns.lines ++ [line], -@log_limit))
  end

  defp line(step, text, level \\ :info) do
    %{id: System.unique_integer([:monotonic, :positive]), step: step, text: text, level: level}
  end

  defp line_class(%{level: :error}), do: "text-error"
  defp line_class(%{level: :warning}), do: "text-warning"
  defp line_class(_info), do: ""

  # The page can hold a run id whose worker is gone — the VM restarted, the job
  # was killed. Waiting for news that will never come is the worst state a page
  # can be in, so say it happened.
  defp settle(socket, run_id) do
    case RunHistory.get(run_id) do
      %{status: "running"} = record ->
        {:ok, _} = RunHistory.finish(record, %{"reason" => "the run's job is gone"}, "failed")
        assign(socket, status: "failed")

      _finished_or_gone ->
        socket
    end
  end

  defp describe(%Ecto.Changeset{} = changeset) do
    Enum.map_join(changeset.errors, ", ", fn {field, {message, _}} -> "#{field}: #{message}" end)
  end

  defp describe(reason), do: inspect(reason)

  # -- helpers ---------------------------------------------------------------

  # The route is a glob, so the name arrives as its segments.
  defp name_of(%{"name" => segments}), do: segments |> List.wrap() |> Enum.join("/")
  defp name_of(_params), do: ""

  defp steps(params) do
    case Integer.parse(to_string(params["steps"] || "")) do
      {count, ""} when count > 0 -> count
      _default -> Monty.Studio.Run.default_steps()
    end
  end

  defp runable?(assigns) do
    case assigns[:opened] do
      nil -> false
      opened -> Setup.valid?(opened.setup)
    end
  end

  defp sensor_summary(setup), do: Enum.map_join(setup.sensors, ", ", & &1.id)

  defp learning_module_summary(setup),
    do: Enum.map_join(setup.learning_modules, ", ", & &1.id)

  defp epochs(setup), do: "train #{setup.epochs.train} · eval #{setup.epochs.eval}"

  defp ported(setup) do
    %{implemented: implemented, total: total} = Setup.ported(setup)
    "#{implemented}/#{total}"
  end
end
