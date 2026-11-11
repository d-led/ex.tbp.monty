defmodule ExTbpMontyWeb.RunParts do
  @moduledoc """
  One card per part of a parallel run, one after the other.

  This is the layout of the pyview dashboard the studio follows (the
  `liveview_experiment` contrib): for every publisher — here, every part of one
  press of Run — its name, how far it has got, the strongest evidence it holds,
  the pictures its sensors just took, and its evidence over time. A parallel run
  is several runs (`Monty.Studio.Partition`), and a page that drew only the one it
  was following hid the other three.

  The cards are drawn from the server's numbers (`Monty.Studio.Parts`): the chart
  is `Monty.Studio.Chart`'s, the frames are `Monty.Studio.Replay`'s, and nothing
  here decides anything.
  """

  use Phoenix.Component

  alias ExTbpMontyWeb.EvidenceChart

  attr :parts, :list, required: true
  attr :title, :string, default: "The parts of this run"

  def parts(assigns) do
    ~H"""
    <section id="run-parts" class="space-y-2">
      <h3 class="text-sm font-medium">{@title}</h3>

      <div
        :for={part <- @parts}
        id={"part-#{part.id}"}
        class="space-y-2 rounded-field border border-base-300 bg-base-100 p-2"
      >
        <header class="flex flex-wrap items-baseline gap-2">
          <span class="font-mono text-xs">{part.label}</span>
          <span id={"part-#{part.id}-status"} class={["badge badge-xs", status_class(part.status)]}>
            {part.status}
          </span>
          <span class="text-[11px] text-base-content/60">{part.span}</span>
          <span
            :if={part.object}
            id={"part-#{part.id}-object"}
            class="text-[11px] text-base-content/60"
          >
            {part.object}
          </span>
          <span class="ms-auto font-mono text-[11px] text-base-content/50">
            {part.steps} step(s) · {part.episodes_done} episode(s)
          </span>
          <a href={"/runs/#{part.id}"} class="text-[11px] link">the run</a>
        </header>

        <p :if={part.best} id={"part-#{part.id}-best"} class="text-xs">
          max evidence: <span class="font-mono">{part.best.object}</span>
          ({format(part.best.evidence)})
        </p>

        <div :if={part.frames != []} class="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
          <figure
            :for={frame <- part.frames}
            id={"part-#{part.id}-frame-#{frame.sensor_id}"}
            class="rounded-field border border-base-300 bg-base-100 p-1.5"
          >
            <figcaption class="flex items-baseline justify-between px-0.5 pb-1 text-[11px] text-base-content/60">
              <span class="font-mono">{frame.sensor_id}</span>
              <span>{frame.note}</span>
            </figcaption>
            <%!-- The frame is markup this application built, with every value
            in it escaped where it was built. --%>
            <div class="text-base-content/80">{frame.data}</div>
          </figure>
        </div>

        <EvidenceChart.evidence_chart
          module_id={"part-#{part.id}"}
          label={"evidence · #{part.label}"}
          chart={part.chart}
        />
      </div>
    </section>
    """
  end

  defp status_class("finished"), do: "badge-success"
  defp status_class("running"), do: "badge-info"
  defp status_class("failed"), do: "badge-error"
  defp status_class(_other), do: "badge-ghost"

  defp format(nil), do: "—"

  defp format(evidence) when is_number(evidence),
    do: :erlang.float_to_binary(evidence * 1.0, decimals: 3)
end
