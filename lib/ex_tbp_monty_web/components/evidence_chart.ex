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
    </style>

    <figure
      id={"chart-#{@module_id}"}
      class="relative rounded-field border border-base-300 bg-base-100 p-2"
    >
      <figcaption class="flex items-baseline justify-between px-0.5 pb-1 font-mono text-[11px] text-base-content/60">
        <span>{@module_id}</span>
        <span :if={@chart.mlh}>{@chart.mlh.graph_id} is the answer so far</span>
      </figcaption>
      <svg
        id={"chart-svg-#{@module_id}"}
        phx-hook=".EvidenceChart"
        viewBox={"0 0 #{@chart.width} #{@chart.height}"}
        class="w-full touch-none"
        role="img"
        aria-label={"evidence per object, step by step and episode by episode, for #{@module_id}"}
        data-x-min={@chart.x_min}
        data-x-max={@chart.x_max}
        data-y-max={@chart.y_max}
        data-width={@chart.width}
        data-height={@chart.height}
        data-margin-left={@chart.margin_left}
        data-margin-right={@chart.margin_right}
        data-margin-top={@chart.margin_top}
        data-margin-bottom={@chart.margin_bottom}
      >
        <%!-- Which episode each stretch of the run is. Evidence restarts at zero
        at every boundary, and a reader counting the descents is counting
        episodes, so they are shaded in turn rather than left to be inferred from
        the dashes. Drawn first, behind the grid and the lines. --%>
        <g :for={band <- @chart.episode_bands}>
          <rect
            x={band.x}
            y={@chart.margin_top}
            width={band.width}
            height={@chart.height - @chart.margin_top - @chart.margin_bottom}
            fill={band.colour}
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
            stroke="currentColor"
            stroke-width="0.5"
            class="text-base-content/20"
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
      </svg>
      <ul class="flex flex-wrap gap-x-3 gap-y-1 px-0.5 pb-0.5 text-[11px]">
        <li :for={series <- @chart.series} class="flex items-center gap-1">
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
      export default {
        mounted() {
          // Where the pointer was, in the page's own pixels. A live chart is
          // redrawn every step, and almost every redraw happens while somebody is
          // hovering it — a tooltip that is hidden on each one is a tooltip that
          // blinks, and one that is never repositioned drifts away from the
          // cursor the moment the chart grows under it.
          this.pointer = null
          this.tooltip = this.el.parentElement.querySelector("[data-chart-tooltip]")

          this.el.addEventListener("mousemove", (event) => this.hover(event))
          this.el.addEventListener("mouseleave", () => this.hide())
        },

        // The picture changed, the pointer did not: the tooltip keeps saying what
        // is under it, with the numbers from the new picture. Only a pointer that
        // has left the chart hides it.
        updated() {
          this.tooltip = this.el.parentElement.querySelector("[data-chart-tooltip]")
          if (this.pointer === null) return this.hide()

          this.hover(this.pointer)
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

        hover(pointer) {
          this.pointer = { clientX: pointer.clientX, clientY: pointer.clientY }

          const chart = this.geometry()
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
    """
  end
end
