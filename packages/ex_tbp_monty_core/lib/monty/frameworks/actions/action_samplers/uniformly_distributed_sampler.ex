defmodule Monty.Frameworks.Actions.ActionSamplers.UniformlyDistributedSampler do
  @moduledoc """
  Makes actions whose parameters are drawn uniformly from configured ranges.

  Mirrors `tbp/monty/frameworks/actions/action_samplers.py::UniformlyDistributedSampler`.
  Turning actions draw their degrees from `:min_rotation_degrees`..
  `:max_rotation_degrees`, moving actions their distance from
  `:min_translation`..`:max_translation`, and the actions that name an absolute
  angle — pitch, yaw — from `:min_absolute_degrees`..`:max_absolute_degrees`.

  Monty's default for `:min_translation` and `:max_translation` is the same
  value, so a default-constructed sampler moves a fixed 5 cm and only the
  turning is random. That looks like an oversight and is reproduced: an
  experiment that wants random distances has to say so.

  ## The quaternion

  `random_quaternion_wxyz/1` is Monty's own construction — two half-angles drawn
  from three uniforms, arranged as `(w, x, y, z)` — not numpy's, so the numbers
  differ from any other uniform-quaternion routine. It is reproduced component
  for component, including the order the three draws are made in, because the
  stream is what a sampler's caller shares.
  """

  alias Monty.Frameworks.Actions.{
    LookDown,
    LookUp,
    MoveForward,
    MoveTangentially,
    OrientHorizontal,
    OrientVertical,
    SetAgentPitch,
    SetAgentPose,
    SetSensorPitch,
    SetSensorPose,
    SetSensorRotation,
    SetYaw,
    TurnLeft,
    TurnRight
  }

  alias Monty.Random.Stream

  defstruct actions: [],
            max_absolute_degrees: 360.0,
            min_absolute_degrees: 0.0,
            max_rotation_degrees: 20.0,
            min_rotation_degrees: 0.0,
            max_translation: 0.05,
            min_translation: 0.05

  @type t :: %__MODULE__{
          actions: [module()],
          max_absolute_degrees: float(),
          min_absolute_degrees: float(),
          max_rotation_degrees: float(),
          min_rotation_degrees: float(),
          max_translation: float(),
          min_translation: float()
        }

  @doc """
  A sampler that draws its parameters from the configured ranges.
  """
  @spec new(keyword()) :: t()
  def new(options \\ []) do
    %__MODULE__{
      actions: Keyword.get(options, :actions, []),
      max_absolute_degrees: Keyword.get(options, :max_absolute_degrees, 360.0),
      min_absolute_degrees: Keyword.get(options, :min_absolute_degrees, 0.0),
      max_rotation_degrees: Keyword.get(options, :max_rotation_degrees, 20.0),
      min_rotation_degrees: Keyword.get(options, :min_rotation_degrees, 0.0),
      max_translation: Keyword.get(options, :max_translation, 0.05),
      min_translation: Keyword.get(options, :min_translation, 0.05)
    }
  end

  # -- the draws ------------------------------------------------------------
  #
  # Each asks the episode's stream, in Monty's order: `rng.uniform(low, high)`
  # is one `Stream.uniform`, and `rng.random(3)` is three `Stream.random` calls,
  # because how many words the stream spends is what the next module draws.

  defp rotation_degrees(%__MODULE__{} = s, stream),
    do: Stream.uniform(stream, s.min_rotation_degrees, s.max_rotation_degrees)

  defp absolute_degrees(%__MODULE__{} = s, stream),
    do: Stream.uniform(stream, s.min_absolute_degrees, s.max_absolute_degrees)

  defp translation(%__MODULE__{} = s, stream),
    do: Stream.uniform(stream, s.min_translation, s.max_translation)

  # Two half-angles from three draws: (w, x, y, z), as Monty arranges them.
  defp random_quaternion_wxyz(stream) do
    [u, v, w] = three(stream)

    {:math.sqrt(1 - u) * :math.sin(2 * :math.pi() * v),
     :math.sqrt(1 - u) * :math.cos(2 * :math.pi() * v),
     :math.sqrt(u) * :math.sin(2 * :math.pi() * w),
     :math.sqrt(u) * :math.cos(2 * :math.pi() * w)}
  end

  defp random_vector_xyz(stream), do: three(stream)

  # Monty draws a tuple of three from one `rng.random(3)`: three draws, in this
  # order, which is what the stream remembers.
  defp three(stream), do: [Stream.random(stream), Stream.random(stream), Stream.random(stream)]

  # -- the fourteen actions -------------------------------------------------

  @doc false
  def sample_look_down(%__MODULE__{} = s, agent_id, stream),
    do: %LookDown{agent_id: agent_id, rotation_degrees: rotation_degrees(s, stream)}

  @doc false
  def sample_look_up(%__MODULE__{} = s, agent_id, stream),
    do: %LookUp{agent_id: agent_id, rotation_degrees: rotation_degrees(s, stream)}

  @doc false
  def sample_move_forward(%__MODULE__{} = s, agent_id, stream),
    do: %MoveForward{agent_id: agent_id, distance: translation(s, stream)}

  @doc false
  def sample_move_tangentially(%__MODULE__{} = s, agent_id, stream) do
    distance = translation(s, stream)
    direction = random_vector_xyz(stream)

    %MoveTangentially{agent_id: agent_id, distance: distance, direction: direction}
  end

  @doc false
  def sample_orient_horizontal(%__MODULE__{} = s, agent_id, stream) do
    degrees = rotation_degrees(s, stream)
    left = translation(s, stream)
    forward = translation(s, stream)

    %OrientHorizontal{
      agent_id: agent_id,
      rotation_degrees: degrees,
      left_distance: left,
      forward_distance: forward
    }
  end

  @doc false
  def sample_orient_vertical(%__MODULE__{} = s, agent_id, stream) do
    degrees = rotation_degrees(s, stream)
    down = translation(s, stream)
    forward = translation(s, stream)

    %OrientVertical{
      agent_id: agent_id,
      rotation_degrees: degrees,
      down_distance: down,
      forward_distance: forward
    }
  end

  @doc false
  def sample_set_agent_pitch(%__MODULE__{} = s, agent_id, stream),
    do: %SetAgentPitch{agent_id: agent_id, pitch_degrees: absolute_degrees(s, stream)}

  @doc false
  def sample_set_agent_pose(%__MODULE__{} = _s, agent_id, stream) do
    location = random_vector_xyz(stream)

    %SetAgentPose{agent_id: agent_id, location: location, rotation_quat: random_quaternion_wxyz(stream)}
  end

  @doc false
  def sample_set_sensor_pitch(%__MODULE__{} = s, agent_id, stream),
    do: %SetSensorPitch{agent_id: agent_id, pitch_degrees: absolute_degrees(s, stream)}

  @doc false
  def sample_set_sensor_pose(%__MODULE__{} = _s, agent_id, stream) do
    location = random_vector_xyz(stream)

    %SetSensorPose{agent_id: agent_id, location: location, rotation_quat: random_quaternion_wxyz(stream)}
  end

  @doc false
  def sample_set_sensor_rotation(%__MODULE__{} = _s, agent_id, stream),
    do: %SetSensorRotation{agent_id: agent_id, rotation_quat: random_quaternion_wxyz(stream)}

  @doc false
  def sample_set_yaw(%__MODULE__{} = s, agent_id, stream),
    do: %SetYaw{agent_id: agent_id, rotation_degrees: absolute_degrees(s, stream)}

  @doc false
  def sample_turn_left(%__MODULE__{} = s, agent_id, stream),
    do: %TurnLeft{agent_id: agent_id, rotation_degrees: rotation_degrees(s, stream)}

  @doc false
  def sample_turn_right(%__MODULE__{} = s, agent_id, stream),
    do: %TurnRight{agent_id: agent_id, rotation_degrees: rotation_degrees(s, stream)}
end
