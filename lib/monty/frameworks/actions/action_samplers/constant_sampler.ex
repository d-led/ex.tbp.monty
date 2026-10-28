defmodule Monty.Frameworks.Actions.ActionSamplers.ConstantSampler do
  @moduledoc """
  Makes actions whose parameters never change.

  Mirrors `tbp/monty/frameworks/actions/action_samplers.py::ConstantSampler`.
  Every parameter is set once, at construction, and every action of a kind is
  identical: `rotation_degrees` for the turning actions,
  `translation_distance` for the moving ones, `direction`, `location` and
  `rotation_quat` for the ones that take a place or an orientation.

  This is the sampler experiments use when the point is the *policy* rather than
  the randomness: a surface agent that always steps 4 mm and turns 5 degrees has
  a reproducible path given a reproducible sequence of action choices.
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

  defstruct actions: [],
            absolute_degrees: 0.0,
            direction: [0.0, 0.0, 0.0],
            location: [0.0, 0.0, 0.0],
            rotation_degrees: 5.0,
            rotation_quat: {1.0, 0.0, 0.0, 0.0},
            translation_distance: 0.004

  @type t :: %__MODULE__{
          actions: [module()],
          absolute_degrees: float(),
          direction: [float()],
          location: [float()],
          rotation_degrees: float(),
          rotation_quat: {float(), float(), float(), float()},
          translation_distance: float()
        }

  @doc """
  A sampler that always makes this step of every action it is asked for.

  `:actions` is which actions it can make; every other option is Monty's
  default and can be overridden per parameter.
  """
  @spec new(keyword()) :: t()
  def new(options \\ []) do
    %__MODULE__{
      actions: Keyword.get(options, :actions, []),
      absolute_degrees: Keyword.get(options, :absolute_degrees, 0.0),
      direction: Keyword.get(options, :direction, [0.0, 0.0, 0.0]),
      location: Keyword.get(options, :location, [0.0, 0.0, 0.0]),
      rotation_degrees: Keyword.get(options, :rotation_degrees, 5.0),
      rotation_quat: Keyword.get(options, :rotation_quat, {1.0, 0.0, 0.0, 0.0}),
      translation_distance: Keyword.get(options, :translation_distance, 0.004)
    }
  end

  # -- the fourteen actions -------------------------------------------------
  #
  # Each answers the action and the stream it was given, unchanged: a constant
  # draws nothing, and pretending otherwise would make the caller's next draw
  # depend on which action came before.

  @doc false
  def sample_look_down(%__MODULE__{} = s, agent_id, rng),
    do: {%LookDown{agent_id: agent_id, rotation_degrees: s.rotation_degrees}, rng}

  @doc false
  def sample_look_up(%__MODULE__{} = s, agent_id, rng),
    do: {%LookUp{agent_id: agent_id, rotation_degrees: s.rotation_degrees}, rng}

  @doc false
  def sample_move_forward(%__MODULE__{} = s, agent_id, rng),
    do: {%MoveForward{agent_id: agent_id, distance: s.translation_distance}, rng}

  @doc false
  def sample_move_tangentially(%__MODULE__{} = s, agent_id, rng) do
    {%MoveTangentially{
       agent_id: agent_id,
       distance: s.translation_distance,
       direction: s.direction
     }, rng}
  end

  @doc false
  def sample_orient_horizontal(%__MODULE__{} = s, agent_id, rng) do
    {%OrientHorizontal{
       agent_id: agent_id,
       rotation_degrees: s.rotation_degrees,
       left_distance: s.translation_distance,
       forward_distance: s.translation_distance
     }, rng}
  end

  @doc false
  def sample_orient_vertical(%__MODULE__{} = s, agent_id, rng) do
    {%OrientVertical{
       agent_id: agent_id,
       rotation_degrees: s.rotation_degrees,
       down_distance: s.translation_distance,
       forward_distance: s.translation_distance
     }, rng}
  end

  @doc false
  def sample_set_agent_pitch(%__MODULE__{} = s, agent_id, rng),
    do: {%SetAgentPitch{agent_id: agent_id, pitch_degrees: s.absolute_degrees}, rng}

  @doc false
  def sample_set_agent_pose(%__MODULE__{} = s, agent_id, rng),
    do:
      {%SetAgentPose{agent_id: agent_id, location: s.location, rotation_quat: s.rotation_quat},
       rng}

  @doc false
  def sample_set_sensor_pitch(%__MODULE__{} = s, agent_id, rng),
    do: {%SetSensorPitch{agent_id: agent_id, pitch_degrees: s.absolute_degrees}, rng}

  @doc false
  def sample_set_sensor_pose(%__MODULE__{} = s, agent_id, rng),
    do:
      {%SetSensorPose{agent_id: agent_id, location: s.location, rotation_quat: s.rotation_quat},
       rng}

  @doc false
  def sample_set_sensor_rotation(%__MODULE__{} = s, agent_id, rng),
    do: {%SetSensorRotation{agent_id: agent_id, rotation_quat: s.rotation_quat}, rng}

  @doc false
  def sample_set_yaw(%__MODULE__{} = s, agent_id, rng),
    do: {%SetYaw{agent_id: agent_id, rotation_degrees: s.absolute_degrees}, rng}

  @doc false
  def sample_turn_left(%__MODULE__{} = s, agent_id, rng),
    do: {%TurnLeft{agent_id: agent_id, rotation_degrees: s.rotation_degrees}, rng}

  @doc false
  def sample_turn_right(%__MODULE__{} = s, agent_id, rng),
    do: {%TurnRight{agent_id: agent_id, rotation_degrees: s.rotation_degrees}, rng}
end
