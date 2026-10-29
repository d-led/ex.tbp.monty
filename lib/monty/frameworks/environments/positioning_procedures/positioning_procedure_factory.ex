defmodule Monty.Frameworks.Environments.PositioningProcedures.PositioningProcedureFactory do
  @moduledoc """
  Where a procedure comes from, given the object an episode is about.

  Mirrors
  `tbp/monty/frameworks/environments/positioning_procedures.py::PositioningProcedureFactory`.
  A factory exists because the target object is only known when the episode
  starts: the scene decides which semantic id is the target, and the procedure has
  to be built for it.
  """

  @doc "A procedure for the object with this semantic id."
  @callback create(factory :: term(), target_semantic_id :: integer()) :: term()
end
