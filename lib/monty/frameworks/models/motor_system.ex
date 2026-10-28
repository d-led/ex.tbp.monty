defmodule Monty.Frameworks.Models.MotorSystem do
  @moduledoc """
  The body: turns a step and the goals it was given into actions.

  Mirrors `tbp/monty/frameworks/models/motor_system.py`, which holds three
  names:

    * `...MotorSystem.SurfacePolicyActionDetailsTelemetry` — **ported**: what a
      surface policy wants remembered about the actions it chose;
    * `...MotorSystem.RuntimeMotorSystem` — **ported**: the interface the rest of
      the runtime calls;
    * `...MotorSystem` (this module) — **ported**: the implementation, which asks
      a policy selector and keeps the record.

  The work is one sentence long: build the state from the proprioceptive state,
  ask the selector, remember the actions and the state they were chosen in,
  return the actions. Everything a policy knows lives in the selector it was
  built with.

  Two differences from Monty, both consequences of not being able to change
  oneself:

    * the answer comes back with the updated motor system, rather than only the
      actions;
    * Monty's `fixme_provide_motor_system` handout is gone: a policy that wants
      `motor_only_step` set on the step says so in the `MotorPolicyResult` it
      returns, which this module then carries.

  Both are recorded in `docs/monty-bugs.md` §2.2 and §2.3.
  """

  @behaviour Monty.Frameworks.Models.MotorSystem.RuntimeMotorSystem

  alias Monty.Frameworks.Models.MotorSystem.SurfacePolicyActionDetailsTelemetry
  alias Monty.Frameworks.Models.MotorSystemState.ProprioceptiveState

  @enforce_keys [:policy_selector]
  defstruct policy_selector: nil,
            motor_only_step: false,
            action_sequence: [],
            telemetry: %SurfacePolicyActionDetailsTelemetry{}

  @typedoc """
  One step's worth of what was decided: the actions, and the state they were
  chosen in — kept together because the state explains the actions.
  """
  @type decided :: {[term()], proprioceptive_state :: ProprioceptiveState.t()}

  @type t :: %__MODULE__{
          policy_selector: struct(),
          motor_only_step: boolean(),
          action_sequence: [decided()],
          telemetry: SurfacePolicyActionDetailsTelemetry.t()
        }

  @doc """
  A motor system that will ask `policy_selector` what to do.

  Monty's constructor also hands itself to the selector, for reasons its own
  comment calls a hack; there is nothing to hand over here.
  """
  @spec new(struct()) :: t()
  def new(policy_selector), do: %__MODULE__{policy_selector: policy_selector}

  @doc """
  Asks the selector for this step's actions, and remembers them.

  The state is the proprioceptive state as it arrived: Monty wraps it in a
  `MotorSystemState`, which is the same map today, so wrapping would only make
  a copy that says nothing new.
  """
  @impl true
  @spec call(
          t(),
          Monty.Context.t(),
          map() | nil,
          ProprioceptiveState.t(),
          Monty.Cmp.Message.t() | nil,
          [Monty.Cmp.Goal.t()]
        ) :: {[term()], t()}
  def call(%__MODULE__{} = motor_system, ctx, observations, proprioceptive_state, percept, goals) do
    selector = motor_system.policy_selector

    {result, selector} =
      selector.__struct__.call(selector, ctx, observations, proprioceptive_state, percept, goals)

    motor_system = %{
      motor_system
      | policy_selector: selector,
        motor_only_step: result.motor_only_step,
        action_sequence: motor_system.action_sequence ++ [{result.actions, proprioceptive_state}],
        telemetry:
          SurfacePolicyActionDetailsTelemetry.append(motor_system.telemetry, result.telemetry)
    }

    {result.actions, motor_system}
  end

  @doc """
  Starts the next episode: no actions remembered, no telemetry, selector reset.
  """
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = motor_system) do
    selector = motor_system.policy_selector

    %__MODULE__{
      motor_system
      | policy_selector: selector.__struct__.reset(selector),
        motor_only_step: false,
        action_sequence: [],
        telemetry: %SurfacePolicyActionDetailsTelemetry{}
    }
  end

  @doc """
  What the selector recorded, for a run that wants to be read afterwards.
  """
  @spec state_dict(t()) :: map()
  def state_dict(%__MODULE__{} = motor_system) do
    selector = motor_system.policy_selector
    selector.__struct__.state_dict(selector)
  end

  @doc """
  Whether learning modules should sit this step out.

  A policy sets it when it is only turning or moving, where there is nothing new
  for a learning module to match.
  """
  @spec motor_only_step(t()) :: boolean()
  def motor_only_step(%__MODULE__{} = motor_system), do: motor_system.motor_only_step

  @doc "Everything the motor system decided, in order."
  @spec action_sequence(t()) :: [decided()]
  def action_sequence(%__MODULE__{} = motor_system), do: motor_system.action_sequence
end
