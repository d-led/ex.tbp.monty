defmodule Monty.Frameworks.Models.MotorSystemState.AgentState do
  @moduledoc """
  Where one agent is, how it is turned, and where its sensors are.

  Mirrors `tbp/monty/frameworks/models/motor_system_state.py::AgentState`. The
  sensors are keyed by sensor id, and their positions and rotations are relative
  to this agent's — which is what lets an environment move an agent without
  rewriting every sensor.
  """

  alias Monty.Frameworks.Models.MotorSystemState.SensorState
  alias Monty.Frameworks.Utils.SpatialArithmetics
  alias Monty.Geometry.Rotation

  @enforce_keys [:sensors, :position, :rotation]
  defstruct sensors: %{}, position: [0.0, 0.0, 0.0], rotation: nil

  @type sensor_id :: atom() | String.t()

  @type t :: %__MODULE__{
          sensors: %{optional(sensor_id()) => SensorState.t()},
          position: [float()],
          rotation: Monty.Geometry.Rotation.t()
        }

  @doc """
  Where the sensor `sensor_id` is, in the world.

  The sensor's own offset is relative to the agent, so its place is the agent's
  position with that offset turned:
  `agent.position + qt.rotate_vectors(agent.rotation, sensor.position)`, and its
  rotation the two rotations multiplied
  ([`sensor_modules.py:565-570`](https://github.com/thousandbrainsproject/tbp.monty/blob/91303642784ce176e2b8196c7bb990fef57688b6/src/tbp/monty/frameworks/models/sensor_modules.py#L565-L570)).

  Monty writes those two lines twice — once in `CameraSM.update_state`, once in
  the transform-pipeline `SensorModule.update_state` — and the port keeps one
  copy, because it is one rule (`docs/monty-bugs.md` §2.12).
  """
  @spec sensor_pose(t(), sensor_id()) :: SensorState.t()
  def sensor_pose(%__MODULE__{} = agent, sensor_id) do
    sensor = fetch_sensor!(agent, sensor_id)

    %SensorState{
      position:
        SpatialArithmetics.add(agent.position, Rotation.apply(agent.rotation, sensor.position)),
      rotation: Rotation.multiply(agent.rotation, sensor.rotation)
    }
  end

  defp fetch_sensor!(%__MODULE__{sensors: sensors}, sensor_id) do
    case Map.fetch(sensors, sensor_id) do
      {:ok, sensor} ->
        sensor

      :error ->
        raise ArgumentError,
              "the agent has no sensor #{inspect(sensor_id)}; it has " <>
                Enum.map_join(Map.keys(sensors), ", ", &inspect/1)
    end
  end
end
