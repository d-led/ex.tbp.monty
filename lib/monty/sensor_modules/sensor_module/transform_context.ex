defmodule Monty.SensorModules.SensorModule.TransformContext do
  @moduledoc """
  What a transform knows about the step it is transforming.

  Mirrors `tbp/monty/sensor_modules/sensor_module.py::TransformContext`: the
  random stream, where the agent and this sensor are, and the two flags that
  decide whether the step is one to learn from and whether a failure inside a
  transform should be raised or reported.

  Monty passes its one runtime `rng` here. The port passes the stream this
  sensor may draw from at this step (`Monty.Context.rng_for/2`), so a transform
  that samples is reproducible from the episode seed alone
  (`docs/monty-bugs.md` §2.1).
  """

  alias Monty.Frameworks.Models.MotorSystemState.{AgentState, SensorState}

  defstruct rng: nil,
            agent_state: nil,
            sensor_state: nil,
            motor_only_step: false,
            suppress_runtime_errors: false

  @type rng :: :rand.state()

  @type t :: %__MODULE__{
          rng: rng() | nil,
          agent_state: AgentState.t() | nil,
          sensor_state: SensorState.t() | nil,
          motor_only_step: boolean(),
          suppress_runtime_errors: boolean()
        }
end
