defmodule Monty.Studio.Parts do
  @moduledoc """
  The parts of one press of Run, as the cards a page draws.

  A parallel run is several runs (`Monty.Studio.Partition`) and a page watching
  one of them used to show one chart: the other parts ran, and nobody saw them
  until the Runs page. This is the other half of Monty's dashboard — the pyview
  contrib draws a section per publisher, with that publisher's evidence and its
  sensor images, one after the other — and it is what the studio's pages draw.

  A card is built from what the part has already reported, never from the
  experiment: the counter of how far a part got, its status, its evidence chart
  and the last pictures its cameras took. While a part runs those come from
  `RunStream`, which holds the steps of every run in memory; once it has settled
  they come from its own record, read once — the page polls this, and a poll that
  re-read four transcripts twice a second would cost more than the run.

  One point a step, from the module that believed most: a part's card is one
  picture of one stretch of the experiment, where the run page offers a chart per
  module of a whole run.
  """

  alias Monty.Studio.{
    Belief,
    Chart,
    Replay,
    RunHistory,
    RunStream,
    Setup
  }

  @typedoc "One point of evidence: the run's own episode, the step, and what was believed."
  @type point :: {non_neg_integer(), non_neg_integer(), map()}

  @typedoc """
  What a page keeps of one part between two polls.

  `read` is how many steps the record had when it was last read: a settled part's
  transcript does not change, so it is read once and kept.
  """
  @type held :: %{
          id: binary(),
          record: RunHistory.Run.t(),
          taken: non_neg_integer(),
          read: non_neg_integer() | nil,
          points: [point()],
          frames: [map()]
        }

  @typedoc "The cards of a batch, as the page draws them."
  @type card :: %{
          id: binary(),
          label: String.t(),
          phase: :train | :eval,
          status: String.t(),
          span: String.t(),
          object: String.t() | nil,
          steps: non_neg_integer(),
          episodes_done: non_neg_integer(),
          best: %{optional(String.t()) => number() | nil} | nil,
          chart: Chart.t(),
          frames: [map()]
        }

  @doc """
  The batch's parts, up to date with the steps taken since `previous`.

  `nil` is a page watching a run of the whole experiment: there is one part and it
  is the run the page already draws, so it has no cards.
  """
  @spec refresh(binary() | nil, %{optional(binary()) => held()}) :: %{
          optional(binary()) => held()
        }
  def refresh(nil, _previous), do: %{}

  def refresh(batch, previous) do
    batch
    |> RunHistory.parts_progress()
    |> Map.new(fn record ->
      {record.id, record |> then(&held_up_to_date(Map.get(previous, &1.id), &1))}
    end)
  end

  @doc """
  One card per part, in the order the plan numbered them, with the colours of the
  objects kept across the cards.

  The labels travel from card to card (`Chart.new/2` answers the ones it made), so
  an object wears the same colour in every part's chart — four parts of one
  experiment read as one experiment.
  """
  @spec cards(%{optional(binary()) => held()}, Setup.t()) :: [card()]
  def cards(held, setup) do
    {cards, _labels} =
      held
      |> Map.values()
      |> Enum.sort_by(&part_index/1)
      |> Enum.map_reduce(%{}, fn part, labels ->
        card = card(part, setup, labels)
        {card, card.chart.labels}
      end)

    cards
  end

  defp held_up_to_date(nil, record) do
    held_up_to_date(
      %{id: record.id, record: record, taken: 0, read: nil, points: [], frames: []},
      record
    )
  end

  defp held_up_to_date(held, record) do
    held = %{held | record: record}

    case RunStream.count(record.id) do
      0 -> from_record(held)
      steps -> from_stream(held, steps)
    end
  end

  # The live steps, and only the ones this page has not seen: a page that read the
  # whole stream on every poll would copy a run's transcript twice a second.
  defp from_stream(held, steps) when steps > held.taken do
    {entries, moments} = RunStream.steps_from(held.id, held.taken - 1)

    %{
      held
      | taken: steps,
        points: Enum.reverse(points_of(entries), held.points),
        frames: pictures_of(moments) || held.frames
    }
  end

  defp from_stream(held, _nothing_new), do: held

  # A part that has settled: its transcript is written and does not change, so it
  # is read once, when the record says there is more of it than was read.
  defp from_record(held) do
    written = held.record.steps_done || 0

    cond do
      written == 0 -> held
      held.read == written -> held
      true -> read(held, written)
    end
  end

  defp read(held, written) do
    case RunHistory.head(held.id) do
      nil ->
        held

      record ->
        %{
          held
          | read: written,
            points: Enum.reverse(points_of(record.log), held.points),
            frames: last_pictures(held.id, written) || held.frames
        }
    end
  end

  defp last_pictures(id, written) do
    position = max(written - 1, 0)

    case RunHistory.sensors_at(id, position) do
      nil -> nil
      sensors -> Replay.pictures(position, sensors) |> presence()
    end
  end

  defp pictures_of(moments) do
    moments
    |> List.last()
    |> case do
      nil ->
        nil

      moment ->
        moment
        |> Map.get("sensors", %{})
        |> then(&Replay.pictures(moment["step"], &1))
        |> presence()
    end
  end

  defp presence([]), do: nil
  defp presence(frames), do: frames

  # A step that reported no beliefs is a step that changed none of them: the run's
  # own page draws the same rule, and a point of nothing would be a hole in the
  # line.
  defp points_of(entries) do
    for %{"episode" => episode, "step" => step, "beliefs" => beliefs} <- entries,
        beliefs != %{},
        do: {episode, step, strongest(beliefs)}
  end

  # The module that believed most, as if it were the only one: a part's card is one
  # picture, and which module is strongest is the same question the run page's
  # first chart answers. The stored map is read back as a belief
  # (`Belief.from_stored/1`), because that is the shape a chart draws from.
  defp strongest(beliefs) do
    beliefs
    |> Enum.map(fn {module_id, stored} -> {module_id, Belief.from_stored(stored)} end)
    |> Enum.max_by(fn {_module, belief} -> best_evidence(belief) end, fn -> nil end)
    |> case do
      nil -> nil
      {_module, belief} -> belief
    end
  end

  defp best_evidence(%{graphs: graphs}) do
    graphs
    |> Map.values()
    |> Enum.map(&(Map.get(&1, :max_evidence) || 0))
    |> Enum.max(fn -> 0 end)
  end

  defp card(held, setup, labels) do
    plan = plan_of(held.record)
    episodes = episodes_of(plan)
    points = Enum.reverse(held.points)

    %{
      id: held.id,
      label: label(plan),
      phase: phase_of(plan),
      status: held.record.status,
      span: span(episodes),
      object: object_of(episodes, setup),
      steps: held.record.steps_done || 0,
      episodes_done: held.record.episodes_done || 0,
      best: best(points),
      chart: Chart.new(points, labels: labels, episode_objects: episode_objects(episodes, setup)),
      frames: held.frames
    }
  end

  defp plan_of(%{inputs: %{"part" => %{} = part}}), do: part
  defp plan_of(_run_of_the_whole_experiment), do: %{"index" => 0, "of" => 1, "phases" => %{}}

  defp part_index(%{record: record}), do: get_in(record.inputs, ["part", "index"]) || 0

  defp label(%{"index" => index, "of" => of}), do: "part #{index + 1} of #{of}"
  defp label(_nothing), do: "part 1 of 1"

  defp phase_of(%{"phases" => phases}) do
    if Map.has_key?(phases, "train"), do: :train, else: :eval
  end

  defp phase_of(_nothing), do: :eval

  defp episodes_of(%{"phases" => phases}) when is_map(phases) do
    phases |> Map.values() |> List.flatten()
  end

  defp episodes_of(_nothing), do: []

  # "episodes 0–34" for a stretch, and just the count for a training part's
  # rotations, which are one object every tenth episode rather than a range.
  defp span([]), do: "no episodes"

  defp span([only]), do: "episode #{only}"

  defp span(episodes) do
    if contiguous?(episodes) do
      "episodes #{hd(episodes)}–#{List.last(episodes)}"
    else
      "#{length(episodes)} episodes, one object each"
    end
  end

  defp contiguous?([_one]), do: true

  defp contiguous?([first, second | rest]),
    do: second == first + 1 and contiguous?([second | rest])

  # The object a part is about, when it is about one: a training part trains one
  # object in every rotation, an evaluation part usually several.
  defp object_of([], _setup), do: nil

  defp object_of(episodes, setup) do
    episodes
    |> Enum.map(&Setup.object_name(setup, &1))
    |> Enum.uniq()
    |> case do
      [only] -> only
      _several -> nil
    end
  end

  # The run's own episode numbers are the ones its steps carry — they count from
  # nought inside the run — and the object each one showed is the experiment's
  # answer for the episode it took, which is what the bands are drawn from.
  defp episode_objects(episodes, setup) do
    episodes
    |> Enum.with_index()
    |> Map.new(fn {experiment_episode, local} ->
      {local, Setup.object_name(setup, experiment_episode)}
    end)
  end

  defp best([]), do: nil

  defp best(points) do
    points
    |> List.last()
    |> elem(2)
    |> then(fn belief ->
      belief
      |> Map.get(:graphs, %{})
      |> Enum.max_by(fn {_graph, graph} -> Map.get(graph, :max_evidence) || 0 end, fn -> nil end)
    end)
    |> case do
      nil -> nil
      {graph_id, graph} -> %{object: graph_id, evidence: Map.get(graph, :max_evidence)}
    end
  end
end
