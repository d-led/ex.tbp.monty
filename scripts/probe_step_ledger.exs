# What a step still does for the page, term by term.
#
#   MIX_ENV=test mix run scripts/probe_step_ledger.exs [experiment] [steps]
#
# The step is meant to hand its report over and move on. This measures what it
# still spends on the way — the beliefs, the world's own observation, the centre
# view, and the cast that carries them — and, separately, what the process that
# writes the record now spends building the entry and the line from that report.
# Whatever dominates the step's column is what moving to the presenter buys.

alias Monty.Studio

Code.require_file("probe_support.exs", __DIR__)

experiment = System.argv() |> Enum.at(0, "base_10simobj_surf_agent")
steps = System.argv() |> Enum.at(1, "12") |> String.to_integer()

opened = ProbeSupport.setup(experiment)
{:ok, run} = Studio.Run.start(opened.setup, steps: steps)
:ok = Studio.Run.set_ground_truth(run)

defmodule ProbeStepLedger do
  @doc "Microseconds each term took, over `steps` steps of `run`."
  def measure(run, steps) do
    # The cast's cost to the step is the copy a `send/2` makes; a sink that
    # never reads is the same price without a writer to crash.
    sink = spawn(fn -> Process.sleep(:infinity) end)
    {_run, ledger} = Enum.reduce(1..steps, {run, %{}}, &step(&1, &2, sink))
    Process.exit(sink, :kill)
    ledger
  end

  defp step(_number, {run, ledger}, sink) do
    {{:ok, info, observations, run}, model_us} = timed(fn -> Studio.Run.step(run) end)
    {beliefs, beliefs_us} = timed(fn -> Studio.Run.beliefs(run) end)
    {rendered, rendered_us} = timed(fn -> Studio.Run.rendered_observations(run) || observations end)
    {centre, centre_us} = timed(fn -> Studio.CentreView.frame(run.interface.env, info.step) end)

    report = %{
      info: info,
      at: Studio.RunLog.now().instant,
      episode: 0,
      beliefs: beliefs,
      observations: rendered,
      sensor_ids: Map.keys(Map.get(rendered, "agent_0", %{})),
      centre: centre
    }

    {_, cast_us} = timed(fn -> send(sink, report) end)

    # What the presenter does with the same report, for the comparison: it is
    # this process that now builds the entry and the line.
    {_, presenter_us} =
      timed(fn ->
        entry = Studio.RunLog.entry(info, beliefs, episode: 0, at: report.at)
        Studio.RunLog.line(entry)
      end)

    row = [
      model: model_us,
      beliefs: beliefs_us,
      rendered: rendered_us,
      centre: centre_us,
      cast: cast_us,
      presenter: presenter_us
    ]

    {run, Enum.reduce(row, ledger, fn {k, v}, acc -> Map.update(acc, k, [v], &[v | &1]) end)}
  end

  def timed(fun) do
    {us, value} = :timer.tc(fun)
    {value, us}
  end

  def report(ledger, steps) do
    for name <- [:model, :beliefs, :rendered, :centre, :cast, :presenter] do
      values = Map.get(ledger, name, [0])

      "#{name}: mean #{Float.round(mean(values), 1)} us, min #{Enum.min(values)}, " <>
        "max #{Enum.max(values)} (n=#{steps})"
    end
  end

  def mean(values), do: Enum.sum(values) / length(values)
end

ledger = ProbeStepLedger.measure(run, steps)

IO.puts("\n== step ledger: #{experiment}, #{steps} steps ==")
Enum.each(ProbeStepLedger.report(ledger, steps), &IO.puts/1)

step_side =
  Enum.reduce([:beliefs, :rendered, :centre, :cast], 0.0, fn name, total ->
    total + Enum.sum(Map.get(ledger, name, [0])) / steps
  end)

IO.puts("the step spends: #{Float.round(step_side, 1)} us a step on its report")

IO.puts(
  "the presenter spends: " <>
    "#{Float.round(ProbeStepLedger.mean(Map.get(ledger, :presenter, [0])), 1)} us a step"
)
