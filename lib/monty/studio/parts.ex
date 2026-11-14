defmodule Monty.Studio.Parts do
  @moduledoc """
  The parts of one run, as the cards a page draws.

  A run asked for several parts (`Monty.Studio.Partition`) is one record and one
  job, with the parts running inside it — and each part keeps a stream of its own,
  which is its steps, its log and its frames. This turns those streams into the
  sections Monty's dashboard draws: one publisher after another, each with its own
  evidence and the last pictures its cameras took.

  A card is built from what the part has already reported, never from the
  experiment: how many steps it has taken, the evidence it reported and its
  frames. While the run is going those come from `RunStream`, which holds every
  part's steps in memory; once the run has settled the streams are gone, and the
  same points are read back from the run's own transcript, where every step says
  which part took it.

  One point a step, from the module that believed most: a part's card is one
  picture of one stretch of the experiment, where the run page offers a chart per
  module of a whole run.
  """

  alias ExTbpMonty.Cluster.Nodes

  alias Monty.Studio.{
    Belief,
    Chart,
    Replay,
    RunHistory,
    RunStream,
    Setup
  }

  # How long a page waits for the node that holds a part before drawing what the
  # record has: half a second shorter than the page's own poll, so a silent peer
  # cannot make a poll take a second.
  @remote_timeout 500

  @typedoc "One point of evidence: the run's own episode, the step, and what was believed."
  @type point :: {non_neg_integer(), non_neg_integer(), map()}

  @typedoc """
  What a page keeps of one part between two polls.

  `taken` is how many of the part's live steps have been read. `read` says whether
  the settled run's transcript has been read for this part: it is written once and
  does not change, so it is read once.
  """
  @type held :: %{
          id: binary(),
          part: map(),
          record: RunHistory.Run.t(),
          taken: non_neg_integer(),
          read: boolean(),
          steps: non_neg_integer(),
          points: [point()],
          frames: [map()]
        }

  @typedoc "One part, as a page draws it."
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
  The run's parts, up to date with the steps taken since `previous`.

  `nil`, or a run of one part, is a run the page already draws in full: there is
  nothing to say twice, so it has no cards. A run's plan lives in its record's
  inputs, written when the run started (`Monty.Studio.RunLog.attributes/6`), so a
  page draws every part's card before the first of them has taken a step.

  A part another node is stepping has its steps in *that* node's memory, and this
  one's stream says nothing about it — so the part is asked of the node that holds
  it (`:read`), once per poll, from the step this page stopped at. Without that, a
  page opened while a peer worked read a part's transcript only when the part
  ended and its file was written. `:read` is a function so a test can answer for a
  peer; the default asks the cluster.
  """
  @spec refresh(RunHistory.Run.t() | map() | nil, %{optional(binary()) => held()}, keyword()) ::
          %{
            optional(binary()) => held()
          }
  def refresh(record, previous, options \\ [])

  def refresh(nil, _previous, _options), do: %{}

  def refresh(record, previous, options) do
    case parts_of(record) do
      [_one] ->
        %{}

      [] ->
        %{}

      parts ->
        read = Keyword.get(options, :read, &read_on/3)
        held_by_peers = held_by_peers(record)

        Map.new(parts, fn part ->
          held = Map.get(previous, part["stream"])
          holder = Map.get(held_by_peers, part["index"])

          {part["stream"], held_up_to_date(held, record, part, holder, read)}
        end)
    end
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
    sorted = held |> Map.values() |> Enum.sort_by(&part_number/1)
    # A run that trains and then evaluates has two waves, and both number their
    # parts from one: "part 1 of 2" twice would be two different parts under one
    # name.
    named? = sorted |> Enum.map(& &1.part["phase"]) |> Enum.uniq() |> length() > 1

    {cards, _labels} =
      Enum.map_reduce(sorted, %{}, fn part, labels ->
        card = card(part, setup, labels, named?)
        {card, card.chart.labels}
      end)

    cards
  end

  @doc """
  The parts a run's record was divided into, in the order they were numbered.

  `[]` for a run of the whole experiment: its record's inputs carry no plan, and
  the page draws it from its own transcript.
  """
  @spec parts_of(RunHistory.Run.t() | map()) :: [map()]
  def parts_of(%{inputs: %{"parts" => [_ | _] = parts}}),
    do: Enum.sort_by(parts, &{&1["phase"] || "", &1["index"] || 0})

  def parts_of(_run_of_the_whole_experiment), do: []

  # A part a peer is stepping, by the number the division gave it: the record's
  # plan says which parts there are and where their steps are written, and the
  # row says which node has one — the only place a node is written down at all.
  defp held_by_peers(record) do
    me = ExTbpMonty.Node.safe_name(node())

    record.id
    |> RunHistory.claimed_parts()
    |> Enum.reject(&(&1.node in [nil, me]))
    |> Map.new(&{&1.part, &1.node})
  end

  defp held_up_to_date(nil, record, part, holder, read) do
    held_up_to_date(
      %{
        id: part["stream"],
        part: part,
        record: record,
        taken: 0,
        read: false,
        steps: 0,
        points: [],
        frames: []
      },
      record,
      part,
      holder,
      read
    )
  end

  defp held_up_to_date(held, record, part, holder, read) do
    held = %{held | record: record, part: part}

    case RunStream.count(held.id) do
      0 -> without_a_stream_here(held, holder, read)
      steps -> from_stream(held, steps)
    end
  end

  # Nothing in this node's memory for the part: it is a peer's, or its transcript
  # is all there is. A peer answers its steps — and only its steps, because a
  # late page shows the transcript it missed and a part's pictures come with the
  # part's file when it ends. Positions are dense from nought in a part's own
  # stream, so the count is where the read started plus what came back.
  defp without_a_stream_here(held, nil, _read), do: from_record(held)

  defp without_a_stream_here(held, holder, read) do
    case read.(holder, held.id, held.taken - 1) do
      [_ | _] = entries -> from_peer(held, entries)
      _nothing_from_that_node -> from_record(held)
    end
  end

  defp from_peer(held, entries) do
    taken = held.taken + length(entries)

    %{held | taken: taken, steps: taken, points: Enum.reverse(points_of(entries), held.points)}
  end

  # The default: ask the node that holds the part, if this cluster has it alive.
  # A node that is gone or silent is not a page's problem — the record answers,
  # which is what a page showed before any of this existed.
  defp read_on(holder, stream, from) do
    case node_holding(holder) do
      nil -> []
      node -> entries_on(node, stream, from)
    end
  end

  defp node_holding(holder) do
    Enum.find_value(Nodes.snapshot(), fn entry ->
      entry.alive and entry.name == holder and entry.node
    end)
  end

  defp entries_on(node, stream, from) do
    case :rpc.call(node, RunStream, :entries_from, [stream, from], @remote_timeout) do
      entries when is_list(entries) -> entries
      _no_answer -> []
    end
  end

  # The live steps, and only the ones this page has not seen: a page that read the
  # whole stream on every poll would copy every part's transcript twice a second.
  defp from_stream(held, steps) when steps > held.taken do
    {entries, moments} = RunStream.steps_from(held.id, held.taken - 1)

    %{
      held
      | taken: steps,
        steps: steps,
        points: Enum.reverse(points_of(entries), held.points),
        frames: pictures_of(moments) || held.frames
    }
  end

  defp from_stream(held, _nothing_new), do: held

  # A part whose stream is gone: the run has settled, and its transcript — the
  # parts' steps one after another — holds every one of them, each saying which
  # part took it. It is written once and does not change, so it is read once.
  defp from_record(%{read: true} = held), do: held

  defp from_record(held) do
    case RunHistory.head(held.record.id) do
      nil ->
        held

      record ->
        mine =
          (record.log || [])
          |> Enum.with_index()
          |> Enum.filter(fn {entry, _position} -> entry["part"] == held.part["index"] end)

        %{
          held
          | read: true,
            steps: length(mine),
            points: Enum.reverse(points_of(Enum.map(mine, &elem(&1, 0))), held.points),
            frames: last_pictures(record.id, List.last(mine)) || held.frames
        }
    end
  end

  defp last_pictures(_id, nil), do: nil

  defp last_pictures(id, {_entry, position}) do
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

  defp card(held, setup, labels, named?) do
    episodes = episodes_of(held.part)
    points = Enum.reverse(held.points)

    %{
      id: held.id,
      label: label(held.part, named?),
      phase: phase_of(held.part),
      status: status_of(held),
      span: span(episodes),
      object: object_of(episodes, setup),
      steps: held.steps,
      episodes_done: episodes_done(points),
      best: best(points),
      chart: Chart.new(points, labels: labels, episode_objects: episode_objects(episodes, setup)),
      frames: held.frames
    }
  end

  defp part_number(%{part: part}), do: {part["phase"] || "", part["index"] || 0}

  defp label(part, named?) do
    name = "part #{Map.get(part, "index", 0) + 1} of #{Map.get(part, "of", 1)}"
    if named?, do: "#{Map.get(part, "phase", "eval")} #{name}", else: name
  end

  defp phase_of(%{"phase" => "train"}), do: :train
  defp phase_of(_eval), do: :eval

  # A part that has not stepped yet is a part the run has not reached: said as
  # "queued" rather than "running", because a page that calls waiting running is
  # a page whose clock cannot be trusted.
  defp status_of(%{record: %{status: "running"}, steps: 0}), do: "queued"
  defp status_of(%{record: %{status: "running"}}), do: "running"
  defp status_of(%{record: %{status: status}}), do: status

  defp episodes_of(%{"phases" => phases}) when is_map(phases) do
    phases |> Map.values() |> List.flatten()
  end

  defp episodes_of(_nothing), do: []

  defp episodes_done(points) do
    points |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length()
  end

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

  # A part's steps carry the experiment's own episode number — a part numbers its
  # episodes as the experiment does, not from nought again — and the object each
  # one showed is the experiment's answer for that episode, which is what the
  # bands are drawn from.
  defp episode_objects(episodes, setup) do
    Map.new(episodes, fn episode -> {episode, Setup.object_name(setup, episode)} end)
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
