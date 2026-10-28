defmodule Monty.Frameworks.Actions.ActionJSONDecoder do
  @moduledoc """
  The action a map names.

  Mirrors `tbp/monty/frameworks/actions/actions.py::ActionJSONDecoder`, which
  reads a map whose `"action"` key names the action and whose other keys are
  that action's parameters.

  Monty raises `ValueError` for a map with no name, an unknown name, or a
  parameter missing. This answers `{:error, reason}` instead: such a map arrives
  from outside the beam, and a run should be able to say what was wrong with it
  rather than end.

  Quaternions are answered as `{w, x, y, z}` tuples, which is how the structs
  hold them; JSON has no tuples, so Monty converts on the way in as well.
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

  @actions %{
    "look_down" => LookDown,
    "look_up" => LookUp,
    "move_forward" => MoveForward,
    "move_tangentially" => MoveTangentially,
    "orient_horizontal" => OrientHorizontal,
    "orient_vertical" => OrientVertical,
    "set_agent_pitch" => SetAgentPitch,
    "set_agent_pose" => SetAgentPose,
    "set_sensor_pitch" => SetSensorPitch,
    "set_sensor_pose" => SetSensorPose,
    "set_sensor_rotation" => SetSensorRotation,
    "set_yaw" => SetYaw,
    "turn_left" => TurnLeft,
    "turn_right" => TurnRight
  }

  @doc """
  The action `object` describes, or what is wrong with the object.

  `{:error, :missing_action}` for a map with no `"action"` key,
  `{:error, {:unknown_action, name}}` for one naming an action this port does
  not have, and `{:error, {:missing_parameter, name}}` for one that leaves a
  parameter out.
  """
  @spec decode(map()) :: {:ok, Monty.Frameworks.Actions.Action.t()} | {:error, term()}
  def decode(%{"action" => name} = object) do
    case Map.fetch(@actions, name) do
      {:ok, module} -> build(module, object)
      :error -> {:error, {:unknown_action, name}}
    end
  end

  def decode(object), do: {:error, {:missing_action, object}}

  defp build(module, object) do
    with {:ok, fields} <- fields(module, object) do
      {:ok, struct(module, fields)}
    end
  end

  defp fields(LookDown, object),
    do: take(object, [:agent_id, :rotation_degrees, :constraint_degrees])

  defp fields(LookUp, object),
    do: take(object, [:agent_id, :rotation_degrees, :constraint_degrees])

  defp fields(MoveForward, object), do: take(object, [:agent_id, :distance])

  defp fields(MoveTangentially, object), do: take(object, [:agent_id, :distance, :direction])

  defp fields(OrientHorizontal, object),
    do: take(object, [:agent_id, :rotation_degrees, :left_distance, :forward_distance])

  defp fields(OrientVertical, object),
    do: take(object, [:agent_id, :rotation_degrees, :down_distance, :forward_distance])

  defp fields(SetAgentPitch, object), do: take(object, [:agent_id, :pitch_degrees])

  defp fields(SetAgentPose, object),
    do: take_quaternion(object, [:agent_id, :location, :rotation_quat])

  defp fields(SetSensorPitch, object), do: take(object, [:agent_id, :pitch_degrees])

  defp fields(SetSensorPose, object),
    do: take_quaternion(object, [:agent_id, :location, :rotation_quat])

  defp fields(SetSensorRotation, object), do: take_quaternion(object, [:agent_id, :rotation_quat])

  defp fields(SetYaw, object), do: take(object, [:agent_id, :rotation_degrees])

  defp fields(TurnLeft, object), do: take(object, [:agent_id, :rotation_degrees])

  defp fields(TurnRight, object), do: take(object, [:agent_id, :rotation_degrees])

  # Every parameter the action has, or the first one that is missing.
  defp take(object, keys) do
    Enum.reduce_while(keys, {:ok, %{}}, fn key, {:ok, fields} ->
      case Map.fetch(object, Atom.to_string(key)) do
        {:ok, value} -> {:cont, {:ok, Map.put(fields, key, value)}}
        :error -> {:halt, {:error, {:missing_parameter, Atom.to_string(key)}}}
      end
    end)
  end

  defp take_quaternion(object, keys) do
    with {:ok, fields} <- take(object, keys) do
      {:ok, %{fields | rotation_quat: to_tuple(fields.rotation_quat)}}
    end
  end

  # JSON carries a quaternion as four numbers, while a struct holds the tuple;
  # an action read straight out of another struct already has the tuple, and
  # Monty's `tuple(...)` is likewise happy with both.
  defp to_tuple(quaternion) when is_tuple(quaternion), do: quaternion
  defp to_tuple(quaternion) when is_list(quaternion), do: List.to_tuple(quaternion)
end
