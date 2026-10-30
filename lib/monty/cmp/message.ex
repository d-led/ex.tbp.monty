defmodule Monty.Cmp.Message do
  @moduledoc """
  A message in Monty's cortical messaging protocol (CMP).

  Mirrors `tbp/monty/cmp.py::Message`. The same payload represents an observed
  state (from a sensor module), a hypothesized state (from a learning module)
  or a goal (from a goal generator) — the receiver decides how to read it.

  Differences from the Python class, on purpose:

    * `sender_type` is an atom (`:sm | :lm`) here and the strings `"SM"`/`"LM"`
      on the wire (`Monty.Cmp.encode/1`), so a typo is a compile-time warning
      rather than a runtime assertion.
    * Construction returns `{:ok, message} | {:error, reason}` instead of
      raising, because messages are built inside supervised processes whose job
      is to keep the run alive.
    * Vectors are plain lists (`[x, y, z]`, `[[x, y, z], ...]`), the shape Nx
      and JSON both read without conversion.
  """

  alias Monty.Geometry
  alias Monty.Geometry.{GazeDirection, OrientationMatrix, SurfacePoseVectors}

  @enforce_keys [:morphological_features, :sender_id, :sender_type]
  defstruct location: nil,
            morphological_features: %{},
            non_morphological_features: %{},
            confidence: 1.0,
            pass_message: true,
            process_features_in_lm: true,
            sender_id: nil,
            sender_type: nil,
            displacement: nil

  @typedoc """
  Where a message came from. `:gsg` only appears on `Monty.Cmp.Goal`.
  """
  @type sender_type :: :sm | :lm | :gsg

  @type vector :: [float()]
  @type pose_vectors :: SurfacePoseVectors.t() | OrientationMatrix.t() | GazeDirection.t()

  @type t :: %__MODULE__{
          location: vector() | nil,
          morphological_features: %{optional(String.t()) => term()},
          non_morphological_features: %{optional(String.t()) => term()},
          confidence: float(),
          pass_message: boolean(),
          process_features_in_lm: boolean(),
          sender_id: String.t(),
          sender_type: sender_type(),
          displacement: %{optional(String.t()) => term()} | nil
        }

  @allowed_sender_types [:sm, :lm]

  @doc """
  Builds a message, validating the fields the Python class asserts on.

  A location-only message (`process_features_in_lm: false`) may omit the pose
  features; it only synchronises the receiver's sense of where the sensor is.
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    message = struct(__MODULE__, attrs)

    with :ok <- validate_sender_type(message),
         :ok <- validate_confidence(message),
         :ok <- validate_location(message),
         :ok <- validate_features(message) do
      {:ok, message}
    end
  end

  @doc "True when the message was produced by a sensor module."
  @spec from_sensor_module?(t()) :: boolean()
  def from_sensor_module?(%__MODULE__{sender_type: :sm}), do: true
  def from_sensor_module?(%__MODULE__{}), do: false

  @doc """
  Whether the sender believes the sensor is on an object.

  Monty's default is `true` when the feature is absent, because a message that
  says nothing about it came from a sensor that could not tell. The feature
  itself is a number — a sensor module writes `1.0` or `0.0`, a goal generator
  `1` — which Monty's `get_on_object` hands on and every caller only ever asks
  as a question, so the answer here is the question's answer.
  """
  @spec on_object?(t()) :: boolean()
  def on_object?(%__MODULE__{morphological_features: features}) do
    Map.get(features, "on_object", true) not in [false, 0, 0.0]
  end

  @doc "The surface normal, for messages carrying `SurfacePoseVectors`."
  @spec surface_normal(t()) :: {:ok, vector()} | {:error, :no_surface_pose_vectors}
  def surface_normal(%__MODULE__{morphological_features: features}) do
    case Map.fetch(features, "pose_vectors") do
      {:ok, %SurfacePoseVectors{} = pose_vectors} ->
        {:ok, SurfacePoseVectors.surface_normal(pose_vectors)}

      _absent_or_other_type ->
        {:error, :no_surface_pose_vectors}
    end
  end

  @doc "The two principal curvature directions, for `SurfacePoseVectors`."
  @spec curvature_directions(t()) ::
          {:ok, {vector(), vector()}} | {:error, :no_surface_pose_vectors}
  def curvature_directions(%__MODULE__{morphological_features: features}) do
    case Map.fetch(features, "pose_vectors") do
      {:ok, %SurfacePoseVectors{} = pose_vectors} ->
        {:ok,
         {SurfacePoseVectors.principal_curvature_1(pose_vectors),
          SurfacePoseVectors.principal_curvature_2(pose_vectors)}}

      _absent_or_other_type ->
        {:error, :no_surface_pose_vectors}
    end
  end

  @doc """
  Looks a feature up among the morphological and then the non-morphological
  features.
  """
  @spec feature(t(), String.t()) :: {:ok, term()} | {:error, {:feature_not_found, String.t()}}
  def feature(%__MODULE__{} = message, name) do
    %{morphological_features: morphological, non_morphological_features: other} = message

    case Map.fetch(morphological, name) do
      {:ok, value} -> {:ok, value}
      :error -> fetch_or_missing(other, name)
    end
  end

  @doc """
  Applies a translation and/or rotation to the message's pose.

  Mirrors `Message.transform_morphological_features`: the location moves by the
  translation, and the pose vectors are rotated by `rotation * pose_vectors`.
  A `GazeDirection` cannot be rotated — it is a goal direction, not a frame.
  """
  @spec transform_morphological_features(t(), vector() | nil, [[float()]] | nil) ::
          {:ok, t()} | {:error, :gaze_direction_not_transformable}
  def transform_morphological_features(message, translation, rotation) do
    message = translate(message, translation)

    case rotate(message, rotation) do
      {:ok, rotated} -> {:ok, rotated}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Records how the sensor moved since the previous message, and optionally the
  point-pair feature that goes with it.
  """
  @spec set_displacement(t(), vector(), term() | nil) :: t()
  def set_displacement(message, displacement, ppf \\ nil) do
    recorded = %{"displacement" => displacement}
    recorded = if ppf == nil, do: recorded, else: Map.put(recorded, "ppf", ppf)
    %{message | displacement: recorded}
  end

  defp translate(message, nil), do: message

  defp translate(%__MODULE__{location: nil} = message, _translation), do: message

  defp translate(%__MODULE__{location: location} = message, translation) do
    %{message | location: Geometry.add(location, translation)}
  end

  defp rotate(message, nil), do: {:ok, message}

  defp rotate(%__MODULE__{morphological_features: features} = message, rotation) do
    case Map.fetch(features, "pose_vectors") do
      {:ok, %GazeDirection{}} ->
        {:error, :gaze_direction_not_transformable}

      {:ok, %module{value: value}} ->
        rotated = struct(module, value: Geometry.mul(rotation, value))
        {:ok, %{message | morphological_features: Map.put(features, "pose_vectors", rotated)}}

      :error ->
        {:ok, message}
    end
  end

  defp fetch_or_missing(features, name) do
    case Map.fetch(features, name) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:feature_not_found, name}}
    end
  end

  defp validate_sender_type(%__MODULE__{sender_type: type}) when type in @allowed_sender_types,
    do: :ok

  defp validate_sender_type(%__MODULE__{sender_type: type}),
    do: {:error, {:invalid_sender_type, type, @allowed_sender_types}}

  defp validate_confidence(%__MODULE__{confidence: confidence})
       when is_number(confidence) and confidence >= 0 and confidence <= 1,
       do: :ok

  defp validate_confidence(%__MODULE__{confidence: confidence}),
    do: {:error, {:confidence_out_of_range, confidence}}

  defp validate_location(%__MODULE__{location: nil}), do: :ok

  defp validate_location(%__MODULE__{location: [_, _, _] = location}) do
    if Enum.all?(location, &is_number/1), do: :ok, else: {:error, {:invalid_location, location}}
  end

  defp validate_location(%__MODULE__{location: location}),
    do: {:error, {:invalid_location, location}}

  defp validate_features(%__MODULE__{process_features_in_lm: false}), do: :ok

  defp validate_features(%__MODULE__{morphological_features: features}) do
    with {:ok, pose_vectors} <- required(features, "pose_vectors"),
         :ok <- valid_pose_vectors(pose_vectors),
         {:ok, fully_defined} <- required(features, "pose_fully_defined") do
      boolean_field("pose_fully_defined", fully_defined)
    end
  end

  defp required(features, name) do
    case Map.fetch(features, name) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_feature, name}}
    end
  end

  defp valid_pose_vectors(%module{})
       when module in [SurfacePoseVectors, OrientationMatrix, GazeDirection],
       do: :ok

  defp valid_pose_vectors(other), do: {:error, {:invalid_pose_vectors, other}}

  defp boolean_field(_name, value) when is_boolean(value), do: :ok
  defp boolean_field(name, value), do: {:error, {:not_a_boolean, name, value}}
end
