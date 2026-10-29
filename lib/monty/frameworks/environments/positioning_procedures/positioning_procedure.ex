defmodule Monty.Frameworks.Environments.PositioningProcedures.PositioningProcedure do
  @moduledoc """
  How an experiment puts the agent somewhere sensible before the first step.

  Mirrors
  `tbp/monty/frameworks/environments/positioning_procedures.py::PositioningProcedure`,
  a `Protocol` in Monty and a behaviour here, which is how this port spells every
  abstract class (`docs/monty-bugs.md` §2.6).

  A procedure is asked for one step at a time and answers with actions the
  environment should take, plus whether it is finished. It is *not* a motor
  policy: it runs before the motor system does, against the environment directly,
  because a run has to see something before a policy has anything to decide.

  Monty's protocol also declares `depth_at_center` as a static method; that is a
  function of `PositioningProcedures`, not of an implementation, so it is not a
  callback here.

  ## State

  Monty's procedures mutate themselves — the number of turns attempted, whether
  the extra orientation step for multi-object scenes has been done. Here a step
  answers `{result, procedure}`, and the caller keeps the procedure it was given
  back, as everything else in this port threads state.
  """

  alias Monty.Frameworks.Environments.PositioningProcedures.PositioningProcedureResult

  @doc "One step of positioning: actions for the environment, and the procedure's new state."
  @callback call(procedure :: term(), observation :: map(), state :: map()) ::
              {PositioningProcedureResult.t(), term()}
end
