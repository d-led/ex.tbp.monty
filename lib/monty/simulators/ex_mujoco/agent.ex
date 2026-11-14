defmodule Monty.Simulators.ExMujoco.Agent do
  @moduledoc """
  One agent in a scene, and what an action does to it.

  `priv/monty_py/world.py` splits this in two — an `Embodiment` that moves a body
  and its sensor head, and one class per agent kind that says which movements its
  action vocabulary has (`SurfaceAgent`, `DistantAgent`, `NoopAgent`) — and so
  does this: the struct is the body, and `act/2` is the vocabulary, in the same
  words.

  A body's place is the free joint's seven `qpos` numbers and the head's pitch is
  the hinge's one, but they are held here as a position, a rotation and a pitch in
  degrees, because that is what an action reads. The numbers are written into
  `qpos` once per step, after every action has been applied.

  ## Which way is forward

  MuJoCo's convention, and Monty's: the body's local **z** points the way it
  faces, local **y** is up, and local **x** is to its right. So a forward step is
  a negative z move, a left move is a negative x move, and a descent is a negative
  y move — which is why every distance below is negated where Monty negates it.
  """

  alias Monty.Simulators.ExMujoco.Orientation

  @enforce_keys [:id, :class, :sensors, :free, :pitch, :position, :rotation]
  defstruct [
    :id,
    :class,
    :sensors,
    :free,
    :pitch,
    :position,
    :rotation,
    pitch_degrees: 0.0,
    origin: nil
  ]

  @typedoc """
  An agent: the names its joints and cameras carry, where it stands, and what its
  head is doing.
  """
  @type t :: %__MODULE__{
          id: String.t(),
          class: String.t(),
          sensors: %{optional(String.t()) => map()},
          free: non_neg_integer(),
          pitch: non_neg_integer(),
          position: [float()],
          rotation: Orientation.t(),
          pitch_degrees: float(),
          origin: {[float()], Orientation.t()} | nil
        }

  @doc """
  The agent an episode starts with: where the config puts it, at no turn on the
  head, keeping the place it has to be returned to when the next episode resets it.
  """
  @spec place(t()) :: t()
  def place(agent), do: %{agent | origin: {agent.position, agent.rotation}}

  @doc """
  Back where the episode started, with the head level.
  """
  @spec reset(t()) :: t()
  def reset(%__MODULE__{origin: {position, rotation}} = agent),
    do: %{agent | position: position, rotation: rotation, pitch_degrees: 0.0}

  def reset(%__MODULE__{} = agent), do: %{agent | pitch_degrees: 0.0}

  @doc """
  Applies one action to an agent.

  `action` is Monty's own `dict(action)` — what `ActionJSONEncoder` produces and
  what `priv/monty_py/world.py` is given — so both worlds read the same words.
  An action this agent's vocabulary does not have is refused or ignored,
  depending on `raise?`, which is Monty's `raise_actuate_missing`.
  """
  @spec act(t(), map(), boolean()) :: t()
  def act(%__MODULE__{class: class} = agent, %{"action" => name} = action, raise?) do
    case perform(class, name, agent, action) do
      :unknown -> unknown(agent, name, raise?)
      agent -> agent
    end
  end

  ## SurfaceAgent: a sensor crawling over a surface

  defp perform("SurfaceAgent", "move_forward", agent, action),
    do: move(agent, -action["distance"], 2)

  # Orbit horizontally, then face where the policy aimed: a sideways move, a yaw,
  # then the forward part of the orbit.
  defp perform("SurfaceAgent", "orient_horizontal", agent, action) do
    agent
    |> move(-action["left_distance"], 0)
    |> yaw(-action["rotation_degrees"])
    |> move(-action["forward_distance"], 2)
  end

  defp perform("SurfaceAgent", "orient_vertical", agent, action) do
    agent
    |> move(-action["down_distance"], 1)
    |> pitch(action["rotation_degrees"])
    |> move(-action["forward_distance"], 2)
  end

  # A tangential move is in the world already — the policy rotated the direction
  # itself — so it is not turned again here.
  defp perform("SurfaceAgent", "move_tangentially", agent, %{"distance" => distance})
       when distance == 0.0,
       do: agent

  defp perform("SurfaceAgent", "move_tangentially", agent, action) do
    [x, y, z] = action["direction"]
    distance = action["distance"]
    [px, py, pz] = agent.position

    %{agent | position: [px + x * distance, py + y * distance, pz + z * distance]}
  end

  defp perform("SurfaceAgent", "set_agent_pose", agent, action),
    do: set_pose(agent, action["location"], action["rotation_quat"])

  defp perform("SurfaceAgent", "set_sensor_rotation", agent, action),
    do: set_sensor_rotation(agent, action["rotation_quat"])

  ## DistantAgent: a camera looking at objects from a distance

  defp perform("DistantAgent", "move_forward", agent, action),
    do: move(agent, -action["distance"], 2)

  defp perform("DistantAgent", "turn_right", agent, action),
    do: yaw(agent, -action["rotation_degrees"])

  defp perform("DistantAgent", "turn_left", agent, action),
    do: yaw(agent, action["rotation_degrees"])

  defp perform("DistantAgent", "look_up", agent, action),
    do: pitch_head(agent, action["rotation_degrees"], action["constraint_degrees"])

  defp perform("DistantAgent", "look_down", agent, action),
    do: pitch_head(agent, -action["rotation_degrees"], action["constraint_degrees"])

  defp perform("DistantAgent", "set_agent_pose", agent, action),
    do: set_pose(agent, action["location"], action["rotation_quat"])

  defp perform("DistantAgent", "set_sensor_rotation", agent, action),
    do: set_sensor_rotation(agent, action["rotation_quat"])

  ## An agent that responds to nothing, which is the point of it

  defp perform(_class, _name, _agent, _action), do: :unknown

  defp unknown(agent, name, true) do
    raise RuntimeError, "#{agent.class} does not understand 'actuate_#{name}'"
  end

  defp unknown(agent, _name, false), do: agent

  ## Movement

  # A step along one of the body's own axes, in world coordinates.
  defp move(agent, distance, axis) do
    {x, y, z} = Orientation.axis(agent.rotation, axis)
    [px, py, pz] = agent.position

    %{agent | position: [px + x * distance, py + y * distance, pz + z * distance]}
  end

  # Yaw turns anticlockwise about y, so a clockwise turn is a negation of its
  # angle and the two are one line.
  defp yaw(agent, degrees),
    do: %{agent | rotation: Orientation.multiply(agent.rotation, Orientation.about_y(degrees))}

  defp pitch(agent, degrees),
    do: %{agent | rotation: Orientation.multiply(agent.rotation, Orientation.about_x(degrees))}

  # The head's pitch is clamped rather than refused: an action may take it as far
  # as the constraint allows, and no further, which keeps it inside its range
  # instead of refusing to move at all.
  defp pitch_head(agent, degrees, nil),
    do: %{agent | pitch_degrees: agent.pitch_degrees + degrees}

  defp pitch_head(agent, degrees, constraint) do
    asked = agent.pitch_degrees + degrees

    cond do
      asked > constraint -> %{agent | pitch_degrees: constraint}
      asked < -constraint -> %{agent | pitch_degrees: -constraint}
      true -> %{agent | pitch_degrees: asked}
    end
  end

  # A full orientation is accepted for the head but only its x angle survives: the
  # head is a hinge, so it can pitch and nothing else.
  defp set_sensor_rotation(agent, rotation) do
    %{agent | pitch_degrees: rotation |> quaternion() |> Orientation.euler_x() |> degrees()}
  end

  defp set_pose(agent, location, rotation) do
    %{agent | position: floats(location), rotation: quaternion(rotation)}
  end

  defp quaternion([_, _, _, _] = values), do: List.to_tuple(floats(values))
  defp quaternion(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> quaternion()
  defp floats(values), do: Enum.map(values, &(&1 * 1.0))
  defp degrees(radians), do: radians * 180.0 / :math.pi()

  @doc """
  The seven `qpos` numbers of the free joint, then the one of the head's hinge.
  """
  @spec qpos(t()) :: {non_neg_integer(), [float()], non_neg_integer(), [float()]}
  def qpos(agent) do
    counter_clockwise = agent.pitch_degrees * :math.pi() / 180.0

    {agent.free, agent.position ++ Tuple.to_list(agent.rotation), agent.pitch,
     [counter_clockwise]}
  end

  @doc """
  Where each sensor sits, relative to the agent, and how it is turned.

  Only the head's pitch moves, which is Monty's assumption: a sensor's pose on the
  agent cannot change, so what a model is told is the head's own rotation applied
  to the sensor's configured place.
  """
  @spec sensor_poses(t()) :: %{optional(String.t()) => map()}
  def sensor_poses(agent) do
    relative = Orientation.about_x(agent.pitch_degrees)

    Map.new(agent.sensors, fn {sensor_id, config} ->
      position = Orientation.rotate(relative, floats(config["position"] || [0.0, 0.0, 0.0]))

      {sensor_id, %{"position" => position, "rotation" => Tuple.to_list(relative)}}
    end)
  end
end
