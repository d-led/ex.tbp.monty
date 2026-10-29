defmodule Monty.Simulators.Synthetic.SensorModule do
  @moduledoc """
  A sensor module that turns an observation into a CMP message.

  Stands in for `frameworks/models/sensor_modules.CameraSM` until feature
  extraction is ported: it reports what the world said rather than inventing it,
  so a world with geometry gives a percept with a surface and a world without
  gives one whose pose is explicitly undefined. It is a simulator-side module
  (Monty's `simulators/` are not part of the core), so it does not appear in the
  module map — but it implements the same behaviour a ported sensor module will.
  """

  use Monty.Frameworks.Models.AbstractMontyClasses.SensorModule
  alias Monty.Cmp.Message
  alias Monty.Frameworks.Utils.SensorProcessing
  alias Monty.Geometry.SurfacePoseVectors

  # The features a world may report, by the names Monty's learning modules and
  # policies read them under.
  @feature_keys ~w(value depth mean_depth min_depth object_coverage principal_curvatures)

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

  # A learning module configured for `principal_curvatures_log` expects the
  # sensor to have scaled the curvatures: a signed logarithm, so that a convex
  # surface stays negative and values near zero do not run off.
  defp features(observation) do
    features = Map.take(observation, @feature_keys)

    case Map.get(features, "principal_curvatures") do
      nil ->
        features

      curvatures ->
        Map.put(features, "principal_curvatures_log", SensorProcessing.log_sign(curvatures))
    end
  end

  # A world that does not say is taken to be on the object: a world without
  # geometry reports everything it has as the thing in front of the sensor.
  defp on_object?(observation), do: Map.get(observation, "on_object", true)
end
