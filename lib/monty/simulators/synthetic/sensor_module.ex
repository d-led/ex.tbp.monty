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
  the depth-to-points transform left in `"semantic_3d"`, the middle of the view
  is the pixel a sensor reports its location and colour at, and the surface —
  its normal and its two principal curvatures — is **estimated** from that patch
  with `SensorProcessing.surface_normal_total_least_squares/4` and
  `SensorProcessing.principal_curvatures/4`, which is what Monty's `CameraSM`
  does (`sensor_modules.py:288`, `366`). The world therefore reports only what a
  camera reports: depth, colour and semantic id.

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

  # A pose that is not the patch's, used when the patch says nothing about the
  # surface: no points, no plane, or a fit with too little to work on.
  @undefined_pose SurfacePoseVectors.new([0.0, 0.0, 1.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0])

  # Monty's tolerance for calling a surface flat in one direction: two principal
  # curvatures closer than this and their directions carry no information, so
  # `pose_fully_defined` is false (`sensor_modules.py:194`, `290-294`).
  @pc1_is_pc2_threshold 10.0

  @type state :: %{sensor_module_id: atom() | String.t(), pose: map() | nil}

  @spec new(atom() | String.t()) :: state()
  def new(sensor_module_id), do: %{sensor_module_id: sensor_module_id, pose: nil}

  @impl true
  def update_state(agent_state, state), do: %{state | pose: agent_state}

  @impl true
  def step(observation, motor_only?, state) do
    surface = surface(observation)
    on_object? = on_object?(observation)

    message = %{
      location: Map.get(observation, "location", [0.0, 0.0, 0.0]),
      morphological_features: %{
        "pose_vectors" => Map.get(surface, :pose_vectors, @undefined_pose),
        "pose_fully_defined" => Map.get(surface, :pose_fully_defined, false),
        "on_object" => if(on_object?, do: 1.0, else: 0.0)
      },
      non_morphological_features: features(observation, surface),
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

  # The surface at the middle of the view, estimated from the points the
  # depth-to-points transform left: the plane the neighbourhood lies in least
  # badly, and the quadric fitted to it.
  defp surface(observation) do
    with {:ok, points, center_id} <- point_cloud(observation),
         {normal, true} <-
           SensorProcessing.surface_normal_total_least_squares(
             points,
             center_id,
             view_direction(observation)
           ),
         {first, second, direction_1, direction_2, true} <-
           SensorProcessing.principal_curvatures(points, center_id, normal) do
      %{
        pose_vectors: SurfacePoseVectors.new(normal, direction_1, direction_2),
        pose_fully_defined: abs(first - second) >= @pc1_is_pc2_threshold,
        principal_curvatures: [first, second]
      }
    else
      _not_defined -> %{}
    end
  end

  # The patch's points and which row of them is the middle pixel. Monty takes a
  # patch's width from its row count, `obs_dim = int(sqrt(len(obs_3d)))`; the
  # depth image knows its own shape, so this uses that — and needs one row per
  # pixel, which is what asking the transform for all of a patch's points means.
  defp point_cloud(observation) do
    points = Map.get(observation, "semantic_3d", [])
    {height, width} = shape(Map.get(observation, "depth"))

    if points != [] and length(points) == height * width,
      do: {:ok, points, div(height, 2) * width + div(width, 2)},
      else: :no_point_cloud
  end

  defp shape(image) when is_list(image) and image != [], do: {length(image), length(hd(image))}
  defp shape(_no_image), do: {0, 0}

  # The camera's own forward in the world: the third column of the frame the
  # transform left, which is what Monty aligns a surface normal with
  # (`sensor_modules.py:366`).
  defp view_direction(observation) do
    case Map.get(observation, "cam_to_world") do
      [top, middle, bottom | _rest] -> [Enum.at(top, 2), Enum.at(middle, 2), Enum.at(bottom, 2)]
      _no_frame -> [0.0, 0.0, -1.0]
    end
  end

  # What a camera module makes of the view. `principal_curvatures_log` is the
  # signed logarithm, so a convex surface stays negative and a curvature near
  # zero does not run off; `hsv` is the centre pixel, because that is the patch a
  # surface agent matches on.
  defp features(observation, surface) do
    %{"value" => Map.get(observation, "value")}
    |> Map.merge(depth_features(observation))
    |> Map.merge(surface_features(surface))
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

  defp surface_features(%{principal_curvatures: curvatures}) do
    %{
      "principal_curvatures" => curvatures,
      "principal_curvatures_log" => SensorProcessing.log_sign(curvatures)
    }
  end

  defp surface_features(_no_surface), do: %{}

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
