defmodule Monty.SensorModules.SensorModule do
  @moduledoc """
  A sensor module that is a pipeline of transforms rather than a class of its own.

  Mirrors `tbp/monty/sensor_modules/sensor_module.py::SensorModule`, the shape
  Monty's newer sensor modules take: one step hands the raw observation to the
  first transform, each transform answers a changed payload, and the last one's
  percept is what the step reports. Nothing here knows what a patch is — a view
  finder whose pipeline is empty reports no percept at all, which is exactly what
  it should do.

  ## The port's one sensor contract

  Monty declares `RuntimeSensorModule` and `ResettableSensorModule` as
  `Protocol`s, purely so a runtime can ask whether an object is one. The port has
  a single sensor behaviour instead
  (`Monty.Frameworks.Models.AbstractMontyClasses.SensorModule`) — a sensor module
  *is* something with `update_state/2`, `step/4`, `reset/1` and the two proposal
  answers — so neither protocol becomes a module here
  (`docs/monty-bugs.md` §2.13).

  ## What it does not have

  Monty gives the plain class no `reset` at all; only the experiment wrapper
  resets, and only its transforms. The port's behaviour requires every sensor to
  reset, so this one forgets what its payloads set (goals, region, telemetry) and
  leaves the transforms alone — the wrapper is what resets those.
  """

  use Monty.Frameworks.Models.AbstractMontyClasses.SensorModule

  alias Monty.Cmp.{AttentionRegion, Goal}
  alias Monty.Context
  alias Monty.Frameworks.Models.MotorSystemState.AgentState
  alias Monty.SensorModules.SensorModule.{Payload, TransformContext}

  @enforce_keys [:sensor_module_id, :sensor_id]
  defstruct sensor_module_id: nil,
            sensor_id: nil,
            transforms: [],
            agent_state: nil,
            sensor_state: nil,
            goals: [],
            region: nil,
            telemetry: %{}

  @type transform :: {module(), struct()}

  @type t :: %__MODULE__{
          sensor_module_id: atom() | String.t(),
          sensor_id: atom() | String.t(),
          transforms: [transform()],
          agent_state: AgentState.t() | nil,
          sensor_state: term(),
          goals: [Goal.t()],
          region: AttentionRegion.t() | nil,
          telemetry: map()
        }

  @doc """
  A sensor module whose step is `transforms`, applied in the order given.

  A transform is `{module, transform}`: the behaviour implementation and the
  config it was built from, because a config may configure the same class twice.
  """
  @spec new(atom() | String.t(), atom() | String.t(), [transform()]) :: t()
  def new(sensor_module_id, sensor_id, transforms) do
    %__MODULE__{
      sensor_module_id: sensor_module_id,
      sensor_id: sensor_id,
      transforms: transforms
    }
  end

  @impl true
  def update_state(%AgentState{} = agent, %__MODULE__{} = sm) do
    %__MODULE__{
      sm
      | agent_state: agent,
        sensor_state: AgentState.sensor_pose(agent, sm.sensor_id)
    }
  end

  @impl true
  def step(observation, motor_only?, ctx, %__MODULE__{} = sm) do
    transform_ctx = %TransformContext{
      rng: Context.rng_for(ctx, sm.sensor_module_id),
      agent_state: sm.agent_state,
      sensor_state: sm.sensor_state,
      motor_only_step: motor_only?,
      suppress_runtime_errors: ctx.suppress_runtime_errors
    }

    {payload, transforms} =
      Enum.reduce(
        sm.transforms,
        {%Payload{observation: observation, telemetry: sm.telemetry}, []},
        fn {module, transform}, {payload, transforms} ->
          {payload, transform} = module.call(transform, transform_ctx, payload)
          {payload, [{module, transform} | transforms]}
        end
      )

    {payload.percept,
     %__MODULE__{
       sm
       | transforms: Enum.reverse(transforms),
         goals: payload.goals,
         region: payload.region,
         telemetry: payload.telemetry
     }}
  end

  @impl true
  def propose_goals(%__MODULE__{} = sm), do: {sm.goals, sm}

  @impl true
  def propose_region(%__MODULE__{region: nil} = sm), do: {AttentionRegion.empty(), sm}
  def propose_region(%__MODULE__{region: region} = sm), do: {region, sm}

  @doc "What this sensor's transforms have written down, as Monty reports it."
  @spec state_dict(t()) :: map()
  def state_dict(%__MODULE__{} = sm), do: sm.telemetry

  @impl true
  def reset(%__MODULE__{} = sm), do: %__MODULE__{sm | goals: [], region: nil, telemetry: %{}}
end
