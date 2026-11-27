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

  # A transform that records the context and the payload it was given, and
  # answers the same payload: Monty's `MagicMock` with a `return_value` of its
  # argument.
  defmodule Passes do
    @moduledoc false
    @behaviour Monty.SensorModules.SensorModule.Transform

    defstruct [:name]

    def new(name), do: %__MODULE__{name: name}

    @impl true
    def call(%__MODULE__{name: name}, ctx, %Payload{} = payload) do
      send(self(), {:passed, name, ctx, payload})
      {payload, %__MODULE__{name: name}}
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

  # -- Monty's own cases ---------------------------------------------------

  # Monty's `tests/unit/sensor_modules/sensor_module_test.py`. Its cases assert
  # on `MagicMock` call arguments and on `sentinel`s; here two recording
  # transforms stand in — one that passes a payload on untouched, one that
  # answers a percept — and a case asserts the same three things: the context a
  # transform is given, that the next transform receives exactly what the last
  # answered, and what the module reports afterwards.
  describe "Monty's own cases" do
    # test_step_no_transforms_returns_none
    test "an empty pipeline answers no percept" do
      sensor = SensorModule.new("test", "test", [])

      assert {nil, _sensor} = SensorModule.step(observation(), false, ctx(), sensor)
    end

    # test_step_no_transforms_prepares_empty_goals_list_for_propose_goals
    test "and proposes no goals" do
      sensor = SensorModule.new("test", "test", [])
      {_percept, sensor} = SensorModule.step(observation(), false, ctx(), sensor)

      assert {[], _sensor} = SensorModule.propose_goals(sensor)
    end

    # test_step_no_transforms_prepares_empty_region_for_propose_region
    test "and attends to nothing" do
      sensor = SensorModule.new("test", "test", [])
      {_percept, sensor} = SensorModule.step(observation(), false, ctx(), sensor)

      assert {region, _sensor} = SensorModule.propose_region(sensor)
      assert region == AttentionRegion.empty()
    end

    # test_step_no_transforms_prepares_empty_telemetry_for_payload
    test "and has nothing written down" do
      sensor = SensorModule.new("test", "test", [])
      {_percept, sensor} = SensorModule.step(observation(), false, ctx(), sensor)

      assert SensorModule.state_dict(sensor) == %{}
    end

    # test_step_invokes_transforms_in_order
    test "each transform is given the context, and the payload the one before it answered" do
      sensor =
        SensorModule.new("test", "test", [
          {Passes, Passes.new(:first)},
          {Passes, Passes.new(:second)}
        ])

      agent = agent_at([0.0, 0.0, 0.0], Rotation.identity(), [0.0, 0.0, 0.0])
      sensor = SensorModule.update_state(agent, sensor)

      {_percept, _sensor} = SensorModule.step(observation(), false, ctx(), sensor)

      assert_receive {:passed, :first, first_ctx, first_payload}
      assert_receive {:passed, :second, second_ctx, second_payload}

      assert first_payload.observation == observation()
      assert first_payload.percept == nil
      assert first_payload.goals == []
      assert first_payload.region == nil
      assert first_payload.telemetry == %{}

      # What the first answered is what the second was given, unchanged.
      assert second_payload == first_payload

      for given <- [first_ctx, second_ctx] do
        assert given.agent_state == agent
        assert given.sensor_state == sensor.sensor_state
        assert given.motor_only_step == false
        assert given.suppress_runtime_errors == ctx().suppress_runtime_errors
        assert given.rng == Context.rng_for(ctx(), "test")
      end
    end

    # test_step_returns_last_transforms_payload_percept
    test "the percept a step answers is the last transform's" do
      sensor =
        SensorModule.new("test", "test", [
          {Passes, Passes.new(:first)},
          {SendsPercept, SendsPercept.new([1.0, 2.0, 3.0])}
        ])

      {percept, _sensor} = SensorModule.step(observation(), false, ctx(), sensor)

      assert percept.location == [1.0, 2.0, 3.0]

      assert_receive {:passed, :first, _ctx, %Payload{observation: observation}}
      assert observation == observation()
    end

    # test_step_prepares_last_transforms_payload_goals_for_propose_goals
    test "the goals it proposes are the last payload's" do
      sensor = SensorModule.new("test", "test", [{RecordsGoals, RecordsGoals.new()}])

      {_percept, sensor} = SensorModule.step(observation(), false, ctx(), sensor)

      assert {[%Goal{} = goal], _sensor} = SensorModule.propose_goals(sensor)
      assert goal.location == [1.0, 2.0, 3.0]
    end

    # test_step_prepares_last_transforms_payload_region_for_propose_region
    test "the region it proposes is the last payload's" do
      sensor = SensorModule.new("test", "test", [{RecordsGoals, RecordsGoals.new()}])

      {_percept, sensor} = SensorModule.step(observation(), false, ctx(), sensor)

      assert {region, _sensor} = SensorModule.propose_region(sensor)
      assert region == AttentionRegion.empty()
    end

    # test_step_prepares_last_transforms_payload_telemetry_for_state_dict
    test "the telemetry it reports is the last payload's" do
      sensor = SensorModule.new("test", "test", [{RecordsGoals, RecordsGoals.new()}])

      {_percept, sensor} = SensorModule.step(observation(), false, ctx(), sensor)

      assert SensorModule.state_dict(sensor) == %{seen: :a_point}
    end

    # test_update_state_stores_agent_state_as_is
    test "the agent's state is kept as the step gave it" do
      agent = agent_at([1.0, 2.0, 3.0], Rotation.identity(), [0.0, 0.0, 0.0])
      sensor = SensorModule.update_state(agent, SensorModule.new("test", "test", []))

      assert sensor.agent_state == agent
    end

    # test_update_state_stores_sensor_state_in_global_reference_frame
    test "and this sensor's pose is kept in the global frame" do
      {:ok, turned} = Rotation.from_euler_degrees([10.0, 20.0, 30.0])

      agent =
        agent_at([1.0, -2.0, 0.5], turned, [0.25, 0.0, -0.1])

      sensor = SensorModule.update_state(agent, SensorModule.new("test", "test", []))

      # The agent's own pose applied to the sensor's, which is Monty's
      # `agent.position + rotate_vectors(agent.rotation, sensor.position)` and
      # `agent.rotation * sensor.rotation`.
      expected_position = add(agent.position, Rotation.apply(turned, [0.25, 0.0, -0.1]))
      expected_rotation = Rotation.multiply(turned, Rotation.identity())

      for {mine, theirs} <- Enum.zip(sensor.sensor_state.position, expected_position) do
        assert_in_delta mine, theirs, 1.0e-9
      end

      assert sensor.sensor_state.rotation == expected_rotation
    end
  end

  defp agent_at(position, rotation, sensor_position) do
    %AgentState{
      position: position,
      rotation: rotation,
      sensors: %{
        "test" => %SensorState{position: sensor_position, rotation: Rotation.identity()}
      }
    }
  end

  defp add(left, right), do: Enum.zip_with(left, right, &(&1 + &2))
end
