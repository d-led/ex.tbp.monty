defmodule Monty.Simulators.Synthetic.SensorModule do
  @moduledoc """
  A sensor module that turns an observation into a CMP message.

  Stands in for `frameworks/models/sensor_modules.CameraSM` until that class is
  ported: it reads the depth, colour and mask images a world reports and answers
  the features Monty's learning modules and policies read — the nearest and the
  mean depth over the pixels on the surface, the share of the patch that is on
  it, the colour at the middle of the view as hue/saturation/value, and the
  curvatures as a signed logarithm.

  The definitions are Monty's own: coverage and the depths come from the mask
  the depth-to-points transform left in `"semantic_3d"`, and the middle of the
  view is the pixel a sensor reports its location and colour at. The surface
  itself — its normal and its curvatures — is still what the world says it hit.
  A camera estimates those from the patch (`sensor_processing.principal_curvatures/5`),
  which is the next thing to port; until then this is the one place where the
  stand-in world knows more than a sensor could.

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

  # Monty reads these over the pixels that are **on the surface** the camera is
  # pointed at: `object_coverage` is the share of `"semantic_3d"`'s rows whose
  # mask column is not zero, and `min_depth`/`mean_depth` are the nearest and
  # mean depth of the pixels those rows came from
  # (`sensor_modules.py:213-218`, `308-312`). A pixel that returned a depth but
  # is not on an object is scenery, and a sensor watching scenery is not on the
  # object — the difference is what a surface agent's search turns on.
  defp depth_features(observation) do
    depths = observation |> Map.get("depth") |> image_cells()

    on_surface =
      for {depth, mask} <- Enum.zip(depths, on_surface(observation, depths)),
          mask > 0.0,
          do: depth

    %{
      "min_depth" => Enum.min(on_surface, fn -> nil end),
      "mean_depth" => mean(on_surface),
      "object_coverage" => if(depths == [], do: 0.0, else: length(on_surface) / length(depths))
    }
  end

  # Which pixels the transform kept as on the surface. `"semantic_3d"` carries
  # that mask as its fourth column; an observation that never went through the
  # transform is read from its semantic image instead, and a world with no
  # semantics at all reports nothing but the object, so every pixel that
  # returned a depth is on it.
  defp on_surface(observation, depths) do
    case Map.get(observation, "semantic_3d") do
      points when is_list(points) and points != [] and length(points) == length(depths) ->
        Enum.map(points, &List.last/1)

      _absent_or_partial ->
        case observation |> Map.get("semantic") |> image_cells() do
          [] -> Enum.map(depths, &if(&1 == @no_return, do: 0.0, else: 1.0))
          semantics -> Enum.map(semantics, &if(&1 > 0.0, do: 1.0, else: 0.0))
        end
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
    case middle(Map.get(observation, "rgba")) do
      [red, green, blue | _alpha] = pixel ->
        %{"rgba" => pixel, "hsv" => SensorProcessing.rgb2hsv([red, green, blue])}

      _no_colour ->
        %{}
    end
  end

  # The middle cell of an image: Monty's `center_id`, the pixel a sensor reports
  # its location and its colour at, and the one whose surface the pose vectors
  # belong to. A depth image's middle is a number and a colour image's is a
  # pixel; both are what the middle row and column hold.
  defp middle(image) when is_list(image) and image != [] do
    row = Enum.at(image, div(length(image), 2))
    Enum.at(row, div(length(row), 2))
  end

  defp middle(_no_image), do: nil

  # A pixel is on the object when the mask at the middle of the view says so; a
  # world that reports no semantics is taken to be on it, because everything
  # such a world reports is the thing in front of the sensor.
  defp on_object?(observation) do
    case observation |> Map.get("semantic") |> middle() do
      nil -> Map.get(observation, "on_object", true)
      semantic_id -> semantic_id > 0.0
    end
  end

  defp image_cells(nil), do: []
  defp image_cells(image) when is_list(image), do: List.flatten(image)
end
