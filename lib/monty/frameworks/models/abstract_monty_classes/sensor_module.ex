defmodule Monty.Frameworks.Models.AbstractMontyClasses.SensorModule do
  @moduledoc """
  Behaviour for a sensor module, mirroring
  `tbp/monty/frameworks/models/abstract_monty_classes.py::SensorModule`.

  The callbacks are pure: they take the module's state and return the next
  state alongside their result. `Monty.Runtime.SensorModuleServer` is the thin
  process that holds that state; a module can be tested without a process at
  all.

  `update_state/2` is called before `step/3` on every step, because a sensor
  module needs to know where the sensor is before it can say what it observes.
  """

  alias Monty.Cmp.{AttentionRegion, Goal, Message}

  @typedoc "Whatever a module keeps between steps; opaque to the runtime."
  @type state :: term()
  @type agent_state :: map()
  @type observation :: map()

  @doc "Records the sensor's pose for the step about to run."
  @callback update_state(agent_state(), state) :: state

  @doc """
  Turns one raw observation into a percept, or `nil` when the sensor has
  nothing to say this step.
  """
  @callback step(observation(), boolean(), state) :: {Message.t() | nil, state}

  @doc "Clears short-term state for a new episode."
  @callback reset(state) :: state

  @doc "Goals this sensor proposes (a salience module proposes; a camera does not)."
  @callback propose_goals(state) :: {[Goal.t()], state}

  @doc "The region this sensor wants attended to."
  @callback propose_region(state) :: {AttentionRegion.t(), state}

  @optional_callbacks propose_goals: 1, propose_region: 1
end
