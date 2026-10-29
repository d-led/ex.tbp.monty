defmodule Monty.Studio.RunLog do
  @moduledoc """
  What a run reports, in the shape a log, a page and the database all agree on.

  A timestep's report from the coordinator is rich and Elixir-shaped; a log line
  is text and the database wants JSON-safe maps. Both are derived here, so a
  headless `mix monty.run` and the studio page print the same line for the same
  step instead of two similar ones that drift, and the history row means the
  same thing whichever way the run was started.
  """

  alias Monty.Studio.{RunHistory, Setup, Summary}
  @doc "One timestep, as the database stores it."
  @spec entry(map()) :: map()
  def entry(info) do
    %{
      "step" => info.step,
      "percepts" => Enum.map(info.percept_ids, &to_string/1),
      "inputs" => Map.new(info.inputs, fn {module, count} -> {to_string(module), count} end),
      "votes" => %{"sent" => info.votes.sent, "used" => info.votes.used},
      "goals" => info.goals,
      "actions" => length(info.actions),
      "duration_us" => info.duration_us
    }
  end

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

  # The arrays a camera answers with, one entry per pixel.
  @camera_arrays ["depth", "rgba", "semantic", "semantic_3d", "sensor_frame_data"]

  defp sensor_moment({sensor_id, observation}),
    do: {sensor_id, Map.drop(observation, @camera_arrays)}

  @doc "One timestep, as a line of text."
  @spec line(map()) :: String.t()
  def line(entry) do
    inputs =
      entry
      |> Map.get("inputs", %{})
      |> Enum.map_join(" ", fn {module, count} -> "#{module}=#{count}" end)

    votes = Map.get(entry, "votes", %{})

    "step #{entry["step"]} · percepts #{Enum.join(Map.get(entry, "percepts", []), ",")} · " <>
      "inputs #{inputs} · votes #{votes["used"]}/#{votes["sent"]} · " <>
      "goals #{entry["goals"]} · #{Map.get(entry, "duration_us", 0)} µs"
  end

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
  def attributes(opened, steps) do
    %{
      experiment: opened.name,
      source: to_string(opened.source),
      steps: steps,
      seed: opened.setup.seed,
      config: opened.config,
      inputs: %{
        "groups" => opened.groups,
        "seed" => opened.setup.seed,
        "train_epochs" => opened.setup.epochs.train,
        "eval_epochs" => opened.setup.epochs.eval,
        "sensors" => Setup.sensor_ids(opened.setup),
        "learning_modules" => Enum.map(opened.setup.learning_modules, & &1.id)
      }
    }
  end

  @doc "Records a step — what was reported and what was seen — and returns the row."
  @spec record_step(RunHistory.Run.t(), map(), map()) :: RunHistory.Run.t()
  def record_step(history, info, observations) do
    case RunHistory.record_step(history, entry(info), moment(info, observations)) do
      {:ok, history} -> history
      {:error, _changeset} -> history
    end
  end

  defp agent_id, do: Monty.Simulators.Synthetic.Environment.agent_id()
end
