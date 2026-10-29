defmodule Monty.Simulators.Synthetic.Kinematics do
  @moduledoc """
  Where the stand-in world puts the agent after an action.

  Monty's world is MuJoCo, and its actuator defines the conventions this module
  follows, because a policy that steers one must steer the other:

    * `MoveForward` moves along the agent's local **−Z** — towards whatever the
      sensor is looking at — and a negative distance moves it backwards;
    * `TurnLeft` / `TurnRight` yaw the *agent* about its local Y, positive to the
      left;
    * `LookUp` / `LookDown` pitch the *sensors* about their local X, and the
      agent stays where it points;
    * `MoveTangentially` moves along the action's `direction`, which is already a
      world vector: the surface policies rotate their heading by the agent's
      rotation before they answer, so it must not be rotated again;
    * `OrientVertical` / `OrientHorizontal` orbit the agent about its own axes:
      a side step, then a pitch or yaw, then a step along the agent's −Z. Monty's
      actuator "ASSUMES" the distances were calculated to orbit the object, and
      takes the surface into account not at all — so neither does this.

  What is not honoured: the actions that set a pose outright (`SetAgentPose`,
  `SetSensorPose`, `SetYaw`, …). Asking for one is an error rather than a silent
  no-op — a world that quietly ignores an action makes an agent look broken in a
  way that the log cannot explain.
  """

  alias Monty.Frameworks.Actions.{
    LookDown,
    LookUp,
    MoveForward,
    MoveTangentially,
    OrientHorizontal,
    OrientVertical,
    TurnLeft,
    TurnRight
  }

  alias Monty.Frameworks.Utils.SpatialArithmetics
  alias Monty.Geometry.Rotation

  @sensor_height 0.1
  @sensor_spacing 0.01

  @typedoc """
  Where one body sits: a position in the world, and a rotation from its own
  frame to the world's.
  """
  @type pose :: %{position: Rotation.vector(), rotation: Rotation.t()}

  @type t :: %{
          agent: pose(),
          sensors: %{optional(Monty.Simulators.Environment.sensor_id()) => pose()}
        }

  @doc """
  A world with the agent at the origin and its sensors above it.

  Sensors sit a decimetre up and a centimetre apart, which is where the
  stand-in world has always put them; the spacing exists so that two sensors of
  one agent see different places.
  """
  @spec new([Monty.Simulators.Environment.sensor_id()]) :: t()
  def new(sensor_ids) do
    %{
      agent: %{position: [0.0, 0.0, 0.0], rotation: Rotation.identity()},
      sensors:
        sensor_ids
        |> Enum.with_index()
        |> Map.new(fn {sensor_id, index} ->
          {sensor_id,
           %{
             position: [0.0, 0.0, @sensor_height + index * @sensor_spacing],
             rotation: Rotation.identity()
           }}
        end)
    }
  end

  @doc "The world after every action of one step, in the order they were given."
  @spec step(t(), [Monty.Frameworks.Actions.Action.t()]) :: t()
  def step(world, actions), do: Enum.reduce(actions, world, &act/2)

  defp act(%MoveForward{distance: distance}, world) do
    translate_agent(world, [0.0, 0.0, -distance])
  end

  defp act(%MoveTangentially{distance: distance, direction: direction}, world) do
    move_agent(world, SpatialArithmetics.scale(SpatialArithmetics.normalize(direction), distance))
  end

  defp act(%TurnLeft{rotation_degrees: degrees}, world),
    do: turn_agent(world, degrees)

  defp act(%TurnRight{rotation_degrees: degrees}, world),
    do: turn_agent(world, -degrees)

  defp act(%LookUp{rotation_degrees: degrees}, world), do: pitch_sensors(world, degrees)

  defp act(%LookDown{rotation_degrees: degrees}, world), do: pitch_sensors(world, -degrees)

  defp act(%OrientVertical{} = action, world) do
    world
    |> translate_agent([0.0, -action.down_distance, 0.0])
    |> rotate_agent([1.0, 0.0, 0.0], action.rotation_degrees)
    |> translate_agent([0.0, 0.0, -action.forward_distance])
  end

  defp act(%OrientHorizontal{} = action, world) do
    world
    |> translate_agent([-action.left_distance, 0.0, 0.0])
    |> rotate_agent([0.0, 1.0, 0.0], -action.rotation_degrees)
    |> translate_agent([0.0, 0.0, -action.forward_distance])
  end

  defp act(action, _world) do
    raise ArgumentError,
          "#{inspect(action.__struct__)} sets a pose outright, which the stand-in " <>
            "world does not do; use a simulator behind " <>
            "Monty.Simulators.Port.Environment instead"
  end

  # -- the agent ------------------------------------------------------------

  # A move in the agent's own frame, in the world's: every step of an orbit is
  # taken after the one before it, so each uses the rotation the last one left.
  defp translate_agent(world, offset) do
    agent = world.agent

    %{
      world
      | agent: %{
          agent
          | position: SpatialArithmetics.add(agent.position, local_to_world(agent, offset))
        }
    }
  end

  defp move_agent(world, offset) do
    agent = world.agent
    %{world | agent: %{agent | position: SpatialArithmetics.add(agent.position, offset)}}
  end

  defp turn_agent(world, degrees), do: rotate_agent(world, [0.0, 1.0, 0.0], degrees)

  defp rotate_agent(world, axis, degrees) do
    agent = world.agent
    rotation = Rotation.multiply(agent.rotation, about(axis, degrees))

    %{world | agent: %{agent | rotation: rotation}}
  end

  # A pitch belongs to the sensors: in Monty the agent keeps facing where it
  # faced and the camera looks up or down.
  defp pitch_sensors(world, degrees) do
    pitch = about([1.0, 0.0, 0.0], degrees)

    sensors =
      Map.new(world.sensors, fn {sensor_id, sensor} ->
        {sensor_id, %{sensor | rotation: Rotation.multiply(sensor.rotation, pitch)}}
      end)

    %{world | sensors: sensors}
  end

  # -- reading the world ----------------------------------------------------

  @doc """
  Where each sensor is and which way it faces, in the world.

  The sensor's own frame is the agent's turned by however the sensor is mounted
  on it, so raising the agent's yaw carries its cameras round too.
  """
  @spec sensor_world_poses(t()) :: %{
          optional(Monty.Simulators.Environment.sensor_id()) => pose()
        }
  def sensor_world_poses(world) do
    Map.new(world.sensors, fn {sensor_id, sensor} ->
      {sensor_id,
       %{
         position:
           SpatialArithmetics.add(
             world.agent.position,
             local_to_world(world.agent, sensor.position)
           ),
         rotation: Rotation.multiply(world.agent.rotation, sensor.rotation)
       }}
    end)
  end

  @doc """
  Where each sensor is, as the environment reports it.
  """
  @spec sensor_positions(t()) :: %{
          optional(Monty.Simulators.Environment.sensor_id()) => Rotation.vector()
        }
  def sensor_positions(world) do
    Map.new(sensor_world_poses(world), fn {sensor_id, pose} -> {sensor_id, pose.position} end)
  end

  @doc """
  Each sensor's own pose, relative to the agent, as proprioception reports it.
  """
  @spec sensor_poses(t()) :: %{
          optional(Monty.Simulators.Environment.sensor_id()) => pose()
        }
  def sensor_poses(world), do: world.sensors

  # A vector in the agent's frame, in the world's frame.
  defp local_to_world(agent, vector), do: Rotation.apply(agent.rotation, vector)

  defp about(axis, degrees) do
    case Rotation.from_axis_angle(axis, radians(degrees)) do
      {:ok, rotation} -> rotation
      {:error, :zero_axis} -> raise ArgumentError, "#{inspect(axis)} is not an axis"
    end
  end

  defp radians(degrees), do: degrees * :math.pi() / 180.0
end
