defmodule Monty.Studio.Replay do
  @moduledoc """
  Stepping back through a run that already happened.

  A replay is not a re-run. Every recorded step kept both halves of what a
  timestep is — what the modules reported (the log) and what they were given
  (the observations) — so a replay reads history instead of guessing at it: the
  frame under the slider is the frame that run saw, and no re-simulation with
  the same seed is needed to produce it.

  Time here is the run's own. Monty counts timesteps from zero, so a step number
  is what a Monty developer would call it, and the slider moves in whole
  timesteps because half a timestep is not a thing that happened. What zooms is
  the chart's window over those steps.
  """

  alias Monty.Simulators.Synthetic.Camera
  alias Monty.Studio.Chart
  alias Monty.Studio.Replay.Digest
  alias Monty.Studio.RunHistory.Run
  alias Monty.Studio.Verdict

  @type step_number :: integer()

  @type point :: %{step: step_number(), value: number(), episode: non_neg_integer() | nil}

  @type series :: %{
          id: String.t(),
          label: String.t(),
          title: String.t(),
          unit: String.t(),
          axis: String.t(),
          points: [point()]
        }

  @typedoc """
  One recorded timestep, ready to draw: the frames it delivered, the report that
  went with them, and what the sensors were looking at.
  """
  @type moment :: %{
          position: non_neg_integer(),
          step: step_number(),
          frames: [Camera.frame()],
          entry: map() | nil,
          sensors: map()
        }

  @doc """
  The positions a replay can show, in order.

  A moment's position is its place in the run's own sequence, not the step
  number it carries: every episode counts its steps from zero again, so a run of
  nine episodes has nine step 0s and one position 0.

  Empty for a run that has not stepped yet — a run is a record from the moment
  it starts, and a replay of no steps is a page that says so, not a crash.
  """
  @spec steps(Run.t()) :: [step_number()]
  def steps(%Run{} = run), do: positions(run)

  @doc "The first step a replay can show, or `nil` when there is nothing to show."
  @spec first_step(Run.t()) :: step_number() | nil
  def first_step(run), do: run |> steps() |> List.first()

  @doc "The last step a replay can show, or `nil`."
  @spec last_step(Run.t()) :: step_number() | nil
  def last_step(run), do: run |> steps() |> List.last()

  @doc """
  Whether the run kept any picture at all.

  A run recorded before a step kept its pictures has none, and a replay that drew
  a row of empty frames for every one of its steps would be space that says
  nothing. The page says it once instead.
  """
  @spec pictures?(Run.t()) :: boolean()
  def pictures?(%Run{timeline: timeline}) do
    timeline
    |> Enum.flat_map(&(&1 |> Map.get("sensors", %{}) |> Map.values()))
    |> Enum.any?(&Camera.pictures?/1)
  end

  @doc """
  Whether these observations kept a picture at all.

  The same question `pictures?/1` asks of a whole run, for a page that read the
  record without its pictures (`RunHistory.head/1`) and has one step's
  observations in hand.
  """
  @spec kept_pictures?(map() | nil) :: boolean()
  def kept_pictures?(sensors) when is_map(sensors),
    do: sensors |> Map.values() |> Enum.any?(&Camera.pictures?/1)

  def kept_pictures?(_none), do: false

  @doc """
  One recorded step.

  A step the run never reached is answered with the nearest one it did, because
  a slider dragged past the end of a run should come to rest at the end rather
  than ask a page to render a hole.
  """
  @spec at(Run.t(), step_number()) :: moment() | nil
  def at(%Run{} = run, step) do
    case last_step(run) do
      nil -> nil
      last -> run |> moment(step |> min(last) |> max(0)) |> draw()
    end
  end

  @doc """
  The series a replay can chart, sensors first.

  The world is what a timestep is about, so its positions come first; then what
  the modules made of it, then what making it cost.
  """
  @spec series(Run.t()) :: [series()]
  def series(%Run{} = run), do: run |> digest() |> Digest.series()

  @doc """
  The run's numbers as they are kept while it grows.

  A page following a run does not build this from the whole log on every step —
  that is quadratic in the run's length and it is what made a watched run's page
  fall further behind the longer the run went. It keeps the digest from one
  rebuild to the next and appends the steps that arrived
  (`Monty.Studio.Replay.Digest`).
  """
  @spec digest(Run.t()) :: Digest.t()
  def digest(%Run{} = run), do: Digest.from(run)

  @doc """
  Every object a learning module held a graph for, one series each.

  This is the chart a Monty experiment is judged by: one line per object the
  module had not ruled out, all on the same axis, so the moment one of them
  climbs away from the others is visible as a shape rather than inferred from a
  table. A module that never built a graph contributes nothing, so a run with no
  graphs answers `[]` — and the page says so instead of drawing a flat line at
  zero and calling it evidence.

  With a module's id, the same lines from that module's beliefs alone. A
  heterarchy is five opinions about the same objects and the ensemble's line above
  them is the strongest of the five, which hides both the four it overruled and
  the fact that one module recognised the object while the rest timed out: on its
  own, a module's evidence says which.
  """
  @spec objects(Run.t(), String.t() | nil) :: [series()]
  def objects(%Run{} = run, module_id \\ nil),
    do: run |> digest() |> Digest.objects(module_id)

  @doc """
  One object's beliefs as the run's modules reported them, and the line they
  converge on (`Monty.Studio.Chart.beliefs/2`).

  A chart is drawn for one module, so an object that five modules were climbing
  at different heights looks like an object one module climbed. This keeps both:
  every module's own report for the graph, and the strongest report at each step.
  `nil` when no module ever reported that object — an object nobody believed is
  not a chart with one empty line in it.
  """
  @spec beliefs(Run.t(), String.t()) :: Chart.beliefs() | nil
  def beliefs(%Run{} = run, graph_id) do
    digest = digest(run)

    reports =
      for module_id <- Digest.modules(digest),
          series <- Digest.objects(digest, module_id),
          series.label == graph_id,
          do: {module_id, Enum.map(series.points, &{&1.step, &1.value})}

    case reports do
      [] -> nil
      reports -> Chart.beliefs(reports, graph_id)
    end
  end

  @doc """
  The learning modules the run reported beliefs for, oldest name first.

  One module here is one chart: which objects it still held, and how strongly,
  is a question about a module and not about the ensemble.
  """
  @spec modules(Run.t()) :: [String.t()]
  def modules(%Run{} = run), do: run |> digest() |> Digest.modules()

  @doc """
  The object the run believed in most, and how much, over the whole run.

  The one number a person wants above the pictures: what it settled on, and how
  sure it was.
  """
  @spec best_evidence(Run.t()) :: %{object: String.t(), value: number()} | nil
  def best_evidence(%Run{} = run), do: run |> digest() |> Digest.best()

  @doc """
  The theories the run was still weighing at one step, strongest first.

  A replay is a slider, and what a person wants while dragging it is the short
  version: not the ten lines, two names and two numbers. Objects the modules have
  ruled out to nothing are left out rather than listed at zero — a theory with no
  evidence behind it is not a theory.

  `count` is how many to name. The default is two because that is what fits on
  one line beside the step, and because a decision between two is the shape of
  the moment being looked at.
  """
  @spec theories(moment(), pos_integer()) :: [%{object: String.t(), evidence: number()}]
  def theories(moment, count \\ 2) do
    moment
    |> object_names()
    |> Enum.map(&%{object: &1, evidence: evidence_of(moment, &1)})
    |> Enum.reject(&(&1.evidence <= 0))
    |> Enum.sort_by(& &1.evidence, :desc)
    |> Enum.take(count)
  end

  defp object_names(moment) do
    moment
    |> beliefs()
    |> Enum.flat_map(fn belief -> belief |> Map.get("graphs", %{}) |> Map.keys() end)
    |> Enum.uniq()
  end

  # An object's evidence on a step: the strongest any module held for it. One
  # number per object per step is what a line needs, and the best module is the
  # one whose belief the ensemble acted on.
  defp evidence_of(moment, name) do
    moment
    |> beliefs()
    |> Enum.map(&(&1 |> Map.get("graphs", %{}) |> Map.get(name, %{}) |> Map.get("max_evidence")))
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> 0.0 end)
  end

  defp beliefs(moment), do: moment |> beliefs_of() |> Map.values()

  # The entry's beliefs, keyed by the module that held them: the key is the only
  # place a module's name is written down.
  defp beliefs_of(%{entry: entry}) when is_map(entry), do: Map.get(entry, "beliefs", %{})

  defp beliefs_of(_moment), do: %{}

  @doc """
  What the modules concluded at one step, and whether they agreed
  (`Monty.Studio.Verdict.of/1`).

  A step in the middle of an episode has concluded nothing, and answers a verdict
  of "no module has concluded yet" — which is the truth about a step, and the
  reason a finished episode is read at its last step.
  """
  @spec verdict(moment()) :: Verdict.t() | nil
  def verdict(moment), do: moment |> beliefs_of() |> Verdict.of()

  @doc "One series by id, with whatever points the run has for it."
  @spec chart_series(Run.t(), String.t()) :: series()
  def chart_series(%Run{} = run, id), do: run |> digest() |> Digest.series_of(id)

  @doc """
  Which episode a recorded moment belongs to, when the record kept it.

  The step's own number restarts in every episode, so it cannot say how far into
  a run a reader is; the number the step was recorded with can, and it is the one
  the bands and the seams are drawn from.
  """
  @spec episode_of(map()) :: non_neg_integer() | nil
  def episode_of(%{entry: %{"episode" => episode}}) when is_integer(episode), do: episode
  def episode_of(_moment), do: nil

  @doc """
  A window over the recorded steps, clamped to the ones the run has.

  Keeping this here means a page never has to work out whether a zoom went past
  the end of the run.
  """
  @spec window(Run.t(), {number(), number()}) :: {number(), number()}
  def window(%Run{} = run, {from, to}) do
    case {first_step(run), last_step(run)} do
      {nil, nil} -> {from, to}
      {first, last} -> {clamp(from, first, last), clamp(to, first, last)}
    end
  end

  @doc """
  A zoomed window: `:in` halves it around the playhead, `:out` doubles it,
  `:all` goes back to the whole run.

  Halving and doubling rather than scaling by a percentage keeps both edges on
  whole timesteps, which is the only kind there are.
  """
  @spec zoom(Run.t(), {number(), number()}, step_number() | nil, :in | :out | :all) ::
          {number(), number()}
  def zoom(%Run{} = run, window, _playhead, :all) do
    case {first_step(run), last_step(run)} do
      {nil, nil} -> window
      {first, last} -> {first, last}
    end
  end

  def zoom(%Run{} = run, {from, to}, playhead, zoom) do
    case {first_step(run), last_step(run)} do
      {nil, nil} ->
        {from, to}

      {first, last} ->
        playhead = clamp(playhead || first, first, last)
        wanted = if zoom == :in, do: div(to - from, 2), else: (to - from) * 2
        around(playhead, min(max(wanted, 1), last - first), first, last)
    end
  end

  @doc "Whether a step lies inside a window."
  @spec inside?({number(), number()}, step_number()) :: boolean()
  def inside?({from, to}, step), do: step >= from and step <= to

  # -- what a step is made of ------------------------------------------------

  # One position, read from the two lists without walking them all: `at/2` is
  # called on every drag of the slider, and a replay that built every moment to
  # then pick one took a tenth of a second to answer.
  defp moment(%Run{} = run, position) do
    moment_of(position, Enum.at(run.log, position), Enum.at(run.timeline, position) || %{})
  end

  defp moment_of(position, entry, seen) do
    %{
      position: position,
      step: Map.get(seen, "step") || (entry || %{})["step"],
      sensors: Map.get(seen, "sensors", %{}),
      entry: entry
    }
  end

  # The run's places, in order. Whichever of the two lists is longer is the
  # spine: a run whose pictures were not read still has every step.
  defp positions(%Run{timeline: timeline, log: log}) do
    case max(length(timeline), length(log)) do
      0 -> []
      count -> Enum.to_list(0..(count - 1)//1)
    end
  end

  @doc """
  The same moment, with the pictures those sensors kept.

  A moment built from a record without its timeline (`RunHistory.head/1`) has no
  frames; this puts them back for the one step being shown, from the one entry
  that step owns.
  """
  @spec with_pictures(moment() | nil, map() | nil) :: moment() | nil
  def with_pictures(nil, _sensors), do: nil

  def with_pictures(moment, nil), do: moment

  def with_pictures(%{step: step} = moment, sensors) when is_map(sensors) do
    %{moment | sensors: sensors, frames: frames(%{sensors: sensors, step: step})}
  end

  # A drawn moment is a recorded one plus the pictures it delivered, so it keeps
  # its place in the run: `at/2` promises a moment, and a moment that had
  # forgotten where it sat would not be one.
  @doc """
  The pictures a step's sensors kept, as frames a page draws.

  A replay asks for these for the one step on screen; a page showing several runs
  side by side (`ExTbpMontyWeb.RunParts`) asks for the last step of each, from the
  sensors it read for that position.
  """
  @spec pictures(non_neg_integer(), map()) :: [map()]
  def pictures(step, sensors) when is_map(sensors),
    do: frames(%{step: step, sensors: sensors})

  defp draw(moment) do
    %{
      position: moment.position,
      step: moment.step,
      sensors: moment.sensors,
      entry: moment.entry,
      frames: frames(moment)
    }
  end

  # Only the sensors that kept a picture. A step from a run recorded before runs
  # kept them has no pictures at all, and a page of empty frames is not a replay —
  # it is space that says nothing.
  defp frames(moment) do
    for {sensor_id, observation} <- moment.sensors,
        Camera.pictures?(observation),
        do: Camera.frame(sensor_id, observation, moment.step)
  end

  defp around(_playhead, 0, first, _last), do: {first, first}

  defp around(playhead, width, first, last) do
    start = (playhead - div(width, 2)) |> max(first) |> min(last - width)
    {start, start + width}
  end

  defp clamp(value, first, last), do: value |> max(first) |> min(last)
end
