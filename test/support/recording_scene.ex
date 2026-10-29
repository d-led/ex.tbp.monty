defmodule Monty.RecordingScene do
  @moduledoc """
  A scene that records what an interface asked it to do.

  The object interface decides *which* object an episode is about and *what id* it
  gets; adding and removing objects is a scene's job. This scene stands in for one
  so those decisions can be compared with Monty's own: every request is kept in
  order, and `add_object` answers an id the way Monty's world does.
  """

  defstruct calls: [], added: 0

  def remove_all_objects(%__MODULE__{} = scene) do
    %{scene | calls: scene.calls ++ [%{"call" => "remove_all_objects"}]}
  end

  def add_object(%__MODULE__{} = scene, attributes) do
    added = scene.added + 1

    call = %{
      "call" => "add_object",
      "name" => Map.get(attributes, "name"),
      "semantic_id" => Map.get(attributes, "semantic_id"),
      "position" => Map.get(attributes, "position"),
      "rotation" => Map.get(attributes, "rotation"),
      "scale" => Map.get(attributes, "scale"),
      "has_primary_target_object" => Map.get(attributes, "primary_target_object") != nil
    }

    {{:object, added}, %{scene | calls: scene.calls ++ [call], added: added}}
  end
end
