defmodule Monty.Test.WorldSensor do
  @moduledoc """
  A sensor module that reports what its world reports, without estimating a
  surface.

  The runtime's plumbing tests walk a surface built as a `"value"` that rises
  along +x, over a world with no geometry in it, and they are about routing
  percepts, not about sensing: how many reach a learning module, what a vote
  does, whether an episode ends. The ported stack
  (`Monty.Frameworks.Models.SensorModules.ObservationProcessor`) needs a point
  cloud and answers real features, which is a different question — it is tested
  against a world with a sphere in it, and against a patch whose surface is known.

  So this is the sensor those tests use: a location, the world's `"value"`, and
  the pose the fixture's graphs are built from. It is a stub, and it lives in
  `test/support` so that nothing in `lib/` mistakes it for a port.
  """

  use Monty.Frameworks.Models.AbstractMontyClasses.SensorModule

  alias Monty.Cmp.Message
  alias Monty.Geometry.SurfacePoseVectors

  # The pose the fixture's graphs are built from: a surface facing +z, with its
  # two curvature directions along x and y.
  @pose_vectors SurfacePoseVectors.new([0.0, 0.0, 1.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0])

  @type state :: %{sensor_module_id: atom() | String.t()}

  @spec new(atom() | String.t()) :: state()
  def new(sensor_module_id), do: %{sensor_module_id: sensor_module_id}

  @impl true
  def update_state(_agent_state, state), do: state

  @impl true
  def step(observation, motor_only?, _ctx, state) do
    message = %{
      location: Map.get(observation, "location", [0.0, 0.0, 0.0]),
      morphological_features: %{
        "pose_vectors" => @pose_vectors,
        "pose_fully_defined" => true,
        "on_object" => 1.0
      },
      non_morphological_features: %{"value" => Map.get(observation, "value", 0.0)},
      confidence: 1.0,
      pass_message: not motor_only?,
      process_features_in_lm: true,
      sender_id: to_string(state.sensor_module_id),
      sender_type: :sm
    }

    case Message.new(message) do
      {:ok, percept} -> {percept, state}
      {:error, _reason} -> {nil, state}
    end
  end

  @impl true
  def reset(state), do: state
end
