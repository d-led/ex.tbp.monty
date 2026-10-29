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
      rotation before they answer, so it must not be rotated again.

  `OrientVertical` and `OrientHorizontal` cannot be honoured here: they align the
  agent against a **surface**, and the stand-in world has no object to be near
  and no surface normal to align with. Asking for one is an error rather than a
  silent no-op — a world that quietly ignores an action makes an agent look
  broken in a way that the log cannot explain.
  """

  alias Monty.Frameworks.Actions.{
    LookDown,
    LookUp,
    MoveForward,
    MoveTangentially,
    TurnLeft,
    TurnRight
  }

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
    move_agent(world, local_to_world(world.agent, [0.0, 0.0, -distance]))
  end

  defp act(%MoveTangentially{distance: distance, direction: direction}, world) do
    move_agent(world, scale(unit(direction), distance))
  end

  defp act(%TurnLeft{rotation_degrees: degrees}, world),
    do: turn_agent(world, degrees)

  defp act(%TurnRight{rotation_degrees: degrees}, world),
    do: turn_agent(world, -degrees)

  defp act(%LookUp{rotation_degrees: degrees}, world), do: pitch_sensors(world, degrees)

  defp act(%LookDown{rotation_degrees: degrees}, world), do: pitch_sensors(world, -degrees)

  defp act(action, _world) do
    raise ArgumentError,
          "#{inspect(action.__struct__)} needs a surface to act on, and the " <>
            "stand-in world has none; use a simulator behind " <>
            "Monty.Simulators.Port.Environment instead"
  end

  # -- the agent ------------------------------------------------------------

  defp move_agent(world, offset) do
    agent = world.agent
    %{world | agent: %{agent | position: add(agent.position, offset)}}
  end

  defp turn_agent(world, degrees) do
    agent = world.agent
    yaw = about([0.0, 1.0, 0.0], degrees)

    %{world | agent: %{agent | rotation: Rotation.multiply(agent.rotation, yaw)}}
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
  Where each sensor is, as the environment reports it.
  """
  @spec sensor_positions(t()) :: %{
          optional(Monty.Simulators.Environment.sensor_id()) => Rotation.vector()
        }
  def sensor_positions(world) do
    Map.new(world.sensors, fn {sensor_id, sensor} ->
      {sensor_id, add(world.agent.position, local_to_world(world.agent, sensor.position))}
    end)
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

  defp add([a1, a2, a3], [b1, b2, b3]), do: [a1 + b1, a2 + b2, a3 + b3]

  defp scale([x, y, z], factor), do: [x * factor, y * factor, z * factor]

  # Monty's actuator assumes a unit direction; a policy that sent something else
  # would otherwise move the agent by an amount nobody chose.
  defp unit([x, y, z]) do
    length = :math.sqrt(x * x + y * y + z * z)

    if length == 0.0 do
      raise ArgumentError, "a movement direction of zero length has no direction"
    else
      [x / length, y / length, z / length]
    end
  end
end
