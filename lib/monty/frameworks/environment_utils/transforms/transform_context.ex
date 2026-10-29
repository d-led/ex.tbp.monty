defmodule Monty.Frameworks.EnvironmentUtils.Transforms.TransformContext do
  @moduledoc """
  What an environment transform knows about the step it is transforming.

  Mirrors `tbp/monty/frameworks/environment_utils/transforms.py::TransformContext`:
  the random stream, and where the agents and their sensors were.

  Monty passes its one runtime `rng` here. The port passes the stream the *step*
  allows, derived from the run's context and the transform's place in the chain
  (`Monty.Context.rng_for/2`), so a transform that adds noise is reproducible
  from the episode seed alone (`docs/monty-bugs.md` §2.1).
  """

  @type rng :: :rand.state()
  @type state :: Monty.Frameworks.Models.MotorSystemState.ProprioceptiveState.t() | nil

  defstruct rng: nil, state: nil

  @type t :: %__MODULE__{rng: rng() | nil, state: state()}
end
