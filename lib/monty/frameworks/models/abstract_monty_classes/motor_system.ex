defmodule Monty.Frameworks.Models.AbstractMontyClasses.MotorSystem do
  @moduledoc """
  Behaviour for a motor system, mirroring
  `tbp/monty/frameworks/models/motor_system.py::MotorSystem`.

  Monty's `MotorSystem.__call__(ctx, observations, proprioceptive_state,
  percept, goals)` hands the first sensor module's percept and the filtered
  goals to a policy selector and returns the actions for the *next*
  environment step. The policy may also declare the step motor-only, which the
  runtime reads on the following step.
  """

  @type state :: term()
  @type action :: map()
  @type request :: %{
          ctx: Monty.Context.t(),
          observations: map(),
          proprioceptive_state: map(),
          percept: Monty.Cmp.Message.t() | nil,
          goals: [Monty.Cmp.Goal.t()]
        }

  @doc """
  Chooses the actions for this step and says whether it is motor-only.
  """
  @callback act(request(), state) :: {[action()], state, boolean()}
end
