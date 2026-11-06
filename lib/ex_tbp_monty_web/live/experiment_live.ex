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

  alias Monty.Prerequisites
  alias Monty.Studio

  alias Monty.Studio.{
    Belief,
    Chart,
    Duration,
    Failure,
    Jobs,
    LogFilter,
    Logging,
    Panel,
    Replay,
    RunHistory,
    RunLog,
    Setup
  }

  alias Monty.Studio.Jobs.Reaper

  # A log is a thing a person reads back, not a database: the last few thousand
  # lines are enough to scroll through a run and bounded enough that a runaway
  # experiment cannot take the page with it.
  @log_limit 2_000

  @impl true
  def mount(params, _session, socket) do
    # Runs of this experiment arrive as messages, the same way a run's steps do:
    # the record is written once, and every page showing it hears about it. No
    # page has to ask the database what changed.
    if connected?(socket), do: RunHistory.subscribe()

    case Studio.open(name_of(params)) do
      {:ok, opened} ->
        {:ok,
         follow_running(
           assign_opened(socket, opened, steps(params), episodes(params), window_of(params))
         )}

      {:error, reason} ->
        {:ok,
         assign(socket,
           opened: nil,
           logging: [],
           error: reason,
           run_id: nil,
           lines: [],
           filter: "",
           x_window: window_of(params),
           chart_extent: {0, 0}
         )}
    end
  end

  defp assign_opened(socket, opened, steps, episodes, window) do
    # What this experiment will leave behind, and what it would have left behind
    # if this port had it — said here as well as in the run's log, because a
    # config that logs nothing is worth knowing before the run, not after.
    logging = Logging.open(opened.setup)
    runs = recent_runs(opened.name)

    socket
    |> assign(
      opened: opened,
      # Runs this experiment already has, so a page opened where something is
      # going shows it — one click away, instead of a second run started only to
      # see anything.
      runs: runs,
      queue: Jobs.by_run(Enum.map(runs, & &1.id)),
      logging: logging.notes,
      error: nil,
      steps: cap(steps, opened.setup),
      episodes: episodes,
      # What a run of this experiment reads off the disk, and which of those is
      # not there yet: the run buttons stay disabled while anything is missing,
      # and the box under the header names it.
      needs: needs(opened),
      missing: missing(opened),
      # One run until somebody asks for more: parallelism is a choice made on
      # this page, not something a link should be able to set for them.
      parallelism: 1,
      run_id: nil,
      status: nil,
      progress: {0, steps},
      lines: [],
      filter: "",
      summary: nil,
      log_path: nil,
      # Per learning module: the beliefs it held, step by step, and the chart a
      # template draws from them. Kept per module because a run with two modules
      # has two answers, and averaging them would be a third.
      beliefs: %{},
      charts: %{},
      # Which stretch of the run's own x axis the chart draws, `{from, to}` or
      # `nil` for all of it. It comes from the URL rather than from an assign the
      # page owns: a zoomed chart is a link that can be kept, and every way of
      # changing it — zoom, pan, reset — is a patch.
      x_window: window,
      chart_extent: {0, 0},
      # The object and the agent in one picture per step: the views a sensor
      # streams say what a camera saw, this says whether there was anything to see.
      centre: nil,
      # The seed a run here would start from. It is the config's until somebody
      # changes it, which is what makes it worth showing: the number a sweep is
      # about is the one a page can say.
      seed: opened.setup.seed
    )
    |> stream_configure(:frames, dom_id: &"frame-#{&1.sensor_id}")
    |> stream(:frames, [])
  end

  @runs_shown 5

  # The last few runs of one experiment, newest first. Five: this is a list to
  # click through, not the runs page, and the detail belongs to the run.
  #
  # By the experiment's own name, in the query: a text search narrowed here would
  # read twenty-five rows to keep five, and — because it is a *substring* match —
  # it could return nothing at all for an experiment whose name is the beginning
  # of a busier one's.
  defp recent_runs(name), do: RunHistory.list_for(name, limit: @runs_shown)

  # A run's record is written the moment it is queued, so `running` on the record
  # before a worker exists means "queued": the queue knows better, and this is
  # the same reading the runs page uses.
  defp run_state(%{status: "running"}, %{state: state})
       when state in ~w(available scheduled retryable),
       do: "queued"

  defp run_state(run, _job), do: run.status

  defp run_state_class("running"), do: "badge-info"
  defp run_state_class("queued"), do: "badge-info"
  defp run_state_class("finished"), do: "badge-success"
  defp run_state_class("failed"), do: "badge-error"
  defp run_state_class(_other), do: "badge-ghost"

  # How long the stepping took. A run that has not finished has no answer yet —
  # a number here would be a number about a different question.
  defp run_duration(%{duration_us: nil}), do: "—"
  defp run_duration(%{duration_us: us}), do: Duration.humanize(us)

  # What a page can be set here, read off the run's own record: the rest is the
  # run page's business.
  defp input_of(%{inputs: %{} = inputs}, key), do: Map.get(inputs, key) |> to_string()
  defp input_of(_run, _key), do: "—"

  # A run outlives its page, so a page that loads must find the run its
  # experiment is in the middle of instead of pretending nothing is happening.
  defp follow_running(%{assigns: %{opened: %{name: name}}} = socket) do
    # A record that says `running` may be the only thing left of a run whose node
    # went away. Settle those before believing one, or this page watches a corpse
    # and refuses to start the run the reader actually asked for.
    _ = Reaper.sweep()

    case RunHistory.running_for(name) do
      nil -> socket
      record -> follow(socket, record)
    end
  end

  defp follow(socket, record) do
    if connected?(socket),
      do: Phoenix.PubSub.subscribe(ExTbpMonty.PubSub, Jobs.Run.topic(record.id))

    # A page that moves to another run starts that run's story, not the last
    # one's: charts, beliefs and frames are per run, and two runs' steps in one
    # chart would be a line through episodes that never happened.

    socket
    |> assign(
      run_id: record.id,
      status: record.status,
      progress: steps_of_last_episode(record),
      log_path: record.log_path,
      summary: nil,
      beliefs: %{},
      charts: %{},
      centre: nil
    )
    |> stream(:frames, [], reset: true)
    |> seed_log(record)
    |> watch()
  end

  # The lines a run already printed are in the record; showing the log from the
  # beginning beats showing it from the moment this page opened.
  defp seed_log(socket, record) do
    lines =
      record.log
      |> Enum.map(&record_line/1)
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
        <.link navigate={~p"/experiments"} class="btn btn-sm btn-outline">
          Back to the experiments
        </.link>
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
          <%!-- Which world a run here would step. A stand-in scene is not Monty
          and its numbers are this port's own, so the page says which one it is
          before anything is run, not only in a warning further down. --%>
          <span
            id="world"
            class={["badge badge-sm", world_badge(@opened.setup)]}
            title={world_note(@opened.setup)}
          >
            world: {Setup.world_name(@opened.setup)}
          </span>
          <%!-- The file, not a description of the file: exporting Monty's own
          experiment is how you take one and change it. --%>
          <.link
            id="export-experiment"
            href={~p"/export/experiments/#{@opened.name}"}
            download
            class="btn btn-ghost btn-xs gap-1.5 font-normal"
            title="Save this experiment's YAML"
          >
            <.icon name="hero-arrow-down-tray-mini" class="size-3.5" /> yaml
          </.link>
        </div>
        <p class="max-w-3xl text-base-content/70">
          {@opened.setup.experiment_class.class} · {@opened.setup.monty_class.class}
        </p>
      </header>

      <%!-- What Monty's own configuration panel shows about a run, in the same
      words: the modules, the memory it starts from, the seed it runs under, and
      the step limits its termination names. A page that kept these in a YAML
      nobody reads would be asking a reader to trust it — and the run page shows
      the same sentences from the record, so what was promised and what was done
      are written once. --%>
      <dl class="grid gap-2 sm:grid-cols-2 lg:grid-cols-4">
        <ExTbpMontyWeb.StudioComponents.fact
          :for={{label, value} <- Panel.facts(@opened.setup, @seed)}
          label={label}
          value={value}
        />
      </dl>

      <ExTbpMontyWeb.StudioComponents.diagram :if={@opened.diagram} diagram={@opened.diagram} />

      <ExTbpMontyWeb.StudioComponents.findings findings={@opened.setup.findings} />

      <p :if={@logging != []} id="logging-notes" class="text-xs text-base-content/70">
        <%= for note <- @logging do %>
          <span class="block">{note}</span>
        <% end %>
      </p>

      <section class="space-y-2">
        <header class="flex flex-wrap items-center gap-3">
          <h2 class="text-lg font-semibold tracking-tight">Run it</h2>
          <button
            id="run"
            phx-click="run"
            class="btn btn-primary btn-sm"
            disabled={!runable?(assigns)}
          >
            <.icon name="hero-play-mini" class="size-4" /> Run it
          </button>
          <%!-- The number is a ceiling, not a target: the experiment's own
          recognition policy ends each episode first, and for a recognition that
          is about twenty matching steps. --%>
          <span class="font-mono text-[11px] text-base-content/60">
            up to {@steps} steps per episode
          </span>
          <button id="step" phx-click="step" class="btn btn-sm" disabled={!runable?(assigns)}>
            <.icon name="hero-forward-mini" class="size-4" /> One step
          </button>
          <%!-- Monty starts a parallel run with a second script; here it is a
          number, and it means what it means there: n processes, n episodes, one
          object each. --%>
          <form id="parallelism" phx-change="parallelism" class="flex items-center gap-1">
            <label for="parallelism-count" class="text-[11px] text-base-content/60">in parallel</label>
            <select
              id="parallelism-count"
              name="parallelism"
              class="select select-xs w-16"
              aria-label="How many episodes to run at once"
            >
              <option :for={count <- 1..8} value={count} selected={count == @parallelism}>
                {count}
              </option>
            </select>
          </form>
          <%!-- Which world the run steps. A run that chooses nothing steps the
          simulator in an external process — the experiment's own engine — and
          the stand-in is the deliberate other way: they answer different
          questions, so the choice is on the run. --%>
          <%!-- The seed is the config's until somebody says otherwise, and the
          record keeps the one a run started from — the worker reads it back, so
          a sweep over seeds is a number on this page rather than a second
          script. --%>
          <form :if={@opened} id="seed-choice" phx-change="seed" class="flex items-center gap-1">
            <label for="seed-value" class="text-[11px] text-base-content/60">seed</label>
            <input
              id="seed-value"
              type="number"
              name="seed"
              value={@seed}
              class="input input-xs w-20 font-mono"
              aria-label="The seed this run starts from"
            />
          </form>
          <form id="world-choice" phx-change="world" class="flex items-center gap-1">
            <label for="world-select" class="text-[11px] text-base-content/60">world</label>
            <select
              :if={@opened}
              id="world-select"
              name="world"
              class="select select-xs w-72"
              aria-label="Which world the run steps"
            >
              <%!-- Two worlds, each named for what it is: Monty's own MuJoCo
              simulator (copied in, run in this application's interpreter), or
              this port's stand-in sphere. --%>
              <option
                :for={world <- [:mujoco, :synthetic]}
                value={world}
                selected={world == @opened.setup.world}
              >
                {Setup.world_name(@opened.setup, world)}{unavailable(@opened.setup, world)}
              </option>
            </select>
          </form>
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

        <%!-- Poka-yoke: a run that reads files nobody has downloaded cannot
        start, so the page says which files before the button is pressed and
        names the page that fetches them — the button is disabled, the reason is
        here. A need is not always a download: the interpreter is configuration
        (`MONTY_PYTHON`), and offering a download for it is offering something
        that does not exist. A stand-in run reads nothing and never sees this. --%>
        <div
          :if={@missing != []}
          id="needs-prerequisites"
          class="alert alert-warning alert-soft items-start gap-3"
          role="status"
        >
          <.icon name="hero-exclamation-triangle-mini" class="size-4 mt-0.5" />
          <div class="space-y-1 text-sm">
            <p class="font-medium">This run needs something before it can start.</p>
            <ul class="list-disc space-y-0.5 pl-4">
              <li :for={need <- @missing}>
                {need.what}<span :if={need.path}> — <code class="font-mono text-xs">{need.path}</code></span>
              </li>
            </ul>
            <p :if={any_remedy?(@missing, :download)}>
              <.link id="download-prerequisites" navigate={~p"/prerequisites"} class="link">
                Download them on the Prerequisites page
              </.link>
            </p>
            <p :if={any_remedy?(@missing, :configure)}>
              Point <code>MONTY_PYTHON</code> at an interpreter with <code>tbp.monty</code> in
              it — <code>scripts/run-dev.sh</code> passes it through — and reload this page.
            </p>
            <%!-- Whatever the reason, the prerequisites page is where the answer is
            written down: which file is missing, where it belongs, what the last fetch of
            it did. A person who has to guess which page to go to is the bug. --%>
            <p>
              <.link id="prerequisites-page" navigate={~p"/prerequisites"} class="link">
                What this needs, and how to get it
              </.link>
            </p>
            <p>
              Or step this port's stand-in scene instead, which reads nothing from disk.
            </p>
          </div>
        </div>

        <%!-- Two kinds of error reach this line — the config's own, which Monty
        would refuse too, and one this port makes ("no implementation here") —
        so it must not claim a cause of its own. --%>
        <p :if={not config_runnable?(assigns)} id="run-blocked" class="text-sm text-error">
          Fix the errors above before running.
        </p>

        <%!-- The runs this experiment already has, newest first, between the
        buttons that start one and the live results one gets by staying. Enough
        to answer "is something going, and how did the last one end?" and to get
        to the run itself; the parameters shown are the ones this page sets, and
        everything else about a run is on its own page. --%>
        <section id="experiment-runs" class="space-y-1">
          <div class="flex items-baseline gap-2">
            <h3 class="text-sm font-medium">Runs</h3>
            <.link
              :if={@runs != []}
              id="all-runs"
              navigate={~p"/runs?q=#{@opened.name}"}
              class="link text-[11px] text-base-content/60"
            >
              all runs of this experiment
            </.link>
          </div>

          <p :if={@runs == []} id="runs-empty" class="text-xs text-base-content/60">
            No run of this experiment yet. The buttons above start one.
          </p>

          <table
            :if={@runs != []}
            id="experiment-runs-table"
            phx-hook={ExTbpMontyWeb.LocalTime.hook_name()}
            class={table_class()}
          >
            <thead class="text-left text-base-content/60">
              <tr>
                <th class="font-normal">when</th>
                <th class="font-normal">state</th>
                <th class="font-normal text-right">steps</th>
                <th class="font-normal text-right">seed</th>
                <th class="font-normal text-right">parallel</th>
                <th class="font-normal text-right">took</th>
                <th class="font-normal">world</th>
              </tr>
            </thead>
            <tbody>
              <%!-- The row is the link: a whole row a person can click beats a
              word at the end of it, and every cell is then the same target. --%>
              <tr
                :for={run <- @runs}
                id={"experiment-run-#{run.id}"}
                phx-click={JS.navigate(~p"/runs/#{run.id}")}
                class="cursor-pointer border-t border-base-300 hover:bg-base-200"
              >
                <td class="py-0.5 font-mono text-base-content/60">
                  <ExTbpMontyWeb.LocalTime.local_time at={run.inserted_at} class="tabular-nums" />
                </td>
                <td>
                  <span class={[
                    "badge badge-xs",
                    run_state_class(run_state(run, @queue[run.id]))
                  ]}>
                    {run_state(run, @queue[run.id])}
                  </span>
                </td>
                <td class="text-right font-mono">{run.steps}</td>
                <td class="text-right font-mono">{input_of(run, "seed")}</td>
                <td class="text-right font-mono">{input_of(run, "parallel")}</td>
                <td class="text-right font-mono whitespace-nowrap">{run_duration(run)}</td>
                <td class="text-[11px] whitespace-nowrap">
                  {ExTbpMontyWeb.StudioComponents.world_label(run)}
                </td>
              </tr>
            </tbody>
          </table>
          <ExTbpMontyWeb.LocalTime.local_time_hook />
        </section>

        <p :if={@run_id == nil and runable?(assigns)} class="text-sm text-base-content/60">
          A run keeps going if this page is closed, and its log and history are
          written as it goes. One run is every object of the experiment, in every
          rotation its config names.
        </p>

        <section :if={@charts != %{}} id="evidence-chart" class="space-y-2">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <h3 class="text-sm font-medium">What the learning modules believe</h3>
            <%!-- Zooming is a patch: the server redraws the stretch asked for and
            the address bar keeps it, so a zoomed chart is a link somebody can
            send, and nothing about it lives only in the browser. --%>
            <div class="join" id="chart-zoom">
              <button
                id="zoom-out"
                phx-click="zoom"
                phx-value-how="out"
                class="btn btn-xs join-item"
                aria-label="show more of the run"
              >
                −
              </button>
              <button
                id="zoom-left"
                phx-click="zoom"
                phx-value-how="left"
                class="btn btn-xs join-item"
                aria-label="earlier steps"
              >
                ←
              </button>
              <span
                id="chart-extent"
                class="join-item border border-base-300 px-2 font-mono text-[11px] leading-6 text-base-content/70"
              >
                {window_label(@x_window, @chart_extent)}
              </span>
              <button
                id="zoom-right"
                phx-click="zoom"
                phx-value-how="right"
                class="btn btn-xs join-item"
                aria-label="later steps"
              >
                →
              </button>
              <button
                id="zoom-in"
                phx-click="zoom"
                phx-value-how="in"
                class="btn btn-xs join-item"
                aria-label="show less of the run"
              >
                +
              </button>
              <button
                id="zoom-all"
                phx-click="zoom"
                phx-value-how="all"
                class="btn btn-xs join-item"
                disabled={is_nil(@x_window)}
                aria-label="the whole run"
              >
                all
              </button>
            </div>
          </div>
          <div class={["grid gap-2", map_size(@charts) > 1 && "lg:grid-cols-2"]}>
            <ExTbpMontyWeb.EvidenceChart.evidence_chart
              :for={{module_id, chart} <- @charts}
              module_id={module_id}
              chart={chart}
            />
          </div>
        </section>

        <section :if={@centre} id="centre-view" class="space-y-2">
          <h3 class="text-sm font-medium">Where the agent is</h3>
          <figure class="max-w-sm rounded-field border border-base-300 bg-base-100 p-2">
            <figcaption class="px-0.5 pb-1 font-mono text-[11px] text-base-content/60">
              step {@centre.step} · {@centre.note}
            </figcaption>
            <div class="text-base-content/80">{@centre.data}</div>
          </figure>
        </section>

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
            <%!-- The frame is markup this application built, with every value in
            it escaped where it was built. --%>
            <div class="text-base-content/80">{frame.data}</div>
          </figure>
        </div>

        <div :if={@run_id} id="run-log-panel" class="space-y-1">
          <div class="flex flex-wrap items-center gap-2">
            <h3 class="text-sm font-medium">Log</h3>
            <form id="log-filter" phx-change="filter" phx-debounce="150" class="flex-1">
              <%!-- The value is deliberately not bound: a run's log arrives
              while a person is typing, and a re-render that rewrites the box
              under their fingers is a filter that cannot be typed into. --%>
              <input
                type="search"
                name="filter"
                placeholder="filter: every word must match"
                class="input input-xs w-full min-w-[16rem] max-w-sm font-mono"
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
            phx-hook={ExTbpMontyWeb.LocalTime.hook_name()}
            class="max-h-56 overflow-auto rounded-field border border-base-300 bg-base-100 p-2 font-mono text-[11px] leading-5"
          >
            <%!-- An empty state is for a log with nothing in it, or a filter
            that kept nothing. With no filter typed, every line matches, so
            there is nothing to say. --%>
            <li :if={@shown == []} id="run-log-empty" class="text-base-content/50">
              {if @lines == [], do: "no lines yet", else: "no line matches this filter"}
            </li>
            <li :for={line <- @shown} id={"log-#{line.id}"} class={line_class(line)}>
              <%!-- The clock is a `<time>` with the instant in it, not a string:
              a run's log says when a step happened, and "when" means the
              reader's clock, not the server's. The hook rewrites the UTC text
              the server sent into the browser's own time zone. --%>
              <ExTbpMontyWeb.LocalTime.local_time
                :if={line.at}
                at={line.at}
                style={:clock}
                class="me-1.5 text-base-content/40 tabular-nums"
              />{line.text}
            </li>
          </ul>
          <ExTbpMontyWeb.LocalTime.local_time_hook />
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
  def handle_params(params, _uri, socket) do
    window = window_of(params)

    socket =
      if window == socket.assigns[:x_window] do
        socket
      else
        socket
        |> assign(x_window: window)
        |> assign(charts: charts_of(socket.assigns.beliefs, window))
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("run", _params, %{assigns: %{opened: opened, steps: steps}} = socket) do
    if Setup.valid?(opened.setup),
      do: start(socket, opened, steps, socket.assigns.parallelism, socket.assigns.episodes),
      else: {:noreply, socket}
  end

  # The chart is drawn for a stretch of the run, and zooming means saying which:
  # `in` halves it around the middle, `out` doubles it, `left` and `right` move
  # it by a quarter without changing its width, and `all` is the whole run.
  # Each is a patch, so the address bar follows the picture.
  def handle_event("zoom", %{"how" => how}, socket) do
    window = zoom(socket.assigns[:x_window], socket.assigns[:chart_extent], how)

    {:noreply, push_patch(socket, to: experiment_path(socket, window))}
  end

  def handle_event("parallelism", %{"parallelism" => count}, socket) do
    {:noreply, assign(socket, parallelism: parallelism(%{"parallelism" => count}))}
  end

  # A seed this page cannot read is not a seed: the number stays as it was and
  # the run keeps the one the setup already had.
  def handle_event("seed", %{"seed" => value}, socket),
    do: {:noreply, with_chosen_seed(socket, value)}

  # The world is a choice made here and recorded on the run, not a property of
  # the deployment: the queue executes what the record says it was given, so two
  # workers with different settings cannot disagree about it afterwards.
  def handle_event("world", %{"world" => choice}, socket) do
    case world_of(choice) do
      nil -> {:noreply, socket}
      world -> {:noreply, reopened(socket, world)}
    end
  end

  # One step is a run of one step: a person clicking it twice wants two runs to
  # look at, not one run that pretends to have done two.
  def handle_event("step", _params, %{assigns: %{opened: opened}} = socket) do
    if Setup.valid?(opened.setup),
      do: start(socket, opened, 1, 1, 1),
      else: {:noreply, socket}
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
  # A run of this experiment was written down, or settled. The row this page
  # draws is the record the database just wrote, so a run that is still queued is
  # in the table from the moment it is queued — not when a worker picks it up.
  def handle_info({:recorded, run}, %{assigns: %{opened: %{name: name}}} = socket)
      when run.experiment == name do
    {:noreply, put_run(socket, run, :first)}
  end

  def handle_info({:recorded, _other}, socket), do: {:noreply, socket}

  def handle_info({:settled, run}, %{assigns: %{opened: %{name: name}}} = socket)
      when run.experiment == name do
    {:noreply, put_run(socket, run, :in_place)}
  end

  def handle_info({:settled, _other}, socket), do: {:noreply, socket}

  def handle_info({:studio, run_id, event}, %{assigns: %{run_id: run_id}} = socket) do
    {:noreply, handle_studio(event, socket)}
  end

  def handle_info({:studio, _other_run, _event}, socket), do: {:noreply, socket}

  # A run is the experiment's, not the page's: two people (or two tabs) looking at
  # the same experiment watch the same run. So a page with nothing to watch asks
  # whether one has started since it opened, and a page whose run has finished
  # asks whether another has begun — the answer is the same run for everybody.
  def handle_info(:studio_poll, socket) do
    socket = follow_started(socket)
    socket = reconcile(socket)

    if socket.assigns.status == "running" do
      {:noreply, watch(socket)}
    else
      {:noreply, socket}
    end
  end

  # A run that this page is not showing, because somebody started it after the
  # page opened.
  defp follow_started(%{assigns: %{run_id: nil, opened: %{name: name}}} = socket) do
    case RunHistory.running_for(name) do
      nil ->
        socket

      record ->
        socket |> follow(record) |> push(nil, "watching a run that was already going", :info)
    end
  end

  defp follow_started(%{assigns: %{status: "running"}} = socket), do: socket

  defp follow_started(%{assigns: %{opened: %{name: name}}} = socket) do
    case RunHistory.running_for(name) do
      nil ->
        socket

      record when record.id == socket.assigns.run_id ->
        socket

      record ->
        socket |> follow(record) |> push(nil, "a new run of this experiment has started", :info)
    end
  end

  defp handle_studio({:started, steps}, socket) do
    socket
    |> assign(status: "running", progress: {0, steps})
    |> refresh_runs()
  end

  # One episode of the epoch has begun. A run is every object of the experiment
  # in every rotation, so the page says which one it is on — the step counter
  # restarts inside each episode, and a log that did not say so would look like
  # a run going backwards.
  defp handle_studio({:episode, %{episode: index, object: object}}, socket) do
    push(socket, nil, "episode #{index + 1}: #{object || "the scene's own object"}", :info)
  end

  defp handle_studio(
         {:step, %{line: text, step: step, frames: frames, episode: episode} = event},
         socket
       ) do
    socket
    |> push(step, text, :info)
    |> assign(progress: {step + 1, elem(socket.assigns.progress, 1)})
    |> then(fn socket -> Enum.reduce(frames, socket, &stream_insert(&2, :frames, &1)) end)
    |> remember(episode, step, Map.get(event, :beliefs, %{}))
    |> assign(centre: Map.get(event, :centre))
  end

  defp handle_studio({:finished, _summary}, socket) do
    # The record is the truth about a finished run; the message only says it is
    # time to look.
    socket |> reconcile() |> refresh_runs()
  end

  defp handle_studio({:failed, %{reason: reason}}, socket) do
    socket
    |> push(nil, "the run failed: #{inspect(reason)}", :error)
    |> reconcile()
    |> refresh_runs()
  end

  defp refresh_runs(%{assigns: %{opened: %{name: name}}} = socket) do
    runs = recent_runs(name)
    assign(socket, runs: runs, queue: Jobs.by_run(Enum.map(runs, & &1.id)))
  end

  defp refresh_runs(socket), do: socket

  # A newly recorded run goes to the top; one that has settled keeps its place,
  # because a page must not shuffle under a reader while they are reading it.
  defp put_run(socket, run, where) do
    runs =
      case where do
        :first -> [run | Enum.reject(socket.assigns.runs, &(&1.id == run.id))]
        :in_place -> Enum.map(socket.assigns.runs, &if(&1.id == run.id, do: run, else: &1))
      end

    assign(socket, runs: runs, queue: Map.merge(socket.assigns.queue, Jobs.by_run([run.id])))
  end

  # What each learning module believed after this step, appended to what it held
  # before it: the chart is the run's history, not the latest frame of it. The
  # episode comes with it because a run is many episodes and each one starts its
  # evidence again at zero — the chart stacks them end to end so a later episode
  # is not drawn on top of the first.
  defp remember(socket, _episode, _step, beliefs) when beliefs == %{}, do: socket

  defp remember(socket, episode, step, beliefs) do
    histories =
      Enum.reduce(beliefs, socket.assigns.beliefs, fn {module_id, belief}, histories ->
        point = {episode, step, belief}
        Map.update(histories, to_string(module_id), [point], &(&1 ++ [point]))
      end)

    assign_charts(socket, histories)
  end

  # The histories, the chart of the stretch being looked at, and how long the run
  # is so far — the last of those is what zoom and pan move within.
  defp assign_charts(socket, histories) do
    window = socket.assigns.x_window

    longest =
      histories
      |> Map.values()
      |> Enum.max_by(&length/1, fn -> [] end)

    assign(socket,
      beliefs: histories,
      charts: charts_of(histories, window),
      chart_extent: Chart.extent(longest)
    )
  end

  # One chart per module, from the module's own history, drawn for the stretch of
  # the run the page is looking at.
  defp charts_of(histories, window),
    do:
      Map.new(histories, fn {module_id, steps} ->
        {module_id, Chart.new(steps, window: window)}
      end)

  # Zoom is a parameter, not a mode: `?x_from=12&x_to=30` is the chart of the
  # run between those two moments, and a link holding it can be sent to somebody
  # else. Nothing about it needs the browser to remember anything.
  defp window_of(params) do
    with {from, ""} <- Integer.parse(to_string(params["x_from"] || "")),
         {to, ""} <- Integer.parse(to_string(params["x_to"] || "")),
         true <- from < to do
      {from, to}
    else
      _all -> nil
    end
  end

  # The stretch on screen, in the run's own x units: "steps 12–30 of 120", or the
  # whole run when nothing is zoomed.
  defp window_label(nil, {first, last}), do: "steps #{first}–#{last}"
  defp window_label({from, to}, {_first, last}), do: "steps #{from}–#{to} of #{last}"

  # The next window, given the one on screen and how long the run is. Every
  # result stays inside `first..last` and keeps at least one step of width, so a
  # person mashing "zoom in" ends up looking at a single step rather than at
  # nothing.
  defp zoom(_window, {0, 0}, _how), do: nil

  defp zoom(_window, _extent, "all"), do: nil

  defp zoom(window, {first, last}, "in") do
    {from, to} = window || {first, last}
    middle = (from + to) / 2
    half = max((to - from) / 4, 0.5)

    clamp({round(middle - half), round(middle + half)}, first, last)
  end

  defp zoom(window, {first, last}, "out") do
    {from, to} = window || {first, last}
    middle = (from + to) / 2
    half = to - from

    clamp({round(middle - half), round(middle + half)}, first, last)
  end

  defp zoom(window, {first, last}, "left"), do: pan(window || {first, last}, first, last, -1)
  defp zoom(window, {first, last}, "right"), do: pan(window || {first, last}, first, last, 1)

  # Moving without resizing: a quarter of the window, and never past an end.
  defp pan({from, to}, first, last, direction) do
    step = max(div(to - from, 4), 1)
    taken = min(max(from + direction * step, first), max(last - (to - from), first))

    {taken, taken + (to - from)}
  end

  defp clamp({from, to}, first, last) do
    {from, to} = {max(from, first), min(to, last)}

    if from < to, do: {from, to}, else: {first, max(first + 1, last)}
  end

  # Where the page is now, with a chart window in it — the address every zoom
  # and pan patches to.
  defp experiment_path(socket, window) do
    query =
      [episodes: socket.assigns[:episodes], steps: socket.assigns[:steps]]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    query =
      case window do
        nil -> query
        {from, to} -> query ++ [x_from: from, x_to: to]
      end

    ~p"/experiments/#{socket.assigns.opened.name}?#{query}"
  end

  # What the record says, applied to the page.
  #
  # A page can miss messages: the queue runs a run wherever a worker is free
  # (another node, another release of this application), and a socket can blink.
  # The row is written before the line is broadcast, so asking the row is always
  # at least as new as the last message — which is why the page also polls it
  # while a run is in flight, and stops as soon as the run is not running.
  defp reconcile(%{assigns: %{run_id: nil}} = socket), do: socket

  defp reconcile(%{assigns: %{run_id: run_id}} = socket) do
    # The whole row, not `head/1`: the page merges the timeline out of it below
    # (`Replay.at/2`), and a run without the pictures is a `timeline` of `nil`
    # rather than an empty one — which the replay walks. Asking for the row
    # without them is for the callers that only want to know it exists.
    case RunHistory.get(run_id) do
      nil ->
        socket

      record ->
        socket
        |> assign(
          status: record.status,
          progress: steps_of_last_episode(record),
          log_path: record.log_path,
          summary: if(record.summary == %{}, do: socket.assigns.summary, else: record.summary)
        )
        |> merge_lines(record)
        |> merge_frames(record)
        |> merge_beliefs(record)
    end
  end

  # "step 2 of 12" is about the episode being run: every episode of a run starts
  # its step counter again, so counting a run's whole log against one episode's
  # budget would have the page claim step seven of three.
  defp steps_of_last_episode(record) do
    case List.last(record.log) do
      nil -> {0, record.steps}
      last -> {Enum.count(record.log, &(&1["episode"] == last["episode"])), record.steps}
    end
  end

  # A run's chart is the run's, not this socket's: a page opened halfway through
  # an episode draws what the record already holds and then carries on live. It is
  # done once — after that the messages are newer than the record.
  defp merge_beliefs(%{assigns: %{beliefs_seeded: true}} = socket, _record), do: socket

  defp merge_beliefs(socket, record) do
    recorded =
      for entry <- record.log,
          entry["beliefs"] != nil,
          {module_id, belief} <- entry["beliefs"],
          into: [] do
        {module_id, {entry["episode"] || 0, entry["step"] || 0, Belief.from_stored(belief)}}
      end

    if recorded == [] do
      socket
    else
      histories =
        Enum.reduce(recorded, socket.assigns.beliefs, fn {module, point}, histories ->
          Map.update(histories, module, [point], &(&1 ++ [point]))
        end)

      socket
      |> assign(:beliefs_seeded, true)
      |> assign_charts(histories)
    end
  end

  # A run that was reported from elsewhere never sent its pictures here, so the
  # last frame of the record's timeline stands in: what the run saw at its last
  # step is better than a panel that never filled in.
  defp merge_frames(socket, record) do
    if socket.assigns[:frames_seeded] do
      socket
    else
      case Replay.at(record, Replay.last_step(record)) do
        %{frames: frames} when frames != [] ->
          socket
          |> assign(frames_seeded: true)
          |> then(fn socket -> Enum.reduce(frames, socket, &stream_insert(&2, :frames, &1)) end)

        _no_frames ->
          socket
      end
    end
  end

  # Lines already on screen stay where they are; lines the record has and the
  # page does not are the ones that were missed.
  defp merge_lines(socket, record) do
    seen = socket.assigns.lines |> Enum.filter(& &1.step) |> length()

    if seen >= length(record.log) do
      socket
    else
      chatter = Enum.filter(socket.assigns.lines, &is_nil(&1.step))
      recorded = Enum.map(record.log, &record_line/1)
      assign(socket, lines: Enum.sort_by(recorded ++ chatter, & &1.id))
    end
  end

  # Often enough that a run looks live, rarely enough to be nothing.
  defp poll_ms, do: Application.get_env(:ex_tbp_monty, :studio_poll_ms, 500)

  defp watch(socket) do
    Process.send_after(self(), :studio_poll, poll_ms())
    socket
  end

  # -- starting a run --------------------------------------------------------

  # Parallelism is the experiment's own answer to "one object after another, or
  # several at once": Monty starts a parallel run with a second script, and the
  # scripts differ only in how many episodes go at the same time. Here that is a
  # number — n runs of n episodes, each its own record, its own topic and its own
  # seed — and the queue is told the same number, because a queue limit of two
  # would quietly turn ten runs into five rounds of two.
  defp start(socket, opened, steps, parallelism, episodes) do
    _ = Jobs.parallelism(parallelism)

    results = Enum.map(0..(parallelism - 1), &queue(opened, steps, &1, parallelism, episodes))
    records = Enum.flat_map(results, &started/1)
    refused = for {:error, changeset} <- results, do: changeset_errors(changeset)

    case records do
      [] ->
        already_going(socket, opened)

      records ->
        # Subscribe before enqueueing: the queue can start a job within
        # milliseconds of the insert, and a run that finishes before the page
        # listens is a run the page watched happen and never heard about.
        Enum.each(records, &Phoenix.PubSub.subscribe(ExTbpMonty.PubSub, Jobs.Run.topic(&1.id)))
        Enum.each(records, &enqueue/1)

        [first | _rest] = records

        {:noreply,
         socket
         |> assign(
           run_id: first.id,
           status: "running",
           progress: {0, steps},
           summary: nil,
           lines: [],
           log_path: first.log_path
         )
         |> push(nil, queued(records, steps, opened.name), :info)
         |> refused(refused)
         |> watch()}
    end
  end

  defp refused(socket, []), do: socket

  defp refused(socket, [reason | _rest]),
    do: push(socket, nil, "could not record every run: #{reason}", :error)

  # Two runs of the same experiment in the same world would be the same run
  # twice, and that is what this refuses. Two *worlds* are two different
  # experiments' worth of evidence — the stand-in checks the runtime, MuJoCo
  # produces the experiment's numbers — so a page that already has one going
  # can still be asked for the other, and the queue decides when it starts.
  defp queue(opened, steps, episode, parallel, episodes) do
    world = to_string(opened.setup.world)

    case RunHistory.running_for(opened.name, episode) do
      %{inputs: %{"world" => ^world}} ->
        :going

      _nothing_or_another_world ->
        RunHistory.start(RunLog.attributes(opened, steps, episode, parallel, episodes))
    end
  end

  defp started({:ok, record}), do: [record]
  defp started(_going_or_refused), do: []

  # A run that cannot be queued is not a run: close its record with the reason,
  # because a row that says "running" with nothing working on it is the lie the
  # Reaper exists to undo.
  defp enqueue(record) do
    case Jobs.Run.enqueue_run(record) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        recorded =
          "The run could not be queued."
          |> Failure.explain(inspect(reason))
          |> Failure.recorded()

        {:ok, _closed} = RunHistory.finish(record, recorded, "failed")
        :ok
    end
  end

  # Nothing to start: every episode asked for is already being run — which is a
  # second click on Run, and the answer is to watch what is already happening.
  defp already_going(socket, opened) do
    case RunHistory.running_for(opened.name) do
      nil ->
        {:noreply, push(socket, nil, "nothing new to start", :warning)}

      record ->
        {:noreply,
         socket |> follow(record) |> push(nil, "a run is already going: watching it", :info)}
    end
  end

  defp queued([only], steps, name),
    do: "queued: #{steps} step(s) of #{name} (episode #{only.episode})"

  defp queued(records, steps, name) do
    first = hd(records)
    last = List.last(records)

    "queued #{length(records)} runs of #{name}, episodes #{first.episode}–#{last.episode}, " <>
      "#{steps} step(s) each: watching episode #{first.episode}, the rest are on Runs"
  end

  # -- the log ---------------------------------------------------------------

  defp push(socket, step, text, level) do
    line = line(step, text, level, RunLog.now())
    assign(socket, lines: Enum.take(socket.assigns.lines ++ [line], -@log_limit))
  end

  # A recorded step keeps its own instant, and the page writes a clock it can
  # hand to the browser: the words are the run's, the hour is the reader's.
  defp record_line(entry), do: line(entry["step"], RunLog.text(entry), :info, RunLog.at(entry))

  defp line(step, text, level, at) do
    %{
      id: System.unique_integer([:monotonic, :positive]),
      step: step,
      text: text,
      level: level,
      at: at
    }
  end

  defp line_class(%{level: :error}), do: "text-error"
  defp line_class(%{level: :warning}), do: "text-warning"
  defp line_class(_info), do: ""

  # The page can hold a run id whose worker is gone — the VM restarted, the job
  # was killed. Waiting for news that will never come is the worst state a page
  # can be in, so say it happened.
  defp settle(socket, run_id) do
    case RunHistory.head(run_id) do
      %{status: "running"} = record ->
        {:ok, _} =
          RunHistory.finish(record, %{"reason" => "nothing was running it any more"}, "failed")

        assign(socket, status: "failed")

      _finished_or_gone ->
        socket
    end
  end

  defp changeset_errors(%Ecto.Changeset{} = changeset) do
    Enum.map_join(changeset.errors, ", ", fn {field, {message, _}} -> "#{field}: #{message}" end)
  end

  # -- helpers ---------------------------------------------------------------

  # A gutter between columns, once, for both tables that show runs. Without it
  # a duration and the world it was measured in read as one word ("38.3
  # smujoco"), and a header sits on its neighbour's values. The last column has
  # no trailing padding, so the row does not end in a gap.
  defp table_class do
    "w-full text-xs [&_th]:pb-1 [&_th]:pr-4 [&_td]:py-0.5 [&_td]:pr-4 " <>
      "[&_th:last-child]:pr-0 [&_td:last-child]:pr-0"
  end

  # The route is a glob, so the name arrives as its segments.
  defp name_of(%{"name" => segments}), do: segments |> List.wrap() |> Enum.join("/")
  defp name_of(_params), do: ""

  defp steps(params) do
    case Integer.parse(to_string(params["steps"] || "")) do
      {count, ""} when count > 0 -> count
      _default -> nil
    end
  end

  # The safety cap a run gets when the page names none: the config's own ceiling
  # on one episode. The per-mode limits belong to the recognition policy, which
  # is what actually ends an episode; this is only here so an episode that never
  # recognises anything still ends.
  defp cap(nil, setup), do: Setup.max_total_steps(setup) || Monty.Studio.Run.default_steps()
  defp cap(asked, _setup), do: asked

  # `?episodes=N`: a slice of the experiment, for when the whole of it — every
  # object in every rotation — is more than a person wants to wait for now.
  defp episodes(params) do
    case Integer.parse(to_string(params["episodes"] || "")) do
      {count, ""} when count > 0 -> count
      _default -> nil
    end
  end

  # A world that is not Monty's simulator is a warning, not a badge of honour:
  # the experiment's own numbers come from MuJoCo, and a stand-in is not it.
  defp world_badge(%{world: :mujoco}), do: "badge-ghost"
  defp world_badge(_setup), do: "badge-warning"

  defp world_note(%{world: :mujoco} = setup) do
    "MuJoCo, in the interpreter this application carries: the experiment's " <>
      "`environment` names #{engine_of(setup)}, and the scene, the agents, their " <>
      "cameras and their images are built here from that config. No Python has to " <>
      "be installed."
  end

  defp world_note(_setup) do
    "This port's own scene: one sphere, stepped in the BEAM. A run here exercises " <>
      "the port, not the experiment — choose MuJoCo above to step the world the " <>
      "experiment was written for."
  end

  defp engine_of(%{environment: %{module: %{class: class}}}), do: class
  defp engine_of(_setup), do: "the config's simulator"

  # What the selector sends back, as the atom a setup carries. A value that is
  # neither is nothing to do, because a page cannot ask for a world no port here
  # has. `"habitat"` is kept for a browser sitting on the old page: it is the
  # world this build no longer carries, so asking for it changes nothing.
  defp world_of("mujoco"), do: :mujoco
  defp world_of("synthetic"), do: :synthetic
  defp world_of(_other), do: nil

  # The experiment, re-opened in the world that was just chosen: the badge, the
  # findings and the record a run leaves all come from the setup, so they follow
  # from one open rather than from a field patched in three places.
  defp reopened(socket, world) do
    case Studio.open(socket.assigns.opened.name, world_simulator: world) do
      {:ok, opened} ->
        socket
        |> assign(
          opened: opened,
          logging: Logging.open(opened.setup).notes,
          error: nil,
          needs: needs(opened),
          missing: missing(opened)
        )

      {:error, reason} ->
        assign(socket, error: reason)
    end
  end

  # How many episodes to run at once. Eight is a ceiling rather than a judgement
  # about what a machine can do: each run is its own world and its own simulator
  # process, and a number large enough to matter is a number that ends in swap.
  @most_in_parallel 8

  defp parallelism(params) do
    case Integer.parse(to_string(params["parallelism"] || "")) do
      {count, ""} -> count |> max(1) |> min(@most_in_parallel)
      _default -> 1
    end
  end

  # A run starts only when the config composes *and* the files it reads are
  # there. The two refusals are different — a composition error is the config's,
  # a missing download is this machine's — so the page says which one it is.
  # A run starts when the config composes and the files it reads are here: two
  # conditions, and the page says which one is in the way.
  defp runable?(assigns), do: config_runnable?(assigns) and missing(assigns[:opened]) == []

  defp config_runnable?(assigns) do
    case assigns[:opened] do
      nil -> false
      opened -> Setup.valid?(opened.setup)
    end
  end

  # An option nobody can pick should say so where it is picked: the engine is
  # the experiment's, and whether this deployment has it is a fact about the
  # deployment, not about the config. Only answered when an interpreter was
  # named: "not installed" about a `python3` nobody chose is not a fact.
  defp unavailable(setup, :habitat) do
    case Prerequisites.engine(setup) do
      nil ->
        ""

      engine ->
        if Prerequisites.python_configured?() and not Prerequisites.engine_installed?(engine),
          do: " — not in MONTY_PYTHON",
          else: ""
    end
  end

  defp unavailable(_setup, _world), do: ""

  defp any_remedy?(needs, remedy), do: Enum.any?(needs, &(Prerequisites.remedy(&1) == remedy))

  # Which files a run of this experiment reads before it steps, and which of
  # them are not here. A stand-in run reads nothing, so this is empty for one.
  defp needs(opened), do: Prerequisites.for_setup(opened.setup)

  defp missing(nil), do: []
  defp missing(opened), do: needs(opened) |> Enum.reject(& &1.present?)

  defp with_seed(%{setup: setup} = opened, seed),
    do: %{opened | setup: Setup.with_seed(setup, seed)}

  defp with_chosen_seed(%{assigns: %{opened: %{} = opened}} = socket, value) do
    case Integer.parse(to_string(value)) do
      {seed, ""} -> assign(socket, seed: seed, opened: with_seed(opened, seed))
      _not_a_number -> socket
    end
  end

  defp with_chosen_seed(socket, _value), do: socket
end
