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
      "sensor_timeouts" => Enum.map(summary.sensor_timeouts, &to_string/1)
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

  @doc "Records a step and returns the updated history row."
  @spec record_step(RunHistory.Run.t(), map()) :: RunHistory.Run.t()
  def record_step(history, info) do
    case RunHistory.record_step(history, entry(info)) do
      {:ok, history} -> history
      {:error, _changeset} -> history
    end
  end
end
