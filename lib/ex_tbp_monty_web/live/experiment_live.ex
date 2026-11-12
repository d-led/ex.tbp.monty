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

  require Logger

  alias Monty.Prerequisites
  alias Monty.Studio

  alias Monty.Studio.{
    Belief,
    Catalog,
    Chart,
    Duration,
    Failure,
    Jobs,
    LogFilter,
    Logging,
    Memory,
    Panel,
    Partition,
    Parts,
    Replay,
    RunHistory,
    RunLog,
    RunStream,
    Setup
  }

  alias Monty.Studio.Jobs.Reaper

  # A log is a thing a person reads back, not a database: the last few thousand
  # lines are enough to scroll through a run and bounded enough that a runaway
  # experiment cannot take the page with it.
  @log_limit 300

  # How often the picture may be redrawn. `Chart.new/2` reads the run's whole
  # history — measured at 14 ms of a 500-step run and 22 ms of a 7 000-step one,
  # windowed or not — and a step can arrive faster than that. A page that rebuilt
  # the chart for every step spends the run drawing and never catches up with its
  # own mailbox: the heap grows with the backlog, the socket misses its heartbeat,
  # and the reader sees "lost connection to the server" while the run is fine.
  #
  # A test that delivers steps faster than a person can watch sets it to nought:
  # there is no socket to keep alive, and every step's picture is worth asserting.
  @chart_interval 250
  @impl true
  def mount(params, _session, socket) do
    # Runs of this experiment arrive as messages, the same way a run's steps do:
    # the record is written once, and every page showing it hears about it. No
    # page has to ask the database what changed.
    socket =
      if connected?(socket) do
        RunHistory.subscribe()
        Logger.info("page opened: #{name_of(params)}", experiment: name_of(params))
        # The staleness check is asked for here and answered in `handle_info/2`:
        # it reads every open run and asks Oban about each, and a page that waits
        # for it before drawing shows nothing until it is done — which, on the
        # first visit after a restart, is exactly when somebody is waiting. A
        # message to ourselves is after this render and before anything the
        # reader can do.
        #
        # "Here" is every connected mount, which includes every websocket
        # reconnect: a page that comes back is a page whose run may have died
        # while it was away, and the answer arrives on the run's own topic like
        # everything else the run says.
        send(self(), :reap)
        socket
      else
        socket
      end

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
      # What the config itself runs, so the control beside it can say "of 2 in
      # the config" rather than leaving a reader to compare a number with a
      # sentence in another panel.
      episodes_in_config: Setup.episodes(opened.setup),
      # And the config's own ceiling on one episode, which is what an empty step
      # field means: the placeholder shows it, so an empty box is a promise
      # rather than a blank.
      steps_in_config: cap(nil, opened.setup),
      # What a run of this experiment reads off the disk, and which of those is
      # not there yet: the run buttons stay disabled while anything is missing,
      # and the checks box names it.
      needs: needs(opened),
      missing: with_actions(missing(opened)),
      # One run until somebody asks for more: parallelism is a choice made on
      # this page, not something a link should be able to set for them.
      parallelism: 1,
      # The batch a press of Run started and the page shows: `nil` until a run of
      # this experiment is followed, and then the parts whose cards the page draws
      # beside the run it is watching (`Monty.Studio.Partition`).
      batch: nil,
      parts: [],
      filter: "",
      # Which stretch of the run's own x axis the chart draws, `{from, to}` or
      # `nil` for all of it. It comes from the URL rather than from an assign the
      # page owns: a zoomed chart is a link that can be kept, and every way of
      # changing it — zoom, pan, reset — is a patch.
      x_window: window,
      # Full screen is part of the page, not of the chart: it exists before the
      # first step arrives and outlives the charts being rebuilt by every one.
      expanded: Map.get(socket.assigns, :expanded),
      # The box each chart was given, in the browser's own pixels, once the
      # browser has said — `%{module_id => {width, height}}`, empty while a
      # chart is still drawn for the shape it was built with.
      chart_sizes: Map.get(socket.assigns, :chart_sizes, %{}),
      # Following the newest steps is the default: a page opened on a run that is
      # still going is a page watching it, not a page reading it.
      follow: Map.get(socket.assigns, :follow, true),
      # The seed a run here would start from. It is the config's until somebody
      # changes it, which is what makes it worth showing: the number a sweep is
      # about is the one a page can say.
      seed: opened.setup.seed
    )
    |> stream_configure(:frames, dom_id: &"frame-#{&1.sensor_id}")
    |> watching_nothing()
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

  # How long the run has been going, or how long it took. A row that has not
  # finished has no stored duration — that is written when it closes — and a
  # nought there was read as "took no time" about a run that was stepping.
  defp run_duration(run), do: Duration.of_run(run)

  # What a page can be set here, read off the run's own record: the rest is the
  # run page's business.
  defp input_of(%{inputs: %{} = inputs}, key), do: Map.get(inputs, key) |> to_string()
  defp input_of(_run, _key), do: "—"

  # A run outlives its page, so a page that loads must find the run its
  # experiment is in the middle of instead of pretending nothing is happening.
  defp follow_running(%{assigns: %{opened: %{name: name}}} = socket) do
    case RunHistory.running_for(name) do
      nil -> socket
      record -> follow(socket, record)
    end
  end

  defp follow(socket, record) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ExTbpMonty.PubSub, Jobs.Run.topic(record.id))
      Logger.info("page follows #{record.id}: subscribed to #{Jobs.Run.topic(record.id)}")
    end

    # A page that moves to another run starts that run's story, not the last
    # one's.
    socket
    |> clear_run_view()
    |> assign(
      run_id: record.id,
      batch: batch_of(record),
      status: record.status,
      progress: steps_of_last_episode(record),
      # The counter restarts inside every episode, so the episode it belongs to
      # belongs to the run being followed.
      episode: last_episode(record),
      log_path: record.log_path,
      summary: nil
    )
    |> seed(record.id)
    |> watch()
  end

  # The batch a record belongs to, if it is a part of one: the id is what the
  # parts of one press of Run share (`Monty.Studio.Partition`).
  defp batch_of(%{inputs: %{"batch" => batch}}) when is_binary(batch), do: batch
  defp batch_of(_run_of_the_whole_experiment), do: nil

  # The record, read once, when this page starts watching a run: the lines it
  # already printed, the last frame it kept, and the beliefs the chart draws from
  # before the page arrived. Everything after this arrives as `{:step, …}`
  # messages, so the poll never reads the transcript again — a run that has
  # stepped twenty thousand times keeps a quarter of a gigabyte of pictures in
  # that row, and two of those a second was what an experiment page cost while its
  # run was trying to step.
  #
  # Read without the pictures (`RunHistory.head/1`): a timeline entry is 11 kB a
  # step and this page draws one of them — the last — which it asks for on its
  # own (`sensors_at/2`). Reading the row whole is what made this page take half
  # a minute to open on a run of thirteen thousand steps, long enough for the
  # socket to give up and reconnect, and none of the pictures but one was drawn.
  defp seed(socket, run_id) do
    case RunHistory.head(run_id) do
      nil ->
        socket

      record ->
        socket
        # What the record gave is what the page starts out having seen; the poll
        # counts the run against this, so a page seeded from a record that was
        # written at a boundary asks the stream for the steps taken since.
        |> assign(steps_seen: length(record.log))
        |> merge_lines(record)
        |> merge_beliefs(record)
        |> merge_frames(record)
    end
  end

  # Everything on the page that belongs to *one* run: the beliefs a chart is drawn
  # from, the chart itself, the picture of where the agent is, and the two flags
  # that say what has already been seeded from a record.
  #
  # Both ways into a run go through it — a second press of "Run it" as much as a
  # page following a run already going. Without it a second run's steps land in
  # the first run's chart: the same episode numbers mean the same x, so the lines
  # of two runs that never happened together are drawn as one.
  defp clear_run_view(socket) do
    socket
    |> assign(
      beliefs: %{},
      charts: %{},
      episode_objects: %{},
      centre: nil,
      chart_extent: {0, 0},
      beliefs_seeded: false,
      frames_seeded: false,
      caught_up: false,
      # How many of the run's steps this page has applied, from whichever way it
      # heard of them. It is what the poll compares the run's own count with: a
      # page that hears every step is nought behind, and one that missed a
      # message never hears of the step again.
      steps_seen: 0,
      # The parts of the previous batch's cards go with the previous run: a page
      # that moves to another run must not keep drawing somebody else's batch.
      parts: []
    )
    |> stream(:frames, [], reset: true)
  end

  # The run part of the page with nothing in it: how a page starts, and where it
  # returns when the run it was waiting for turns out to be over before it
  # stepped once. What the reader set themselves — the filter, the window, the
  # boxes they have opened — is theirs and is left alone.
  defp watching_nothing(socket) do
    socket
    |> clear_run_view()
    |> assign(
      run_id: nil,
      batch: nil,
      status: nil,
      progress: {0, socket.assigns.steps},
      # Which episode the step counter is counting inside: it restarts at every
      # episode, so a badge without it reads as a run going backwards.
      episode: 0,
      lines: [],
      summary: nil,
      log_path: nil
    )
  end

  # The lines a run already printed are in the record; showing the log from the
  # beginning beats showing it from the moment this page opened.
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

      <ExTbpMontyWeb.StudioComponents.findings
        findings={checks(@opened.setup.findings)}
        needs={@missing}
      />

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
            disabled={!startable?(assigns)}
          >
            <.icon name="hero-play-mini" class="size-4" /> Run it
          </button>
          <%!-- Stop is about the experiment, not about the run this page
          happens to be following: a run started from another tab, and the
          second, third and fourth of a parallel press, are runs of this
          experiment too. It is here whenever one of them is going, and it stops
          all of them — a reader who says "stop" means the thing they started,
          not the one page that was watching it. Beside Run, where a person looks
          for it: it used to be a ghost at the end of this row, where nobody
          looking for it found it. Neutral rather than a warning colour — stopping
          is an ordinary thing to want, not something to be warned about — and the
          icon says what it is. --%>
          <button
            :if={in_flight(assigns) != []}
            id="stop"
            phx-click="stop"
            class="btn btn-outline btn-sm"
            title="Stop it at its next step"
          >
            <.icon name="hero-stop-mini" class="size-4" /> {stop_label(assigns)}
          </button>
          <%!-- What a run does, as two numbers on the page. The step budget is a
          ceiling, not a target — the experiment's own recognition policy ends
          each episode first, and for a recognition that is about twenty
          matching steps — and the episode count is the whole config unless a
          reader slices it. Both used to live in the address bar and nowhere
          else, which is how a page ran one episode of a config that says two
          and read as the experiment stopping early by itself. --%>
          <form
            :if={@opened}
            id="run-budget"
            phx-change="budget"
            class="flex flex-wrap items-center gap-1 font-mono text-[11px] text-base-content/60"
          >
            <label for="run-episodes">episodes</label>
            <input
              id="run-episodes"
              type="number"
              name="episodes"
              min="1"
              max={@episodes_in_config}
              value={@episodes}
              placeholder={to_string(@episodes_in_config)}
              class="input input-xs w-16"
              aria-label="How many of the config's episodes to run"
            />
            <span id="run-episodes-note">of {@episodes_in_config} in the config</span>
            <label for="run-steps" class="ms-2">steps each, at most</label>
            <input
              id="run-steps"
              type="number"
              name="steps"
              min="1"
              value={@steps}
              placeholder={to_string(@steps_in_config)}
              class="input input-xs w-24"
              aria-label="The most steps one episode may take"
            />
          </form>
          <button id="step" phx-click="step" class="btn btn-sm" disabled={!startable?(assigns)}>
            <.icon name="hero-forward-mini" class="size-4" /> One step
          </button>
          <%!-- Monty starts a parallel run with a second script; here it is a
          number of *parts*, and it means what the script's `num_parallel` means
          there: the experiment divided between that many processes — evaluation
          by episode, training by object. Not that many copies of it: a hundred
          and forty episodes at four parts is a quarter of the clock, where four
          copies were four times the work. --%>
          <form id="parallelism" phx-change="parallelism" class="flex items-center gap-1">
            <label for="parallelism-count" class="text-[11px] text-base-content/60">in parallel</label>
            <select
              id="parallelism-count"
              name="parallelism"
              class="select select-xs w-16"
              aria-label="How many parts to run the experiment in"
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
          <span :if={@run_id} id="run-progress" class="badge badge-ghost">
            episode {(@episode || 0) + 1} · step {elem(@progress, 0)} / {elem(@progress, 1)}
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

        <%!-- Why the run cannot start is in the checks box below, with the
        missing files, their paths on their own lines and one action each. A
        second box here said the same thing in other words; what is left is the
        way out that costs nothing. --%>
        <p :if={@missing != []} id="needs-hint" class="text-xs text-base-content/70">
          Or step this port's stand-in scene, which reads nothing from disk.
        </p>

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

          <%!-- What this experiment has done, in a box that scrolls: a config run
          a hundred times is a hundred rows, and the chart above it should stay
          where a reader put it. --%>
          <div :if={@runs != []} class="max-h-[60vh] overflow-auto rounded-box border border-base-300">
            <table
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
          </div>
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
                {window_label(@chart_window, @chart_extent)}
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
              <%!-- Full screen is per chart: four learning modules are four
              opinions, and the one a reader wants to read is the one they
              clicked. Escape leaves it, as does the same control. --%>
              <%!-- The one control the dashboard had that this page did not: while
              a run is going, a window that is zoomed into should keep showing the
              newest steps, or the chart quietly falls behind the experiment. --%>
              <label class="ml-2 flex items-center gap-1 text-[11px] text-base-content/70">
                <input
                  type="checkbox"
                  id="follow-latest"
                  class="checkbox checkbox-xs"
                  checked={@follow}
                  phx-click="follow"
                  phx-value-follow={to_string(not @follow)}
                /> follow latest steps
              </label>
              <%!-- The wheel and the double click leave no trace on the page, so
              the page says them: the same two gestures the run page's chart has,
              which is where a reader learns them. --%>
              <span id="chart-hint" class="ml-2 text-[11px] text-base-content/50">
                wheel to zoom · double-click for the whole run
              </span>
            </div>
          </div>
          <div
            id="charts"
            phx-hook=".EscapeCollapse"
            phx-window-keydown="collapse"
            phx-key="Escape"
            phx-window-keyup="collapse"
            class="grid gap-2"
          >
            <script :type={Phoenix.LiveView.ColocatedHook} name=".EscapeCollapse">
              import { isEscape } from "../../../../../assets/js/keys.js"

              // Escape leaves full screen at once, in the browser, and tells the
              // server after: while a run is stepping that round trip is what
              // made the key feel like it did nothing.
              //
              // Both the click and the key set one attribute — the same one the
              // server renders — and CSS decides what full screen looks like.
              // Nothing here rewrites a class: these cards are patched by
              // LiveView, and a hook that writes their attributes is a second
              // author of the same markup.
              export default {
                mounted() {
                  this.escape = (event) => {
                    if (!isEscape(event)) return

                    const card = this.el.querySelector("[data-fullscreen=true]")
                    if (card === null) return

                    this.pending = { card: card, expanded: false, at: Date.now() }
                    this.setFullScreen(card, false)
                    this.pushEvent("collapse", {})
                  }

                  // Capture phase, on the window: the first listener a key
                  // reaches. Bubbling from `window` comes after every element
                  // handler, and an open `<select>`, a `<dialog>` or anything
                  // that calls `stopPropagation` takes the key on the way.
                  window.addEventListener("keydown", this.escape, true)
                  window.addEventListener("keyup", this.escape, true)

                  // The box changes here, on the click itself; the picture is
                  // the server's and arrives when it can.
                  this.el.addEventListener("click", (event) => {
                    const button = event.target.closest?.("[data-fullscreen-control]")
                    if (button === undefined || button === null) return

                    const card = button.closest("[data-fullscreen]")
                    if (card === null) return

                    const expanded = card.dataset.fullscreen !== "true"
                    this.pending = { card: card, expanded: expanded, at: Date.now() }
                    this.setFullScreen(card, expanded)
                  })
                },

                // A patch computed before the click can land after it and put
                // the card back where it was, so the layout that was asked for
                // is held until the server's render agrees — no longer than four
                // seconds, so a real answer always wins.
                updated() {
                  if (this.pending === undefined) return

                  const { card, expanded, at } = this.pending
                  if (!card.isConnected || Date.now() - at > 4000) {
                    this.pending = undefined

                    return
                  }

                  if ((card.dataset.fullscreen === "true") === expanded) {
                    this.pending = undefined

                    return
                  }

                  this.setFullScreen(card, expanded)
                },

                destroyed() {
                  window.removeEventListener("keydown", this.escape, true)
                  window.removeEventListener("keyup", this.escape, true)
                },

                setFullScreen(card, expanded) {
                  card.dataset.fullscreen = expanded ? "true" : "false"
                }
              }
            </script>
            <div
              :for={{module_id, chart} <- @charts}
              id={"chart-card-#{module_id}"}
              data-expanded={to_string(@expanded == module_id)}
              data-fullscreen={to_string(@expanded == module_id)}
              class="rounded-field"
            >
              <ExTbpMontyWeb.EvidenceChart.evidence_chart
                module_id={module_id}
                chart={chart}
                expanded={@expanded == module_id}
              >
                <%!-- On the plot, in its top right corner, because the plot is
                what it acts on: a control in a header row acts on "the chart"
                in the abstract, and the expanded picture then hides it. --%>
                <:control>
                  <button
                    id={"chart-expand-#{module_id}"}
                    data-fullscreen-control
                    phx-click="expand"
                    phx-value-module={module_id}
                    class="btn btn-sm size-8 min-h-0 p-0 absolute right-2 top-2 z-10 border border-base-300"
                    aria-label={
                      if @expanded == module_id, do: "leave full screen (Esc)", else: "full screen"
                    }
                    title={
                      if @expanded == module_id, do: "leave full screen (Esc)", else: "full screen"
                    }
                  >
                    <span class="fullscreen-glyph-out">
                      <.icon name="hero-arrows-pointing-out" class="size-4" />
                    </span>
                    <span class="fullscreen-glyph-in">
                      <.icon name="hero-arrows-pointing-in" class="size-4" />
                    </span>
                  </button>
                </:control>
              </ExTbpMontyWeb.EvidenceChart.evidence_chart>
            </div>
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

        <%!-- One card per part, one after the other: the pyview dashboard's
        multi-publisher view. A parallel run is several runs, and the page above
        draws the one this page is following in full. --%>
        <ExTbpMontyWeb.RunParts.parts :if={@parts != []} parts={@parts} />

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
        # Through `assign_charts/2` rather than drawing here: a window a zoom
        # asks for is still subject to following, and two places computing the
        # drawn window is how a page comes to draw one stretch and label another.
        socket
        |> assign(x_window: window)
        |> request_drawing()
        |> assign(
          # Full screen survives the steps that arrive while it is on: it is a
          # property of how the page is being read, not of the run.
          expanded: Map.get(socket.assigns, :expanded)
        )
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("run", _params, %{assigns: %{opened: opened, steps: steps}} = socket) do
    case refusal(socket.assigns) do
      nil -> start(socket, opened, steps, socket.assigns.parallelism, socket.assigns.episodes)
      :going -> already_going(socket, opened)
      :cannot_run -> {:noreply, socket}
    end
  end

  # The chart is drawn for a stretch of the run, and zooming means saying which:
  # `in` halves it around the middle, `out` doubles it, `left` and `right` move
  # it by a quarter without changing its width, and `all` is the whole run.
  # Each is a patch, so the address bar follows the picture. Zooming starts from
  # the window on screen rather than the one asked for, so following does not
  # make the buttons work on a stretch nobody is looking at.
  # A drag or a wheel asks for the stretch under the pointer rather than a
  # direction, so the window is the caller's — clamped to the run, which is the
  # one thing a chart cannot see from where it is drawn. A stretch narrower than
  # a step says nothing, and the picture stays as it is rather than jumping to
  # the whole run under a reader who only scrolled too hard.
  def handle_event("zoom", %{"from" => from, "to" => to}, socket),
    do: zoom_to(socket, from, to)

  def handle_event("zoom", %{"how" => how}, socket), do: zoom_by(socket, how)

  def handle_event("expand", %{"module" => module_id}, socket),
    do: {:noreply, show_chart(socket, module_id)}

  # Escape and the control itself are the same request: leave full screen.
  def handle_event("collapse", _params, socket), do: {:noreply, show_chart(socket, nil)}

  # The chart filling the screen says how big its box is, because only the
  # browser knows: a picture drawn for a guessed screen is a picture stretched
  # into it, and one drawn for the real box has square labels and an axis as long
  # as it is read.
  def handle_event("chart-size", params, socket), do: {:noreply, size_chart(socket, params)}

  # Turning following off is how a reader says "leave the window where I put it";
  # turning it back on slides it to the newest step at the next step to arrive.
  #
  # The tick's own value travels with the click and is what the page assigns: a
  # label that wraps its checkbox can deliver the activation twice in a browser,
  # and a handler that merely inverted the assign would then put the tick back
  # where it was — which is the box that "sprang back" when it was unticked.
  def handle_event("follow", params, socket), do: set_follow(socket, params)

  def handle_event("parallelism", %{"parallelism" => count}, socket) do
    {:noreply, assign(socket, parallelism: parallelism(%{"parallelism" => count}))}
  end

  # The two numbers that make a run shorter than the experiment. Set here, by a
  # reader looking at them, and not by whatever the address bar was carrying: a
  # run's budget is a decision about the run.
  def handle_event("budget", params, socket), do: {:noreply, assign_budget(socket, params)}

  # A seed this page cannot read is not a seed: the number stays as it was and
  # the run keeps the one the setup already had.
  def handle_event("seed", %{"seed" => value}, socket),
    do: {:noreply, with_chosen_seed(socket, value)}

  # The world is a choice made here and recorded on the run, not a property of
  # the deployment: the queue executes what the record says it was given, so two
  # workers with different settings cannot disagree about it afterwards.
  def handle_event("world", %{"world" => choice}, socket) do
    case world_of(choice) do
      nil ->
        {:noreply, socket}

      world ->
        # Opening a config in another world costs what the config costs, not what
        # the page costs: it is composed in a task, so the steps still streaming
        # in are answered while it goes and the socket is never held open for it.
        name = socket.assigns.opened.name

        {:noreply,
         start_async(socket, :world, fn -> Studio.open(name, world_simulator: world) end)}
    end
  end

  # One step is a run of one step: a person clicking it twice wants two runs to
  # look at, not one run that pretends to have done two.
  def handle_event("step", _params, %{assigns: %{opened: opened}} = socket) do
    case refusal(socket.assigns) do
      nil -> start(socket, opened, 1, 1, 1)
      :going -> already_going(socket, opened)
      :cannot_run -> {:noreply, socket}
    end
  end

  # Stop ends every run of this experiment that is still going, and it is here
  # whether or not this page is the one watching: a run started from another tab,
  # or the second of a parallel press, is a run of this experiment too.
  #
  # `Jobs.cancel/1` is the whole answer for both shapes of job. One still waiting
  # its turn is cancelled outright, because cancelling is the only thing that was
  # going to happen to it; one that is executing is asked to end at its next step,
  # so it still writes down the steps it took.
  def handle_event("stop", _params, socket) do
    outcomes = socket.assigns |> in_flight() |> Enum.map(&cancel/1)
    {text, level} = stopped(outcomes)

    {:noreply, socket |> push(nil, text, level) |> refresh_runs()}
  end

  def handle_event("filter", %{"filter" => text}, socket) do
    {:noreply, assign(socket, filter: text)}
  end

  # A tick's own value, or the opposite of what the page shows when a client
  # sends none (a test, or a page built before this attribute existed).
  defp wanted_follow(%{"follow" => value}, _socket) when value in ["true", "false"],
    do: value == "true"

  defp wanted_follow(_params, socket), do: not Map.get(socket.assigns, :follow, true)

  # A window that is asked for is a reader saying which stretch they are reading,
  # and following slides it out from under them: a drag across the middle of a run
  # drew a window of that width at the newest step, not the stretch the reader
  # chose. Zooming back out to the whole run is not that — the whole run is where
  # the newest step is — so following survives it.
  defp stop_following(%{assigns: %{follow: false}} = socket), do: socket
  defp stop_following(socket), do: assign(socket, :follow, false)

  # The stretch the pointer chose, as the window the page then keeps.
  defp zoom_to(socket, from, to) do
    case range_window(socket.assigns[:chart_extent], count_of(from), count_of(to)) do
      nil ->
        {:noreply, socket}

      window ->
        {:noreply, socket |> stop_following() |> push_patch(to: experiment_path(socket, window))}
    end
  end

  # One of the legend's own directions, as a window.
  defp zoom_by(socket, how) do
    window = zoom(socket.assigns[:chart_window], socket.assigns[:chart_extent], how)
    socket = if how == "all", do: socket, else: stop_following(socket)

    {:noreply, push_patch(socket, to: experiment_path(socket, window))}
  end

  # The tick, and what it does to the window: on, the window slides to the newest
  # step; off, the picture stays where it is (`freeze_window/1`).
  defp set_follow(socket, params) do
    case wanted_follow(params, socket) do
      true -> {:noreply, socket |> assign(:follow, true) |> request_drawing()}
      false -> {:noreply, freeze_window(socket)}
    end
  end

  # Following stops where the picture is. A window that slid to the newest step
  # while the reader followed it becomes the window the page keeps, so saying
  # "leave it here" does not throw them back to a stretch they asked for minutes
  # ago — and the address bar names what is on screen, because a window that is
  # drawn is a window somebody can send.
  defp freeze_window(socket) do
    socket = assign(socket, :follow, false)

    case {Map.get(socket.assigns, :chart_window), Map.get(socket.assigns, :x_window)} do
      {nil, _unzoomed} -> request_drawing(socket)
      {window, window} -> request_drawing(socket)
      {window, _asked} -> push_patch(socket, to: experiment_path(socket, window))
    end
  end

  defp range_window(_extent, nil, _to), do: nil
  defp range_window(_extent, _from, nil), do: nil

  defp range_window({first, last}, from, to) do
    if to - from >= 1, do: clamp({from, to}, first, last), else: nil
  end

  # A box the browser measured. A chart narrower than a couple of hundred pixels
  # cannot carry a labelled axis, and one larger than any display is a mistake,
  # so a number outside that range is not a size to draw at.
  defp measured_size(%{"module" => module_id, "width" => width, "height" => height}) do
    with true <- is_binary(module_id) and module_id != "",
         {width, ""} <- Integer.parse(to_string(width)),
         {height, ""} <- Integer.parse(to_string(height)),
         true <- width in 200..4_000 and height in 120..4_000 do
      {module_id, width, height}
    else
      _ -> nil
    end
  end

  defp measured_size(_params), do: nil

  defp assign_budget(socket, params) do
    assign(socket,
      episodes: count_of(params["episodes"]),
      steps: cap(count_of(params["steps"]), socket.assigns.opened.setup)
    )
  end

  # One chart at a time, drawn for the box it has: the size measured for the
  # chart that was expanded belongs to it, so another one — or none — goes back
  # to the size of its cell.
  defp show_chart(socket, module_id) do
    expanded = if Map.get(socket.assigns, :expanded) == module_id, do: nil, else: module_id

    socket
    |> assign(:expanded, expanded)
    |> assign(:chart_sizes, %{})
    |> request_drawing()
  end

  defp size_chart(socket, params) do
    case measured_size(params) do
      nil ->
        socket

      {module_id, width, height} ->
        socket
        |> assign(:chart_sizes, Map.put(chart_sizes(socket.assigns), module_id, {width, height}))
        |> request_drawing()
    end
  end

  @impl true
  # A run of this experiment was written down, or settled. The row this page
  # draws is the record the database just wrote, so a run that is still queued is
  # in the table from the moment it is queued — not when a worker picks it up.
  def handle_info({:recorded, run}, %{assigns: %{opened: %{name: name}}} = socket)
      when run.experiment == name do
    {:noreply,
     socket
     |> put_run(run, :first)
     |> follow_if_idle(run)}
  end

  def handle_info({:recorded, _other}, socket), do: {:noreply, socket}

  def handle_info({:settled, run}, %{assigns: %{opened: %{name: name}}} = socket)
      when run.experiment == name do
    {:noreply, put_run(socket, run, :in_place)}
  end

  def handle_info({:settled, _other}, socket), do: {:noreply, socket}

  # A step, and every step that is already waiting behind it: a page that fell
  # behind does not have to draw each of them to be right about the last one, and
  # a run should not wait for its readers. Every line still goes into the
  # transcript; what a backlog costs is the drawing of the steps the newest one
  # has already replaced.
  def handle_info({:studio, run_id, {:step, event}}, %{assigns: %{run_id: run_id}} = socket) do
    if steps_seen(socket) == 0,
      do: Logger.info("page hears its first step of #{run_id} (episode #{event.episode})")

    {steps, stopped_by} = drain_steps(run_id, [event])

    socket = handle_steps(steps, socket)

    # Whatever stopped the drain is handled now, after the steps that came
    # before it — it is not put back into the mailbox, where it would land
    # behind steps it arrived ahead of. An episode's own message is the case
    # that matters: applied late, the steps of the new episode are counted
    # against the old one's progress and drawn in the old one's band.
    socket =
      case stopped_by do
        nil -> socket
        event -> handle_studio(event, socket)
      end

    {:noreply, socket}
  end

  def handle_info({:studio, run_id, event}, %{assigns: %{run_id: run_id}} = socket) do
    {:noreply, handle_studio(event, socket)}
  end

  def handle_info({:studio, other_run, _event}, socket) do
    if steps_seen(socket) == 0 do
      Logger.info(
        "page follows #{inspect(socket.assigns[:run_id])} and ignored a message for #{other_run}"
      )
    end

    {:noreply, socket}
  end

  # The staleness check the page asked for when it loaded, answered before
  # anything the reader can do. It is a message to ourselves rather than work in
  # `mount/3`, so the page paints first; a run that turned out to be gone becomes
  # a failed run with its reason, on screen, without a reload.
  def handle_info(:reap, socket) do
    {:noreply, after_reap(socket, Reaper.sweep())}
  end

  # A run that turned out to be gone becomes a failed run with its reason, on
  # screen, without a reload. This and `handle_async(:world, ...)` below are one
  # group: a callback's clauses belong together, however far the calls that
  # start them are apart.

  # The drawing a step asked for and could not have yet.
  def handle_info(:chart_due, socket) do
    {:noreply, socket |> assign(:chart_pending?, false) |> request_drawing()}
  end

  # A run is the experiment's, not the page's: two people (or two tabs) looking at
  # the same experiment watch the same run. So a page with nothing to watch asks
  # whether one has started since it opened, and a page whose run has finished
  # asks whether another has begun — the answer is the same run for everybody.
  def handle_info(:studio_poll, socket) do
    # The same check the run page makes, for the run this page shows: a worker
    # that died leaves the word `running` behind, and closing the record is what
    # stops a page saying it. It is the cheap question — one run, counters only —
    # and the answer comes back on the run's topic like everything else the run
    # says, so the page draws it from `handle_studio/2`.
    _ =
      if socket.assigns[:run_id] && socket.assigns.status == "running",
        do: Reaper.reap(socket.assigns.run_id)

    socket =
      socket
      |> follow_started()
      |> reconcile()
      |> refresh_parts()

    # The clock does not stop while the page is open. It used to, for anything
    # whose status was not `running` — and a run that started while the page
    # still held `queued` (the worker's own status write is one more message
    # that can be lost, and a page that opened before the job was picked up has
    # seen nothing else) left the page standing there for ever. That is a page
    # looking at a run it does not follow, which is what a reader reports as the
    # live updates having stopped.
    {:noreply, watch(socket)}
  end

  # The run's cards, brought up to date with the steps its parts have taken since
  # the last poll (`Monty.Studio.Parts`). A run of one part is the run the page is
  # already drawing in full, so it draws no cards at all.
  defp refresh_parts(socket) do
    setup = socket.assigns.opened && socket.assigns.opened.setup
    record = socket.assigns[:run_id] && RunHistory.progress(socket.assigns.run_id)
    held = Parts.refresh(record, Map.get(socket.assigns, :parts_held, %{}))

    if setup == nil or length(Map.keys(held)) < 2 do
      assign(socket, parts_held: held, parts: [])
    else
      socket
      |> assign(parts_held: held)
      |> assign(parts: Parts.cards(held, setup))
    end
  end

  # Zero is the ordinary answer to the staleness check and costs nothing. A run
  # that was closed is one this page may be describing as `running`, so it is
  # read again — the run, and the list of runs this experiment has.
  defp after_reap(socket, closed) when closed > 0 do
    socket
    |> reconcile()
    |> let_go_of_a_run_that_never_started()
    |> refresh_runs()
  end

  defp after_reap(socket, _closed), do: socket

  # A run this page followed because its record said `running`, before it had
  # stepped once, that the check has now settled: nothing will step it, so
  # waiting for it would wait for news that cannot come — and it would also
  # refuse the run the reader opened the page to start. The list of runs below
  # says how it ended. What a page watched itself stays on screen: that is a run
  # it can describe.
  defp let_go_of_a_run_that_never_started(%{assigns: %{run_id: nil}} = socket), do: socket

  defp let_go_of_a_run_that_never_started(
         %{assigns: %{progress: {0, _}, lines: [], status: status}} = socket
       )
       when status != "running",
       do: watching_nothing(socket)

  defp let_go_of_a_run_that_never_started(socket), do: socket

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

  # The job says when it is writing an episode back to the database. The run's
  # own page shows that; this page's line is about the experiment's queue, and a
  # write is not something it has anything to say about — but the news arrives
  # here too, on the same topic, so it has to be answered.
  defp handle_studio({:keeping, _steps}, socket), do: socket
  defp handle_studio(:kept, socket), do: socket

  defp handle_studio({:started, steps}, socket) do
    socket
    |> assign(status: "running", progress: {0, steps}, episode: 0, episode_objects: %{})
    |> refresh_runs()
  end

  # One episode of the epoch has begun. A run is every object of the experiment
  # in every rotation, so the page says which one it is on — the step counter
  # restarts inside each episode, and a log that did not say so would look like
  # a run going backwards. The badge therefore names the episode and counts
  # inside it, which is what the number actually is.
  #
  # The counter goes back to nought with the episode. A step of the new episode
  # is a smaller number than the last step of the old one, and the out-of-order
  # guard below drops small numbers inside the same episode — so a counter that
  # kept the old episode's last step would swallow every step of the new one and
  # the badge would stand still at that number for the rest of the run.
  defp handle_studio({:episode, %{episode: index, object: object}}, socket) do
    socket
    |> assign(
      episode: index,
      progress: {0, elem(socket.assigns.progress, 1)},
      episode_objects: Map.put(socket.assigns.episode_objects, index, object)
    )
    |> push(nil, "episode #{index + 1}: #{object || "the scene's own object"}", :info)
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

  # Every step that has arrived and not been answered yet, oldest first, and the
  # message that came after them.
  #
  # `receive ... after 0` is the mailbox read LiveView does not offer: it takes
  # what is there now and nothing later, which is exactly "am I behind?". The
  # first message that is not a step of this run ends the batch and is answered
  # by the caller: re-sending it to ourselves would put it behind the steps it
  # arrived ahead of, and the order of a run's own messages is the order its
  # episodes happened in.
  defp drain_steps(run_id, acc) do
    receive do
      {:studio, ^run_id, {:step, event}} ->
        drain_steps(run_id, [event | acc])

      {:studio, ^run_id, event} ->
        {Enum.reverse(acc), event}
    after
      0 -> {Enum.reverse(acc), nil}
    end
  end

  # A batch of steps: every line, every step's beliefs, and the last one's
  # picture. Steps of another episode, and steps a step already shown has
  # overtaken, are dropped exactly as a single one was — the mailbox is not the
  # worker's clock, and the badge must not walk backwards inside an episode.
  defp handle_steps(events, socket) do
    shown = elem(socket.assigns.progress, 0)

    fresh =
      Enum.reject(events, fn event ->
        event.episode == socket.assigns[:episode] and event.step + 1 < shown
      end)

    case fresh do
      [] ->
        socket

      fresh ->
        last = List.last(fresh)

        socket
        |> push_lines(fresh)
        |> assign(steps_seen: steps_seen(socket) + length(fresh))
        |> assign(progress: {last.step + 1, elem(socket.assigns.progress, 1)})
        |> then(fn socket ->
          Enum.reduce(last.frames, socket, &stream_insert(&2, :frames, &1))
        end)
        |> remember_each(fresh)
        |> assign(centre: Map.get(last, :centre))
        |> tick()
    end
  end

  # Every step of the batch, not only the last one: a backlog is what a page
  # that has fallen behind receives, and keeping one point of it drew a line with
  # every fourth point missing — which reads as the run stalling, not as the page
  # catching up.
  defp remember_each(socket, events) do
    Enum.reduce(events, socket, fn event, socket ->
      remember(socket, event.episode, event.step, Map.get(event, :beliefs, %{}))
    end)
  end

  # A row of a run that is still going has no stored duration — the record's is
  # written when it closes — so the elapsed time goes into the row itself as the
  # steps arrive. It has to be the row: a comprehension re-renders its body when
  # the *item* changes, and a number worked out in the body from something else
  # would stand still, which is why a running run's "took" used to freeze.
  defp tick(%{assigns: %{run_id: nil}} = socket), do: socket

  defp tick(socket) do
    runs =
      Enum.map(socket.assigns.runs, fn run ->
        if run.id == socket.assigns.run_id,
          do: %{run | duration_us: Duration.elapsed_us(run)},
          else: run
      end)

    assign(socket, runs: runs)
  end

  defp refresh_runs(%{assigns: %{opened: %{name: name}}} = socket) do
    runs = recent_runs(name)
    assign(socket, runs: runs, queue: Jobs.by_run(Enum.map(runs, & &1.id)))
  end

  defp refresh_runs(socket), do: socket

  # A page that was open before a run of this experiment started watches it. The
  # run belongs to the experiment, not to the page that asked for it — and Run is
  # disabled while one is going, so joining it is not something a reader should
  # have to press: with nothing to press, a second viewer would otherwise have to
  # find the run on another page.
  defp follow_if_idle(%{assigns: %{run_id: nil}} = socket, record) do
    socket
    |> follow(record)
    |> push(nil, "a run of this experiment started: watching it", :info)
  end

  defp follow_if_idle(socket, _record), do: socket

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

        # Newest first. A step adds a point to the history of every module, and
        # adding it at the end copies the list: thirteen thousand steps copied a
        # history that had grown to thousands of points, once per step, which is
        # what made a long run slower than a short one. `Chart.new/2` takes the
        # points in any order and sorts them itself, so nothing has to reverse.
        Map.update(histories, to_string(module_id), [point], &[point | &1])
      end)

    assign(socket, beliefs: histories) |> redraw_when_due()
  end

  # A step is recorded whatever happens to the picture — that is a cheap append —
  # but the picture itself is drawn at most `@chart_interval` apart, and a step
  # that arrives between two drawings asks for one rather than drawing it.
  #
  # A picture can only change when the run puts a step *inside* the window being
  # drawn, or when the window itself moves. A reader zoomed into a stretch the run
  # has already passed is looking at a finished picture: redrawing it four times a
  # second — the same SVG, re-sent — is what made the page fight the reader, every
  # keystroke queuing behind a drawing that could not have changed, until the
  # socket gave up.
  defp redraw_when_due(socket) do
    now = System.monotonic_time(:millisecond)

    cond do
      not drawing_can_change?(socket) ->
        # The extent still moves, because a zoom is measured against it; what
        # does not move is the drawing.
        assign(socket, :chart_extent, extent_of(socket.assigns.beliefs))

      now - Map.get(socket.assigns, :chart_drawn_at, 0) >= wait_between_charts(socket) ->
        request_drawing(socket)

      true ->
        schedule_redraw(socket)
    end
  end

  defp chart_interval, do: Application.get_env(:ex_tbp_monty, :chart_interval, @chart_interval)

  # How long the page waits between drawings of a history that is still growing.
  # A drawing costs what the run is long, and asking for four of them a second
  # whatever they cost is a page that spends all of its time drawing; half of it
  # is kept for the reader. A reader's own action — a zoom, a tick, a chart made
  # full screen — is drawn at once, because it is the picture they are waiting for.
  defp wait_between_charts(socket) do
    max(chart_interval(), Map.get(socket.assigns, :chart_cost, 0))
  end

  defp schedule_redraw(%{assigns: %{chart_pending?: true}} = socket), do: socket

  defp schedule_redraw(socket) do
    Process.send_after(self(), :chart_due, wait_between_charts(socket))
    assign(socket, :chart_pending?, true)
  end

  # The histories, the chart of the stretch being looked at, and how long the run
  # is so far — the last of those is what zoom and pan move within.
  #
  # Computed from the page's own state rather than from the socket, because this is
  # the one thing here that costs what the run costs and it is drawn in a task
  # (`request_drawing/1`): a picture is of the history as it stood when the
  # drawing started, so what it is drawn from has to be a value, not a process.
  defp drawing(page, histories) do
    labels = Map.get(page, :chart_labels, %{})

    extent = extent_of(histories)

    # The window the chart is drawn for, which is the one asked for except while
    # following: the label beside the chart names this, so a page that drew one
    # stretch and said another would be lying about its own picture.
    window = window_with_follow(page, extent)

    {charts, labels} =
      charts_of(
        histories,
        window,
        Map.get(page, :episode_objects, %{}),
        chart_sizes(page),
        labels
      )

    # The picture and what it was drawn from — never the history itself. A
    # drawing is of the history as it stood when it started, so assigning one back
    # would roll the page back over every step that arrived while it ran: a
    # history is the page's own and only ever grows.
    [
      charts: charts,
      chart_labels: labels,
      chart_window: window,
      chart_extent: extent
    ]
  end

  # The page's first picture, drawn from the history it was just given: the one
  # place a drawing and a history are assigned together.
  defp assign_drawing(socket, histories) do
    socket
    |> assign(beliefs: histories)
    |> assign(drawing(socket.assigns, histories))
  end

  # A picture is of the history as it stood when the drawing started, and there is
  # one at a time: a request that arrives while one runs is served when it
  # returns, with the history as it stands then.
  #
  # It runs in a task because this process answers everything else — a click, a
  # step, a filter — and a drawing of a long run is a second of arithmetic. Drawn
  # here, four times a second, it left no time between them: the controls of a long
  # run answered seconds late, and the socket gave up waiting.
  defp request_drawing(socket) do
    if Map.get(socket.assigns, :chart_asking, false) do
      assign(socket, :chart_asks_again, true)
    else
      start_drawing(socket)
    end
  end

  defp start_drawing(socket) do
    generation = Map.get(socket.assigns, :chart_generation, 0) + 1

    # Only what a picture is made of, not the page: LiveView copies whatever a
    # task closes over, and the page holds a run's whole history.
    page =
      Map.take(socket.assigns, [:chart_labels, :follow, :x_window, :episode_objects, :chart_sizes])

    histories = Map.get(socket.assigns, :beliefs, %{})

    socket
    |> assign(chart_generation: generation, chart_asking: true, chart_asks_again: false)
    |> start_async({:charts, generation}, fn ->
      {microseconds, drawing} = :timer.tc(fn -> drawing(page, histories) end)
      {drawing, div(microseconds, 1000)}
    end)
  end

  # How far the run has got, as the chart reads it: the longest history there is.
  defp extent_of(histories) do
    histories
    |> Map.values()
    |> Enum.max_by(&length/1, fn -> [] end)
    |> Chart.extent()
  end

  # Whether a drawing started now could differ from the one on screen.
  defp drawing_can_change?(socket) do
    case {
      Map.get(socket.assigns, :follow, true),
      Map.get(socket.assigns, :chart_window),
      Map.get(socket.assigns, :chart_extent)
    } do
      {false, {_from, to}, {_first, last}} -> last <= to
      _following_or_not_drawn_yet -> true
    end
  end

  # How big the expanded chart's box is, as the browser measured it. A screen is
  # a shape no server can guess, so the one chart filling it is drawn for the
  # box it really has; every other chart keeps the size of its cell.
  defp chart_sizes(page), do: Map.get(page, :chart_sizes, %{})

  # "Follow latest", the way the pyview dashboard has it: while it is on, a window
  # that has been zoomed into keeps its width and slides so that it ends at the
  # newest step — the run grows and the reader keeps seeing the live end of it.
  # Off, the window is exactly what was asked for, and the run grows out of view.
  defp window_with_follow(page, {_first, last}) do
    case {Map.get(page, :follow, true), Map.get(page, :x_window)} do
      {true, {from, to}} -> {max(last - (to - from), 0), last}
      {_off, window} -> window
    end
  end

  # One chart per module, from the module's own history, drawn for the stretch of
  # the run the page is looking at. The objects by episode travel with it: a band
  # wears the colour of the object its episode was about.
  #
  # Answers the charts and the colours and legend places they gave out. A chart is
  # rebuilt on every step and its lines are drawn worst-first, so the drawing
  # order moves; what must not move is which colour an object wears and where it
  # sits in the legend. `Chart.new/2` takes the assignments it made before and
  # answers the map it now holds, so a new object takes the next free place and
  # nothing already on screen is repainted or reshuffled.
  defp charts_of(histories, window, episode_objects, expanded_size, labels) do
    {charts, labels} =
      Enum.map_reduce(histories, labels, fn {module_id, steps}, labels ->
        chart =
          Chart.new(
            steps,
            [window: window, episode_objects: episode_objects, labels: labels] ++
              size_of(module_id, expanded_size)
          )

        {{module_id, chart}, chart.labels}
      end)

    {Map.new(charts), labels}
  end

  defp size_of(module_id, sizes) when is_map(sizes) do
    case Map.get(sizes, module_id) do
      {width, height} -> [width: width, height: height]
      _not_measured -> []
    end
  end

  defp size_of(_module_id, _sizes), do: []

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
  # The address of a zoomed chart: the stretch it draws, and nothing else.
  #
  # The run's own budget (`episodes`, `steps`) used to travel here too, which
  # made a chart link a run setting: zooming a picture rewrote the number of
  # episodes in the address bar, and every later run on that page kept it. A
  # window is about the picture; what a run does is a control on the page.
  defp experiment_path(socket, nil), do: ~p"/experiments/#{socket.assigns.opened.name}"

  defp experiment_path(socket, {from, to}),
    do: ~p"/experiments/#{socket.assigns.opened.name}?#{[x_from: from, x_to: to]}"

  # What the record says, applied to the page.
  #
  # A page can miss messages: the queue runs a run wherever a worker is free
  # (another node, another release of this application), and a socket can blink.
  # The row is written before the line is broadcast, so asking the row is always
  # at least as new as the last message — which is why the page also polls it
  # while a run is in flight, and stops as soon as the run is not running.
  defp reconcile(%{assigns: %{run_id: nil}} = socket), do: socket

  defp reconcile(%{assigns: %{run_id: run_id}} = socket) do
    # The state and the counters, not the transcript: an experiment page asked for
    # the whole row twice a second, and by the end of a twenty-thousand-step run
    # that row is a quarter of a gigabyte of pictures — read again and again while
    # the run is trying to step (`RunHistory.progress/1`).
    case RunHistory.progress(run_id) do
      nil ->
        socket

      record ->
        socket
        |> assign(
          status: status_of(record, socket),
          progress: progress_from(record, socket.assigns[:progress]),
          log_path: record.log_path,
          summary: if(record.summary == %{}, do: socket.assigns.summary, else: record.summary)
        )
        |> catch_up(record)
    end
  end

  # A row that says `queued` while the run's steps are already in the stream is
  # a run that is stepping: the status is one more write that can be missed or
  # not made, and the steps are what is actually happening.
  defp status_of(%{status: status} = record, socket) do
    if status in ["queued", nil] and RunStream.count(record.id) > steps_seen(socket),
      do: "running",
      else: status
  end

  # A run whose steps did not all arrive here: another node's worker wrote the
  # row, and this page heard nothing of it. The row is written before a line is
  # broadcast, so the transcript is where a missing message is made good — read
  # once, when the run has stopped, and without the pictures (`head/1`), which
  # this page already has from the messages it did hear.
  defp catch_up(%{assigns: %{caught_up: true}} = socket, _record), do: socket

  # A run that is still stepping: repaired from its own stream, because that is
  # the only place its steps are complete. Push is best effort — a page that was
  # reloaded, reconnected or hot-upgraded mid-run misses whatever was announced
  # while it was away, and nothing in the announcements says where it is, so a
  # page that has missed one step has missed every step after it. What it missed
  # is handed to the same handler a broadcast goes to, so the transcript, the
  # chart and the badge are repaired the way they were built.
  #
  # The row cannot answer this while the run is going: only its counters are
  # written, and its transcript is written at boundaries. The stream holds every
  # step this node published, and reading it waits for nobody.
  defp catch_up(socket, %{status: status} = record) when status in ["queued", "running"],
    do: repair(socket, record)

  defp catch_up(socket, record) do
    case RunHistory.head(record.id) do
      nil ->
        socket

      settled ->
        socket
        |> assign(caught_up: true)
        |> assign(steps_seen: length(settled.log))
        |> merge_lines(settled)
    end
  end

  # How far behind a page may be before the poll stops believing push and reads
  # the stream: a step or two behind is a message in flight, and reading the
  # whole stream twice a second to find it would be the page paying for the
  # run's history to learn that nothing was lost.
  @behind_steps 8

  # The stream's own count is the measure, not the row's: while a run steps the
  # row is written at boundaries, so its `steps_done` stands still for a whole
  # episode and a page that had lost its place would wait for a boundary to be
  # noticed — which is a page that looks frozen for the length of an episode.
  defp repair(socket, record) do
    if RunStream.count(record.id) - steps_seen(socket) > @behind_steps,
      do: read_missing(socket, record),
      else: socket
  end

  defp read_missing(socket, record) do
    {entries, _moments} = RunStream.read_from(record.id, -1)

    case Enum.filter(entries, &after_shown?(&1, socket)) do
      [] ->
        # Nothing here to give: the steps were taken by another node, or this
        # stream has already let them go. Asking again every half second would
        # be the page reading the whole stream to be told the same thing; the
        # record answers when the run stops (`catch_up/2`).
        assign(socket, steps_seen: RunStream.count(record.id))

      fresh ->
        # The same handler a broadcast goes to, so a repaired step is a step the
        # page drew exactly as it would have drawn it live.
        socket = handle_steps(Enum.map(fresh, &event_of/1), socket)

        # The badge counts inside an episode, so the episode a repaired batch
        # belongs to goes with it: a page that heard nothing of episode fifty
        # would otherwise number its steps against the episode it opened on.
        assign(socket, episode: List.last(fresh)["episode"])
    end
  end

  # The steps newer than the last one this page has drawn. A run numbers its
  # steps from nought inside every episode, so it is the pair that orders them.
  defp after_shown?(entry, socket) do
    case Map.get(socket.assigns, :episode) do
      nil ->
        true

      episode ->
        {entry["episode"], entry["step"]} > {episode, elem(socket.assigns.progress, 0) - 1}
    end
  end

  # A stored step as the message that would have carried it: the words the line
  # holds, the beliefs the chart draws, and the pair the badge counts.
  #
  # Beliefs are stored the way a row keeps them — string keys — and the chart
  # reads the shape a live step carries. Handing one to the other drew nothing
  # and raised `key :graphs not found`, which killed the drawing task.
  defp event_of(entry) do
    %{
      line: RunLog.text(entry),
      step: entry["step"],
      episode: entry["episode"],
      frames: [],
      beliefs:
        Map.new(entry["beliefs"] || %{}, fn {module_id, belief} ->
          {module_id, Belief.from_stored(belief)}
        end),
      centre: nil
    }
  end

  defp steps_seen(socket), do: Map.get(socket.assigns, :steps_seen, 0)

  # Which step to show. A run that is still going is counted by its own step
  # messages; the record is written at episode boundaries, so counting its log
  # answers "the last episode that finished" — and putting that on screen twice a
  # second is the counter that dived to nought and came back. Only the limit is
  # re-read while the run is live; a run that has stopped is described by its
  # record.
  defp progress_from(%{status: "running", steps: limit}, {count, _old_limit}),
    do: {count, limit}

  defp progress_from(%{status: "running", steps: limit}, nil), do: {0, limit}
  # A run that has stopped: the count is the one the page watched up to. A page
  # that watched none of it followed the record, which seeded the count already.
  defp progress_from(%{steps: limit}, {count, _old_limit}), do: {count, limit}

  defp progress_from(%{steps: limit, steps_done: done}, nil), do: {done || 0, limit}

  # "step 2 of 12" is about the episode being run: every episode of a run starts
  # its step counter again, so counting a run's whole log against one episode's
  # budget would have the page claim step seven of three.
  defp steps_of_last_episode(record) do
    case List.last(record.log) do
      nil -> {0, record.steps}
      last -> {Enum.count(record.log, &(&1["episode"] == last["episode"])), record.steps}
    end
  end

  # The episode the record's log last reached, so the badge starts where the run
  # is rather than at the first one.
  defp last_episode(record) do
    case List.last(record.log) do
      nil -> 0
      last -> last["episode"] || 0
    end
  end

  # A run's chart is the run's, not this socket's: a page opened halfway through
  # an episode draws what the record already holds and then carries on live. It is
  # done once — after that the messages are newer than the record.
  defp merge_beliefs(%{assigns: %{beliefs_seeded: true}} = socket, _record), do: socket

  defp merge_beliefs(socket, record) do
    case recorded_beliefs(record) do
      [] ->
        socket

      recorded ->
        socket
        |> assign(:beliefs_seeded, true)
        |> assign_drawing(histories_of(socket, recorded))
    end
  end

  # Every opinion the record's log holds, as the chart's own points: an episode,
  # a step, and the belief the module had there.
  defp recorded_beliefs(record) do
    for entry <- record.log,
        entry["beliefs"] != nil,
        {module_id, belief} <- entry["beliefs"],
        into: [] do
      {module_id, {entry["episode"] || 0, entry["step"] || 0, Belief.from_stored(belief)}}
    end
  end

  # Newest first while merging, then one reverse per module: appending a point
  # copies the history it grows, and a page opened on a long run has exactly that
  # many points to merge. Seeding starts from an empty view
  # (`clear_run_view/1`), so every list here is this record's own.
  defp histories_of(socket, recorded) do
    recorded
    |> Enum.reduce(socket.assigns.beliefs, fn {module, point}, histories ->
      Map.update(histories, module, [point], &[point | &1])
    end)
    |> Map.new(fn {module, points} -> {module, Enum.reverse(points)} end)
  end

  # A run that was reported from elsewhere never sent its pictures here, so the
  # last frame the record kept stands in: what the run saw at its last step is
  # better than a panel that never filled in.
  #
  # The record in hand is the log alone (`RunHistory.head/1`), so the one step's
  # observations are asked for by name — the same read the run page makes for the
  # step a reader is looking at.
  defp merge_frames(%{assigns: %{frames_seeded: true}} = socket, _record), do: socket

  defp merge_frames(socket, record) do
    case last_frame(record) do
      [] ->
        socket

      frames ->
        socket
        |> assign(frames_seeded: true)
        |> then(fn socket -> Enum.reduce(frames, socket, &stream_insert(&2, :frames, &1)) end)
    end
  end

  defp last_frame(record) do
    with step when not is_nil(step) <- Replay.last_step(record),
         sensors when is_map(sensors) <- RunHistory.sensors_at(record.id, step),
         %{frames: frames} <- Replay.at(record, step) |> Replay.with_pictures(sensors) do
      frames
    else
      _nothing_recorded -> []
    end
  end

  # Lines already on screen stay where they are; lines the record has and the
  # page does not are the ones that were missed.
  #
  # What a record hands over is bounded the way a step's own line is
  # (`@log_limit`): a run of thirteen thousand steps has thirteen thousand lines
  # in its record, and a page that drew them all on mount spent the time the log
  # window exists to save — a window is a window whether the lines arrive one at
  # a time or all at once.
  defp merge_lines(socket, record) do
    seen = socket.assigns.lines |> Enum.filter(& &1.step) |> length()

    if seen >= length(record.log) do
      socket
    else
      chatter = Enum.filter(socket.assigns.lines, &is_nil(&1.step))
      recorded = record.log |> Enum.map(&record_line/1) |> Enum.take(-@log_limit)
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

  # Parallelism is how many parts of the experiment go at the same time — Monty's
  # `run_parallel.py`, where one script runs `num_parallel` configs and merges
  # what they produced. It is one record and one job (`Monty.Studio.Jobs.Run`),
  # with the parts as processes inside it, so the Runs page shows the experiment
  # once and the experiment's page shows every part's evidence and pictures.
  #
  # A part is not a copy of the experiment. A config evaluated a hundred and forty
  # times is finished in a fourteenth of the clock at fourteen parts, where
  # fourteen copies of it were fourteen times the work and no faster.
  defp start(socket, opened, steps, parallelism, episodes) do
    plan = Partition.plan(opened.setup, parallelism, episodes)
    parts = with_streams(Partition.parts(plan))

    attributes =
      RunLog.attributes(opened, steps, first_episode(parts), parallelism, episodes, %{
        parts: parts
      })

    case RunHistory.start(attributes) do
      {:ok, record} ->
        # Subscribe before enqueueing: the queue can start a job within
        # milliseconds of the insert, and a run that finishes before the page
        # listens is a run the page watched happen and never heard about.
        Phoenix.PubSub.subscribe(ExTbpMonty.PubSub, Jobs.Run.topic(record.id))
        enqueue(record)

        {:noreply,
         socket
         |> clear_run_view()
         |> assign(
           run_id: record.id,
           status: "running",
           progress: {0, steps},
           episode: 0,
           summary: nil,
           lines: [],
           log_path: record.log_path,
           parts: [],
           parts_held: %{}
         )
         |> push(nil, queued(parts, steps, opened.name), :info)
         |> watch()}

      {:error, changeset} ->
        {:noreply, push(socket, nil, changeset_errors(changeset), :error)}
    end
  end

  # Each part's stream id, made here because the page that draws the cards needs
  # it before anything has run: a part's steps are its own stream, and the record
  # is where the page finds which stream belongs to which part.
  defp with_streams(parts) do
    Enum.map(parts, &Map.put(&1, :stream, Ecto.UUID.generate()))
  end

  # The episode a plan starts at, which is what a second press of Run is refused
  # by: a run of the whole experiment starts at its first episode.
  defp first_episode([%{episodes: [first | _rest]} | _more]), do: first
  defp first_episode(_no_work), do: 0

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
        {:noreply, push(socket, nil, "a run of this experiment is already on its way", :warning)}

      record ->
        {:noreply,
         socket |> follow(record) |> push(nil, "a run is already going: watching it", :info)}
    end
  end

  defp queued([_one], steps, name),
    do: "queued: #{steps} step(s) of #{name}"

  defp queued([], steps, name),
    do: "queued: #{steps} step(s) of #{name}"

  defp queued(parts, steps, name) do
    "queued #{length(parts)} parts of #{name} as one run, #{steps} step(s) an episode: " <>
      "every part's chart and pictures below"
  end

  # -- the log ---------------------------------------------------------------

  # The world a reader picks is composed in a task: opening a config costs what
  # the config costs, not what the page costs, so the steps still arriving are
  # answered while it goes. The badge, the findings and the record a run leaves
  # all follow from one open. A failure is said out loud in the flash, because
  # this page's own lines live in a panel that only exists while a run is being
  # followed.
  @impl true
  # The drawing a task made: the page takes it if it is the newest one asked for,
  # and draws again if the history moved while it was being drawn.
  def handle_async({:charts, generation}, {:ok, {drawing, cost}}, socket) do
    socket =
      socket
      |> assign(
        chart_asking: false,
        chart_drawn_at: System.monotonic_time(:millisecond),
        chart_cost: cost
      )

    socket =
      if generation == Map.get(socket.assigns, :chart_generation),
        do: assign(socket, drawing),
        else: socket

    {:noreply, if(socket.assigns[:chart_asks_again], do: start_drawing(socket), else: socket)}
  end

  def handle_async({:charts, _generation}, {:exit, reason}, socket) do
    Logger.warning("a chart could not be drawn: #{inspect(reason)}")

    {:noreply, assign(socket, chart_asking: false, chart_asks_again: false)}
  end

  def handle_async(:world, {:ok, {:ok, opened}}, socket) do
    {:noreply,
     socket
     |> assign(
       opened: opened,
       logging: Logging.open(opened.setup).notes,
       error: nil,
       needs: needs(opened),
       missing: with_actions(missing(opened))
     )}
  end

  def handle_async(:world, {:ok, {:error, reason}}, socket) do
    {:noreply, put_flash(socket, :error, "That world will not open: #{inspect(reason)}")}
  end

  def handle_async(:world, {:exit, reason}, socket) do
    {:noreply, put_flash(socket, :error, "Opening that world failed: #{inspect(reason)}")}
  end

  # The page's own closing line. A reconnect is a page that closed and opened
  # again, so the closing half has to be in the log with the reason and how far
  # the page had got — otherwise "it reconnected again" arrives with no time on
  # it and nothing to compare it against the run's own log.
  @impl true
  def terminate(reason, socket) do
    episode = Map.get(socket.assigns, :episode)
    {step, _total} = Map.get(socket.assigns, :progress) || {nil, nil}

    Logger.info(
      "page closed: #{inspect(reason)} at episode #{inspect(episode)} step #{inspect(step)}",
      run_id: Map.get(socket.assigns, :run_id)
    )

    :ok
  end

  defp push(socket, step, text, level) do
    line = line(step, text, level, RunLog.now())
    assign(socket, lines: Enum.take(socket.assigns.lines ++ [line], -@log_limit))
  end

  # The lines of several steps in one append: a backlog of a hundred steps would
  # otherwise copy the window a hundred times.
  defp push_lines(socket, events) do
    at = RunLog.now()
    lines = Enum.map(events, &line(&1.step, &1.line, :info, at))
    assign(socket, lines: Enum.take(socket.assigns.lines ++ lines, -@log_limit))
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
  # can be in, so a record that still says `running` with no job behind it is
  # closed where it is read: the only thing left of that run is the row, and a
  # row saying "running" with nothing working on it is the lie the Reaper exists
  # to undo. Closing it here means a page that has just stopped something does
  # not wait for the sweep to say so.
  defp close_orphan(run_id) do
    case RunHistory.head(run_id) do
      %{status: "running"} = record ->
        {:ok, _closed} =
          RunHistory.finish(record, %{"reason" => "nothing was running it any more"}, "failed")

        :settled

      _finished_or_gone ->
        :nothing
    end
  end

  defp cancel({run, %{id: job_id}}) do
    case Jobs.cancel(job_id) do
      {:ok, ended} -> ended
      {:error, :settled} -> close_orphan(run.id)
    end
  end

  defp cancel({run, nil}) do
    # No job in hand: ask the queue once before deciding the run is gone. A
    # record that still says `running` because the page's queue map was older
    # than the retry is not an orphan.
    case Map.get(Jobs.by_run([run.id]), run.id) do
      nil -> close_orphan(run.id)
      job -> cancel({run, job})
    end
  end

  defp stopped([]), do: {"nothing was going", :warning}

  defp stopped(outcomes) do
    case Enum.uniq(outcomes) do
      [:stopping] -> {"stopping: the run ends after its next step", :info}
      [:settled] -> {"stopped: it had not started yet", :info}
      [:nothing] -> {"that run had already finished", :warning}
      _several -> {"stopping what is running; what had not started will not start", :info}
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

  # A number the page was given, or nothing at all — which is what an empty field
  # means: every episode of the config, and the config's own ceiling on steps.
  defp count_of(value) do
    case Integer.parse(to_string(value || "")) do
      {count, ""} when count > 0 -> count
      _empty -> nil
    end
  end

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

  # A run starts when the config composes and the files it reads are here: two
  # conditions, and the page says which one is in the way — a composition error
  # is the config's, a missing download is this machine's.
  defp runable?(assigns), do: config_runnable?(assigns) and missing(assigns[:opened]) == []

  # Why a press of Run or One step would do nothing, or `nil` when it would
  # start. Both buttons are disabled for the same two reasons, and both events
  # refuse for them as well: a disabled button can still be pressed by a page
  # that was one refresh behind, or by a client that posts the event itself.
  #
  # The second reason is not the queue's. The queue refuses a second run of the
  # same episode in the same world; it would happily start a *different* run of
  # the same experiment beside the one already going, which is the same world
  # stepped twice and two answers to one question.
  defp refusal(assigns) do
    cond do
      not runable?(assigns) -> :cannot_run
      in_flight(assigns) != [] -> :going
      true -> nil
    end
  end

  defp startable?(assigns), do: refusal(assigns) == nil

  # The runs of this experiment that are still going — queued or executing — each
  # with the job that will carry it. Read off the records the page keeps live
  # (`{:recorded, …}` and `{:settled, …}` come from the runs table), not off the
  # one run this page happens to be following, so a run started from another tab
  # is as visible and as stoppable here as one started from this one.
  defp in_flight(assigns) do
    queue = Map.get(assigns, :queue) || %{}

    for run <- Map.get(assigns, :runs, []),
        run_state(run, Map.get(queue, run.id)) in ["running", "queued"],
        do: {run, Map.get(queue, run.id)}
  end

  # "Stop" says how much it would stop: one press of Run with a parallelism of
  # four is four runs, and a button that said "Stop" would be hiding three.
  defp stop_label(assigns) do
    case length(in_flight(assigns)) do
      1 -> "Stop"
      several -> "Stop #{several} runs"
    end
  end

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
  defp unavailable(_setup, _world), do: ""

  # A need is not always a download: the interpreter is configuration, and
  # offering a download for it would be offering something that does not exist.
  # The two findings the checks box already says as a missing need, dropped so a
  # reader is not told the same thing twice in two boxes.
  @said_as_a_need [:world_data_missing, :no_pretrained_memory]
  defp checks(findings), do: Enum.reject(findings, &(&1.code in @said_as_a_need))

  # Where the click for one need goes: the archive that fills its directory, the
  # experiment that would train the model it names, or the page that lists what
  # can be fetched.
  defp with_actions(needs), do: Enum.map(needs, &Map.put(&1, :action, action_for(&1)))

  defp action_for(%{kind: :models} = need) do
    name = Memory.name_of(need[:display] || need.path)
    release = Memory.release_of(need[:display] || need.path)

    cond do
      archive = Prerequisites.for_model(name, release) ->
        %{label: "download", href: "/prerequisites?fetch=#{archive.id}"}

      trainer = Catalog.trainer_for(name) ->
        %{label: "train it", href: "/experiments/#{trainer}"}

      true ->
        %{label: "prerequisites", href: "/prerequisites"}
    end
  end

  defp action_for(%{path: path}) when is_binary(path) do
    case Prerequisites.for_path(path) do
      nil -> %{label: "prerequisites", href: "/prerequisites"}
      prerequisite -> %{label: "download", href: "/prerequisites?fetch=#{prerequisite.id}"}
    end
  end

  # Every missing thing has something to click. A need with no file of its own is
  # configuration — an interpreter this application cannot import an engine from —
  # and the page that says which interpreter it carries and what each needs is
  # where that is answered.
  defp action_for(_need), do: %{label: "what it needs", href: "/prerequisites"}

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
