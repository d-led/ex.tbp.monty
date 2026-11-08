defmodule Monty.Cmp do
  @moduledoc """
  The cortical messaging protocol: one payload for observed states,
  hypothesized states and goals.

  Mirrors `tbp/monty/cmp.py`. Everything that crosses a module boundary in
  Monty is a `Monty.Cmp.Message` (or a `Monty.Cmp.Goal`), which is what makes
  arbitrary module configurations — `sm_to_lm_matrix`, `lm_to_lm_matrix`,
  `lm_to_lm_vote_matrix` — expressible as wiring rather than code.

  Two representations live here:

    * the structs (`Message`, `Goal`, `AttentionRegion`), used in the runtime;
    * the wire form, plain maps with string keys, used for persistence, the
      step inspector in the UI, and the simulator sidecar.

  The wire form is deliberately close to Monty's own `ActionJSONEncoder` /
  message dictionaries so a Python fixture can be compared field by field.
  """

  alias Monty.Cmp.{AttentionRegion, Goal, Message}
  alias Monty.Geometry.{GazeDirection, OrientationMatrix, SurfacePoseVectors}

  @typedoc "Anything that can travel on the CMP."
  @type message :: Message.t() | Goal.t() | AttentionRegion.t()

  @sender_types %{sm: "SM", lm: "LM", gsg: "GSG"}

  @doc """
  Mean of the messages' locations, or `nil` when no message has a location.

  Mirrors `cmp.location_mean`: a missing location is not zero, and the mean of
  an empty list is not a point.
  """
  @spec location_mean([Message.t() | Goal.t()]) :: [float()] | nil
  def location_mean(messages) do
    messages
    |> Enum.map(& &1.location)
    |> Enum.reject(&is_nil/1)
    |> average()
  end

  @doc """
  The wire form of a CMP payload.

  Pose vectors keep their type: a `SurfacePoseVectors` and an
  `OrientationMatrix` are both 3×3, and confusing them rotates a reference
  frame by 90 degrees without any number looking wrong.
  """
  @spec encode(message()) :: map()
  def encode(%Message{} = message),
    do: message |> Map.from_struct() |> Map.put(:kind, "message") |> encode_map()

  def encode(%Goal{} = goal),
    do: goal |> Map.from_struct() |> Map.put(:kind, "goal") |> encode_map()

  def encode(%AttentionRegion{} = region) do
    %{"kind" => "attention_region", "locations" => region.locations, "weights" => region.weights}
  end

  @doc """
  Reads a payload produced by `encode/1` back into a struct.

  Validation is the same as construction: a payload that would not have been
  accepted by `Message.new/1` is rejected here too.
  """
  @spec decode(map()) :: {:ok, message()} | {:error, term()}
  def decode(%{"kind" => "message"} = payload), do: payload |> decode_message() |> wrap()
  def decode(%{"kind" => "goal"} = payload), do: payload |> decode_goal() |> wrap()

  def decode(%{"kind" => "attention_region", "locations" => locations, "weights" => weights}) do
    {:ok, %AttentionRegion{locations: locations, weights: weights}}
  end

  def decode(other), do: {:error, {:unknown_payload, other}}

  defp wrap({:ok, value}), do: {:ok, value}
  defp wrap({:error, _reason} = error), do: error

  defp decode_message(payload) do
    Message.new(%{
      location: payload["location"],
      morphological_features: decode_features(payload["morphological_features"]),
      non_morphological_features: decode_features(payload["non_morphological_features"]),
      confidence: payload["confidence"],
      pass_message: payload["pass_message"],
      process_features_in_lm: payload["process_features_in_lm"],
      sender_id: payload["sender_id"],
      sender_type: decode_sender_type(payload["sender_type"]),
      displacement: payload["displacement"],
      semantic_id: payload["semantic_id"]
    })
  end

  defp decode_goal(payload) do
    Goal.new(%{
      location: payload["location"],
      morphological_features: decode_features(payload["morphological_features"]),
      non_morphological_features: decode_features(payload["non_morphological_features"]),
      confidence: payload["confidence"],
      pass_message: payload["pass_message"],
      process_features_in_lm: payload["process_features_in_lm"],
      sender_id: payload["sender_id"],
      sender_type: decode_sender_type(payload["sender_type"]),
      goal_tolerances: payload["goal_tolerances"],
      info: payload["info"] || %{}
    })
  end

  # -- encoding -------------------------------------------------------------

  defp encode_map(struct_map) do
    struct_map
    |> Map.new(fn
      {:sender_type, type} ->
        {"sender_type", Map.fetch!(@sender_types, type)}

      {:morphological_features, features} ->
        {"morphological_features", encode_features(features)}

      {:non_morphological_features, features} ->
        {"non_morphological_features", encode_features(features)}

      {key, value} ->
        {to_string(key), value}
    end)
    |> encode_nested_values()
  end

  defp encode_nested_values(map) do
    Map.new(map, fn {key, value} -> {key, encode_value(value)} end)
  end

  defp encode_features(nil), do: nil

  defp encode_features(features) when is_map(features) do
    Map.new(features, fn {name, value} -> {name, encode_value(value)} end)
  end

  defp encode_value(%SurfacePoseVectors{value: value}),
    do: %{"pose_vectors_type" => "surface_pose_vectors", "value" => value}

  defp encode_value(%OrientationMatrix{value: value}),
    do: %{"pose_vectors_type" => "orientation_matrix", "value" => value}

  defp encode_value(%GazeDirection{value: value}),
    do: %{"pose_vectors_type" => "gaze_direction", "value" => value}

  defp encode_value(%{} = map), do: encode_features(map)

  defp encode_value(list) when is_list(list), do: Enum.map(list, &encode_value/1)

  defp encode_value(other), do: other

  # -- decoding -------------------------------------------------------------

  defp decode_sender_type(type) when is_binary(type) do
    Enum.find_value(@sender_types, type, fn {atom, wire} -> if wire == type, do: atom end)
  end

  defp decode_sender_type(type), do: type

  defp decode_features(nil), do: nil

  defp decode_features(features) when is_map(features) do
    Map.new(features, fn {name, value} -> {name, decode_value(value)} end)
  end

  defp decode_value(%{"pose_vectors_type" => "surface_pose_vectors", "value" => value}),
    do: %SurfacePoseVectors{value: value}

  defp decode_value(%{"pose_vectors_type" => "orientation_matrix", "value" => value}),
    do: %OrientationMatrix{value: value}

  defp decode_value(%{"pose_vectors_type" => "gaze_direction", "value" => value}),
    do: %GazeDirection{value: value}

  defp decode_value(%{} = map), do: decode_features(map)

  defp decode_value(list) when is_list(list), do: Enum.map(list, &decode_value/1)

  defp decode_value(other), do: other

  # -- arithmetic -----------------------------------------------------------

  defp average([]), do: nil

  defp average(locations) do
    count = length(locations)

    [x, y, z] =
      Enum.reduce(locations, [0.0, 0.0, 0.0], fn [x, y, z], [sum_x, sum_y, sum_z] ->
        [sum_x + x, sum_y + y, sum_z + z]
      end)

    [x / count, y / count, z / count]
  end
end
