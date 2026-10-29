defmodule Monty.Experiment.SensorModule.ExperimentSensorModuleTest do
  @moduledoc """
  The view finder's class: the pipeline sensor, plus resetting its transforms.

  Monty's surf experiments give their view finder this class with an empty
  `transforms` list, so what these tests are about is the two things the wrapper
  adds — a reset that reaches the transforms, and a config it can and cannot be
  built from — plus that a step is the pipeline's step, unchanged.
  """

  use ExUnit.Case, async: true

  alias Monty.Context
  alias Monty.Experiment.SensorModule.ExperimentSensorModule
  alias Monty.SensorModules.SensorModule
  alias Monty.SensorModules.SensorModule.Payload

  defmodule CountingTransform do
    @moduledoc false
    # A transform that keeps how much it has seen, which is what a smoothing
    # filter or a background model does — and what a reset has to clear.
    @behaviour Monty.Experiment.SensorModule.ExperimentTransform

    defstruct seen: 0

    def new, do: %__MODULE__{}

    @impl true
    def call(%__MODULE__{seen: seen} = transform, _ctx, %Payload{} = payload) do
      {%Payload{payload | telemetry: Map.put(payload.telemetry, :seen, seen + 1)},
       %__MODULE__{transform | seen: seen + 1}}
    end

    @impl true
    def reset(%__MODULE__{}), do: new()
  end

  defmodule StatelessTransform do
    @moduledoc false
    # A transform with nothing to forget: it implements the plain behaviour, so
    # the wrapper must leave it alone rather than demanding a reset.
    @behaviour Monty.SensorModules.SensorModule.Transform

    defstruct []

    def new, do: %__MODULE__{}

    @impl true
    def call(%__MODULE__{} = transform, _ctx, %Payload{} = payload),
      do: {%Payload{payload | telemetry: %{stateless: true}}, transform}
  end

  describe "the class a config names" do
    test "is built from the surf experiment's view finder entry" do
      assert {:ok, %SensorModule{} = sensor} =
               ExperimentSensorModule.from_config(%{
                 "_target_" => "tbp.monty.experiment.sensor_module.ExperimentSensorModule",
                 "sensor_module_id" => "view_finder",
                 "sensor_id" => "view_finder",
                 "transforms" => []
               })

      assert sensor.sensor_module_id == "view_finder"
      assert sensor.sensor_id == "view_finder"
      assert sensor.transforms == []
    end

    test "declines a sensor another class owns" do
      # So `Setup` can ask each class in turn, as it does for learning modules.
      assert {:error, {:unsupported_sensor_module, _target}} =
               ExperimentSensorModule.from_config(%{
                 "_target_" => "tbp.monty.frameworks.models.sensor_modules.CameraSM",
                 "sensor_module_id" => "patch",
                 "sensor_id" => "patch",
                 "transforms" => []
               })
    end

    test "declines the transforms this port has not written, and names them" do
      # A sensor that silently ran without its pipeline would measure something
      # other than the experiment asked for.
      assert {:error, {:unsupported_transforms, targets}} =
               ExperimentSensorModule.from_config(%{
                 "_target_" => "tbp.monty.experiment.sensor_module.ExperimentSensorModule",
                 "sensor_module_id" => "view_finder",
                 "sensor_id" => "view_finder",
                 "transforms" => [
                   %{"_target_" => "tbp.monty.sensor_modules.transforms.GaussianBlurRGB"}
                 ]
               })

      assert targets == ["tbp.monty.sensor_modules.transforms.GaussianBlurRGB"]
    end

    test "declines an entry with no sensor id, because the agent could not place it" do
      assert {:error, :sensor_id_missing} =
               ExperimentSensorModule.from_config(%{
                 "_target_" => "tbp.monty.experiment.sensor_module.ExperimentSensorModule",
                 "sensor_module_id" => "view_finder",
                 "transforms" => []
               })
    end
  end

  describe "a step" do
    test "is the pipeline's step, and it keeps the transform it leaves behind" do
      sensor =
        ExperimentSensorModule.new("view_finder", "view_finder", [
          {CountingTransform, CountingTransform.new()}
        ])

      {nil, sensor} =
        ExperimentSensorModule.step(%{"depth" => [[0.1]]}, false, Context.new(0), sensor)

      assert [{CountingTransform, %CountingTransform{seen: 1}}] = sensor.transforms
      assert SensorModule.state_dict(sensor) == %{seen: 1}
    end
  end

  describe "reset/1" do
    test "forgets what the payloads set, and resets the transforms that keep state" do
      sensor =
        ExperimentSensorModule.new("view_finder", "view_finder", [
          {CountingTransform, CountingTransform.new()}
        ])

      {_percept, sensor} =
        ExperimentSensorModule.step(%{"depth" => [[0.1]]}, false, Context.new(0), sensor)

      {_percept, sensor} =
        ExperimentSensorModule.step(%{"depth" => [[0.1]]}, false, Context.new(0), sensor)

      assert [{CountingTransform, %CountingTransform{seen: 2}}] = sensor.transforms

      reset = ExperimentSensorModule.reset(sensor)

      # The transform starts the next episode having seen nothing.
      assert [{CountingTransform, %CountingTransform{seen: 0}}] = reset.transforms
      assert SensorModule.state_dict(reset) == %{}
    end

    test "leaves a transform with nothing to forget alone" do
      sensor =
        ExperimentSensorModule.new("view_finder", "view_finder", [
          {StatelessTransform, StatelessTransform.new()}
        ])

      {_percept, sensor} =
        ExperimentSensorModule.step(%{"depth" => [[0.1]]}, false, Context.new(0), sensor)

      reset = ExperimentSensorModule.reset(sensor)

      assert reset.transforms == [{StatelessTransform, StatelessTransform.new()}]
      assert SensorModule.state_dict(reset) == %{}
    end
  end
end
