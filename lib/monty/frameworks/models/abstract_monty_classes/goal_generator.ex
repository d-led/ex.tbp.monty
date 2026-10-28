defmodule Monty.Frameworks.Models.AbstractMontyClasses.GoalGenerator do
  @moduledoc """
  Goals other learning modules and motor systems will try to achieve.

  Mirrors `tbp/monty/frameworks/models/abstract_monty_classes.py::GoalGenerator`,
  the abstract class a goal-state generator (GSG) implements. A GSG belongs to a
  learning module: the module knows what it thinks it is looking at, the GSG
  turns that into where to look next, and the motor system moves there.

  ## Why `parent_lm` is set from outside

  Monty's docstring is explicit that the GSG is not fully initialised until its
  owner provides the learning module, because the module holds the GSG and the
  GSG reads the module. The circularity is broken by injection: `from_config`
  builds the GSG, the learning module sets itself as `parent_lm`, and setting it
  resets the GSG so that it starts from a state consistent with that module.

  A GSG asked about its parent before one was provided has nothing to answer
  with, and says so rather than returning `nil` that a caller would then have to
  guard against everywhere.
  """

  alias Monty.Cmp.{Goal, Message}

  @typedoc "The parent learning module: whatever a GSG reads from."
  @type parent_lm :: struct()

  @typedoc "What a sensor reports on one step."
  @type observations :: [Message.t()]

  @doc """
  The learning module this generator reads.

  Raises `Monty.Frameworks.Models.GoalGeneration.ParentLMNotProvided` when none
  has been set, which is the same error Monty raises.
  """
  @callback parent_lm(generator :: struct()) :: parent_lm()

  @doc """
  Points this generator at the learning module it belongs to, and resets it.

  Monty's setter resets the generator, because a generator keeping goals from
  another module's episode would be answering about the wrong object.
  """
  @callback put_parent_lm(generator :: struct(), parent_lm()) :: struct()

  @doc "Receives a new high-level goal for this generator to pursue."
  @callback set_driving_goal(generator :: struct(), goal :: Goal.t() | nil) :: struct()

  @doc "The goals this generator wants other modules and the motor system to achieve."
  @callback output_goals(generator :: struct()) :: [Goal.t()]

  @doc "Called on each step of the learning module the generator belongs to."
  @callback step(generator :: struct(), ctx :: Monty.Context.t(), observations()) :: struct()

  @doc "Forgets the goals held from before."
  @callback reset(generator :: struct()) :: struct()
end
