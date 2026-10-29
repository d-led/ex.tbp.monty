defmodule Monty.Experiment.SensorModule.ExperimentSensorModule do
  @moduledoc """
  The transform-pipeline sensor module, plus resetting its transforms.

  Mirrors `tbp/monty/experiment/sensor_module.py::ExperimentSensorModule`: the
  same step as `Monty.SensorModules.SensorModule`, but a reset also resets every
  transform that keeps state. This is the class Monty's surf experiments give
  their **view finder** — a camera that measures the scene for the motor system
  and sends no percept at all (its config's `transforms` list is empty).

  ## Why this is a module and not a subclass

  Python subclasses `SensorModule`; an Elixir struct cannot. So the step and the
  state belong to `Monty.SensorModules.SensorModule`, and this module is the
  sensor the runtime is told to call: the same functions, and one that differs
  (`reset/1`). Same shape as §2.9 — a wrapper class becomes a module that
  dispatches, not a copied implementation.
  """

  use Monty.Frameworks.Models.AbstractMontyClasses.SensorModule

  alias Monty.SensorModules.SensorModule

  @target "tbp.monty.experiment.sensor_module.ExperimentSensorModule"

  @doc """
  The sensor a config entry describes, or why it is not this class's.

  Monty's entry: `sensor_module_id`, `sensor_id` and `transforms`. A transform
  the config names is only built when this port has written it — an empty list is
  the common case and the one every shipped surf config uses.
  """
  @spec from_config(map()) :: {:ok, SensorModule.t()} | {:error, term()}
  def from_config(%{} = config) do
    with :ok <- check_target(Map.get(config, "_target_", @target)),
         {:ok, sensor_id} <- sensor_id(config),
         {:ok, transforms} <- transforms(config) do
      {:ok,
       SensorModule.new(
         Map.get(config, "sensor_module_id", sensor_id),
         sensor_id,
         transforms
       )}
    end
  end

  defp check_target(@target), do: :ok
  defp check_target(target), do: {:error, {:unsupported_sensor_module, target}}

  defp sensor_id(%{"sensor_id" => sensor_id}), do: {:ok, sensor_id}
  defp sensor_id(_config), do: {:error, :sensor_id_missing}

  # A config may name classes this port has not written, and a sensor that
  # silently ran without them would measure something else than the experiment
  # asked for. `GaussianSmoothing`, `GaussianBlurRGB` and
  # `AddNoiseToRawDepthImage` are still to come.
  defp transforms(%{"transforms" => []}), do: {:ok, []}

  defp transforms(%{"transforms" => transforms}) when is_list(transforms),
    do: {:error, {:unsupported_transforms, Enum.map(transforms, &Map.get(&1, "_target_"))}}

  defp transforms(_config), do: {:error, :transforms_missing}

  @doc "The same sensor module, built from its parts."
  @spec new(atom() | String.t(), atom() | String.t(), [SensorModule.transform()]) ::
          SensorModule.t()
  def new(sensor_module_id, sensor_id, transforms),
    do: SensorModule.new(sensor_module_id, sensor_id, transforms)

  @impl true
  defdelegate update_state(agent, sm), to: SensorModule

  @impl true
  defdelegate step(observation, motor_only?, ctx, sm), to: SensorModule

  @impl true
  defdelegate propose_goals(sm), to: SensorModule

  @impl true
  defdelegate propose_region(sm), to: SensorModule

  @doc "What this sensor's transforms have written down, as Monty reports it."
  defdelegate state_dict(sm), to: SensorModule

  @impl true
  def reset(%SensorModule{} = sm) do
    sm
    |> SensorModule.reset()
    |> reset_transforms()
  end

  defp reset_transforms(%SensorModule{} = sm) do
    transforms =
      Enum.map(sm.transforms, fn {module, transform} ->
        if function_exported?(module, :reset, 1),
          do: {module, module.reset(transform)},
          else: {module, transform}
      end)

    %SensorModule{sm | transforms: transforms}
  end
end
