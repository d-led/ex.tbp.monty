defmodule Monty.SensorModules.Transforms.Ommatidia do
  @moduledoc """
  A fly's compound eye, as a percept.

  **Not Monty's.** Monty's only sensor module is `CameraSM`, which reads a patch
  of RGBA and depth from a scene it rendered; a fly has neither a patch nor a
  depth. Its eye is 721 ommatidia per side, each reading one of two
  photoreceptor types (yellow and pale, with a zero in the other column), which
  `Monty.Simulators.Flygym.World` hands over as the body's observation. This
  transform turns that into a percept a learning module can store, and
  `docs/monty-differences.md` §2.51 writes down what it decided and why — Monty's
  own tests can be no evidence for any of it.

  ## What a fly's percept is, in Monty's terms

  * **The features are the eye**, flattened: one `"ommatidia"` feature holding
    every reading of both eyes in the body's own order. It is a high-dimensional
    view rather than a patch of pixels, and a graph stores it as one node's
    feature — which is what a view-based distant agent does with what it sees.
  * **The location is the body's own position.** A fly's eye has no depth, so the
    only place a view is *from* is where the fly stands. Inventing a surface
    point would be inventing the one thing a compound eye cannot measure.
  * **The pose vectors are the body's own orientation**, as three orthonormal
    rows, and `pose_fully_defined` is 1: a fly always knows which way it is
    facing, even though it does not know how far away anything is.
  * **`on_object` is 1 and the semantic id is 0.** A fly sees the world and no
    labels: 0 is Monty's own id for "not an object", and claiming otherwise would
    put a name on a patch of sky.

  A body that sends no ommatidia is passed through untouched with no percept —
  the pipeline's answer for a step that has nothing to report, rather than an
  empty message that a model would read as "saw nothing".
  """

  @behaviour Monty.SensorModules.SensorModule.Transform

  alias Monty.Cmp.Message
  alias Monty.Geometry.{OrientationMatrix, Rotation}
  alias Monty.SensorModules.SensorModule.{Payload, TransformContext}

  @feature "ommatidia"

  defstruct sensor_module_id: "ommatidia"

  @type t :: %__MODULE__{sensor_module_id: String.t()}

  @doc """
  The transform, named for the sensor it belongs to.

  A percept says who sent it, and a transform is not told that by the step — so
  the config names it, and the default is the feature's own name.
  """
  @spec new(map()) :: t()
  def new(config \\ %{}) do
    %__MODULE__{sensor_module_id: Map.get(config, "sensor_module_id", "ommatidia")}
  end

  @impl true
  @spec call(t(), TransformContext.t(), Payload.t()) :: {Payload.t(), t()}
  def call(%__MODULE__{} = transform, %TransformContext{} = context, %Payload{} = payload) do
    case readings(payload.observation) do
      {:ok, features} ->
        {%{payload | percept: percept(features, context, transform.sensor_module_id)}, transform}

      :no_eye ->
        {payload, transform}
    end
  end

  # Every eye in the observation, flattened to one feature. Two shapes arrive in
  # practice: a sensor's own observation (what a sensor module is handed, one eye
  # with its `"ommatidia"` readings), and a world's report for an agent (a map of
  # sensor id to that sensor's observation, which is what a body answers for both
  # eyes at once). A sensor that sent no eye contributes nothing rather than
  # zeros: a blind eye and a dark one are not the same observation.
  defp readings(%{"ommatidia" => readings} = _eye) when is_list(readings),
    do: {:ok, List.flatten(readings)}

  defp readings(observation) when is_map(observation) do
    features =
      observation
      |> Map.values()
      |> Enum.flat_map(fn
        %{"ommatidia" => readings} when is_list(readings) -> List.flatten(readings)
        _not_an_eye -> []
      end)

    if features == [], do: :no_eye, else: {:ok, features}
  end

  defp readings(_observation), do: :no_eye

  defp percept(features, %TransformContext{} = context, sensor_module_id) do
    attributes = %{
      location: position(context),
      morphological_features: morphological_features(context),
      non_morphological_features: %{@feature => features},
      confidence: 1.0,
      pass_message: true,
      process_features_in_lm: true,
      sender_id: sensor_module_id,
      sender_type: :sm,
      semantic_id: 0
    }

    case Message.new(attributes) do
      {:ok, message} ->
        message

      {:error, reason} ->
        # The pose this transform builds is one of Monty's own types and always
        # fully defined, so a refusal here is a defect in this file rather than
        # something an observation can cause.
        raise ArgumentError, "a fly's eye made no valid percept: #{inspect(reason)}"
    end
  end

  # Where the fly stands. The agent's own pose is the only location a compound
  # eye can support: there is no depth to put a surface point at.
  defp position(%TransformContext{agent_state: %{position: position}}), do: position
  defp position(%TransformContext{sensor_state: %{position: position}}), do: position
  defp position(%TransformContext{}), do: [0.0, 0.0, 0.0]

  # The body's own orientation as Monty's distant-agent pose type: a fly looking
  # out knows which way it faces (fully defined) and does not know how far away
  # anything is, which is what an `OrientationMatrix` says and a surface patch's
  # `SurfacePoseVectors` does not.
  defp morphological_features(%TransformContext{sensor_state: %{rotation: rotation}})
       when not is_nil(rotation) do
    %{
      "pose_vectors" => %OrientationMatrix{value: pose_vectors(rotation)},
      "pose_fully_defined" => true,
      "on_object" => 1.0
    }
  end

  defp morphological_features(%TransformContext{agent_state: %{rotation: rotation}})
       when not is_nil(rotation) do
    %{
      "pose_vectors" => %OrientationMatrix{value: pose_vectors(rotation)},
      "pose_fully_defined" => true,
      "on_object" => 1.0
    }
  end

  # A step with no pose is a step with no orientation; saying `on_object` alone is
  # honest, and a learning module that needs vectors says so by refusing.
  defp morphological_features(%TransformContext{}), do: %{"on_object" => 1.0}

  defp pose_vectors(rotation) do
    {w, x, y, z} = Rotation.to_quaternion(rotation)

    [
      [1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y)],
      [2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x)],
      [2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y)]
    ]
  end
end
