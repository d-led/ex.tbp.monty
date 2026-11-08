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

  alias Monty.Frameworks.Actions.ActionSamplers

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

  defp rotation_degrees(%__MODULE__{} = s, rng),
    do: ActionSamplers.uniform(rng, s.min_rotation_degrees, s.max_rotation_degrees)

  defp absolute_degrees(%__MODULE__{} = s, rng),
    do: ActionSamplers.uniform(rng, s.min_absolute_degrees, s.max_absolute_degrees)

  defp translation(%__MODULE__{} = s, rng),
    do: ActionSamplers.uniform(rng, s.min_translation, s.max_translation)

  # Two half-angles from three draws: (w, x, y, z), as Monty arranges them.
  defp random_quaternion_wxyz(rng) do
    {[u, v, w], rng} = ActionSamplers.three(rng)

    quaternion =
      {:math.sqrt(1 - u) * :math.sin(2 * :math.pi() * v),
       :math.sqrt(1 - u) * :math.cos(2 * :math.pi() * v),
       :math.sqrt(u) * :math.sin(2 * :math.pi() * w),
       :math.sqrt(u) * :math.cos(2 * :math.pi() * w)}

    {quaternion, rng}
  end

  defp random_vector_xyz(rng) do
    # Monty draws a tuple of three; the order matters to the stream, not the
    # shape, so this keeps the draws in the same order.
    {[x, y, z], rng} = ActionSamplers.three(rng)
    {[x, y, z], rng}
  end

  # -- the fourteen actions -------------------------------------------------

  @doc false
  def sample_look_down(%__MODULE__{} = s, agent_id, rng) do
    {degrees, rng} = rotation_degrees(s, rng)
    {%LookDown{agent_id: agent_id, rotation_degrees: degrees}, rng}
  end

  @doc false
  def sample_look_up(%__MODULE__{} = s, agent_id, rng) do
    {degrees, rng} = rotation_degrees(s, rng)
    {%LookUp{agent_id: agent_id, rotation_degrees: degrees}, rng}
  end

  @doc false
  def sample_move_forward(%__MODULE__{} = s, agent_id, rng) do
    {distance, rng} = translation(s, rng)
    {%MoveForward{agent_id: agent_id, distance: distance}, rng}
  end

  @doc false
  def sample_move_tangentially(%__MODULE__{} = s, agent_id, rng) do
    {distance, rng} = translation(s, rng)
    {direction, rng} = random_vector_xyz(rng)

    {%MoveTangentially{agent_id: agent_id, distance: distance, direction: direction}, rng}
  end

  @doc false
  def sample_orient_horizontal(%__MODULE__{} = s, agent_id, rng) do
    {degrees, rng} = rotation_degrees(s, rng)
    {left, rng} = translation(s, rng)
    {forward, rng} = translation(s, rng)

    {%OrientHorizontal{
       agent_id: agent_id,
       rotation_degrees: degrees,
       left_distance: left,
       forward_distance: forward
     }, rng}
  end

  @doc false
  def sample_orient_vertical(%__MODULE__{} = s, agent_id, rng) do
    {degrees, rng} = rotation_degrees(s, rng)
    {down, rng} = translation(s, rng)
    {forward, rng} = translation(s, rng)

    {%OrientVertical{
       agent_id: agent_id,
       rotation_degrees: degrees,
       down_distance: down,
       forward_distance: forward
     }, rng}
  end

  @doc false
  def sample_set_agent_pitch(%__MODULE__{} = s, agent_id, rng) do
    {degrees, rng} = absolute_degrees(s, rng)
    {%SetAgentPitch{agent_id: agent_id, pitch_degrees: degrees}, rng}
  end

  @doc false
  def sample_set_agent_pose(%__MODULE__{} = _s, agent_id, rng) do
    {location, rng} = random_vector_xyz(rng)
    {rotation_quat, rng} = random_quaternion_wxyz(rng)
    {%SetAgentPose{agent_id: agent_id, location: location, rotation_quat: rotation_quat}, rng}
  end

  @doc false
  def sample_set_sensor_pitch(%__MODULE__{} = s, agent_id, rng) do
    {degrees, rng} = absolute_degrees(s, rng)
    {%SetSensorPitch{agent_id: agent_id, pitch_degrees: degrees}, rng}
  end

  @doc false
  def sample_set_sensor_pose(%__MODULE__{} = _s, agent_id, rng) do
    {location, rng} = random_vector_xyz(rng)
    {rotation_quat, rng} = random_quaternion_wxyz(rng)
    {%SetSensorPose{agent_id: agent_id, location: location, rotation_quat: rotation_quat}, rng}
  end

  @doc false
  def sample_set_sensor_rotation(%__MODULE__{} = _s, agent_id, rng) do
    {rotation_quat, rng} = random_quaternion_wxyz(rng)
    {%SetSensorRotation{agent_id: agent_id, rotation_quat: rotation_quat}, rng}
  end

  @doc false
  def sample_set_yaw(%__MODULE__{} = s, agent_id, rng) do
    {degrees, rng} = absolute_degrees(s, rng)
    {%SetYaw{agent_id: agent_id, rotation_degrees: degrees}, rng}
  end

  @doc false
  def sample_turn_left(%__MODULE__{} = s, agent_id, rng) do
    {degrees, rng} = rotation_degrees(s, rng)
    {%TurnLeft{agent_id: agent_id, rotation_degrees: degrees}, rng}
  end

  @doc false
  def sample_turn_right(%__MODULE__{} = s, agent_id, rng) do
    {degrees, rng} = rotation_degrees(s, rng)
    {%TurnRight{agent_id: agent_id, rotation_degrees: degrees}, rng}
  end
end
