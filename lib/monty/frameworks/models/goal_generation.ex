defmodule Monty.Frameworks.Models.GoalGeneration do
  @moduledoc """
  Goal-state generators: what a learning module wants to look at next.

  Mirrors `tbp/monty/frameworks/models/goal_generation.py`, which holds one
  error and two generators:

    * `...GoalGeneration.ParentLMNotProvided` — **ported**: the error a generator
      raises when asked about its learning module before it has one;
    * `...GoalGeneration.GraphGoalGenerator` — **ported**: the base generator,
      which checks whether the goal it last emitted was reached and emits the
      next one; on its own it emits nothing, meaning "just be more certain";
    * `...GoalGeneration.EvidenceGoalGenerator` — **ported**: the generator an
      evidence-based module uses to pick where to look, from the mismatch
      between the graph of the object it believes in and the graph of the one
      it cannot rule out.

  The behaviour these implement is
  `Monty.Frameworks.Models.AbstractMontyClasses.GoalGenerator`.
  """

  alias Monty.Frameworks.Models.GoalGeneration.{EvidenceGoalGenerator, GraphGoalGenerator}

  # The two generators a learning module's `gsg:` entry may name. Monty's file
  # holds exactly three classes and the third is an error, so the list is closed.
  @generators %{
    "tbp.monty.frameworks.models.goal_generation.EvidenceGoalGenerator" => EvidenceGoalGenerator,
    "tbp.monty.frameworks.models.goal_generation.GraphGoalGenerator" => GraphGoalGenerator
  }

  @doc """
  The generator a config entry names, built from its own keys.

  Monty instantiates the entry through Hydra and hands the learning module the
  object; a module built from a config has to instantiate the entry itself, which
  is what this does. A class this port has not written is an error rather than a
  silent `nil`, so building a module cannot quietly drop the goals the experiment
  asked for.
  """
  @spec from_config(map()) :: {:ok, struct()} | {:error, term()}
  def from_config(%{} = config) do
    case Map.fetch(@generators, Map.get(config, "_target_")) do
      {:ok, generator} -> {:ok, generator.from_config(config)}
      :error -> {:error, {:unsupported_goal_generator, Map.get(config, "_target_")}}
    end
  end
end
