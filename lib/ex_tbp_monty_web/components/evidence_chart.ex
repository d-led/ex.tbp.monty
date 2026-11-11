defmodule ExTbpMontyWeb.EvidenceChart do
  @moduledoc """
  One learning module's evidence, drawn.

  The picture is the server's: `Monty.Studio.Chart` works out every coordinate
  and this only draws them, so a test of the geometry is a test of a pure
  function and the template has nothing to decide. What the browser adds is the
  one thing the server cannot know — where the pointer is — and it reads that
  out of the SVG the server already sent rather than asking for the numbers a
  second time.

  Its three parts live here together: the styles that need a value from the data
  (a line's colour, a tooltip's position), the markup, and the colocated hook.
  """

  use Phoenix.Component

  attr :module_id, :string, required: true
  attr :chart, :map, required: true
  # Expanded is the chart filling the screen rather than its cell in the grid.
  # It is the card's state, not the chart's: the picture is the same run, drawn
  # in the same units, and only the box it is drawn into changes.
  attr :expanded, :boolean, default: false

  # A control drawn *on* the plot, in its top right corner: the page that owns
  # the card decides what it does, and the chart only says where it goes. On the
  # plot rather than above it, because the thing it acts on is the plot.
  slot :control

  def evidence_chart(assigns) do
    ~H"""
    <style :type={ExTbpMontyWeb.ColocatedCSS}>
      .evidence-chart__swatch {
        background-color: var(--swatch);
      }

      .evidence-chart__tooltip {
        position: absolute;
        z-index: 10;
        pointer-events: none;
      }

      .evidence-chart__tooltip[hidden] {
        display: none;
      }

      .evidence-chart__crosshair {
        pointer-events: none;
        stroke: currentColor;
        stroke-width: 0.5;
        opacity: 0.5;
      }

      /* The stretch a drag is choosing, drawn over the plot while the pointer is
         down: a gesture that says "this much" has to show how much. */
      .evidence-chart__brush {
        pointer-events: none;
        fill: currentColor;
        fill-opacity: 0.12;
        stroke: currentColor;
        stroke-opacity: 0.4;
        stroke-width: 0.5;
      }
    </style>

    <figure
      id={"chart-#{@module_id}"}
      class={
        [
          "relative rounded-field border border-base-300 bg-base-100 p-2",
          # Full screen is the chart's own size, not the card's: a card filling the
          # window around a 960x300 ribbon is a small chart with a lot of padding,
          # which is what "full screen" looked like before.
          #
          # The height is a viewport height, not `h-full`: a percentage height is
          # only as good as the chain of ancestors it resolves through, and the
          # card it lands in is a grid cell, then a fixed box. A chart asked for
          # 78vh is 78vh, which is what the run page's plot already does.
          @expanded && "flex flex-col"
        ]
      }
    >
      <figcaption class={[
        "flex shrink-0 flex-wrap items-baseline justify-between gap-x-2 px-0.5 pb-1 font-mono text-[11px] text-base-content/60",
        @expanded && "pr-8"
      ]}>
        <span>{@module_id}</span>
        <span :if={@chart.mlh}>{@chart.mlh.graph_id} is the answer so far</span>
      </figcaption>
      <%!-- The plot's own box, not the picture's shape: full screen hands the
      chart the height the card has, and the hook tells the server how big that
      is so the picture is drawn for it rather than stretched to fit. A stretched
      chart squashes its own tick labels; a redrawn one keeps them square.

      The gestures are the shared hook's (`assets/js/chart.js`), the same one the
      run page's chart answers to: drag a stretch to zoom, shift-drag to pan, the
      wheel to zoom about the pointer, double-click for the whole run. --%>
      <div class="relative">
        {render_slot(@control)}
        <svg
          id={"chart-svg-#{@module_id}"}
          phx-hook=".EvidenceChart"
          viewBox={"0 0 #{@chart.width} #{@chart.height}"}
          class={
            [
              "w-full touch-none cursor-crosshair",
              # The height is the page's, not the picture's: a chart given the whole
              # width of a column and its own aspect ratio is a chart twice as tall
              # as it reads well, because the aspect was drawn for half a row.
              @expanded && "h-[78vh]",
              !@expanded && "h-52"
            ]
          }
          data-expanded={to_string(@expanded)}
          data-chart-key={@module_id}
          data-size-event="chart-size"
          data-zoom-event="zoom"
          data-zoom-all-event="zoom"
          role="img"
          aria-label={"evidence per object, step by step and episode by episode, for #{@module_id}"}
          data-x-min={@chart.x_min}
          data-x-max={@chart.x_max}
          data-y-max={@chart.y_max}
          data-width={@chart.width}
          data-height={@chart.height}
          data-left={@chart.margin_left}
          data-right={@chart.margin_right}
          data-top={@chart.margin_top}
          data-bottom={@chart.margin_bottom}
          data-margin-left={@chart.margin_left}
          data-margin-right={@chart.margin_right}
          data-margin-top={@chart.margin_top}
          data-margin-bottom={@chart.margin_bottom}
        >
          <%!-- The plot's own tint, inside the axes and not in the gutter the
        labels sit in: the page's colour outside, one pale grey within, which is
        what makes a light chart read as a chart rather than as a hole in the
        card. Drawn first, behind the grid and the lines.

        The colour is on the element, with the value written out as a fallback:
        a `fill` whose custom property is missing is not a default colour, it is
        black — and a stylesheet this page did not rebuild is not a reason for a
        chart to turn into a hole. --%>
          <rect
            x={@chart.margin_left}
            y={@chart.margin_top}
            width={@chart.width - @chart.margin_left - @chart.margin_right}
            height={@chart.height - @chart.margin_top - @chart.margin_bottom}
            fill="var(--chart-plot, #fafafa)"
          />
          <%!-- Which episode each stretch of the run is, in the colour of the object
        that episode was about — the pyview dashboard's own bands, at its own
        0.08: enough to name the object, far too little to hide a line. Drawn
        over the plot's tint and under the grid. --%>
          <g :for={band <- @chart.episode_bands}>
            <rect
              x={band.x}
              y={@chart.margin_top}
              width={band.width}
              height={@chart.height - @chart.margin_top - @chart.margin_bottom}
              fill={band.colour}
              fill-opacity="0.08"
              class="episode-band"
              data-episode={band.episode}
            />
          </g>
          <%!-- Where one episode ends and the next begins. Every episode starts its
        evidence again at zero, so the chart lays them end to end and marks the
        boundary: without it the drop is a fall nobody measured. --%>
          <g :for={start <- @chart.episode_starts}>
            <%= if start.episode > 0 do %>
              <line
                x1={start.x}
                x2={start.x}
                y1="10"
                y2={@chart.height - 22}
                stroke="currentColor"
                stroke-width="0.5"
                stroke-dasharray="2 2"
                class="text-base-content/30"
              />
            <% end %>
          </g>
          <g :for={start <- @chart.episode_labels}>
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
          <g :for={tick <- @chart.ticks}>
            <line
              x1={@chart.margin_left}
              x2={@chart.width - @chart.margin_right}
              y1={tick.y}
              y2={tick.y}
              stroke="var(--chart-grid, #e5e7eb)"
              stroke-width="0.5"
            />
            <text
              x={@chart.margin_left - 6}
              y={tick.y + 3}
              text-anchor="end"
              fill="currentColor"
              font-size="8"
              class="text-base-content/50"
            >
              {tick.label}
            </text>
          </g>
          <%!-- Zero: what evidence is measured from. Every episode starts on this
        line and a hypothesis can be penalised below it, so it is drawn heavier
        than the grid and under the lines — a chart of a signed quantity that
        does not say where zero is makes the reader guess. --%>
          <line
            x1={@chart.margin_left}
            x2={@chart.width - @chart.margin_right}
            y1={@chart.zero}
            y2={@chart.zero}
            stroke="currentColor"
            stroke-width="1"
            class="text-base-content/40"
            data-zero={@chart.zero}
          />
          <%!-- The lines are one group so that shift-dragging can slide them under
        the hand. The frame around them — bands, grid, axis labels — stays put:
        it is what a reader is reading against. --%>
          <g id={"chart-lines-#{@module_id}"}>
            <g :for={series <- @chart.series}>
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
              :if={@chart.mlh}
              cx={@chart.mlh.x}
              cy={@chart.mlh.y}
              r="3"
              fill={@chart.mlh_colour}
            />
          </g>
        </svg>
      </div>
      <ul class="flex shrink-0 flex-wrap gap-x-3 gap-y-1 px-0.5 pb-0.5 text-[11px]">
        <li :for={series <- @chart.legend} class="flex items-center gap-1">
          <span
            class="evidence-chart__swatch inline-block size-2 rounded-full"
            style={"--swatch: #{series.colour}"}
          ></span>
          <span class="font-mono text-base-content/70">{series.graph_id}</span>
          <span class="text-base-content/50">
            {series.evidence |> List.last() |> elem(1) |> Float.round(2)}
          </span>
        </li>
      </ul>
      <div
        class="evidence-chart__tooltip max-w-[16rem] rounded-field border border-base-300 bg-base-100/95 px-2 py-1 font-mono text-[11px] leading-4 shadow-sm"
        data-chart-tooltip
        hidden
      >
      </div>
    </figure>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".EvidenceChart">
      // A line says which objects were climbing; only a hover says by how much
      // at which step. The numbers are already in the picture — every polyline
      // carries its own points and its object's name — so the crosshair reads
      // them out of the SVG instead of asking the server for a second copy.
      //
      // The gestures are not here. Zooming, panning and double-click-to-reset
      // are `ChartZoom` in `assets/js/chart.js`, shared with the run page's
      // chart: they are the same gestures, and writing them twice is what made
      // the two charts zoom by different factors.
      import { ChartZoom } from "../../../../../assets/js/chart.js";

      export default {
        // One element carries one hook, so this is the shared gesture hook *with*
        // the readout added, not a second hook beside it. The zoom came out of
        // this file into `assets/js/chart.js` because the two charts zoomed by
        // different factors; what stayed here is what only this chart has, which
        // is a tooltip.
        ...ChartZoom,

        mounted() {
          ChartZoom.mounted.call(this)

          // Where the pointer was, in the page's own pixels. A live chart is
          // redrawn every step, and almost every redraw happens while somebody is
          // hovering it — a tooltip that is hidden on each one is a tooltip that
          // blinks, and one that is never repositioned drifts away from the
          // cursor the moment the chart grows under it.
          this.pointer = null
          this.tooltip = this.el.parentElement.querySelector("[data-chart-tooltip]")
          if (this.tooltip === null) return

          this.el.addEventListener("mousemove", (event) => this.hover(event))
          this.el.addEventListener("mouseleave", () => this.hide())
        },

        // The picture changed, the pointer did not: the tooltip keeps saying what
        // is under it, with the numbers from the new picture. Only a pointer that
        // has left the chart hides it.
        updated() {
          ChartZoom.updated.call(this)

          this.tooltip = this.el.parentElement.querySelector("[data-chart-tooltip]")
          if (this.tooltip === null) return

          if (this.pointer === null) return this.hide()

          this.hover(this.pointer)
        },

        // Named apart from `ChartZoom.geometry/0`: spreading the shared hook
        // first and declaring this one second would otherwise shadow it, and
        // every zoom calculation would read a shape it does not know.
        hoverGeometry() {
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

        hover(pointer) {
          this.pointer = { clientX: pointer.clientX, clientY: pointer.clientY }

          const chart = this.hoverGeometry()
          const rect = this.el.getBoundingClientRect()
          const scale = rect.width / chart.width
          const x = (this.pointer.clientX - rect.left) / scale
          const plot = chart.width - chart.left - chart.right

          if (x < chart.left || x > chart.left + plot) return this.hide(false)

          const rows = this.rowsAt(x, chart)
          if (rows.length === 0) return this.hide(false)

          this.show(rows, chart, rect, this.pointer)
        },

        // The values at the step nearest the cursor, which is the question a
        // hover asks: the cursor sits between steps, the numbers do not.
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

        // The x of the reported step closest to `x`, taken across the polylines:
        // a line breaks where a step went unreported, so no single one of them
        // spans the axis. Each polyline's points are in step order, which is what
        // lets the nearest be a search rather than a walk — walking cost
        // `lines × steps` point reads on every pointer move and on every patch,
        // eleven thousand steps deep, and a chart that reads that much on a hover
        // is a chart that stops moving rather than one that answers.
        nearestStep(x) {
          let best = null

          for (const line of this.el.querySelectorAll("polyline[data-graph]")) {
            const point = nearestPoint(line.points, x)
            if (!point) continue
            if (best === null || Math.abs(point.x - x) < Math.abs(best - x)) best = point.x
          }

          return best
        },

        show(rows, chart, rect, event) {
          const shown = rows.slice(0, 8)
          const hidden = rows.length - shown.length

          this.tooltip.innerHTML =
            shown
              .map(
                (row) =>
                  `<div class="flex items-center gap-1.5">` +
                  `<span class="evidence-chart__swatch inline-block size-2 rounded-full" style="--swatch: ${row.colour}"></span>` +
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
          this.tooltip.removeAttribute("hidden")

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
          line.setAttribute("class", "evidence-chart__crosshair text-base-content/50")

          this.el.appendChild(line)
          this.crosshairMark = line

          return line
        },

        hide(pointer_left = true) {
          if (pointer_left) this.pointer = null

          if (this.tooltip) this.tooltip.setAttribute("hidden", "")
          this.crosshairMark?.remove()
          this.crosshairMark = null
        },
      }

      // The point in a polyline whose x is nearest `x`, in the SVG's own
      // units, so nothing has to guess what the browser scaled it to.
      //
      // A binary search, because a polyline's points are in step order: a run of
      // thousands of steps was read point by point for a hover that answers one
      // place. Indexed rather than iterated: `SVGPointList` is not an iterable in
      // every browser this page is read in.
      function nearestPoint(points, x) {
        let low = 0
        let high = points.numberOfItems - 1

        if (high < 0) return null

        while (low < high) {
          const middle = (low + high) >> 1
          if (points.getItem(middle).x < x) low = middle + 1
          else high = middle
        }

        const after = points.getItem(low)
        if (low === 0) return after

        const before = points.getItem(low - 1)
        return x - before.x <= after.x - x ? before : after
      }

      function escape(text) {
        const node = document.createElement("span")
        node.textContent = text
        return node.innerHTML
      }
    </script>
    """
  end
end
