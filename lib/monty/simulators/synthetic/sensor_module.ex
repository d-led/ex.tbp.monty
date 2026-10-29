defmodule Monty.Simulators.Synthetic.SensorModule do
  @moduledoc """
  A sensor module that turns an observation into a CMP message.

  Stands in for `frameworks/models/sensor_modules.CameraSM` until feature
  extraction is ported: it reads the one-pixel depth and colour images a world
  reports and answers the features Monty's learning modules and policies read —
  the nearest and the mean depth, how much of the view is on the object, the
  colour as hue/saturation/value, and the curvatures as a signed logarithm. The
  surface itself (its normal and its curvatures) is whatever the world says it
  hit: a camera would estimate it from a depth image, and that estimator
  (`sensor_processing.principal_curvatures/5`) is not ported yet.

  It is a simulator-side module (Monty's `simulators/` are not part of the core),
  so it does not appear in the module map — but it implements the same behaviour
  a ported sensor module will.
  """

  use Monty.Frameworks.Models.AbstractMontyClasses.SensorModule
  alias Monty.Cmp.Message
  alias Monty.Frameworks.Utils.SensorProcessing
  alias Monty.Geometry.SurfacePoseVectors

  # Depth 0 is what a depth image has where the camera saw nothing.
  @no_return 0.0

  # A pose that is not the world's, used when the world reports none.
  @undefined_pose {SurfacePoseVectors.new([0.0, 0.0, 1.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]),
                   false}

  @type state :: %{sensor_module_id: atom() | String.t(), pose: map() | nil}

  @spec new(atom() | String.t()) :: state()
  def new(sensor_module_id), do: %{sensor_module_id: sensor_module_id, pose: nil}

  @impl true
  def update_state(agent_state, state), do: %{state | pose: agent_state}

  @impl true
  def step(observation, motor_only?, state) do
    {pose_vectors, pose_defined?} = pose_vectors(observation)
    on_object? = on_object?(observation)

    message = %{
      location: Map.get(observation, "location", [0.0, 0.0, 0.0]),
      morphological_features: %{
        "pose_vectors" => pose_vectors,
        "pose_fully_defined" => pose_defined?,
        "on_object" => if(on_object?, do: 1.0, else: 0.0)
      },
      non_morphological_features: features(observation),
      confidence: 1.0,
      pass_message: not motor_only?,
      process_features_in_lm: on_object?,
      sender_id: to_string(state.sensor_module_id),
      sender_type: :sm
    }

    case Message.new(message) do
      {:ok, percept} -> {percept, state}
      {:error, _reason} -> {nil, state}
    end
  end

  @impl true
  def reset(state), do: %{state | pose: nil}

  defp pose_vectors(%{"pose_vectors" => [normal, direction_1, direction_2]}),
    do: {SurfacePoseVectors.new(normal, direction_1, direction_2), true}

  defp pose_vectors(_observation), do: @undefined_pose

  # What a camera module makes of the view. `principal_curvatures_log` is the
  # signed logarithm, so a convex surface stays negative and a curvature near
  # zero does not run off; `hsv` is the centre pixel, because that is the patch a
  # surface agent matches on.
  defp features(observation) do
    %{"value" => Map.get(observation, "value")}
    |> Map.merge(depth_features(observation))
    |> Map.merge(surface_features(observation))
    |> Map.merge(colour_features(observation))
    |> Enum.reject(fn {_name, value} -> is_nil(value) end)
    |> Map.new()
  end

  # Monty reads these off the *object*: `object_coverage` is the fraction of
  # pixels whose semantic id is not background, and `min_depth`/`mean_depth` are
  # the nearest and mean depth of those pixels only
  # (`sensor_modules.py:213-216`, `308-312`). A pixel that returned a depth but
  # is not on an object is scenery, and a sensor watching scenery is not on the
  # object — the difference is what a surface agent's search turns on.
  defp depth_features(observation) do
    depths = observation |> Map.get("depth", []) |> List.flatten()
    on_object = on_object_depths(observation, depths)

    %{
      "min_depth" => Enum.min(on_object, fn -> nil end),
      "mean_depth" => mean(on_object),
      "object_coverage" => if(depths == [], do: 0.0, else: length(on_object) / length(depths))
    }
  end

  # A world that reports no semantic image reports nothing but the object, so
  # every pixel that returned is on it.
  defp on_object_depths(observation, depths) do
    case observation |> Map.get("semantic", []) |> List.flatten() do
      [] ->
        Enum.reject(depths, &(&1 == @no_return))

      semantics ->
        for {depth, semantic_id} <- Enum.zip(depths, semantics),
            semantic_id > @no_return,
            do: depth
    end
  end

  defp mean([]), do: nil
  defp mean(values), do: Enum.sum(values) / length(values)

  defp surface_features(observation) do
    case Map.get(observation, "principal_curvatures") do
      nil ->
        %{}

      curvatures ->
        %{
          "principal_curvatures" => curvatures,
          "principal_curvatures_log" => SensorProcessing.log_sign(curvatures)
        }
    end
  end

  defp colour_features(observation) do
    case centre(Map.get(observation, "rgba")) do
      [red, green, blue | _alpha] = pixel ->
        %{"rgba" => pixel, "hsv" => SensorProcessing.rgb2hsv([red, green, blue])}

      _no_colour ->
        %{}
    end
  end

  defp centre([pixel]), do: pixel
  defp centre(_not_an_image), do: nil

  # A pixel is on the object when the world's semantic id says so; a world that
  # reports no semantic id is taken to be on it, because everything such a world
  # reports is the thing in front of the sensor.
  defp on_object?(observation) do
    case centre(Map.get(observation, "semantic")) do
      [semantic_id] -> semantic_id > 0.0
      _no_semantics -> Map.get(observation, "on_object", true)
    end
  end
end
