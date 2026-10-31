defmodule Monty.Frameworks.Models.SensorModules.ObservationProcessor do
  @moduledoc """
  Turns one camera observation into a CMP message: a location, a surface, and the
  features a learning module matches on.

  Mirrors `tbp/monty/frameworks/models/sensor_modules.py::ObservationProcessor`.
  It is the pure part of `CameraSM` — an observation in, a percept out, no state —
  which is why Monty has it as a class of its own too.

  ## What it reads

  The observation has been through the experiment's transforms, so it carries
  `"semantic_3d"` (one row per pixel: three coordinates and the on-surface mask),
  `"cam_to_world"`, `"rgba"` and `"depth"`. The middle pixel is
  `half + width * half` of the point cloud — Monty's own arithmetic for a square
  patch — and `on_object` is that row's mask.

  ## Which features

  `:features` is the list a config declares, and a feature not in it is not
  computed. That is the point of declaring it: `feature_weights` in a hidden layer
  and the tolerances in graph matching are written against exactly these names,
  and a percept carrying more would be one Monty's modules never see.
  `:object_coverage`, `:min_depth` and `:mean_depth` are taken over the pixels on
  the surface rather than over the whole patch.

  ## One difference from Monty

  Monty reads `features["object_coverage"]` when a surface sensor's middle pixel
  is off the object, and raises `KeyError` if the config did not ask for that
  feature. Here a missing coverage counts as zero (`docs/monty-bugs.md` §2.10).
  """

  alias Monty.Cmp.Message
  alias Monty.Frameworks.Models.SensorModules.SurfaceNormalMethod
  alias Monty.Frameworks.Utils.SensorProcessing
  alias Monty.Geometry.SurfacePoseVectors

  # Monty's list of the features that come from the curvature fit.
  @curvature_features [
    "principal_curvatures",
    "principal_curvatures_log",
    "gaussian_curvature",
    "mean_curvature",
    "gaussian_curvature_sc",
    "mean_curvature_sc",
    "curvature_for_TM"
  ]

  @enforce_keys [:features, :sensor_module_id]
  defstruct features: [],
            sensor_module_id: nil,
            pc1_is_pc2_threshold: 10.0,
            surface_normal_method: :tls,
            weight_curvature: true,
            is_surface_sm: false

  @type t :: %__MODULE__{
          features: [String.t()],
          sensor_module_id: atom() | String.t(),
          pc1_is_pc2_threshold: float(),
          surface_normal_method: SurfaceNormalMethod.t(),
          weight_curvature: boolean(),
          is_surface_sm: boolean()
        }

  @doc """
  The processor a config describes.

  Options: `:features` and `:sensor_module_id`, then `:pc1_is_pc2_threshold`,
  `:surface_normal_method`, `:weight_curvature` and `:is_surface_sm`, as Monty's
  takes them.
  """
  @spec new(keyword()) :: t()
  def new(options) do
    %__MODULE__{
      features: Keyword.fetch!(options, :features),
      sensor_module_id: Keyword.fetch!(options, :sensor_module_id),
      pc1_is_pc2_threshold: Keyword.get(options, :pc1_is_pc2_threshold, 10.0),
      surface_normal_method:
        SurfaceNormalMethod.new(Keyword.get(options, :surface_normal_method)),
      weight_curvature: Keyword.get(options, :weight_curvature, true),
      is_surface_sm: Keyword.get(options, :is_surface_sm, false)
    }
  end

  @doc """
  The percept one observation makes.

  `{:error, :no_point_cloud}` when the observation never went through the
  depth-to-points transform: there is no surface to report, and inventing one
  would be worse than saying so.
  """
  @spec process(t(), map()) :: {:ok, Message.t()} | {:error, term()}
  def process(%__MODULE__{} = processor, observation) do
    with {:ok, points} <- point_cloud(observation) do
      center_id = center_id(points)
      features = coverage_feature(processor, points)
      [x, y, z, semantic_id] = Enum.at(points, center_id)
      on_object? = semantic_id > 0.0

      {features, morphological_features, valid_signals?} =
        if on_object? or (processor.is_surface_sm and coverage(points) > 0.0),
          do: extract(processor, observation, points, center_id, features),
          else: {features, %{}, false}

      morphological_features =
        if "on_object" in processor.features,
          do: Map.put(morphological_features, "on_object", if(on_object?, do: 1.0, else: 0.0)),
          else: morphological_features

      Message.new(%{
        location: [x, y, z],
        morphological_features: morphological_features,
        non_morphological_features: features,
        confidence: 1.0,
        pass_message: true,
        process_features_in_lm: on_object? and valid_signals?,
        sender_id: to_string(processor.sensor_module_id),
        sender_type: :sm,
        # The centre pixel's semantic id, which is Monty's `_semantic_id`: the
        # world sends it with the point's coordinates, which are floats, and a
        # semantic id is an integer — the id of an object, or 0 for background.
        semantic_id: trunc(semantic_id)
      })
    end
  end

  # The patch's points. One row per pixel, in Monty's order, which is what the
  # transform answers when the experiment asks it for all of them.
  defp point_cloud(observation) do
    case Map.get(observation, "semantic_3d") do
      [_ | _] = points -> {:ok, points}
      _absent -> {:error, :no_point_cloud}
    end
  end

  defp center_id(points) do
    half = div(patch_width(points), 2)
    half + patch_width(points) * half
  end

  defp patch_width(points), do: points |> length() |> :math.sqrt() |> round()

  defp on_surface?(row), do: List.last(row) > 0.0

  # The share of the patch on the surface the camera is pointed at.
  defp coverage(points), do: Enum.count(points, &on_surface?/1) / length(points)

  # Coverage is read before the surface is fitted, because a surface sensor is
  # allowed to report features with its middle pixel off the object as long as
  # some of the patch is on it (`sensor_modules.py:216-222`).
  defp coverage_feature(%__MODULE__{features: wanted}, points) do
    if "object_coverage" in wanted, do: %{"object_coverage" => coverage(points)}, else: %{}
  end

  # The two depths, over the pixels on the surface rather than over the whole
  # image: a pixel that returned a depth but is not on an object is scenery, and a
  # sensor watching scenery is not on the object — the difference is what a
  # surface agent's search turns on (`sensor_modules.py:308-312`).
  defp depth_features(%__MODULE__{features: wanted}, observation, points) do
    depths = observation |> Map.get("depth") |> List.flatten()
    mask = Enum.map(points, &on_surface?/1)

    on_surface = for {depth, true} <- Enum.zip(depths, mask), do: depth

    %{"min_depth" => Enum.min(on_surface, fn -> nil end), "mean_depth" => mean(on_surface)}
    |> Map.take(wanted)
  end

  # -- the fitted surface ----------------------------------------------------

  defp extract(processor, observation, points, center_id, features) do
    {normal, valid_normal?} =
      SensorProcessing.surface_normal_total_least_squares(
        points,
        center_id,
        view_direction(observation)
      )

    {first, second, direction_1, direction_2, valid_curvatures?} =
      SensorProcessing.principal_curvatures(points, center_id, normal,
        weighted: processor.weight_curvature
      )

    morphological_features = %{
      "pose_vectors" => SurfacePoseVectors.new(normal, direction_1, direction_2),
      "pose_fully_defined" => abs(first - second) >= processor.pc1_is_pc2_threshold
    }

    features =
      features
      |> Map.merge(depth_features(processor, observation, points))
      |> with_colour(processor, observation)
      |> with_curvatures(processor, first, second, valid_normal?, valid_curvatures?)

    {features, morphological_features, valid_normal? and valid_curvatures?}
  end

  defp with_colour(features, processor, observation) do
    pixel = observation |> Map.get("rgba") |> middle_pixel()

    features
    |> maybe_put("rgba" in processor.features and pixel != nil, "rgba", pixel)
    |> maybe_put(
      "hsv" in processor.features and pixel != nil,
      "hsv",
      pixel && SensorProcessing.rgb2hsv(Enum.take(pixel, 3))
    )
  end

  # Monty only fits curvatures when it could fit a normal, and only reports them
  # when the fit answered. When either falls through it flags the percept with a
  # `pose_fully_defined` of false — in the features rather than among the
  # morphological ones, which is reproduced as it stands
  # (`docs/monty-bugs.md` §1.10).
  defp with_curvatures(features, processor, first, second, valid_normal?, valid_curvatures?) do
    cond do
      not wants_curvatures?(processor) or not valid_normal? ->
        Map.put(features, "pose_fully_defined", false)

      valid_curvatures? ->
        curvature_features(features, processor, first, second)

      true ->
        features
    end
  end

  defp wants_curvatures?(%__MODULE__{features: features}),
    do: Enum.any?(features, &(&1 in @curvature_features))

  defp curvature_features(features, %__MODULE__{features: wanted}, first, second) do
    features
    |> maybe_put("principal_curvatures" in wanted, "principal_curvatures", [first, second])
    |> maybe_put(
      "principal_curvatures_log" in wanted,
      "principal_curvatures_log",
      SensorProcessing.log_sign([first, second])
    )
    |> maybe_put("gaussian_curvature" in wanted, "gaussian_curvature", first * second)
    |> maybe_put("mean_curvature" in wanted, "mean_curvature", (first + second) / 2.0)
    |> maybe_put(
      "gaussian_curvature_sc" in wanted,
      "gaussian_curvature_sc",
      SensorProcessing.scale_clip(first * second, 4096.0)
    )
    |> maybe_put(
      "mean_curvature_sc" in wanted,
      "mean_curvature_sc",
      SensorProcessing.scale_clip((first + second) / 2.0, 256.0)
    )
  end

  # The camera's own forward in the world: the third column of the frame the
  # transform left, which is what a surface normal is aligned with
  # (`sensor_modules.py:366`).
  defp view_direction(observation) do
    case Map.get(observation, "cam_to_world") do
      [top, middle, bottom | _rest] -> [Enum.at(top, 2), Enum.at(middle, 2), Enum.at(bottom, 2)]
      _no_frame -> [0.0, 0.0, -1.0]
    end
  end

  # The middle cell of an image: the pixel a sensor reports its colour at
  # (`center_row_col = rgba_feat.shape[0] // 2`).
  defp middle_pixel(image) when is_list(image) and image != [] do
    row = Enum.at(image, div(length(image), 2))
    Enum.at(row, div(length(row), 2))
  end

  defp middle_pixel(_no_image), do: nil

  defp maybe_put(map, true, key, value), do: Map.put(map, key, value)
  defp maybe_put(map, false, _key, _value), do: map

  defp mean([]), do: nil
  defp mean(values), do: Enum.sum(values) / length(values)
end
