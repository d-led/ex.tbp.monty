defmodule Monty.Frameworks.Models.Salience.MotorPolicy.LookAtGoal do
  @moduledoc """
  A policy that turns to look at a goal: the agent yaws, the sensor pitches.

  Mirrors `tbp/monty/frameworks/models/salience/motor_policy.py::LookAtGoal`,
  and assumes the body it drives is a two-axis gimbal — the agent turns left and
  right about the vertical axis, the sensor on it looks up and down about the
  horizontal one. That is the distant agent: a camera on a neck.

  Two actions come out of one step, and only ever these two: `TurnLeft` by the
  target's azimuth, and `LookUp` by the target's elevation measured *from where
  the sensor is already pointing*. Turning right and looking down are negative
  degrees on the same actions, which is why the action list has two entries and
  not four.

  Everything is computed in frames, not in degrees, until the last line: the
  target is moved into the agent's frame by the agent's inverse rotation, and
  then into the sensor's frame by the sensor's, because the sensor may be
  pitched relative to the body it sits on.
  """

  @behaviour Monty.Frameworks.Models.MotorPolicies.MotorPolicy

  require Logger

  alias Monty.Cmp
  alias Monty.Frameworks.Actions.{LookUp, TurnLeft}
  alias Monty.Frameworks.Models.MotorPolicies.{MotorPolicyResult, NoGoalProvided}
  alias Monty.Frameworks.Models.Salience.MotorPolicy.GoalCollocatedWithSensor
  alias Monty.Frameworks.Utils.SpatialArithmetics
  alias Monty.Geometry.Rotation

  # Monty tests the sensor-to-target distance with `np.isclose(norm, 0.0)`, whose
  # default tolerance is 1e-8.
  @collocated_tolerance 1.0e-8

  @enforce_keys [:agent_id, :sensor_id]
  defstruct agent_id: nil, sensor_id: nil

  @type t :: %__MODULE__{
          agent_id: atom() | String.t(),
          sensor_id: atom() | String.t()
        }

  @doc "A look-at policy for `:agent_id`, aiming the sensor `:sensor_id`."
  @spec new(keyword()) :: t()
  def new(options) do
    %__MODULE__{
      agent_id: Keyword.fetch!(options, :agent_id),
      sensor_id: Keyword.fetch!(options, :sensor_id)
    }
  end

  @doc """
  The turn and the pitch that put the sensor on the goal.

  A goal at the sensor is refused: there is no azimuth to turn to. Both refusals
  and the missing goal become a warning and no action when the run suppresses
  runtime errors.
  """
  @impl true
  @spec call(
          t(),
          Monty.Context.t(),
          map() | nil,
          Monty.Frameworks.Models.MotorSystemState.t(),
          Cmp.Message.t() | nil,
          Cmp.Goal.t() | nil
        ) :: {MotorPolicyResult.t(), t()}
  def call(%__MODULE__{} = policy, ctx, _observations, state, _percept, goal) do
    case aim_at(ctx, state, policy, goal) do
      {:ok, actions} -> {%MotorPolicyResult{actions: actions}, policy}
      :no_actions -> {%MotorPolicyResult{}, policy}
    end
  end

  defp aim_at(ctx, state, policy, goal) do
    with {:ok, goal} <- require_goal(ctx, goal) do
      actions(ctx, goal, state, policy)
    end
  end

  defp require_goal(%{suppress_runtime_errors: true}, nil) do
    Logger.warning("No goal provided")
    :no_actions
  end

  defp require_goal(_ctx, nil), do: raise(NoGoalProvided)

  defp require_goal(_ctx, %Cmp.Goal{} = goal), do: {:ok, goal}

  defp actions(ctx, %Cmp.Goal{} = goal, state, %__MODULE__{} = policy) do
    agent = Map.fetch!(state, policy.agent_id)
    sensor = Map.fetch!(agent.sensors, policy.sensor_id)

    target_rel_agent =
      agent.rotation
      |> Rotation.invert()
      |> Rotation.apply(SpatialArithmetics.subtract(goal.location, agent.position))

    target_rel_sensor =
      sensor.rotation
      |> Rotation.invert()
      |> Rotation.apply(SpatialArithmetics.subtract(target_rel_agent, sensor.position))

    if collocated?(target_rel_sensor) do
      refuse_collocated(ctx)
    else
      {:ok, aim(target_rel_agent, sensor, policy.agent_id)}
    end
  end

  defp refuse_collocated(%{suppress_runtime_errors: true}) do
    Logger.warning("Goal is collocated with sensor")
    :no_actions
  end

  defp refuse_collocated(_ctx), do: raise(GoalCollocatedWithSensor)

  # The azimuth is the target's bearing in the horizontal plane; the elevation is
  # its height over its horizontal distance. The sensor's own pitch comes off the
  # elevation, so a sensor already looking up only has the difference left to do.
  defp aim([x, y, z], sensor, agent_id) do
    yaw = -:math.atan2(x, -z)
    elevation = :math.atan2(y, :math.sqrt(x * x + z * z))
    sensor_pitch = sensor.rotation |> Rotation.to_euler_radians() |> hd()

    [
      %TurnLeft{agent_id: agent_id, rotation_degrees: degrees(yaw)},
      %LookUp{agent_id: agent_id, rotation_degrees: degrees(elevation - sensor_pitch)}
    ]
  end

  defp collocated?(target_rel_sensor) do
    SpatialArithmetics.magnitude(target_rel_sensor) <= @collocated_tolerance
  end

  defp degrees(radians), do: radians * 180.0 / :math.pi()

  @doc "Nothing to forget: where the sensor points is the world's business."
  @impl true
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = policy), do: policy

  @doc "Which body and which sensor it aims."
  @impl true
  @spec state_dict(t()) :: map()
  def state_dict(%__MODULE__{} = policy),
    do: %{agent_id: policy.agent_id, sensor_id: policy.sensor_id}
end
