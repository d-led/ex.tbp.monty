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
  alias Monty.Studio.RunHistory.Run

  @logged_series ["evidence", "percepts", "votes_used", "duration_us"]

  # The value axis of an evidence chart, named where the charts are built so the
  # page never has to guess what the numbers are.
  @evidence_axis "evidence"

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
  def series(%Run{} = run) do
    # One walk for every series: each used to rebuild all the run's moments, and
    # a moment asked its own position for an entry with `Enum.at/2` — quadratic
    # in the steps and repeated once per series, which on a 24 329-step run was
    # nine seconds on every page load.
    moments = recorded(run)

    ids = Enum.map(sensor_ids(run), &("sensor:" <> &1)) ++ @logged_series

    Enum.map(ids, fn id ->
      %{
        id: id,
        label: label_of(id),
        title: label_of(id),
        unit: unit_of(id),
        axis: axis_of(id),
        points: Enum.map(moments, &point(&1, id))
      }
    end)
  end

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
  def objects(%Run{} = run, module_id \\ nil) do
    moments = recorded(run)

    names =
      moments |> Enum.flat_map(&object_names(&1, module_id)) |> Enum.uniq() |> Enum.sort()

    Enum.map(names, fn name -> object_series(moments, name, module_id) end)
  end

  @doc """
  The learning modules the run reported beliefs for, oldest name first.

  One module here is one chart: which objects it still held, and how strongly,
  is a question about a module and not about the ensemble.
  """
  @spec modules(Run.t()) :: [String.t()]
  def modules(%Run{} = run) do
    run |> recorded() |> Enum.flat_map(&module_ids/1) |> Enum.uniq() |> Enum.sort()
  end

  defp object_series(moments, name, module_id) do
    %{
      id: "object:" <> name,
      label: name,
      title: name,
      unit: "",
      axis: @evidence_axis,
      points:
        moments
        |> Enum.filter(&(name in object_names(&1, module_id)))
        |> Enum.map(fn moment ->
          %{
            step: moment.position,
            value: evidence_of(moment, name, module_id),
            episode: episode_of(moment)
          }
        end)
    }
  end

  @doc """
  The object the run believed in most, and how much, over the whole run.

  The one number a person wants above the pictures: what it settled on, and how
  sure it was.
  """
  @spec best_evidence(Run.t()) :: %{object: String.t(), value: number()} | nil
  def best_evidence(%Run{} = run) do
    run
    |> recorded()
    |> Enum.flat_map(fn moment ->
      for name <- object_names(moment), do: %{object: name, value: evidence_of(moment, name)}
    end)
    |> Enum.max_by(& &1.value, fn -> nil end)
    |> case do
      nil -> nil
      best -> best
    end
  end

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

  defp object_names(moment, module_id \\ nil) do
    moment
    |> beliefs(module_id)
    |> Enum.flat_map(fn belief -> belief |> Map.get("graphs", %{}) |> Map.keys() end)
    |> Enum.uniq()
  end

  # An object's evidence on a step: the strongest any module held for it, or what
  # one module held when a module is named. One number per object per step is what
  # a line needs, and the best module is the one whose belief the ensemble acted
  # on.
  defp evidence_of(moment, name, module_id \\ nil) do
    moment
    |> beliefs(module_id)
    |> Enum.map(&(&1 |> Map.get("graphs", %{}) |> Map.get(name, %{}) |> Map.get("max_evidence")))
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> 0.0 end)
  end

  defp beliefs(moment, nil), do: moment |> beliefs_of() |> Map.values()

  defp beliefs(moment, module_id) do
    moment
    |> beliefs_of()
    |> Map.get(module_id)
    |> case do
      nil -> []
      belief -> [belief]
    end
  end

  # The entry's beliefs, keyed by the module that held them: the key is the only
  # place a module's name is written down.
  defp beliefs_of(%{entry: entry}) when is_map(entry), do: Map.get(entry, "beliefs", %{})

  defp beliefs_of(_moment), do: %{}

  defp module_ids(%{entry: entry}) when is_map(entry),
    do: entry |> Map.get("beliefs", %{}) |> Map.keys()

  defp module_ids(_moment), do: []

  @doc "One series by id, with whatever points the run has for it."
  @spec chart_series(Run.t(), String.t()) :: series()
  def chart_series(%Run{} = run, id) do
    %{
      id: id,
      label: label_of(id),
      title: label_of(id),
      unit: unit_of(id),
      axis: axis_of(id),
      points: run |> recorded() |> Enum.map(&point(&1, id))
    }
  end

  # The episode travels with the point: the chart shades them in turn, and a
  # step on its own does not say which episode it belonged to.
  defp point(moment, id),
    do: %{step: moment.position, value: value_of(moment, id), episode: episode_of(moment)}

  defp episode_of(%{entry: %{"episode" => episode}}) when is_integer(episode), do: episode
  defp episode_of(_moment), do: nil

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

  # The log is the spine, and the timeline is what the sensors saw at each place
  # on it. Both are written one entry per step, but a record read without its
  # pictures (`RunHistory.head/1`) has the log alone: every line, every number
  # and every theory is still there, and only the frames are missing — which is
  # why a step made from a log-only record is a step with no pictures, not a
  # step that did not happen.
  defp recorded(%Run{log: log, timeline: timeline}) do
    # A step's own number restarts at zero in every episode, so it cannot address
    # a replay: nine episodes of twelve steps are 108 recorded moments, not
    # twelve. The log and the timeline are appended together, one entry each per
    # step, so a moment's place in the sequence is what pairs it with its
    # report — and its episode is what the band on the chart is drawn from.
    #
    # Both lists are walked once. Asking each position for its entry made a
    # page's charts quadratic in the run's steps.
    seen = timeline ++ List.duplicate(%{}, max(length(log) - length(timeline), 0))

    log
    |> Enum.zip(seen)
    |> Enum.with_index()
    |> Enum.map(fn {{entry, moment}, position} -> moment_of(position, entry, moment) end)
  end

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

  defp sensor_ids(%Run{timeline: timeline}) do
    timeline
    |> Enum.flat_map(&(&1 |> Map.get("sensors", %{}) |> Map.keys()))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp value_of(%{sensors: sensors}, "sensor:" <> sensor_id),
    do: sensors |> Map.get(sensor_id, %{}) |> position() |> x()

  defp value_of(%{entry: entry}, "percepts"), do: length(get_in(entry || %{}, ["percepts"]) || [])
  defp value_of(%{entry: entry}, "votes_used"), do: get_in(entry || %{}, ["votes", "used"]) || 0
  defp value_of(%{entry: entry}, "duration_us"), do: Map.get(entry || %{}, "duration_us", 0)

  # How sure the run was on that step: the best evidence any learning module held
  # for any object. That is the curve an episode is judged by — it climbs to the
  # recognition or it does not — and it is what the live page draws while a run is
  # going, so a replay can draw the same one.
  defp value_of(%{entry: entry}, "evidence"), do: strongest_evidence(entry)

  defp strongest_evidence(nil), do: 0.0

  defp strongest_evidence(entry) do
    entry
    |> Map.get("beliefs", %{})
    |> Map.values()
    |> Enum.flat_map(&(&1 |> Map.get("graphs", %{}) |> Map.values()))
    |> Enum.map(&(Map.get(&1, "max_evidence") || 0.0))
    |> Enum.max(fn -> 0.0 end)
  end

  # Where a sensor was on that step: the `location` the transforms filled in, or
  # the camera pose the world sent back, whose last column is the sensor's place
  # in the world. A world behind the port answers no `location`, so without the
  # second the chart draws a flat line at zero for a sensor that did move.
  defp position(observation),
    do: Map.get(observation, "location") || translation(observation["cam_to_world"])

  defp translation([row | _rest] = matrix) when is_list(row), do: Enum.map(matrix, &List.last/1)
  defp translation(_absent), do: nil

  defp x([x | _rest]), do: x
  defp x(_not_a_location), do: 0.0

  defp label_of("sensor:" <> sensor_id), do: "#{sensor_id} x"
  defp label_of("percepts"), do: "percepts per step"
  defp label_of("votes_used"), do: "votes used"
  defp label_of("duration_us"), do: "step duration"
  defp label_of("evidence"), do: "best evidence"
  defp label_of(other), do: other

  defp unit_of("sensor:" <> _sensor_id), do: "m"
  defp unit_of("duration_us"), do: "µs"
  defp unit_of(_counted), do: ""

  # What the numbers on the value axis are. Evidence is the score a hypothesis is
  # ranked by and the one axis a Monty page is read against, so it says
  # "evidence" rather than nothing; a count says what it counts.
  defp axis_of("sensor:" <> _sensor_id), do: "metres"
  defp axis_of("duration_us"), do: "microseconds"
  defp axis_of("percepts"), do: "percepts"
  defp axis_of("votes_used"), do: "votes"
  defp axis_of(_evidence), do: @evidence_axis

  defp around(_playhead, 0, first, _last), do: {first, first}

  defp around(playhead, width, first, last) do
    start = (playhead - div(width, 2)) |> max(first) |> min(last - width)
    {start, start + width}
  end

  defp clamp(value, first, last), do: value |> max(first) |> min(last)
end
