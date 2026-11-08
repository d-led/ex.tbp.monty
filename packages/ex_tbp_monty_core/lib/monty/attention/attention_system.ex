defmodule Monty.Attention.AttentionSystem do
  @moduledoc """
  What attention does to a step — Monty's `attention/attention_system.py`.

  Sensors propose where to look (`Monty.Cmp.AttentionRegion`), the goal generator
  proposes what to do (`Monty.Cmp.Goal`), and the attention system sits between
  them: it keeps a grid of how interesting each part of space has been, and it
  answers which goals are worth pursuing given that grid.

  Monty declares the contract as a `Protocol` over `step`, `reset` and
  `state_dict`, and the systems are objects with a `_grid` they mutate. Here the
  system is a struct and `step/3` answers `{system, goals}` — the caller threads
  the system, so what a step did is visible in its return value rather than only
  in the object afterwards.
  """

  alias Monty.Cmp.{AttentionRegion, Goal}
  alias Monty.Memento

  @doc "Act on one step's goals given where the sensors looked."
  @callback step(system :: term(), [Goal.t()], [AttentionRegion.t()]) ::
              {system :: term(), [Goal.t()]}

  @doc "Forget everything attention has learned."
  @callback reset(system :: term()) :: system :: term()

  @doc "The system's state, for a recording run."
  @callback state_dict(system :: term()) :: Memento.t()
end
