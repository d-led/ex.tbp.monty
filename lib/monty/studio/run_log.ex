defmodule Monty.Studio.RunLog do
  @moduledoc """
  What a run reports, in the shape a log, a page and the database all agree on.

  A timestep's report from the coordinator is rich and Elixir-shaped; a log line
  is text and the database wants JSON-safe maps. Both are derived here, so a
  headless `mix monty.run` and the studio page print the same line for the same
  step instead of two similar ones that drift, and the history row means the
  same thing whichever way the run was started.
  """

  alias Monty.Simulators.Synthetic.Camera
  alias Monty.Studio.{Duration, RunHistory, Setup, Summary}

  @doc """
  One timestep, as the database stores it.

  With `beliefs` — what each learning module held after the step — the entry also
  records the module's own numbers, which is what a run's page draws: the objects
  it had not ruled out, the hypothesis it believed most, and per object how many
  hypotheses were alive and how strong the best one was.

  The episode travels with the step. A run is every object of the experiment in
  every rotation, and the step counter restarts inside each episode, so
  `"step" => 0` alone says *when inside an episode* and not *when in the run* —
  which is exactly what a chart needs to keep the episodes apart.

  It is the run's own episode number, not the epoch's: every epoch counts its
  episodes from zero again, so a run of three training epochs and three
  evaluation ones has six episodes and only three epoch-indices. Keeping the
  index here would file the first evaluation episode with the first training one
  and a chart would draw them as a single episode — a line across the boundary
  where the evidence really did restart (`Jobs.Run.start_episode/5`).

  `:at` is the moment the step was taken. A step hands its report to the process
  that writes the record (`Monty.Studio.RunStream`), so the entry is built there
  and the moment has to travel with the report: read here instead, it would be
  when the record was written, which is indistinguishable on a quiet run and
  wrong on any other.
  """
  @spec entry(map(), map(), keyword()) :: map()
  def entry(info, beliefs \\ %{}, options \\ []) do
    %{
      "episode" => Keyword.get(options, :episode, 0),
      "step" => info.step,
      "at" => Keyword.get_lazy(options, :at, fn -> now().instant end),
      "percepts" => Enum.map(info.percept_ids, &to_string/1),
      "inputs" => Map.new(info.inputs, fn {module, count} -> {to_string(module), count} end),
      "votes" => %{"sent" => info.votes.sent, "used" => info.votes.used},
      "goals" => info.goals,
      "actions" => length(info.actions),
      "duration_us" => info.duration_us,
      # The world steps the agent before the model sees anything, and that time
      # is not the model's: a step's own clock measures the modules only. Without
      # this the wall clock of a run cannot be split into the simulation it is
      # and the bookkeeping around it, which is how 772 s of one run came to be
      # blamed on the studio.
      "world_us" => Map.get(info, :world_us, 0)
    }
    |> put_beliefs(beliefs)
  end

  defp put_beliefs(entry, beliefs) when map_size(beliefs) == 0, do: entry

  # A belief goes in as the database will hand it back: string keys, all the way
  # down. It is Monty's record either way, but the JSON column rewrites keys
  # whether we do or not, and a run read from the history then has a different
  # shape from a run being watched. One shape, the stored one, so there is one
  # line — which is what `line/1` prints and a page replays.
  defp put_beliefs(entry, beliefs) do
    Map.put(
      entry,
      "beliefs",
      Map.new(beliefs, fn {id, belief} -> {to_string(id), stored(belief)} end)
    )
  end

  defp stored(%_{} = struct), do: struct |> Map.from_struct() |> stored()

  defp stored(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stored(value)} end)

  defp stored(list) when is_list(list), do: Enum.map(list, &stored/1)
  defp stored(value), do: value

  @doc """
  One timestep's scene, as the database stores it.

  The log says what the modules made of a step; this says where the sensors were
  and what they reported. A sensor's observation is kept in Monty's own shape
  (`"location"` in metres), so a replay redraws the frame a run actually saw
  rather than a re-simulation of it: what is on the slider is history, not a
  guess.

  The camera's arrays are left out. They are one entry per pixel — on an
  experiment's own 64×64 camera, a megabyte per step across two sensors — and
  nothing reads them back: a replay draws a frame from where a sensor was. A
  step that stored them would make the history table the largest thing in the
  database to draw the same dot.
  """
  @spec moment(map() | non_neg_integer(), map()) :: map()
  def moment(%{step: step}, observations) when is_integer(step),
    do: moment(step, observations, %{})

  def moment(step, observations) when is_integer(step),
    do: moment(step, observations, %{})

  @doc """
  The same scene, from pictures somebody has already drawn.

  `RunStream` encodes a sensor's pictures once per step — the page's frame and the
  record's scene are the same two PNGs — so it hands them here instead of having
  them drawn twice.
  """
  @spec moment(non_neg_integer(), map(), %{optional(String.t()) => map()}) :: map()
  def moment(step, observations, images) when is_integer(step),
    do: moment(step, observations, images, nil)

  @typedoc """
  Where a picture goes, and the name it is asked for by afterwards.

  `nil` keeps the picture in the record as the PNG it already is. A run passes
  `&Artifacts.put_frame/5`, which writes the bytes under the run's own directory
  and answers `frames/<step>/<sensor>-<kind>.png`.
  """
  @type store :: (String.t(), String.t(), String.t() -> {:ok, String.t()} | {:error, term()})

  @doc """
  The same scene, with each picture written where a run can serve it from.

  A step's two PNGs per sensor are ten kilobytes in the record, and a
  twenty-thousand-step run passes Postgres's ceiling on a jsonb value; the record
  keeps the name and the file keeps the bytes. `nil` is the record a test and a
  page without a run id want: the pictures stay inline.
  """
  @spec moment(non_neg_integer(), map(), %{optional(String.t()) => map()}, store() | nil) ::
          map()
  def moment(step, observations, images, store) when is_integer(step) do
    %{
      "step" => step,
      "sensors" =>
        observations
        |> Map.get(agent_id(), %{})
        |> Map.new(fn {sensor_id, observation} ->
          {sensor_id, drawn(sensor_id, observation, Map.get(images, sensor_id), store)}
        end)
    }
  end

  # The arrays a camera answers with, one entry per pixel.
  @camera_arrays ["depth", "rgba", "semantic", "semantic_3d", "sensor_frame_data"]

  @doc """
  A sensor's observation with its pictures drawn into it.

  The arrays a camera answers with are dropped on the way into a record — four
  thousand numbers a step, per sensor, is not something a history row should carry
  — and the two *pictures* they make are kept instead: a few kilobytes of PNG,
  which is what a page shows anyway. An observation that carries them is what
  `Camera.frame/3` draws without encoding anything, which is how a step that both
  records its pictures and shows them pays for one encoding rather than two.

  `images` is what `Camera.images/1` answered for the observation; `nil` draws
  them here.
  """
  @spec drawn(map(), map() | nil) :: map()
  def drawn(observation, images), do: drawn(nil, observation, images, nil)

  defp drawn(sensor_id, observation, images, store) do
    kept = Map.drop(observation, @camera_arrays)
    recorded = recorded(images || Camera.images(observation), sensor_id, store)

    if map_size(recorded) == 0,
      do: kept,
      else: Map.put(kept, "images", recorded)
  end

  # The shape a record keeps, and the shape `Camera.images/1` reads back: an
  # observation that carries `"images"` has already been drawn.
  defp recorded(images, sensor_id, store) do
    %{
      "depth" => picture(images.depth, "depth", sensor_id, store),
      "colour" => picture(images.colour, "colour", sensor_id, store),
      "range" => images.range && Tuple.to_list(images.range)
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp picture(nil, _kind, _sensor_id, _store), do: nil
  defp picture(base64, _kind, _sensor_id, nil), do: base64

  # A picture the filesystem would not take stays in the record rather than
  # disappearing: a run whose pictures cannot be written is still a run whose
  # replay shows what it saw, at the cost of a big row. Anything the store
  # answers that is not a name is the same answer as a refusal.
  defp picture(base64, kind, sensor_id, store) do
    case store.(sensor_id, kind, base64) do
      {:ok, name} -> name
      _refused -> base64
    end
  end

  @doc """
  One timestep, as a line of text.

  The line starts with the wall clock and ends with how long the step took: a
  log that only counts percepts says a run is alive without saying whether the
  last step took a millisecond or a minute, and "why is this slow" is the first
  question anyone asks a log.
  """
  @spec line(map()) :: String.t()
  def line(entry), do: clock(entry) <> text(entry)

  @doc """
  The line without its clock.

  A page shows the time in the reader's own zone, which a string cannot: it needs
  the instant, next to the words. The file on disk keeps `line/1`, which is the
  same words with the clock in front.
  """
  @spec text(map()) :: String.t()
  def text(entry) do
    inputs =
      entry
      |> Map.get("inputs", %{})
      |> Enum.map_join(" ", fn {module, count} -> "#{module}=#{count}" end)

    votes = Map.get(entry, "votes", %{})

    "step #{entry["step"]} · percepts #{Enum.join(Map.get(entry, "percepts", []), ",")} · " <>
      "inputs #{inputs} · votes #{votes["used"]}/#{votes["sent"]} · " <>
      "goals #{entry["goals"]} · #{Duration.humanize(Map.get(entry, "duration_us", 0))}" <>
      believed(entry)
  end

  alias Monty.Studio.LocalClock

  @doc """
  When the step happened: the instant it belongs to, and that instant as UTC.

  A line recorded before runs kept the time is history, not an error, so it
  answers `nil` and the page shows no clock rather than a wrong one.
  """
  @spec at(map()) :: %{instant: String.t(), clock: String.t()} | nil
  def at(entry) do
    with iso when is_binary(iso) <- Map.get(entry, "at"),
         {:ok, at, _offset} <- DateTime.from_iso8601(iso) do
      %{LocalClock.stamp(at) | instant: iso}
    else
      _missing -> nil
    end
  end

  @doc "Now, in the shape `at/1` answers, for a line this side of the log writes."
  @spec now() :: %{instant: String.t(), clock: String.t()}
  def now, do: LocalClock.now()

  defp clock(entry) do
    case at(entry) do
      nil -> ""
      %{clock: clock} -> clock <> " "
    end
  end

  # What each module believes, on the same line: a run that is watched through a
  # log is watched for this, and a line that only counts percepts says a run is
  # alive without saying whether it is getting anywhere.
  defp believed(entry) do
    case Map.get(entry, "beliefs") do
      nil ->
        ""

      beliefs ->
        " · " <>
          Enum.map_join(beliefs, " ", fn {id, belief} -> "#{id}: #{belief_line(belief)}" end)
    end
  end

  defp belief_line(belief) do
    case Map.get(belief, "mlh") do
      nil ->
        "nothing yet"

      mlh ->
        graphs = Map.get(belief, "graphs", %{})

        "#{mlh["graph_id"]} ev #{round_evidence(mlh["evidence"])}" <>
          " (#{hypotheses(graphs[mlh["graph_id"]])} hyps, " <>
          "#{length(Map.get(belief, "possible_matches", []))} possible)"
    end
  end

  defp hypotheses(nil), do: 0
  defp hypotheses(graph), do: graph["hypotheses"]

  defp round_evidence(evidence) when is_number(evidence), do: Float.round(evidence * 1.0, 3)
  defp round_evidence(_not_a_number), do: nil

  @doc """
  A finished run's summary, as the database stores it.

  `failure` is what stopped a run that did not finish — a sentence and the
  detail beside it, in the shape `Failure` writes. It joins the numbers, because
  the summary is the whole of what a page shows after the last step: a record
  that says "failed" in one column and nothing in the other is a page that says
  the run stopped without saying why.
  """
  @spec summary(Summary.t(), %{String.t() => String.t() | nil} | nil) :: map()
  def summary(%Summary{} = summary, failure \\ nil) do
    %{
      "steps" => summary.steps,
      "duration_us" => summary.duration_us,
      "deadline_hits" => summary.deadline_hits,
      "goals" => summary.goals,
      "votes_sent" => summary.votes_sent,
      "votes_used" => summary.votes_used,
      "actions" => summary.actions,
      "inputs" => summary.inputs,
      "never_updated" => summary.never_updated,
      "sensor_timeouts" => Enum.map(summary.sensor_timeouts, &to_string/1),
      # What the last step concluded, with the module ids as strings: this is
      # what makes "stopped after one step because the module said no_match"
      # readable in the record, rather than looking like a run that gave up.
      "outcome" =>
        Map.new(summary.outcome, fn {id, terminal} ->
          {to_string(id), terminal && to_string(terminal)}
        end),
      # And what every episode concluded, counted: the number a reader compares
      # with Monty's own benchmark, which counts the same episodes. Absent for a
      # run that predates the tally, which is why it is not spelled out empty.
      "outcomes" =>
        Map.new(summary.outcomes, fn {id, per_module} ->
          {to_string(id), Map.new(per_module, fn {state, count} -> {to_string(state), count} end)}
        end)
    }
    |> Map.merge(failure || %{})
  end

  @doc """
  The attributes for a run that is starting.

  The config snapshot is the composed tree, and the inputs are what the run was
  given: the group choices, the seed, the budget, and the modules it addresses.
  """
  @spec attributes(map(), pos_integer()) :: map()
  def attributes(opened, steps, episode \\ 0, parallel \\ 1, episodes \\ nil) do
    %{
      experiment: opened.name,
      episode: episode,
      source: to_string(opened.source),
      steps: steps,
      seed: opened.setup.seed,
      config: opened.config,
      inputs: %{
        "groups" => opened.groups,
        "seed" => opened.setup.seed,
        "world" => to_string(opened.setup.world),
        "train_epochs" => opened.setup.epochs.train,
        "eval_epochs" => opened.setup.epochs.eval,
        # What this run is: every episode of the experiment (objects × rotations),
        # unless the caller asked for fewer. The record keeps it so a page can say
        # how far a run got without knowing the config.
        "episodes" => episodes || Setup.episodes(opened.setup),
        "sensors" => Setup.sensor_ids(opened.setup),
        "learning_modules" => Enum.map(opened.setup.learning_modules, & &1.id),
        # How many runs were started together: one episode each, the same
        # experiment side by side. A property of the run's record, not of the
        # page that started it.
        "parallel" => parallel
      }
    }
  end

  @doc "Appends a step to the record in hand, leaving it unwritten until `RunHistory.checkpoint/1`."
  @spec append_step(RunHistory.Run.t(), map(), map(), map(), keyword()) :: RunHistory.Run.t()
  def append_step(history, info, observations, beliefs \\ %{}, options \\ []) do
    RunHistory.append_step(
      history,
      entry(info, beliefs, options),
      moment(info.step, observations, %{}, store(history, info))
    )
  end

  @doc "Records a step — what was reported, what was seen and what was believed — and returns the row."
  @spec record_step(RunHistory.Run.t(), map(), map(), map()) :: RunHistory.Run.t()
  def record_step(history, info, observations, beliefs \\ %{}, options \\ []) do
    case RunHistory.record_step(
           history,
           entry(info, beliefs, options),
           moment(info.step, observations, %{}, store(history, info))
         ) do
      {:ok, history} -> history
      {:error, _changeset} -> history
    end
  end

  # Where a step's pictures go: a file of the run's own, named by the step and
  # the sensor. Handing `moment/3` no store keeps them in the row, which is what
  # made a long run wider than a jsonb value can be — and is why the record a
  # page reads names a path instead of carrying ten kilobytes a step.
  defp store(history, info) do
    fn sensor_id, kind, base64 ->
      with {:ok, name} <-
             Monty.Studio.Artifacts.put_frame(history.id, info.step, sensor_id, kind, base64),
           do: {:ok, Monty.Studio.Artifacts.frame_url(history.id, name)}
    end
  end

  defp agent_id, do: Monty.Simulators.Synthetic.Environment.agent_id()
end
