defmodule Monty.Frameworks.Models.MotorSystem.RuntimeMotorSystem do
  @moduledoc """
  What the rest of the runtime asks a motor system: this step, what should move?

  Mirrors `tbp/monty/frameworks/models/motor_system.py::RuntimeMotorSystem`, a
  protocol with one method. The percept is the one from the first sensor module,
  which is the only one a body has ever needed to be told about.
  """

  alias Monty.Cmp.{Goal, Message}
  alias Monty.Context
  alias Monty.Frameworks.Models.MotorSystemState.ProprioceptiveState

  @doc """
  The actions to take next, and the motor system as it now stands.

  Monty answers only the actions, because it can change itself; the step's
  record of what was decided is the motor system's own state, so it comes back
  with the answer, as everywhere else in this port.
  """
  @callback call(
              t(),
              ctx :: Context.t(),
              observations :: map() | nil,
              proprioceptive_state :: ProprioceptiveState.t(),
              percept :: Message.t() | nil,
              goals :: [Goal.t()]
            ) :: {[term()], t()}

  @type t :: struct()
end
