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
    Jobs,
    LogFilter,
    Logging,
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
        {:ok, follow_running(assign_opened(socket, opened, steps(params), episodes(params)))}

      {:error, reason} ->
        {:ok,
         assign(socket,
           opened: nil,
           logging: [],
           error: reason,
           run_id: nil,
           lines: [],
           filter: ""
         )}
    end
  end

  defp assign_opened(socket, opened, steps, episodes) do
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
      steps: steps,
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
      # The object and the agent in one picture per step: the views a sensor
      # streams say what a camera saw, this says whether there was anything to see.
      centre: nil
    )
    |> stream_configure(:frames, dom_id: &"frame-#{&1.sensor_id}")
    |> stream(:frames, [])
  end

  @runs_shown 5

  # The last few runs of one experiment, newest first. Five: this is a list to
  # click through, not the runs page, and the detail belongs to the run.
  defp recent_runs(name) do
    RunHistory.search(state: "all", text: name, per_page: 25).runs
    |> Enum.filter(&(&1.experiment == name))
    |> Enum.take(@runs_shown)
  end

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

  defp run_time(%{inserted_at: nil}), do: "unknown"
  defp run_time(%{inserted_at: at}), do: Calendar.strftime(at, "%H:%M:%S")

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
            <.icon name="hero-play-mini" class="size-4" /> Run {@steps} steps
          </button>
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
            <p>
              Or step this port's stand-in scene instead, which reads nothing from disk.
            </p>
          </div>
        </div>

        <p :if={not config_runnable?(assigns)} id="run-blocked" class="text-sm text-error">
          Fix the errors above before running: this config would not start in Monty either.
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

          <table :if={@runs != []} class={table_class()}>
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
                <td class="py-0.5 font-mono text-base-content/60">{run_time(run)}</td>
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
        </section>

        <p :if={@run_id == nil and runable?(assigns)} class="text-sm text-base-content/60">
          A run keeps going if this page is closed, and its log and history are
          written as it goes. One run is every object of the experiment, in every
          rotation its config names.
        </p>

        <section :if={@charts != %{}} id="evidence-chart" class="space-y-2">
          <h3 class="text-sm font-medium">What the learning modules believe</h3>
          <div class={["grid gap-2", map_size(@charts) > 1 && "lg:grid-cols-2"]}>
            <figure
              :for={{module_id, chart} <- @charts}
              id={"chart-#{module_id}"}
              class="relative rounded-field border border-base-300 bg-base-100 p-2"
            >
              <figcaption class="flex items-baseline justify-between px-0.5 pb-1 font-mono text-[11px] text-base-content/60">
                <span>{module_id}</span>
                <span :if={chart.mlh}>
                  {chart.mlh.graph_id} is the answer so far
                </span>
              </figcaption>
              <svg
                id={"chart-svg-#{module_id}"}
                phx-hook=".EvidenceChart"
                viewBox={"0 0 #{chart.width} #{chart.height}"}
                class="w-full touch-none"
                role="img"
                aria-label={"evidence per object, step by step and episode by episode, for #{module_id}"}
                data-x-min={chart.x_min}
                data-x-max={chart.x_max}
                data-y-max={chart.y_max}
                data-width={chart.width}
                data-height={chart.height}
                data-margin-left={chart.margin_left}
                data-margin-right={chart.margin_right}
                data-margin-top={chart.margin_top}
                data-margin-bottom={chart.margin_bottom}
              >
                <%!-- Where one episode ends and the next begins. Every episode
                starts its evidence again at zero, so the chart lays them end to
                end and marks the boundary: without it the drop is a fall nobody
                measured. --%>
                <g :for={start <- chart.episode_starts}>
                  <%= if start.episode > 0 do %>
                    <line
                      x1={start.x}
                      x2={start.x}
                      y1="10"
                      y2={chart.height - 22}
                      stroke="currentColor"
                      stroke-width="0.5"
                      stroke-dasharray="2 2"
                      class="text-base-content/30"
                    />
                  <% end %>
                </g>
                <g :for={start <- chart.episode_labels}>
                  <text
                    x={start.x + 2}
                    y="8"
                    fill="currentColor"
                    font-size="7"
                    class="text-base-content/40"
                  >
                    {start.label}
                  </text>
                </g>
                <g :for={tick <- chart.ticks}>
                  <line
                    x1={chart.margin_left}
                    x2={chart.width - chart.margin_right}
                    y1={tick.y}
                    y2={tick.y}
                    stroke="currentColor"
                    stroke-width="0.5"
                    class="text-base-content/20"
                  />
                  <text
                    x={chart.margin_left - 6}
                    y={tick.y + 3}
                    text-anchor="end"
                    fill="currentColor"
                    font-size="8"
                    class="text-base-content/50"
                  >
                    {tick.label}
                  </text>
                </g>
                <g :for={series <- chart.series}>
                  <polyline
                    :for={points <- series.points}
                    points={points}
                    fill="none"
                    stroke={series.colour}
                    stroke-width="1.5"
                    data-graph={series.graph_id}
                  />
                </g>
                <circle
                  :if={chart.mlh}
                  cx={chart.mlh.x}
                  cy={chart.mlh.y}
                  r="3"
                  fill={chart.mlh_colour}
                />
              </svg>
              <ul class="flex flex-wrap gap-x-3 gap-y-1 px-0.5 pb-0.5 text-[11px]">
                <li :for={series <- chart.series} class="flex items-center gap-1">
                  <span
                    class="inline-block size-2 rounded-full"
                    style={"background-color: #{series.colour}"}
                  ></span>
                  <span class="font-mono text-base-content/70">{series.graph_id}</span>
                  <span class="text-base-content/50">
                    {series.evidence |> List.last() |> elem(1) |> Float.round(2)}
                  </span>
                </li>
              </ul>
              <div
                class="pointer-events-none absolute z-10 hidden max-w-[16rem] rounded-field border border-base-300 bg-base-100/95 px-2 py-1 font-mono text-[11px] leading-4 shadow-sm"
                data-chart-tooltip
              >
              </div>
            </figure>
          </div>
          <script :type={Phoenix.LiveView.ColocatedHook} name=".EvidenceChart">
            // A line says which objects were climbing; only a hover says by how
            // much at which step. The numbers are already in the picture — every
            // polyline carries its own points and its object's name — so the
            // crosshair reads them out of the SVG instead of asking the server
            // for a second copy of the same data.
            export default {
              mounted() {
                this.tooltip = this.el.parentElement.querySelector("[data-chart-tooltip]")
                this.el.addEventListener("mousemove", (event) => this.hover(event))
                this.el.addEventListener("mouseleave", () => this.hide())
              },

              // The chart is redrawn every step, so a tooltip from before the
              // patch would be describing a picture that is no longer there.
              updated() {
                this.hide()
              },

              geometry() {
                const data = this.el.dataset

                return {
                  width: Number(data.width),
                  height: Number(data.height),
                  left: Number(data.marginLeft),
                  right: Number(data.marginRight),
                  top: Number(data.marginTop),
                  bottom: Number(data.marginBottom),
                  xMin: Number(data.xMin),
                  xMax: Number(data.xMax),
                  yMax: Number(data.yMax),
                }
              },

              hover(event) {
                const chart = this.geometry()
                const rect = this.el.getBoundingClientRect()
                const scale = rect.width / chart.width
                const x = (event.clientX - rect.left) / scale
                const plot = chart.width - chart.left - chart.right

                if (x < chart.left || x > chart.left + plot) return this.hide()

                const rows = this.rowsAt(x, chart)
                if (rows.length === 0) return this.hide()

                this.show(rows, chart, rect, event)
              },

              // The values at the step nearest the cursor, which is the question
              // a hover asks: the cursor sits between steps, the numbers do not.
              // Snapping to that step, rather than demanding the cursor be near a
              // point, is what makes a chart with far-apart steps still answer.
              rowsAt(x, chart) {
                const snap = this.nearestStep(x)
                if (snap === null) return []

                const rows = []

                for (const line of this.el.querySelectorAll("polyline[data-graph]")) {
                  const point = nearestPoint(line.points, snap)
                  if (!point || Math.abs(point.x - snap) > 0.01) continue

                  rows.push({
                    graph: line.dataset.graph,
                    colour: line.getAttribute("stroke"),
                    x: point.x,
                    evidence: ((chart.height - chart.bottom - point.y) /
                      (chart.height - chart.top - chart.bottom)) * chart.yMax,
                  })
                }

                return rows.sort((a, b) => b.evidence - a.evidence)
              },

              // The x of the reported step closest to `x`. Every line's points are
              // already in the picture, so the axis needs no second copy of them.
              nearestStep(x) {
                let best = null

                for (const line of this.el.querySelectorAll("polyline[data-graph]")) {
                  for (let index = 0; index < line.points.numberOfItems; index++) {
                    const pointX = line.points.getItem(index).x
                    if (best === null || Math.abs(pointX - x) < Math.abs(best - x)) best = pointX
                  }
                }

                return best
              },

              show(rows, chart, rect, event) {
                const shown = rows.slice(0, 8)
                const hidden = rows.length - shown.length

                this.tooltip.innerHTML =
                  rows
                    .slice(0, 8)
                    .map(
                      (row) =>
                        `<div class="flex items-center gap-1.5">` +
                        `<span class="inline-block size-2 rounded-full" style="background-color: ${row.colour}"></span>` +
                        `<span class="text-base-content/70">${escape(row.graph)}</span>` +
                        `<span class="text-base-content/90">${row.evidence.toFixed(2)}</span>` +
                        `</div>`,
                    )
                    .join("") +
                  (hidden > 0
                    ? `<div class="text-base-content/50">and ${hidden} more below</div>`
                    : "")

                // Beside the cursor, and on the other side of it near the edge:
                // a tooltip that hangs off the chart is a tooltip nobody reads.
                // Both numbers are in the reader's pixels — the box is positioned
                // in the page, not in the SVG's own units.
                const left = Math.min(
                  event.clientX - rect.left + 14,
                  rect.width - this.tooltip.offsetWidth - 4,
                )

                this.tooltip.style.left = `${Math.max(left, 4)}px`
                this.tooltip.style.top = `${Math.max(event.clientY - rect.top - 10, 4)}px`
                this.tooltip.classList.remove("hidden")

                this.crosshairFor(shown[0].x, chart)
              },

              // The step the values are from, drawn where it is: the cursor is
              // between steps and the numbers are not.
              crosshairFor(x, chart) {
                this.crosshairMark?.remove()

                const line = document.createElementNS("http://www.w3.org/2000/svg", "line")
                line.setAttribute("x1", x)
                line.setAttribute("x2", x)
                line.setAttribute("y1", chart.top)
                line.setAttribute("y2", chart.height - chart.bottom)
                line.setAttribute("stroke", "currentColor")
                line.setAttribute("stroke-width", "0.5")
                line.setAttribute("class", "text-base-content/50")
                line.setAttribute("pointer-events", "none")

                this.el.appendChild(line)
                this.crosshairMark = line

                return line
              },

              hide() {
                if (this.tooltip) this.tooltip.classList.add("hidden")
                this.crosshairMark?.remove()
                this.crosshairMark = null
              },
            }

            // The point in a polyline whose x is nearest `x`, in the SVG's own
            // units, so nothing has to guess what the browser scaled it to.
            // Indexed rather than iterated: `SVGPointList` is not an iterable in
            // every browser this page is read in.
            function nearestPoint(points, x) {
              let best = null

              for (let index = 0; index < points.numberOfItems; index++) {
                const point = points.getItem(index)
                if (!best || Math.abs(point.x - x) < Math.abs(best.x - x)) best = point
              }

              return best
            }

            function escape(text) {
              const node = document.createElement("span")
              node.textContent = text
              return node.innerHTML
            }
          </script>
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
            phx-hook=".LocalTime"
            class="max-h-56 overflow-auto rounded-field border border-base-300 bg-base-100 p-2 font-mono text-[11px] leading-5"
          >
            <%!-- An empty state is for a log with nothing in it, or a filter
            that kept nothing. With no filter typed, every line matches, so
            there is nothing to say. --%>
            <li :if={@shown == []} id="run-log-empty" class="text-base-content/50">
              {if @lines == [], do: "no lines yet", else: "no line matches this filter"}
            </li>
            <li :for={line <- @shown} id={"log-#{line.id}"} class={line_class(line)}>
              <%!-- The clock is a `<time>` with the instant in it, not a
              string: a run's log says when a step happened, and "when" means
              the reader's clock, not the server's. The hook rewrites the UTC
              text the server sent into the browser's own time zone. --%>
              <time
                :if={line.at}
                datetime={line.at.instant}
                title={line.at.instant}
                class="me-1.5 text-base-content/40 tabular-nums"
              >
                {line.at.clock}
              </time>{line.text}
            </li>
          </ul>
          <script :type={Phoenix.LiveView.ColocatedHook} name=".LocalTime">
            // A log line is stamped in UTC because that is what a server knows.
            // The reader's clock is what they compare it to, and only the
            // browser knows that zone, so each `<time>` is rewritten here — on
            // mount and again after every patch, because a live log keeps
            // appending lines while it is read.
            export default {
              mounted() {
                this.localise()
              },

              updated() {
                this.localise()
              },

              localise() {
                for (const node of this.el.querySelectorAll("time[datetime]")) {
                  const at = new Date(node.getAttribute("datetime"))
                  if (Number.isNaN(at.getTime())) continue

                  node.textContent = at.toLocaleTimeString(undefined, {
                    hour: "2-digit",
                    minute: "2-digit",
                    second: "2-digit",
                  })
                  node.title = at.toLocaleString()
                }
              },
            }
          </script>
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
    if Setup.valid?(opened.setup),
      do: start(socket, opened, steps, socket.assigns.parallelism, socket.assigns.episodes),
      else: {:noreply, socket}
  end

  def handle_event("parallelism", %{"parallelism" => count}, socket) do
    {:noreply, assign(socket, parallelism: parallelism(%{"parallelism" => count}))}
  end

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

    assign(socket, beliefs: histories, charts: charts_of(histories))
  end

  # One chart per module, from the module's own history.
  defp charts_of(histories),
    do: Map.new(histories, fn {module_id, steps} -> {module_id, Chart.new(steps)} end)

  # What the record says, applied to the page.
  #
  # A page can miss messages: the queue runs a run wherever a worker is free
  # (another node, another release of this application), and a socket can blink.
  # The row is written before the line is broadcast, so asking the row is always
  # at least as new as the last message — which is why the page also polls it
  # while a run is in flight, and stops as soon as the run is not running.
  defp reconcile(%{assigns: %{run_id: nil}} = socket), do: socket

  defp reconcile(%{assigns: %{run_id: run_id}} = socket) do
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

      assign(socket, beliefs_seeded: true, beliefs: histories, charts: charts_of(histories))
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
        {:ok, _closed} = RunHistory.finish(record, %{"reason" => inspect(reason)}, "failed")
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
    case RunHistory.get(run_id) do
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
      _default -> Monty.Studio.Run.default_steps()
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

  defp sensor_summary(setup), do: Enum.map_join(setup.sensors, ", ", & &1.id)

  defp learning_module_summary(setup),
    do: Enum.map_join(setup.learning_modules, ", ", & &1.id)

  defp epochs(setup), do: "train #{setup.epochs.train} · eval #{setup.epochs.eval}"

  defp ported(setup) do
    %{implemented: implemented, total: total} = Setup.ported(setup)
    "#{implemented}/#{total}"
  end
end
