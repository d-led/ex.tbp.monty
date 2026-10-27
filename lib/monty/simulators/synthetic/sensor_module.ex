defmodule Monty.Simulators.Synthetic.SensorModule do
  @moduledoc """
  A sensor module that turns the synthetic observation into a CMP message.

  Stands in for `frameworks/models/sensor_modules.CameraSM` until feature
  extraction is ported. It is a simulator-side module (Monty's `simulators/`
  are not part of the core), so it does not appear in the module map — but it
  implements the same behaviour a ported sensor module will.
  """

  use Monty.Frameworks.Models.AbstractMontyClasses.SensorModule
  alias Monty.Cmp.Message
  alias Monty.Geometry.SurfacePoseVectors

  @type state :: %{sensor_module_id: atom() | String.t(), pose: map() | nil}

  @spec new(atom() | String.t()) :: state()
  def new(sensor_module_id), do: %{sensor_module_id: sensor_module_id, pose: nil}

  @impl true
  def update_state(agent_state, state), do: %{state | pose: agent_state}

  @impl true
  def step(observation, motor_only?, state) do
    message = %{
      location: Map.get(observation, "location", [0.0, 0.0, 0.0]),
      morphological_features: %{
        "pose_vectors" =>
          SurfacePoseVectors.new([0.0, 0.0, 1.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]),
        "pose_fully_defined" => true,
        "on_object" => true
      },
      non_morphological_features: Map.take(observation, ["value"]),
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
  def reset(state), do: %{state | pose: nil}
end
