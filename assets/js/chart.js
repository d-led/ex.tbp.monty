// The gestures every chart in this application answers to.
//
// Two pages draw a chart of a run over steps: the experiment page, one per
// learning module as the run goes, and a run's own page, replaying one series.
// The pictures are different — the data, the axes and the words are theirs — but
// the *way a reader operates one* is not, and it was written twice: once here
// and once in a colocated hook of the experiment page's, which is how the two
// came to zoom by different factors, and how one got a drag-to-zoom the other
// never had.
//
// So the gestures live here once, and a chart says what to call them:
//
//   data-width, data-height   the chart's own user units
//   data-left, data-right     the gutter the plot leaves for its labels
//   data-x-min, data-x-max    the stretch drawn now
//   data-zoom-event           pushed with `{from, to}` when a window is chosen
//   data-zoom-all-event       pushed with `{how: "all"}` for the whole run
//   data-size-event           pushed with `{width, height}` when a chart that
//                             fills the screen is given a box (optional)
//   data-expanded             "true" while the chart fills the screen
//
// Everything else — lines, bands, labels, the readout — belongs to the chart.

const SVG = "http://www.w3.org/2000/svg";

// A wheel ticks many times before a page can be rebuilt, and every range asked
// for is a re-render: the last range wins, a moment after the wheel stops.
const WHEEL_SETTLE_MS = 120;

// A drag shorter than this is a click that wobbled, not a window.
const DRAG_MIN_UNITS = 4;

export const ChartZoom = {
  mounted() {
    this.el.addEventListener("pointerdown", (event) => this.startDrag(event));
    this.el.addEventListener("pointermove", (event) => this.drag(event));
    this.el.addEventListener("pointerup", () => this.endDrag());
    this.el.addEventListener("pointercancel", () => this.cancelDrag());

    // The wheel is the first thing a reader tries to look closer, and it costs
    // no control to find: it zooms about the pointer, so the step under the hand
    // keeps its place.
    this.el.addEventListener("wheel", (event) => this.zoomAtPointer(event), {
      passive: false,
    });

    // Double-clicking puts the whole run back, as Plotly's charts do: the way
    // out of a zoom is never a button a reader has to hunt for.
    this.el.addEventListener("dblclick", () => this.zoomAll());

    // A chart that fills the screen has a box the server cannot guess, so it is
    // measured here and sent: a picture drawn for the guessed box is a picture
    // stretched into it, and stretching squashes a chart's own labels.
    this.measured = null;
    this.measure();
    window.addEventListener("resize", () => this.measure());
  },

  // The plot is drawn for too many steps to redraw on every pointer move, so a
  // step that changes the data must not forget where the window was asked to be.
  updated() {
    this.measure();
  },

  // An element that holds the plot, and the plot itself. The run page's hook
  // sits on a box around the SVG (it has an HTML axis beside it); the
  // experiment page's sits on the SVG. Both are one answer here.
  plot() {
    return this.el.tagName.toLowerCase() === "svg"
      ? this.el
      : this.el.querySelector("svg");
  },

  geometry() {
    const data = this.el.dataset;
    const plot = this.plot() || this.el;
    const box = plot.getBoundingClientRect();

    return {
      width: Number(data.width) || 320,
      height: Number(data.height) || 64,
      left: Number(data.left || 0),
      right: Number(data.right || 0),
      from: Number.isFinite(Number(data.xMin))
        ? Number(data.xMin)
        : Number(data.from || 0),
      to: Number.isFinite(Number(data.xMax))
        ? Number(data.xMax)
        : Number(data.to || 0),
      box,
    };
  },

  plotWidth(chart) {
    return Math.max(chart.width - chart.left - chart.right, 1);
  },

  // Where a pointer is across the plot, in the chart's own units.
  unitX(event, chart = this.geometry()) {
    if (chart.box.width === 0) return 0;

    return ((event.clientX - chart.box.left) / chart.box.width) * chart.width;
  },

  inPlot(unitX, chart) {
    return unitX >= chart.left && unitX <= chart.left + this.plotWidth(chart);
  },

  // And where that is in the run's own terms.
  positionOf(unitX, chart) {
    const share = (unitX - chart.left) / this.plotWidth(chart);

    return chart.from + share * (chart.to - chart.from);
  },

  startDrag(event) {
    const chart = this.geometry();
    const unitX = this.unitX(event, chart);

    if (
      event.button !== 0 ||
      chart.to <= chart.from ||
      !this.inPlot(unitX, chart)
    )
      return;

    // Shift and drag moves the window instead of choosing one: the same two
    // gestures Plotly gives a reader, so the dashboard this is compared against
    // is operated the same way.
    if (event.shiftKey) {
      this.pan = { from: unitX, range: null, moved: false };
      this.el.classList.add("cursor-grabbing");

      return;
    }

    this.brush = { from: unitX, to: unitX, moved: false };
    this.showBrush(chart);
  },

  drag(event) {
    if (this.pan) return this.dragPan(event);
    if (!this.brush) return;

    const chart = this.geometry();
    const unitX = this.unitX(event, chart);

    this.brush.to = unitX;
    this.brush.moved =
      this.brush.moved || Math.abs(unitX - this.brush.from) > DRAG_MIN_UNITS;
    this.showBrush(chart);
  },

  brushRect() {
    const existing = this.el.querySelector("[data-chart-brush]");
    if (existing) return existing;

    const plot = this.plot();
    const rect = document.createElementNS(SVG, "rect");
    rect.setAttribute("data-chart-brush", "");
    rect.setAttribute("fill", "currentColor");
    rect.setAttribute("fill-opacity", "0.12");
    rect.setAttribute("stroke", "currentColor");
    rect.setAttribute("stroke-opacity", "0.4");
    rect.setAttribute("pointer-events", "none");
    rect.setAttribute("visibility", "hidden");

    if (plot.tagName.toLowerCase() === "svg") plot.appendChild(rect);

    return rect;
  },

  showBrush(chart) {
    if (!this.brush) return;

    const rect = this.brushRect();
    const top = Number(this.el.dataset.top || 0);
    const bottom = Number(this.el.dataset.bottom || 0);

    rect.setAttribute("x", String(Math.min(this.brush.from, this.brush.to)));
    rect.setAttribute("y", String(top));
    rect.setAttribute(
      "width",
      String(Math.abs(this.brush.to - this.brush.from)),
    );
    rect.setAttribute("height", String(chart.height - top - bottom));
    rect.setAttribute("visibility", "visible");
  },

  hideBrush() {
    const rect = this.el.querySelector("[data-chart-brush]");
    if (rect) rect.setAttribute("visibility", "hidden");
  },

  // A drag that went nowhere is a click, and only a real drag scopes a window.
  endDrag() {
    if (this.pan) return this.endPan();

    const brush = this.brush;
    if (!brush) return;

    this.brush = null;
    this.hideBrush();

    if (!brush.moved) return;

    const chart = this.geometry();
    const ends = [
      this.positionOf(brush.from, chart),
      this.positionOf(brush.to, chart),
    ].map(Math.round);

    this.pushRange(Math.min(...ends), Math.max(...ends));
  },

  cancelDrag() {
    this.brush = null;
    this.pan = null;
    this.hideBrush();
    this.el.classList.remove("cursor-grabbing");
    this.linesFor()?.removeAttribute("transform");
  },

  linesFor() {
    return this.el.querySelector("[data-chart-lines]");
  },

  // Shift-drag: the window slides with the hand. The lines move under the
  // pointer while it is down, and the range that was let go of is asked for
  // once — dragging is one decision, not one per pixel.
  dragPan(event) {
    const chart = this.geometry();
    const by = this.unitX(event, chart) - this.pan.from;

    this.pan.moved = this.pan.moved || Math.abs(by) > 2;

    // Dragging right looks earlier in the run, because the plot moves with the
    // hand.
    const shift = -(by / this.plotWidth(chart)) * (chart.to - chart.from);
    const from = Math.round(chart.from + shift);

    this.pan.range = [from, from + Math.round(chart.to - chart.from)];
    this.linesFor()?.setAttribute("transform", `translate(${by} 0)`);
  },

  endPan() {
    const pan = this.pan;

    this.cancelDrag();

    if (!pan || !pan.moved || !pan.range) return;

    this.pushRange(...pan.range);
  },

  // Zooming halves or doubles the window about the step under the pointer, so
  // looking closer is looking harder at what is already there rather than
  // walking somewhere else first.
  zoomAtPointer(event) {
    const chart = this.geometry();
    const unitX = this.unitX(event, chart);

    if (
      this.brush ||
      this.pan ||
      chart.to <= chart.from ||
      !this.inPlot(unitX, chart)
    )
      return;

    event.preventDefault();

    const span = chart.to - chart.from;
    const anchor = this.positionOf(unitX, chart);
    const wanted = Math.max(1, Math.round(span * (event.deltaY < 0 ? 0.5 : 2)));
    const share = (anchor - chart.from) / span;
    const from = Math.round(anchor - share * wanted);

    this.pushRange(from, from + wanted);
  },

  zoomAll() {
    const event = this.el.dataset.zoomAllEvent;
    if (event) this.pushEvent(event, { how: "all" });
  },

  // Ticks that arrive faster than a page can be rebuilt are one request: the
  // last range wins, a moment after the wheel stops. Until then the window
  // asked for is the one the next tick starts from.
  pushRange(from, to) {
    if (!(to > from)) return;

    const event = this.el.dataset.zoomEvent;
    if (!event) return;

    this.pendingRange = [from, to];

    if (this.zoomTimer) return;

    this.zoomTimer = setTimeout(() => {
      this.zoomTimer = null;

      const range = this.pendingRange;
      this.pendingRange = null;

      if (range) this.pushEvent(event, { from: range[0], to: range[1] });
    }, WHEEL_SETTLE_MS);
  },

  // Only an expanded chart has a box of its own to report: in a grid the chart
  // decides its own height from its shape, and asking the server to match that
  // would be a circle. The same size is not sent twice, so a step that redraws
  // the chart does not ask again for what it already has.
  measure() {
    const event = this.el.dataset.sizeEvent;
    if (!event) return;

    if (this.el.dataset.expanded !== "true") {
      // Out of full screen, the size that was asked for belonged to that box.
      // Remembering it is how a second visit to full screen was drawn for the
      // first one's box.
      this.measured = null;
      return;
    }

    const box = this.plot().getBoundingClientRect();
    const size = [Math.round(box.width), Math.round(box.height)];
    if (size[0] < 200 || size[1] < 120) return;
    if (
      this.measured &&
      this.measured[0] === size[0] &&
      this.measured[1] === size[1]
    )
      return;

    this.measured = size;
    this.pushEvent(event, {
      module: this.el.dataset.chartKey || "",
      width: size[0],
      height: size[1],
    });
  },
};
