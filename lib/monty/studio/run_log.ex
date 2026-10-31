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
  """
  @spec entry(map(), map()) :: map()
  def entry(info, beliefs \\ %{}) do
    %{
      "step" => info.step,
      "at" => now(),
      "percepts" => Enum.map(info.percept_ids, &to_string/1),
      "inputs" => Map.new(info.inputs, fn {module, count} -> {to_string(module), count} end),
      "votes" => %{"sent" => info.votes.sent, "used" => info.votes.used},
      "goals" => info.goals,
      "actions" => length(info.actions),
      "duration_us" => info.duration_us
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
  @spec moment(map(), map()) :: map()
  def moment(info, observations) do
    %{
      "step" => info.step,
      "sensors" => observations |> Map.get(agent_id(), %{}) |> Map.new(&sensor_moment/1)
    }
  end

  # The arrays a camera answers with, one entry per pixel. They are dropped on
  # the way into the database — four thousand numbers a step, per sensor, is not
  # something a history row should carry — and the two *pictures* they make are
  # kept instead: a few kilobytes of PNG, which is what a page shows anyway. So a
  # run that has finished still shows what its sensors saw, and a replay is the
  # episode as it happened rather than a table of numbers.
  @camera_arrays ["depth", "rgba", "semantic", "semantic_3d", "sensor_frame_data"]

  defp sensor_moment({sensor_id, observation}) do
    images = Camera.images(observation)

    recorded =
      %{
        "depth" => images.depth,
        "colour" => images.colour,
        "range" => images.range && Tuple.to_list(images.range)
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    kept = Map.drop(observation, @camera_arrays)

    if map_size(recorded) == 0,
      do: {sensor_id, kept},
      else: {sensor_id, Map.put(kept, "images", recorded)}
  end

  @doc """
  One timestep, as a line of text.

  The line starts with the wall clock and ends with how long the step took: a
  log that only counts percepts says a run is alive without saying whether the
  last step took a millisecond or a minute, and "why is this slow" is the first
  question anyone asks a log.
  """
  @spec line(map()) :: String.t()
  def line(entry) do
    inputs =
      entry
      |> Map.get("inputs", %{})
      |> Enum.map_join(" ", fn {module, count} -> "#{module}=#{count}" end)

    votes = Map.get(entry, "votes", %{})

    "#{at(entry)}step #{entry["step"]} · percepts #{Enum.join(Map.get(entry, "percepts", []), ",")} · " <>
      "inputs #{inputs} · votes #{votes["used"]}/#{votes["sent"]} · " <>
      "goals #{entry["goals"]} · #{Duration.humanize(Map.get(entry, "duration_us", 0))}" <>
      believed(entry)
  end

  # When the step happened, to the second. A line recorded before runs kept the
  # time is history, not an error: it prints without the prefix.
  defp at(entry) do
    with iso when is_binary(iso) <- Map.get(entry, "at"),
         {:ok, at, _offset} <- DateTime.from_iso8601(iso) do
      Calendar.strftime(at, "%H:%M:%S ")
    else
      _missing -> ""
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

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

  @doc "A finished run's summary, as the database stores it."
  @spec summary(Summary.t()) :: map()
  def summary(%Summary{} = summary) do
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
        end)
    }
  end

  @doc """
  The attributes for a run that is starting.

  The config snapshot is the composed tree, and the inputs are what the run was
  given: the group choices, the seed, the budget, and the modules it addresses.
  """
  @spec attributes(map(), pos_integer()) :: map()
  def attributes(opened, steps, episode \\ 0) do
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
        "sensors" => Setup.sensor_ids(opened.setup),
        "learning_modules" => Enum.map(opened.setup.learning_modules, & &1.id)
      }
    }
  end

  @doc "Records a step — what was reported, what was seen and what was believed — and returns the row."
  @spec record_step(RunHistory.Run.t(), map(), map(), map()) :: RunHistory.Run.t()
  def record_step(history, info, observations, beliefs \\ %{}) do
    case RunHistory.record_step(history, entry(info, beliefs), moment(info, observations)) do
      {:ok, history} -> history
      {:error, _changeset} -> history
    end
  end

  defp agent_id, do: Monty.Simulators.Synthetic.Environment.agent_id()
end
