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
end
