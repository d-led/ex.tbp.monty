defmodule ExTbpMontyWeb.StudioComponents do
  @moduledoc """
  The pieces an experiment page is made of: the wiring diagram, the findings
  list, and the small facts about a setup.

  These are presentation only. Every number and every coordinate comes from
  `Monty.Studio.*`, so a component test checks *that the page shows what the
  studio knows* rather than re-deriving it in HEEx.
  """

  use Phoenix.Component

  alias Monty.Studio.{Diagram, Finding}

  @doc """
  Draws an experiment's wiring.

  Sensors on the left, learning modules in the middle, the motor system on the
  right, the world above them; votes are dashed, because a vote is not input.
  """
  attr :diagram, Diagram, required: true
  attr :id, :string, default: "setup-diagram"

  def diagram(assigns) do
    ~H"""
    <figure id={@id} class="rounded-box border border-base-300 bg-base-100 p-3">
      <%!-- A wiring diagram that shrinks to fit a phone is a diagram nobody
      can read. It keeps roughly its natural size and the box scrolls. --%>
      <div class="overflow-x-auto">
        <svg
          viewBox={"0 0 #{@diagram.width} #{@diagram.height}"}
          style={"min-width: #{round(@diagram.width * 0.9)}px"}
          class="h-auto w-full"
          role="img"
          aria-label="Experiment wiring: sensors, learning modules and motor system"
        >
          <defs>
            <marker
              id="setup-arrow"
              viewBox="0 0 10 10"
              refX="9"
              refY="5"
              markerWidth="6"
              markerHeight="6"
              orient="auto-start-reverse"
            >
              <path d="M 0 0 L 10 5 L 0 10 z" class="fill-base-content/40" />
            </marker>
          </defs>

          <polyline
            :for={edge <- @diagram.edges}
            points={points(edge)}
            fill="none"
            class={edge_class(edge.kind)}
            marker-end="url(#setup-arrow)"
          />

          <g :for={node <- @diagram.nodes}>
            <rect
              x={node.x}
              y={node.y}
              width={node.width}
              height={node.height}
              rx="8"
              class={node_class(node.kind)}
              stroke-dasharray={if node.note, do: "6 3", else: nil}
            />
            <text
              x={node.x + 10}
              y={node.y + 17}
              class="fill-base-content text-[11px] font-semibold"
            >
              {truncate(node.label, node.width)}
            </text>
            <text
              x={node.x + 10}
              y={node.y + 31}
              class="fill-base-content/60 text-[10px]"
            >
              {truncate(node.detail || "", node.width)}
            </text>
            <text
              :if={node.note}
              x={node.x + 10}
              y={node.y + 43}
              class="fill-warning text-[9px]"
            >
              {truncate(node.note, node.width)}
            </text>
          </g>
        </svg>
      </div>

      <figcaption class="mt-2 flex flex-wrap gap-x-3 gap-y-0.5 text-[11px] text-base-content/60">
        <span>solid: percepts and hierarchy</span>
        <span>dashed: lateral votes</span>
        <span>dotted: goals to the motor system</span>
        <span>dashed box: nothing to learn from</span>
      </figcaption>
    </figure>
    """
  end

  @doc "The findings, worst first, each with what to do about it."
  attr :findings, :list, required: true
  attr :id, :string, default: "setup-findings"

  def findings(assigns) do
    assigns =
      assigns
      |> assign(:grouped, Finding.group(assigns.findings))
      |> assign(:ordered, ordered(assigns.findings))

    ~H"""
    <section id={@id} class="space-y-2">
      <header class="flex items-center justify-between">
        <h2 class="text-lg font-semibold tracking-tight">Checks</h2>
        <span class={["badge", verdict_class(@grouped)]}>{verdict(@grouped)}</span>
      </header>

      <p :if={@findings == []} class="text-sm text-base-content/60">
        Nothing to report: this config would start.
      </p>

      <ul class="space-y-1.5">
        <li
          :for={entry <- @ordered}
          id={"finding-#{entry.finding.code}-#{entry.index}"}
          class="flex items-start gap-2 rounded-field border border-base-300 bg-base-100 px-2.5 py-1.5"
        >
          <span class={["badge badge-sm mt-0.5", level_class(entry.level)]}>{entry.level}</span>
          <div class="space-y-0.5">
            <p class="text-sm">{entry.finding.message}</p>
            <p :if={entry.finding.where} class="font-mono text-xs break-all text-base-content/50">
              {entry.finding.where}
            </p>
          </div>
        </li>
      </ul>
    </section>
    """
  end

  @doc "One labelled value, for the facts strip above the diagram."
  attr :label, :string, required: true
  attr :value, :string, required: true

  def fact(assigns) do
    ~H"""
    <div class="rounded-field border border-base-300 bg-base-100 px-2.5 py-1.5">
      <dt class="text-xs text-base-content/60">{@label}</dt>
      <dd class="font-mono text-sm">{@value}</dd>
    </div>
    """
  end

  @doc "How a module's implementation status reads and looks."
  @spec status_label(atom() | nil) :: String.t()
  def status_label(:implemented), do: "ported"
  def status_label(:planned), do: "planned"
  def status_label(:excluded), do: "excluded"
  def status_label(_unknown), do: "not in map"

  @spec status_class(atom() | nil) :: String.t()
  def status_class(:implemented), do: "badge-success"
  def status_class(:planned), do: "badge-ghost"
  def status_class(:excluded), do: "badge-warning"
  def status_class(_unknown), do: "badge-error"

  @doc """
  The world a run stepped, in the words the selector used to offer it.

  A record keeps the atom a run was started with, which is the right kind of
  thing to keep and the wrong kind to read: `synthetic` says nothing to somebody
  choosing between "the stand-in sphere" and "the simulator the experiment's
  config names". A run that recorded no world says so rather than being labelled
  with whatever this build happens to default to now.
  """
  @spec world_label(map()) :: String.t()
  def world_label(%{inputs: %{} = inputs}) do
    case Map.get(inputs, "world") do
      nil -> "—"
      "synthetic" -> "stand-in"
      "habitat" -> "Monty's Python"
      other -> to_string(other)
    end
  end

  def world_label(_run), do: "—"

  @doc "The counts a run leaves behind, as the database stores them."
  attr :summary, :map, required: true

  def summary(assigns) do
    ~H"""
    <section id="run-summary" class="space-y-2">
      <h2 class="text-sm font-medium">After the run</h2>

      <dl class="grid gap-2 sm:grid-cols-3 lg:grid-cols-6">
        <.fact label="steps" value={to_string(@summary["steps"])} />
        <.fact label="total" value={duration(@summary["duration_us"] || 0)} />
        <.fact label="votes sent" value={to_string(@summary["votes_sent"])} />
        <.fact label="votes used" value={to_string(@summary["votes_used"])} />
        <.fact label="goals" value={to_string(@summary["goals"])} />
        <.fact label="actions" value={to_string(@summary["actions"])} />
      </dl>

      <p
        :if={@summary["never_updated"] not in [nil, []]}
        id="run-summary-never-updated"
        class="text-sm text-warning"
      >
        These learning modules never received input: {Enum.join(@summary["never_updated"], ", ")}
      </p>
    </section>
    """
  end

  @doc "Milliseconds for a duration in microseconds."
  @spec duration(non_neg_integer()) :: String.t()
  def duration(microseconds) when microseconds < 1_000, do: "#{microseconds} µs"
  def duration(microseconds), do: "#{Float.round(microseconds / 1_000, 1)} ms"

  # Why there is nothing to look at, in the run's own terms: a run from before a
  # step kept its pictures has none anywhere, and one step can miss its own.
  defp no_pictures(false),
    do:
      "This run kept no pictures of what its sensors saw, so the steps have no views — the numbers are what it recorded."

  defp no_pictures(true), do: "This step kept no pictures."

  @doc """
  A finished run, step by step: the slider, the frames at that step, and a chart.

  Replaying is reading, not running: the frames come from the observations the
  run recorded, so what the slider shows is what happened. The chart's window
  is what the zoom buttons move — the slider stays on whole timesteps.
  """
  attr :moment, :map, default: nil
  attr :chart, :map, default: nil
  attr :series, :list, default: []
  attr :series_id, :string, default: nil
  attr :best, :map, default: nil
  attr :theories, :list, default: []
  attr :graphs, :boolean, default: true
  attr :recorded, :integer, default: 0
  attr :playing, :boolean, default: false
  # Whether the run kept any picture at all: a run recorded before a step kept
  # them has none, and that is said in one sentence rather than drawn as a row of
  # empty frames per step.
  attr :pictures, :boolean, default: false
  attr :id, :string, default: "replay"

  def replay(assigns) do
    ~H"""
    <section id={@id} class="space-y-1.5">
      <header class="flex flex-wrap items-center gap-1.5">
        <h2 class="text-sm font-medium">Replay</h2>

        <div :if={@moment} class="join">
          <button
            id="replay-back"
            phx-click="replay_step"
            phx-value-delta="-1"
            class="btn join-item btn-xs"
            aria-label="Previous step"
          >
            ◀
          </button>
          <button
            id="replay-play"
            phx-click={if @playing, do: "replay_pause", else: "replay_play"}
            class="btn join-item btn-xs btn-primary"
            aria-label={if @playing, do: "Pause the replay", else: "Play the replay"}
          >
            {if @playing, do: "❚❚", else: "▶"}
          </button>
          <button
            id="replay-forward"
            phx-click="replay_step"
            phx-value-delta="1"
            class="btn join-item btn-xs"
            aria-label="Next step"
          >
            ▶
          </button>
        </div>

        <span :if={@moment} id="replay-step" class="badge badge-sm badge-ghost font-mono">
          step {@moment.step}
        </span>
        <span :if={@moment && @moment.entry} class="text-xs text-base-content/60">
          {duration(@moment.entry["duration_us"])}
        </span>
        <span class="ms-auto text-[11px] text-base-content/50">
          {@recorded} recorded step(s)
        </span>
      </header>

      <p :if={@moment == nil} id="replay-empty" class="text-sm text-base-content/60">
        This run recorded no steps, so there is nothing to replay.
      </p>

      <form :if={@moment} id="replay-seek" phx-change="replay_seek" class="px-0.5">
        <%!-- The slider is drawn from the step the page is showing, so every
        patch that arrives while a drag is in flight would put the handle back
        where the server last left it. The hook holds the reader's own value for
        as long as the pointer is down: the page catches up when the drag ends,
        not while it is happening. --%>
        <input
          type="range"
          name="step"
          id="replay-slider"
          phx-hook=".ReplaySlider"
          min="0"
          max={max(@recorded - 1, 0)}
          value={@moment.position}
          phx-debounce="120"
          class="range range-xs range-primary w-full"
          aria-label="Step"
        />
      </form>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".ReplaySlider">
        export default {
          mounted() {
            this.dragging = false
            this.wanted = this.el.value

            this.hold = () => {
              this.dragging = true
            }
            this.release = () => {
              this.dragging = false
            }
            this.remember = () => {
              this.wanted = this.el.value
            }

            this.el.addEventListener("pointerdown", this.hold)
            this.el.addEventListener("input", this.remember)

            // A pointer released anywhere ends the drag, including one the
            // pointer left the slider for.
            window.addEventListener("pointerup", this.release)
            window.addEventListener("pointercancel", this.release)
          },

          // The element's own listeners go with the element; the window's do
          // not, so a page navigated away from would keep one per visit.
          destroyed() {
            window.removeEventListener("pointerup", this.release)
            window.removeEventListener("pointercancel", this.release)
          },

          // A patch that lands mid-drag is behind the reader's hand, not ahead
          // of it: putting it in would move the handle backwards under the
          // pointer. The value the reader chose wins until the drag ends.
          updated() {
            if (this.dragging && this.el.value !== this.wanted) this.el.value = this.wanted
          },
        }
      </script>

      <%!-- What the step under the slider was deciding between. Two names and two
      numbers, so dragging the slider answers "and then what?" without reading a
      chart or a log. --%>
      <p
        :if={@moment && @theories != []}
        id="replay-theories"
        class="flex flex-wrap items-baseline gap-x-2 px-0.5 text-xs"
      >
        <span class="text-base-content/60">strongest theories</span>
        <span
          :for={{theory, rank} <- Enum.with_index(@theories)}
          class={["font-mono", rank == 0 && "font-semibold"]}
        >
          {theory.object}
          <span class="text-base-content/60">{format_value(theory.evidence)}</span>
        </span>
      </p>

      <div :if={@moment} class="grid gap-2 lg:grid-cols-[minmax(0,2fr)_minmax(0,1fr)]">
        <div :if={@moment.frames != []} id="replay-frames" class="grid gap-1.5 sm:grid-cols-2">
          <figure
            :for={frame <- @moment.frames}
            id={"replay-frame-#{frame.sensor_id}"}
            class="rounded-field border border-base-300 bg-base-100 p-1.5 text-base-content"
          >
            <figcaption class="flex items-baseline justify-between px-0.5 pb-0.5 text-[11px] text-base-content/60">
              <span class="font-mono">{frame.sensor_id}</span>
              <span>{frame.note}</span>
            </figcaption>
            <div class="text-base-content/80">{frame.data}</div>
          </figure>
        </div>

        <p :if={@moment.frames == []} id="replay-no-pictures" class="text-xs text-base-content/60">
          {no_pictures(@pictures)}
        </p>

        <dl :if={@moment.entry} class="grid grid-cols-2 gap-x-3 gap-y-0.5 text-xs">
          <div>
            <dt class="text-base-content/60">percepts</dt>
            <dd class="font-mono">{Enum.join(@moment.entry["percepts"], ", ")}</dd>
          </div>
          <div>
            <dt class="text-base-content/60">votes</dt>
            <dd class="font-mono">
              {@moment.entry["votes"]["used"]}/{@moment.entry["votes"]["sent"]}
            </dd>
          </div>
          <div>
            <dt class="text-base-content/60">goals</dt>
            <dd class="font-mono">{@moment.entry["goals"]}</dd>
          </div>
          <div>
            <dt class="text-base-content/60">actions</dt>
            <dd class="font-mono">{@moment.entry["actions"]}</dd>
          </div>
          <div class="col-span-2">
            <dt class="text-base-content/60">inputs</dt>
            <dd class="font-mono break-all">{inputs(@moment.entry)}</dd>
          </div>
        </dl>
      </div>

      <div :if={@chart} class="space-y-1 pt-0.5">
        <div class="flex flex-wrap items-center gap-1.5">
          <form id="replay-series" phx-change="replay_series">
            <select name="series" class="select select-xs" aria-label="Series to chart">
              <option :for={series <- @series} value={series.id} selected={series.id == @series_id}>
                {series.label}
              </option>
            </select>
          </form>
          <div class="join">
            <button
              id="replay-zoom-out"
              phx-click="replay_zoom"
              phx-value-zoom="out"
              class="btn join-item btn-xs"
              aria-label="Zoom out"
            >
              −
            </button>
            <button
              id="replay-zoom-in"
              phx-click="replay_zoom"
              phx-value-zoom="in"
              class="btn join-item btn-xs"
              aria-label="Zoom in"
            >
              +
            </button>
            <button
              id="replay-zoom-all"
              phx-click="replay_zoom"
              phx-value-zoom="all"
              class="btn join-item btn-xs"
              aria-label="Show the whole run"
            >
              all
            </button>
          </div>
          <span class="text-[11px] text-base-content/50">
            steps {@chart.from}–{@chart.to} · {format_value(@chart.min)} … {format_value(@chart.max)} {chart_unit(
              @series,
              @series_id
            )}
          </span>
          <span :if={@best} id="replay-best" class="ms-auto text-[11px] text-base-content/60">
            strongest evidence
            <span class="font-mono text-base-content">{@best.object} {format_value(@best.value)}</span>
          </span>
        </div>

        <%!-- Hovering a line says which object is under the pointer, which step
        it is, and what it was worth. The samples come from the server, so the
        words and the unit are the ones the rest of the page uses; the hook only
        decides which drawn point is nearest and where to put the line. --%>
        <%!-- The value axis, outside the plot. Inside it, a label would be
        stretched with the chart's geometry — `preserveAspectRatio="none"`
        makes every glyph as wide as the box is wider than the viewBox — and its
        gutter would cost that many stretched pixels of line. A column beside
        the plot costs only the width of the words. --%>
        <div class="flex gap-1.5">
          <div
            id="replay-chart-y-axis"
            class="relative w-9 shrink-0 text-right font-mono text-[10px] leading-none text-base-content/50"
            style={"height: #{@chart.height}"}
            aria-hidden="true"
          >
            <span
              :for={tick <- @chart.ticks}
              class="absolute right-0 -translate-y-1/2 tabular-nums"
              style={"top: #{tick.y / @chart.height * 100}%"}
            >
              {tick.label}
            </span>
          </div>
          <div
            id="replay-chart-hover"
            phx-hook=".ChartHover"
            data-width={@chart.width}
            data-height={@chart.height}
            data-from={@chart.from}
            data-to={@chart.to}
            data-samples={chart_samples(@chart, @series, @series_id)}
            class="relative min-w-0 flex-1 cursor-crosshair touch-none select-none"
          >
            <svg
              id="replay-chart"
              viewBox={"0 0 #{@chart.width} #{@chart.height}"}
              preserveAspectRatio="none"
              class="h-40 w-full rounded-field border border-base-300 bg-base-100"
              role="img"
              aria-label="The chosen series over the steps in the window"
            >
              <%!-- The plot's own tint, as Monty's pyview dashboard draws it:
            one pale grey inside the axes against the page's own colour. Drawn
            first, behind everything. The SVG *is* the plot here — the value
            labels are HTML beside it — so this fills it entire. --%>
              <rect
                x="0"
                y="0"
                width={@chart.width}
                height={@chart.height}
                fill="var(--chart-plot, #fafafa)"
              />
              <%!-- Which episode each stretch of the run is: evidence restarts at
            zero at every boundary, so the bands are what makes the rhythm
            countable. Each wears the colour of the object its episode was about
            — the pyview dashboard's fill, at its own 0.08. Drawn over the plot's
            tint and under the lines. --%>
              <rect
                :for={band <- @chart.bands}
                x={band.x}
                y="0"
                width={band.width}
                height={@chart.height}
                fill={band.colour}
                fill-opacity="0.08"
                class="episode-band"
                data-episode={band.episode}
              />
              <%!-- Where one episode ends and the next begins, ruled as well as
            tinted: two episodes of the same object are one colour, and the
            boundary between them is still a step the chart must show. --%>
              <line
                :for={band <- @chart.bands}
                :if={band.x > 0}
                x1={band.x}
                y1="0"
                x2={band.x}
                y2={@chart.height}
                stroke="currentColor"
                stroke-opacity="0.18"
                stroke-dasharray="2 2"
                vector-effect="non-scaling-stroke"
              />
              <%!-- Where the labels beside the plot sit, drawn under the lines so a
            line is never hidden by a gridline. --%>
              <g id="replay-chart-gridlines">
                <line
                  :for={tick <- @chart.ticks}
                  x1="0"
                  y1={tick.y}
                  x2={@chart.width}
                  y2={tick.y}
                  stroke="var(--chart-grid, #e5e7eb)"
                  stroke-width="1"
                  vector-effect="non-scaling-stroke"
                />
              </g>
              <%!-- Zero: what evidence is measured from. Every episode starts on
            this line and a hypothesis can be penalised under it, so it is drawn
            heavier than a gridline and below the lines. --%>
              <line
                :if={@chart.zero}
                id="replay-chart-zero"
                x1="0"
                y1={@chart.zero}
                x2={@chart.width}
                y2={@chart.zero}
                stroke="currentColor"
                stroke-opacity="0.4"
                vector-effect="non-scaling-stroke"
              />
              <polyline
                :for={polyline <- @chart.polylines}
                id={polyline.id}
                points={polyline.points}
                fill="none"
                stroke={polyline.colour}
                stroke-width="1.5"
                stroke-linejoin="round"
                vector-effect="non-scaling-stroke"
              />
              <line
                :if={@chart.playhead}
                x1={@chart.playhead}
                y1="0"
                x2={@chart.playhead}
                y2={@chart.height}
                stroke="currentColor"
                stroke-opacity="0.35"
                stroke-dasharray="2 2"
                vector-effect="non-scaling-stroke"
              />
              <%!-- The range a drag is choosing, drawn while the pointer is down
            and gone on release: the zoom is the drag, so the box is feedback
            rather than a state the page has to keep. --%>
              <rect
                id="replay-chart-brush"
                x="0"
                y="0"
                width="0"
                height="0"
                fill="currentColor"
                fill-opacity="0.12"
                stroke="currentColor"
                stroke-opacity="0.4"
                vector-effect="non-scaling-stroke"
                visibility="hidden"
              />
            </svg>
          </div>
        </div>

        <%!-- A legend is only worth its line when there is a choice to make: a
        chart of one object needs no key. --%>
        <ul
          :if={length(@chart.lines) > 1}
          id="replay-chart-legend"
          class="flex flex-wrap gap-x-3 gap-y-0.5 text-[11px] text-base-content/70"
        >
          <li :for={line <- @chart.lines} class="flex items-center gap-1">
            <span class="h-0.5 w-3 rounded" style={"background: #{line.colour}"}></span>
            <span class="font-mono">{line.label}</span>
          </li>
        </ul>

        <%!-- A line at zero is honest, but it is not an answer: a run whose
        modules reported no graphs has nothing to compare per object, and saying
        so is the difference between "nothing happened" and "nothing was kept". --%>
        <p
          :if={not @graphs and @chart.lines != []}
          id="replay-chart-no-graphs"
          class="text-[11px] text-base-content/50"
        >
          No graphs were kept for this run, so there is nothing to compare per object —
          the line above is the strongest evidence there was, which is none.
        </p>
        <script :type={Phoenix.LiveView.ColocatedHook} name=".ChartHover">
          // Points are drawn in the SVG's own 0..width units but shown stretched to
          // the width of the box, so a pointer position is turned back into those
          // units before the nearest drawn step is looked up.
          export default {
            mounted() {
              this.marker = document.createElement("div")
              this.marker.className =
                "pointer-events-none absolute inset-y-0 w-px border-l border-dashed border-base-content/50"
              this.marker.hidden = true

              this.label = document.createElement("div")
              this.label.className =
                "pointer-events-none absolute z-10 whitespace-nowrap rounded bg-base-content px-1 py-0.5 font-mono text-[10px] leading-none text-base-100"
              this.label.hidden = true

              this.attach()

              this.el.addEventListener("pointermove", event => this.hover(event))
              this.el.addEventListener("pointerleave", () => this.hide())

              // Clicking a point is the shortest way to say "show me that step":
              // the slider below the chart does the same thing, one drag at a time.
              this.el.addEventListener("click", event => this.seek(event))

              // Dragging across the plot is the other way to be told what to
              // look at: it chooses a range and zooms to it.
              this.el.addEventListener("pointerdown", event => this.startBrush(event))
              this.el.addEventListener("pointermove", event => this.drag(event))
              this.el.addEventListener("pointerup", event => this.endBrush(event))
              this.el.addEventListener("pointercancel", () => this.cancelBrush())

              this.read()
            },

            // LiveView re-renders this box whenever the step changes, and a
            // re-render replaces its children — including the two nodes this
            // hook appended. Without putting them back, hover writes into
            // nodes nobody can see: it works until the first update.
            updated() {
              this.read()
              this.attach()
            },

            attach() {
              if (!this.el.contains(this.marker)) this.el.append(this.marker, this.label)
            },

            read() {
              this.samples = JSON.parse(this.el.dataset.samples || "[]")
              this.width = Number(this.el.dataset.width || 320)
              this.height = Number(this.el.dataset.height || 64)
              this.from = Number(this.el.dataset.from || 0)
              this.to = Number(this.el.dataset.to || 0)
              this.brush = null
            },

            // Where a pointer is across the plot, in the chart's own units.
            unitX(event) {
              const box = this.el.getBoundingClientRect()
              if (box.width === 0) return 0

              return ((event.clientX - box.left) / box.width) * this.width
            },

            // And where that is in the window's own terms: the plot is the whole
            // width of the box, so a position is a fraction of it.
            positionOf(unitX) {
              const fraction = unitX / Math.max(this.width, 1)

              return this.from + fraction * (this.to - this.from)
            },

            startBrush(event) {
              if (event.button !== 0 || this.to <= this.from) return

              const unitX = this.unitX(event)
              this.brush = {from: unitX, to: unitX, moved: false}
              this.showBrush()
            },

            drag(event) {
              if (!this.brush) return

              const unitX = this.unitX(event)

              this.brush.to = unitX
              this.brush.moved = this.brush.moved || Math.abs(unitX - this.brush.from) > 4
              this.showBrush()
            },

            showBrush() {
              const box = this.el.querySelector("#replay-chart-brush")
              if (!box || !this.brush) return

              box.setAttribute("x", String(Math.min(this.brush.from, this.brush.to)))
              box.setAttribute("width", String(Math.abs(this.brush.to - this.brush.from)))
              box.setAttribute("height", String(this.height))
              box.setAttribute("visibility", "visible")
            },

            // A drag that went nowhere is a click, and a click already means
            // "show me that step"; only a real drag scopes the window.
            endBrush(_event) {
              const brush = this.brush
              if (!brush) return

              this.brush = null
              this.cancelBrush()

              if (!brush.moved) return

              // The click that ends a drag is not a seek: the reader chose a
              // range, not a point.
              this.dragged = true

              const ends = [this.positionOf(brush.from), this.positionOf(brush.to)].map(Math.round)

              this.pushEvent("replay_brush", {
                from: String(Math.min(...ends)),
                to: String(Math.max(...ends))
              })
            },

            cancelBrush() {
              const box = this.el.querySelector("#replay-chart-brush")
              if (box) box.setAttribute("visibility", "hidden")
            },

            // What the pointer is over, read off the drawn line rather than off
            // the nearest stored point: a run of hundreds of steps has points a
            // few pixels apart, and a readout that jumps from one to the next
            // says the value is a staircase. Between two points of one stretch
            // the line is straight, so the value at the pointer's place is the
            // value between them.
            atCursor(event) {
              if (this.samples.length === 0) return null

              const box = this.el.getBoundingClientRect()
              if (box.width === 0 || box.height === 0) return null

              const atX = ((event.clientX - box.left) / box.width) * this.width
              const atY = ((event.clientY - box.top) / box.height) * this.height
              let best = null

              for (const line of this.byLine().values()) {
                // A pointer past the end of a line is not over it: reading the
                // end of a line from somewhere else on the plot is the jump this
                // readout exists to avoid.
                if (atX < line[0].x || atX > line[line.length - 1].x) continue

                const reading = this.readingAt(line, atX)
                if (!reading) continue

                // Which line the pointer is nearest, measured on the reading
                // itself, so a steep line just under the cursor wins over a flat
                // one at the same x.
                const away = ((reading.y - atY) / this.height) ** 2
                if (best === null || away < best.away) best = {...reading, away}
              }

              return best
            },

            // The points of each line, in the order they were drawn.
            byLine() {
              const lines = new Map()

              for (const sample of this.samples) {
                const drawn = lines.get(sample.line) || []
                drawn.push(sample)
                lines.set(sample.line, drawn)
              }

              return lines
            },

            // One line's value at `atX`: straight between the two points that
            // bracket it when they are consecutive steps, and the nearer of them
            // when they are not — an object that was not reported for a step has
            // no line there to read.
            readingAt(line, atX) {
              let before = null
              let after = null

              for (const sample of line) {
                if (sample.x <= atX) before = sample
                else {
                  after = sample
                  break
                }
              }

              if (!before) return after
              if (!after) return before
              if (after.step - before.step !== 1 || after.x <= before.x) {
                return atX - before.x < after.x - atX ? before : after
              }

              const t = (atX - before.x) / (after.x - before.x)

              return {
                ...before,
                x: atX,
                y: before.y + t * (after.y - before.y),
                step: before.step + t * (after.step - before.step),
                value: before.value + t * (after.value - before.value)
              }
            },

            // The sentence the server writes for a stored sample — the object,
            // the step, the value — for a place between two of them, which is a
            // step the server never had.
            readingLabel(reading) {
              // A pointer that lands on a step says the step, not "48.0": the
              // interpolation only decides the decimals when it really is
              // between two of them.
              const step = Math.round(reading.step * 10) / 10
              const position = Number.isInteger(step) ? String(step) : step.toFixed(1)
              const name = reading.named ? `${reading.line} · ` : ""
              const unit = reading.unit ? ` ${reading.unit}` : ""

              return `${name}#${position} · ${reading.value.toFixed(2)}${unit}`
            },

            hover(event) {
              const reading = this.atCursor(event)

              // Over a stretch where nothing was recorded there is no value to
              // name, and keeping the last one is worse than saying nothing: the
              // crosshair would stand where the pointer is not.
              if (!reading) return this.hide()

              const percent = (reading.x / this.width) * 100
              const rect = this.el.getBoundingClientRect()

              this.marker.style.left = `${percent}%`
              this.marker.hidden = false

              this.label.textContent = this.readingLabel(reading)
              this.label.style.left = `${percent}%`
              this.label.style.transform =
                percent < 20 ? "translateX(0)" : percent > 80 ? "translateX(-100%)" : "translateX(-50%)"

              // Beside the place it names, a little above it: a number pinned to
              // the top edge and a crosshair halfway down are two things a
              // reader has to connect by hand. Above the point unless there is
              // no room above it, in which case below.
              const point = (reading.y / this.height) * rect.height
              const above = point > 28

              this.label.style.top = `${Math.max(
                Math.min(above ? point - 24 : point + 8, rect.height - 20),
                2
              )}px`
              this.label.style.bottom = ""

              this.label.hidden = false
            },

            seek(event) {
              // The mouse-up of a drag fires a click too, and a drag has already
              // said what it wanted.
              if (this.dragged) {
                this.dragged = false
                return
              }

              const nearest = this.nearest(event)
              if (!nearest) return

              this.pushEvent("replay_seek", {step: String(nearest.position)})
            },

            hide() {
              this.marker.hidden = true
              this.label.hidden = true
            },
          }
        </script>
      </div>
    </section>
    """
  end

  # The chart's points are thinned to what a pointer can tell apart before they
  # are sent: this many per line, which is more than the plot has pixels for.
  # Every drawn point is sent, not a sample of them: a hover reads the value at
  # the pointer's own place on the line, and a line is only straight between the
  # points it was drawn through. Twelve hundred points is well over one per pixel
  # of a plot this wide, so a run zoomed all the way out still has a point under
  # the pointer without sending a step per pixel.
  @samples_per_line 1200

  # One entry per drawn point: where it sits, and the words a hover shows. The
  # label is made here, not in the browser, so it says "mug · step 3 · 0.41" like
  # every other number on the page — and it names the line, because with ten of
  # them a value alone does not say whose it is.
  #
  # The points are thinned to what a pointer can tell apart before they are sent:
  # a run of a thousand steps over ten objects is seven thousand drawn points in
  # three hundred and twenty units of chart, so a hover was answered by scanning
  # seven thousand entries to name the one under the cursor, and the entries
  # themselves were seven hundred kilobytes in the page's own attributes.
  defp chart_samples(chart, series, series_id) do
    unit = chart_unit(series, series_id)
    named? = length(chart.lines) > 1

    chart.hover
    |> nearest_per_unit(chart.width)
    |> Enum.map(fn %{line: line, x: x, y: y, step: step, value: value} ->
      %{
        x: Float.round(x * 1.0, 2),
        y: Float.round(y * 1.0, 2),
        step: step,
        value: value,
        line: line,
        unit: unit,
        named: named?
      }
    end)
    |> Jason.encode!()
  end

  # Every point per line whose place a pointer could land on, and the last one it
  # could not: a line's shape is kept — its top, its bottom, where it turns — and
  # the steps in between are the ones a pixel cannot separate anyway.
  defp nearest_per_unit(points, _width) do
    points
    |> Enum.group_by(& &1.line)
    |> Enum.flat_map(fn {_line, drawn} ->
      Enum.take_every(drawn, max(div(length(drawn), @samples_per_line), 1))
    end)
  end

  defp inputs(entry) do
    entry
    |> Map.get("inputs", %{})
    |> Enum.map_join(" ", fn {module, count} -> "#{module}=#{count}" end)
  end

  defp format_value(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp format_value(value), do: to_string(value)

  defp chart_unit(series, id) do
    case Enum.find(series, &(&1.id == id)) do
      nil -> ""
      found -> found.unit
    end
  end

  @doc """
  Trims a label to the box it sits in.

  The diagram sizes its boxes from this same budget, so a label is only cut when
  it is longer than the widest box the layout allows — which is the one place a
  truncation is the honest answer.
  """
  @spec truncate(String.t(), number()) :: String.t()
  def truncate(text, width) do
    limit = max(trunc(width / 6.1) - 1, 4)

    if String.length(text) <= limit, do: text, else: String.slice(text, 0, limit - 1) <> "…"
  end

  defp edge_class(:vote), do: "stroke-base-content/25 [stroke-dasharray:6_4]"
  defp edge_class(:goal), do: "stroke-base-content/30 [stroke-dasharray:2_4]"
  defp edge_class(_input), do: "stroke-base-content/40"

  defp points(edge) do
    [{edge.x1, edge.y1} | edge.via]
    |> Kernel.++([{edge.x2, edge.y2}])
    |> Enum.map_join(" ", fn {x, y} -> "#{x},#{y}" end)
  end

  defp node_class(:environment), do: "fill-info/15 stroke-info/40"
  defp node_class(:sensor), do: "fill-secondary/15 stroke-secondary/40"
  defp node_class(:learning_module), do: "fill-primary/15 stroke-primary/40"
  defp node_class(:motor), do: "fill-accent/15 stroke-accent/40"

  defp verdict_class(%{error: [_ | _]}), do: "badge-error"
  defp verdict_class(%{warning: [_ | _]}), do: "badge-warning"
  defp verdict_class(_clean), do: "badge-success"

  defp verdict(%{error: errors}) when errors != [], do: "#{length(errors)} error(s)"
  defp verdict(%{warning: warnings}) when warnings != [], do: "#{length(warnings)} warning(s)"
  defp verdict(_clean), do: "ready"

  defp level_class(:error), do: "badge-error"
  defp level_class(:warning), do: "badge-warning"
  defp level_class(:info), do: "badge-info"

  # Worst first, and numbered: several findings can share a code (every module
  # that is not ported yet says so), so the code alone is not an id.
  defp ordered(findings) do
    for level <- [:error, :warning, :info],
        finding <- Finding.at(findings, level),
        uniq: true do
      {level, finding}
    end
    |> Enum.with_index()
    |> Enum.map(fn {{level, finding}, index} ->
      %{level: level, finding: finding, index: index}
    end)
  end
end
