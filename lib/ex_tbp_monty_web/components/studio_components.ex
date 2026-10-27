defmodule ExTbpMontyWeb.StudioComponents do
  @moduledoc """
  The pieces an experiment page is made of: the wiring diagram, the findings
  list, and the small facts about a setup.

  These are presentation only. Every number and every coordinate comes from
  `Monty.Studio.*`, so a component test checks *that the page shows what the
  studio knows* rather than re-deriving it in HEEx.
  """

  use Phoenix.Component

  alias Monty.Studio.{Diagram, Finding, Summary}

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

  @doc "The counts a run leaves behind."
  attr :summary, Summary, required: true

  def summary(assigns) do
    ~H"""
    <section id="run-summary" class="space-y-2">
      <h2 class="text-lg font-semibold tracking-tight">After the run</h2>

      <dl class="grid gap-2 sm:grid-cols-3 lg:grid-cols-6">
        <.fact label="steps" value={Integer.to_string(@summary.steps)} />
        <.fact label="total" value={duration(@summary.duration_us)} />
        <.fact label="votes sent" value={Integer.to_string(@summary.votes_sent)} />
        <.fact label="votes used" value={Integer.to_string(@summary.votes_used)} />
        <.fact label="goals" value={Integer.to_string(@summary.goals)} />
        <.fact label="actions" value={Integer.to_string(@summary.actions)} />
      </dl>

      <p id="run-summary-never-updated" class="text-sm text-warning">
        These learning modules never received input: {Enum.join(@summary.never_updated, ", ")}
      </p>
    </section>
    """
  end

  @doc "Milliseconds for a duration in microseconds."
  @spec duration(non_neg_integer()) :: String.t()
  def duration(microseconds) when microseconds < 1_000, do: "#{microseconds} µs"
  def duration(microseconds), do: "#{Float.round(microseconds / 1_000, 1)} ms"

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
