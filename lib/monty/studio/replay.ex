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

  @logged_series ["percepts", "votes_used", "duration_us"]

  @type step_number :: integer()

  @type point :: %{step: step_number(), value: number()}

  @type series :: %{id: String.t(), label: String.t(), unit: String.t(), points: [point()]}

  @typedoc """
  One recorded timestep, ready to draw: the frames it delivered, the report that
  went with them, and what the sensors were looking at.
  """
  @type moment :: %{
          step: step_number(),
          frames: [Camera.frame()],
          entry: map() | nil,
          sensors: map()
        }

  @doc """
  The step numbers a run recorded, in order.

  Empty for a run that has not stepped yet — a run is a record from the moment
  it starts, and a replay of no steps is a page that says so, not a crash.
  """
  @spec steps(Run.t()) :: [step_number()]
  def steps(%Run{timeline: timeline}), do: Enum.map(timeline, & &1["step"])

  @doc "The first step a replay can show, or `nil` when there is nothing to show."
  @spec first_step(Run.t()) :: step_number() | nil
  def first_step(run), do: run |> steps() |> List.first()

  @doc "The last step a replay can show, or `nil`."
  @spec last_step(Run.t()) :: step_number() | nil
  def last_step(run), do: run |> steps() |> List.last()

  @doc """
  One recorded step.

  A step the run never reached is answered with the nearest one it did, because
  a slider dragged past the end of a run should come to rest at the end rather
  than ask a page to render a hole.
  """
  @spec at(Run.t(), step_number()) :: moment() | nil
  def at(%Run{} = run, step) do
    case recorded(run) do
      [] -> nil
      recorded -> recorded |> Enum.min_by(&abs(&1.step - step)) |> draw()
    end
  end

  @doc """
  The series a replay can chart, sensors first.

  The world is what a timestep is about, so its positions come first; then what
  the modules made of it, then what making it cost.
  """
  @spec series(Run.t()) :: [series()]
  def series(%Run{} = run) do
    sensor_series(run) ++ Enum.map(@logged_series, &chart_series(run, &1))
  end

  @doc "One series by id, with whatever points the run has for it."
  @spec chart_series(Run.t(), String.t()) :: series()
  def chart_series(%Run{} = run, id) do
    %{
      id: id,
      label: label_of(id),
      unit: unit_of(id),
      points:
        Enum.map(recorded(run), fn moment -> %{step: moment.step, value: value_of(moment, id)} end)
    }
  end

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

  # The timeline is the spine: a step exists because the run saw something at
  # it, and the log is what the modules said about that same step.
  defp recorded(%Run{timeline: timeline, log: log}) do
    log_by_step = Map.new(log, &{&1["step"], &1})

    Enum.map(timeline, fn moment ->
      %{
        step: moment["step"],
        sensors: Map.get(moment, "sensors", %{}),
        entry: Map.get(log_by_step, moment["step"])
      }
    end)
  end

  defp draw(moment) do
    %{
      step: moment.step,
      sensors: moment.sensors,
      entry: moment.entry,
      frames:
        Enum.map(moment.sensors, fn {sensor_id, observation} ->
          Camera.frame(sensor_id, observation, moment.step)
        end)
    }
  end

  defp sensor_series(%Run{} = run) do
    run
    |> sensor_ids()
    |> Enum.map(&chart_series(run, "sensor:" <> &1))
  end

  defp sensor_ids(%Run{timeline: timeline}) do
    timeline
    |> Enum.flat_map(&(&1 |> Map.get("sensors", %{}) |> Map.keys()))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp value_of(%{sensors: sensors}, "sensor:" <> sensor_id),
    do: sensors |> Map.get(sensor_id, %{}) |> Map.get("location") |> x()

  defp value_of(%{entry: entry}, "percepts"), do: length(get_in(entry || %{}, ["percepts"]) || [])
  defp value_of(%{entry: entry}, "votes_used"), do: get_in(entry || %{}, ["votes", "used"]) || 0
  defp value_of(%{entry: entry}, "duration_us"), do: Map.get(entry || %{}, "duration_us", 0)

  defp x([x | _rest]), do: x
  defp x(_not_a_location), do: 0.0

  defp label_of("sensor:" <> sensor_id), do: "#{sensor_id} x"
  defp label_of("percepts"), do: "percepts per step"
  defp label_of("votes_used"), do: "votes used"
  defp label_of("duration_us"), do: "step duration"
  defp label_of(other), do: other

  defp unit_of("sensor:" <> _sensor_id), do: "m"
  defp unit_of("duration_us"), do: "µs"
  defp unit_of(_counted), do: ""

  defp around(_playhead, 0, first, _last), do: {first, first}

  defp around(playhead, width, first, last) do
    start = (playhead - div(width, 2)) |> max(first) |> min(last - width)
    {start, start + width}
  end

  defp clamp(value, first, last), do: value |> max(first) |> min(last)
end
