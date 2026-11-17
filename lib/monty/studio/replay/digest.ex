defmodule Monty.Studio.Replay.Digest do
  @moduledoc """
  A run's lines, kept as the run grows.

  A page following a run needs six things about every step it has taken: what
  the modules believed, what it perceived, what it voted, what it cost, where
  the sensors were. Recomputing them from the whole log on every step is
  quadratic in a run's length, and it is what a watched run paid — a page that
  was three thousand steps behind a run of eight thousand and never caught up,
  because each of its rebuilds walked every step the run had ever taken.

  So the numbers are kept here as they arrive. Appending a step touches only that
  step, and what is kept is bounded: a line holds its lowest, highest and latest
  point per group of steps, and when it has too many groups neighbouring ones
  merge. A run of any length therefore keeps at most `3 * @buckets` points a
  line — the whole run's shape as a chart draws it, at a resolution that falls as
  the run grows, and no growth in what a page holds or what a rebuild costs.

  What it answers is `Monty.Studio.Replay`'s shape: the same series ids, the same
  labels, units and axes, points a chart can draw. A run short enough to keep
  every step (fewer than `@buckets` steps) keeps every point, one per step, so a
  short run's lines are exactly what they always were.
  """

  alias Monty.Studio.RunHistory.Run

  # The lines every step reports, in the order a page offers them.
  @logged_series ~w(evidence percepts votes_used duration_us world_us)

  # The evidence chart's value axis, named where the charts are built so the page
  # never has to guess what the numbers are.
  @evidence_axis "evidence"

  # How many groups of steps one line keeps. Each group keeps three points — its
  # lowest, its highest and its latest — so a line holds at most three times this
  # whatever the run's length, and a run of fewer steps than this is kept exactly.
  @buckets 512

  @typedoc """
  One group of a line's steps: where it rose least, where it rose most, and where
  it ended. The extremes are what stop a line from losing a peak when groups
  merge; the last point is what lets a line end where the run does.
  """
  @type bucket :: %{low: map(), high: map(), last: map()}

  @typedoc "One line: the group being filled, the ones closed behind it, and its drawn points."
  @type line :: %{
          stride: pos_integer(),
          buckets: [bucket()],
          size: non_neg_integer(),
          open: [map()],
          points: [map()] | nil
        }

  @typedoc """
  A run's numbers so far: its length in positions, one line per reported number,
  one line per object (and per module per object), and the sets the page shows.
  """
  @type t :: %__MODULE__{
          steps: non_neg_integer(),
          lines: %{String.t() => line()},
          objects: %{String.t() => line()},
          module_objects: %{String.t() => %{String.t() => line()}},
          modules: MapSet.t(),
          sensors: MapSet.t(),
          best: %{object: String.t(), value: number()} | nil
        }

  defstruct steps: 0,
            lines: %{},
            objects: %{},
            module_objects: %{},
            modules: MapSet.new(),
            sensors: MapSet.new(),
            best: nil

  @doc "An empty digest: a run that has not stepped yet."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  The digest of a whole record.

  Positions, not step numbers, address a moment: every episode counts its steps
  from zero again, so the run's ninth episode's step 4 is the run's
  nine-hundredth-and-something moment. The log and the timeline are appended one
  entry each per step, but either may be the longer one — a record written before
  a step kept its pictures has a log longer than its timeline, and one whose log
  lost an entry has a timeline longer than its log — so both are read, and a
  position missing from one is a step with no report or with nothing seen.
  """
  @spec from(Run.t()) :: t()
  def from(%Run{log: log, timeline: timeline}) do
    new()
    |> append(numbered(log), numbered(timeline))
  end

  # `Enum.with_index/1` pairs an element with its index; a position is the
  # index, so it goes first.
  defp numbered(list), do: list |> Enum.with_index() |> Enum.map(fn {item, at} -> {at, item} end)

  @doc """
  Appends the steps that arrived.

  `entries` are `{position, entry}` pairs read from the run's log and `moments`
  are `{position, moment}` pairs read from its timeline, both for positions the
  digest does not have yet. A position may appear in one and not the other.
  """
  @spec append(t(), [{non_neg_integer(), map()}], [{non_neg_integer(), map()}]) :: t()
  def append(%__MODULE__{} = digest, entries, moments) do
    entries
    |> pair(moments)
    |> Enum.reduce(digest, fn {position, entry, moment}, digest ->
      add(digest, position, entry, moment)
    end)
  end

  @doc "How many steps the digest has seen: the run's length, in positions."
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{steps: steps}), do: steps

  @doc "The sensor ids the run's steps reported, in the order a page offers them."
  @spec sensor_ids(t()) :: [String.t()]
  def sensor_ids(%__MODULE__{sensors: sensors}), do: sensors |> MapSet.to_list() |> Enum.sort()

  @doc "The learning modules the run reported beliefs for, oldest name first."
  @spec modules(t()) :: [String.t()]
  def modules(%__MODULE__{modules: modules}), do: modules |> MapSet.to_list() |> Enum.sort()

  @doc """
  The object the run believed in most, and how much, over the whole run.

  The one number a person wants above the pictures: what it settled on, and how
  sure it was.
  """
  @spec best(t()) :: %{object: String.t(), value: number()} | nil
  def best(%__MODULE__{best: best}), do: best

  @doc """
  Every series a replay can chart, sensors first.

  The world is what a timestep is about, so its positions come first; then what
  the modules made of it, then what making it cost.
  """
  @spec series(t()) :: [map()]
  def series(%__MODULE__{} = digest) do
    (Enum.map(sensor_ids(digest), &("sensor:" <> &1)) ++ @logged_series)
    |> Enum.map(&series_of(digest, &1))
  end

  @doc "One series by id, whether or not the run reported that line."
  @spec series_of(t(), String.t()) :: map()
  def series_of(%__MODULE__{} = digest, id) do
    %{
      id: id,
      label: label_of(id),
      title: label_of(id),
      unit: unit_of(id),
      axis: axis_of(id),
      points: points(line(digest, id))
    }
  end

  @doc """
  Every object a learning module held a graph for, one series each.

  With a module's id, the same lines from that module's beliefs alone.
  """
  @spec objects(t(), String.t() | nil) :: [map()]
  def objects(%__MODULE__{} = digest, module_id \\ nil) do
    digest
    |> object_lines(module_id)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {name, line} ->
      %{
        id: "object:" <> name,
        label: name,
        title: name,
        unit: "",
        axis: @evidence_axis,
        points: points(line)
      }
    end)
  end

  # -- the steps that arrive -------------------------------------------------

  # The log's entries and the timeline's moments, paired by position and in
  # order: one walk over both, so appending a thousand steps is a thousand
  # steps' work rather than a walk of the run so far.
  defp pair(entries, moments) do
    by_position =
      Enum.reduce(entries, %{}, fn {position, entry}, acc ->
        Map.update(acc, position, {entry, nil}, fn {_entry, moment} -> {entry, moment} end)
      end)

    by_position =
      Enum.reduce(moments, by_position, fn {position, moment}, acc ->
        Map.update(acc, position, {nil, moment}, fn {entry, _moment} -> {entry, moment} end)
      end)

    by_position
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {position, {entry, moment}} -> {position, entry, moment || %{}} end)
  end

  # A position the digest has not reached yet; one it has is not a step (a page
  # that reads the same step twice must not count it twice, nor draw it twice).
  defp add(%__MODULE__{steps: steps} = digest, position, _entry, _moment) when position < steps,
    do: digest

  defp add(digest, position, entry, moment) do
    episode = episode_of(entry)
    sensors = Map.get(moment, "sensors", %{})

    digest
    |> Map.put(:steps, position + 1)
    |> remember_sensors(Map.keys(sensors))
    |> add_step_lines(position, episode, entry, sensors)
    |> add_object_lines(position, episode, entry)
    |> remember_best(entry)
  end

  defp remember_sensors(digest, ids) do
    %{digest | sensors: Enum.reduce(ids, digest.sensors, &MapSet.put(&2, &1))}
  end

  # The five numbers every step reports, and where each sensor was.
  #
  # A sensor line reports a place at every step, whether or not that sensor saw
  # anything at it: a line that began where a sensor happened to report would
  # leave a hole in the chart where the sensor was in front of nothing.
  defp add_step_lines(digest, position, episode, entry, sensors) do
    {object, evidence} = winner_of(entry)

    lines = [
      {"evidence", place(position, episode, evidence, object)},
      {"percepts", counted(position, episode, length(Map.get(entry || %{}, "percepts") || []))},
      {"votes_used", counted(position, episode, get_in(entry || %{}, ["votes", "used"]) || 0)},
      {"duration_us", counted(position, episode, Map.get(entry || %{}, "duration_us", 0))},
      {"world_us", counted(position, episode, Map.get(entry || %{}, "world_us", 0))}
    ]

    digest = Enum.reduce(lines, digest, fn {id, point}, digest -> push(digest, id, point) end)

    Enum.reduce(digest.sensors, digest, fn sensor_id, digest ->
      seen_at = sensors |> Map.get(sensor_id) |> spot()
      push(digest, "sensor:" <> sensor_id, counted(position, episode, seen_at))
    end)
  end

  defp add_object_lines(digest, position, episode, entry) do
    digest =
      entry
      |> evidence_by_object()
      |> Enum.reduce(digest, fn {name, value}, digest ->
        push_object(digest, name, counted(position, episode, value))
      end)

    Enum.reduce(beliefs_of(entry), digest, fn {module_id, belief}, digest ->
      digest = %{digest | modules: MapSet.put(digest.modules, module_id)}

      belief
      |> evidence_of_belief()
      |> Enum.reduce(digest, fn {name, value}, digest ->
        push_module_object(digest, module_id, name, counted(position, episode, value))
      end)
    end)
  end

  defp remember_best(digest, entry) do
    best =
      entry
      |> evidence_by_object()
      |> Enum.reduce(digest.best, fn {name, value}, best ->
        if best == nil or value > best.value, do: %{object: name, value: value}, else: best
      end)

    %{digest | best: best}
  end

  # -- what a step is worth --------------------------------------------------

  defp place(position, episode, value, object),
    do: %{step: position, value: value, episode: episode, object: object}

  defp counted(position, episode, value),
    do: %{step: position, value: value, episode: episode}

  defp episode_of(%{"episode" => episode}) when is_integer(episode), do: episode
  defp episode_of(_entry), do: nil

  # What each object a step held a graph for was worth there: the strongest
  # evidence any module held for it. An object a module named without a number is
  # worth nought rather than missing — the line has a point there with nothing
  # behind it, which is what a ruled-out theory looks like.
  defp evidence_by_object(entry) do
    entry
    |> beliefs()
    |> Enum.map(&evidence_of_belief/1)
    |> Enum.reduce(%{}, fn strengths, kept -> Map.merge(strengths, kept, &strongest/3) end)
  end

  defp evidence_of_belief(belief) do
    belief
    |> Map.get("graphs", %{})
    |> Enum.reduce(%{}, &stronger/2)
    |> Map.new(fn {name, strength} -> {name, strength || 0.0} end)
  end

  # Two modules' numbers for the same object: the stronger one wins, which is
  # what the ensemble acted on.
  defp strongest(_name, one, other), do: max(one, other)

  defp stronger({name, graph}, strengths) do
    case Map.get(graph, "max_evidence") do
      value when is_number(value) ->
        Map.update(strengths, name, value, fn
          nil -> value
          kept -> max(kept, value)
        end)

      _none ->
        Map.put_new(strengths, name, nil)
    end
  end

  defp beliefs(entry), do: entry |> beliefs_of() |> Map.values()

  defp beliefs_of(entry) when is_map(entry), do: Map.get(entry, "beliefs", %{})
  defp beliefs_of(_entry), do: %{}

  # The object the strongest evidence at that step belonged to, and how strong.
  # Who that is changes with the episode, which is why the line is drawn in
  # stretches: one colour per object, named in the legend and in the hover.
  defp winner_of(nil), do: {nil, 0.0}

  defp winner_of(entry) do
    entry
    |> Map.get("beliefs", %{})
    |> Enum.flat_map(fn {_module, belief} ->
      for {object, graph} <- Map.get(belief, "graphs", %{}) do
        {object, Map.get(graph, "max_evidence") || 0.0}
      end
    end)
    |> Enum.max_by(&elem(&1, 1), fn -> {nil, 0.0} end)
  end

  # Where a sensor was on that step: the `location` the transforms filled in, or
  # the camera pose the world sent back, whose last column is the sensor's place
  # in the world. A world behind the port answers no `location`, so without the
  # second the chart draws a flat line at zero for a sensor that did move.
  defp spot(nil), do: 0.0

  defp spot(observation) do
    [observation["location"], translation(observation["cam_to_world"])]
    |> Enum.find(&is_list/1)
    |> first()
  end

  defp translation([row | _rest] = matrix) when is_list(row), do: Enum.map(matrix, &List.last/1)
  defp translation(_absent), do: nil

  defp first([x | _rest]) when is_number(x), do: x
  defp first(_not_a_location), do: 0.0

  # -- the bounded lines ----------------------------------------------------

  defp line(digest, id), do: Map.get(digest.lines, id, empty_line())

  defp object_lines(digest, nil), do: Enum.to_list(digest.objects)

  defp object_lines(digest, module_id),
    do: digest.module_objects |> Map.get(module_id, %{}) |> Enum.to_list()

  defp empty_line, do: %{stride: 1, buckets: [], size: 0, open: [], points: nil}

  defp push(digest, id, point) do
    %{digest | lines: Map.update(digest.lines, id, grow(empty_line(), point), &grow(&1, point))}
  end

  defp push_object(digest, name, point) do
    %{
      digest
      | objects: Map.update(digest.objects, name, grow(empty_line(), point), &grow(&1, point))
    }
  end

  defp push_module_object(digest, module_id, name, point) do
    lines =
      Map.update(
        digest.module_objects,
        module_id,
        %{name => grow(empty_line(), point)},
        fn lines ->
          Map.update(lines, name, grow(empty_line(), point), &grow(&1, point))
        end
      )

    %{digest | module_objects: lines}
  end

  # A point joins the group being filled. When that group is as wide as the
  # stride it closes into its three points and a new group opens; past `@buckets`
  # groups the neighbours merge, which roughly halves the resolution and doubles
  # the stride, so a line's size never grows past three points a group.
  defp grow(line, point) do
    line = %{line | open: [point | line.open], points: nil}

    if length(line.open) >= line.stride, do: close(line), else: line
  end

  defp close(%{open: open} = line) do
    line = %{line | buckets: [bucket_of(open) | line.buckets], size: line.size + 1, open: []}

    if line.size > @buckets, do: halve(line), else: line
  end

  defp bucket_of([newest | _rest] = points) do
    %{
      low: Enum.min_by(points, & &1.value),
      high: Enum.max_by(points, & &1.value),
      last: newest
    }
  end

  # Newest first, so the first pair merged is the newest. Which end is merged
  # first does not change the answer: what matters is that a merge is always
  # between neighbours, never between points of different parts of the run.
  defp halve(%{buckets: buckets} = line) do
    merged = merge_pairs(buckets)
    %{line | buckets: merged, size: length(merged), stride: line.stride * 2}
  end

  defp merge_pairs([]), do: []
  defp merge_pairs([only]), do: [only]
  defp merge_pairs([newest, older | rest]), do: [merge(newest, older) | merge_pairs(rest)]

  defp merge(newer, older) do
    %{
      low: Enum.min_by([newer.low, older.low], & &1.value),
      high: Enum.max_by([newer.high, older.high], & &1.value),
      last: newer.last
    }
  end

  defp points(%{points: points}) when is_list(points), do: points

  defp points(line) do
    # The closed groups are newest first, and the open one's points are too;
    # sorting by the step they sit at puts the line in the order a chart draws
    # it, and is cheap because there are at most `3 * @buckets + stride`.
    (Enum.flat_map(line.buckets, &bucket_points/1) ++ Enum.reverse(line.open))
    |> Enum.sort_by(& &1.step)
  end

  defp bucket_points(bucket) do
    [bucket.low, bucket.high, bucket.last]
    |> Enum.uniq()
    |> Enum.sort_by(& &1.step)
  end

  # -- the names of the lines ------------------------------------------------

  defp label_of("sensor:" <> sensor_id), do: "#{sensor_id} x"
  defp label_of("percepts"), do: "percepts per step"
  defp label_of("votes_used"), do: "votes used"
  defp label_of("duration_us"), do: "step duration"
  defp label_of("world_us"), do: "world time per step"
  defp label_of("evidence"), do: "best evidence"
  defp label_of(other), do: other

  defp unit_of("sensor:" <> _sensor_id), do: "m"
  defp unit_of("duration_us"), do: "µs"
  defp unit_of("world_us"), do: "µs"
  defp unit_of(_counted), do: ""

  # What the numbers on the value axis are. Evidence is the score a hypothesis is
  # ranked by and the one axis a Monty page is read against, so it says
  # "evidence" rather than nothing; a count says what it counts.
  defp axis_of("sensor:" <> _sensor_id), do: "metres"
  defp axis_of("duration_us"), do: "microseconds"
  defp axis_of("world_us"), do: "microseconds"
  defp axis_of("percepts"), do: "percepts"
  defp axis_of("votes_used"), do: "votes"
  defp axis_of(_evidence), do: @evidence_axis
end
