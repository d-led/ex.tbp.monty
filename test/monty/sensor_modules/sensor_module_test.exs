defmodule Monty.SensorModules.SensorModuleTest do
  @moduledoc """
  A sensor module that is whatever sequence of transforms its config names.

  The classes under test here have no opinion about patches or cameras: a step
  is a payload passed down a pipeline. So the tests are about the pipeline —
  what a transform is given, what the last one's answer becomes, and what the
  module reports when nothing in it made a percept.
  """

  use ExUnit.Case, async: true

  alias Monty.Cmp.{AttentionRegion, Goal, Message}
  alias Monty.Context
  alias Monty.Frameworks.Models.MotorSystemState.{AgentState, SensorState}
  alias Monty.Geometry.{Rotation, SurfacePoseVectors}
  alias Monty.SensorModules.SensorModule
  alias Monty.SensorModules.SensorModule.{Payload, TransformContext}

  defmodule SendsPercept do
    @moduledoc false
    # The transform a camera-like sensor would have: reads the observation and
    # answers a percept, recording what it was given on the way.
    @behaviour Monty.SensorModules.SensorModule.Transform

    defstruct location: [0.0, 0.0, 0.0]

    def new(location), do: %__MODULE__{location: location}

    @impl true
    def call(%__MODULE__{location: location}, ctx, %Payload{} = payload) do
      send(self(), {:transform, :sends_percept, ctx, payload})

      {:ok, percept} =
        Message.new(%{
          location: location,
          morphological_features: %{
            "pose_vectors" =>
              SurfacePoseVectors.new([0.0, 0.0, 1.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]),
            "pose_fully_defined" => false,
            "on_object" => 1.0
          },
          sender_id: "sensor",
          sender_type: :sm
        })

      {%Payload{payload | percept: percept}, %__MODULE__{location: location}}
    end
  end

  defmodule RecordsGoals do
    @moduledoc false
    # A transform that only writes down what it wants next time: the shape a
    # salience module's pipeline has.
    @behaviour Monty.SensorModules.SensorModule.Transform

    defstruct []

    def new, do: %__MODULE__{}

    @impl true
    def call(%__MODULE__{}, _ctx, %Payload{} = payload) do
      {:ok, goal} = Goal.new(sender_id: "patch", sender_type: :sm, location: [1.0, 2.0, 3.0])

      payload = %Payload{
        payload
        | goals: [goal],
          region: AttentionRegion.empty(),
          telemetry: Map.put(payload.telemetry, :seen, :a_point)
      }

      {payload, %__MODULE__{}}
    end
  end

  describe "a sensor whose pipeline is empty" do
    test "answers no percept at all" do
      # Monty's view finder: a camera that measures the scene for the motor
      # system, with no transform that would turn an observation into a percept.
      sensor = SensorModule.new("view_finder", "view_finder", [])

      assert {nil, _sensor} = SensorModule.step(observation(), false, ctx(), sensor)
    end
  end

  describe "a step" do
    test "hands each transform the observation as the pipeline's first payload" do
      sensor =
        SensorModule.new("patch", "patch", [{SendsPercept, SendsPercept.new([1.0, 2.0, 3.0])}])

      SensorModule.step(observation(), false, ctx(), sensor)

      assert_receive {:transform, :sends_percept, _ctx, %Payload{observation: observation}}
      assert observation == observation()
    end

    test "answers the percept the last transform made" do
      sensor =
        SensorModule.new("patch", "patch", [{SendsPercept, SendsPercept.new([1.0, 2.0, 3.0])}])

      {percept, _sensor} = SensorModule.step(observation(), false, ctx(), sensor)

      assert percept.location == [1.0, 2.0, 3.0]
    end

    test "runs the transforms in the order the config gives them" do
      sensor =
        SensorModule.new("patch", "patch", [
          {SendsPercept, SendsPercept.new([1.0, 0.0, 0.0])},
          {RecordsGoals, RecordsGoals.new()}
        ])

      {percept, sensor} = SensorModule.step(observation(), false, ctx(), sensor)

      # The second transform saw the first one's percept, and passed it on.
      assert percept.location == [1.0, 0.0, 0.0]
      assert [%Goal{}] = sensor.goals
    end
  end

  describe "the context a transform is given" do
    test "carries the agent's pose, this sensor's pose and the step's two flags" do
      agent = %AgentState{
        position: [1.0, 2.0, 3.0],
        rotation: Rotation.identity(),
        sensors: %{
          "patch" => %SensorState{position: [0.0, 0.0, 0.1], rotation: Rotation.identity()}
        }
      }

      sensor =
        SensorModule.new("patch", "patch", [{SendsPercept, SendsPercept.new([0.0, 0.0, 0.0])}])

      sensor = SensorModule.update_state(agent, sensor)
      {_percept, sensor} = SensorModule.step(observation(), true, ctx(), sensor)

      assert sensor.sensor_state.position == [1.0, 2.0, 3.1]
      assert sensor.agent_state == agent
    end

    test "carries the flags and this sensor's stream for the step" do
      sensor =
        SensorModule.new("patch", "patch", [{SendsPercept, SendsPercept.new([0.0, 0.0, 0.0])}])

      SensorModule.step(observation(), true, %{ctx() | suppress_runtime_errors: true}, sensor)

      assert_receive {:transform, :sends_percept, %TransformContext{} = ctx, _payload}
      assert ctx.motor_only_step
      assert ctx.suppress_runtime_errors

      # The same seed and step give the same stream, which is what makes a
      # transform that samples reproducible.
      assert ctx.rng == Context.rng_for(ctx(), "patch")
    end
  end

  describe "what the module reports" do
    test "proposes the goals and region its last payload set" do
      sensor = SensorModule.new("patch", "patch", [{RecordsGoals, RecordsGoals.new()}])

      {_percept, sensor} = SensorModule.step(observation(), false, ctx(), sensor)

      {goals, sensor} = SensorModule.propose_goals(sensor)
      assert [%Goal{}] = goals
      assert {region, _sensor} = SensorModule.propose_region(sensor)
      assert region == AttentionRegion.empty()
    end

    test "attends to nothing when no transform claimed a region" do
      sensor = SensorModule.new("patch", "patch", [])

      assert {region, _sensor} = SensorModule.propose_region(sensor)
      assert region == AttentionRegion.empty()
    end

    test "keeps the telemetry its transforms wrote, and forgets it for the next episode" do
      sensor = SensorModule.new("patch", "patch", [{RecordsGoals, RecordsGoals.new()}])

      {_percept, sensor} = SensorModule.step(observation(), false, ctx(), sensor)
      assert SensorModule.state_dict(sensor) == %{seen: :a_point}

      reset = SensorModule.reset(sensor)
      assert SensorModule.state_dict(reset) == %{}
      assert reset.goals == []
      assert reset.region == nil
    end
  end

  describe "the sensor's pose" do
    test "is refused when the agent has no such sensor" do
      # The sensor's own `sensor_id` names it, which for a view finder is not
      # always its module id.
      agent = %AgentState{position: [0.0, 0.0, 0.0], rotation: Rotation.identity(), sensors: %{}}

      assert_raise ArgumentError, ~r/has no sensor/, fn ->
        SensorModule.update_state(agent, SensorModule.new("patch", "view_finder", []))
      end
    end
  end

  defp ctx, do: Context.new(0)

  defp observation, do: %{"depth" => [[0.1]]}
end
