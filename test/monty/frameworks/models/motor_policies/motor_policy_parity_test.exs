defmodule Monty.Frameworks.Models.MotorPolicies.MotorPolicyParityTest do
  @moduledoc """
  The motor half answers what Monty's answers: which goal, what turn, what pitch.

  `scripts/record_monty_motor_policy.py` asked Monty's own `LookAtGoal`,
  `highest_confidence_goal`, `SinglePolicySelector` and `DistantPolicySelector`
  over four agent poses and five goal locations, and wrote down the actions they
  produced. These replay them. The salience parity test covers where a view
  finder *wants* to look; this covers what the body is told to do about it, which
  is the last hand-written arithmetic before an action leaves the system.

  Poses arrive as quaternions, not as Euler angles: a rotation vector and a
  sequence of Euler angles are different rotations in general, and what is being
  compared here is `LookAtGoal`, not two ways of reading a pose.
  """

  use ExUnit.Case, async: true

  alias Monty.Cmp.Goal
  alias Monty.Context
  alias Monty.Frameworks.Actions.{ActionSamplers.ConstantSampler, LookUp, MoveForward, TurnLeft}
  alias Monty.Frameworks.Models.MotorPolicies
  alias Monty.Frameworks.Models.MotorPolicies.{BasePolicy, JumpToGoal, MotorPolicyResult}
  alias Monty.Frameworks.Models.MotorPolicySelectors
  alias Monty.Frameworks.Models.MotorPolicySelectors.{DistantPolicySelector, SinglePolicySelector}
  alias Monty.Frameworks.Models.MotorSystemState.{AgentState, SensorState}
  alias Monty.Frameworks.Models.Salience.MotorPolicy.{GoalCollocatedWithSensor, LookAtGoal}
  alias Monty.Geometry.Rotation

  @fixture Path.expand("../../../../fixtures/monty_motor_policy.json", __DIR__)

  # Degrees, well below anything a body could resolve; the recording is float64
  # arithmetic on float64 input.
  @degrees 1.0e-9

  @agent "agent_id_0"
  @sensor "camera_id_0"

  setup_all do
    {:ok, fixture: @fixture |> File.read!() |> Jason.decode!()}
  end

  test "an action is undone by itself with its amount negated", %{fixture: fixture} do
    for %{"action" => recorded, "undo" => expected} <- fixture["undo"] do
      undo = MotorPolicies.undo_last_action(action_from(recorded))

      assert action_fields(undo) == expected,
             "undoing #{recorded["action"]} gave #{inspect(action_fields(undo))}"
    end
  end

  test "an action an informed policy cannot sample has no inverse", %{fixture: fixture} do
    %{"action" => "OrientHorizontal"} = fixture["not_undoable"]

    assert_raise ArgumentError, fn ->
      MotorPolicies.undo_last_action(action_from(fixture["not_undoable"]))
    end
  end

  test "of several goals, the most confident is pursued", %{fixture: fixture} do
    for %{"confidences" => confidences, "chosen" => chosen} <- fixture["highest_confidence_goal"] do
      goals =
        confidences
        |> Enum.with_index()
        |> Enum.map(fn {confidence, index} -> goal([0.0, 0.0, -1.0 - index], confidence) end)

      assert MotorPolicySelectors.highest_confidence_goal(goals) == Enum.at(goals, chosen)
    end
  end

  test "the turn and the pitch are Monty's", %{fixture: fixture} do
    for recorded <- fixture["look_at_goal"] do
      pose_name = recorded["pose"]
      location = recorded["goal"]

      {result, _policy} = look_at(pose(fixture, pose_name), goal(location))

      assert_close(
        actions(result),
        expected_actions(recorded),
        "pose #{pose_name}, goal #{inspect(location)}"
      )
    end
  end

  test "a goal on the sensor is refused", %{fixture: fixture} do
    %{"pose" => pose_name, "goal" => location, "raises" => "GoalCollocatedWithSensor"} =
      fixture["collocated"]

    assert_raise GoalCollocatedWithSensor, fn ->
      look_at(pose(fixture, pose_name), goal(location))
    end
  end

  test "a single policy selector pursues the most confident goal, whatever its sender", %{
    fixture: fixture
  } do
    %{"goals" => recorded, "actions" => expected} = fixture["single_policy_selector"]

    {result, _selector} =
      SinglePolicySelector.call(
        single(),
        Context.new(0),
        nil,
        pose(fixture, "looking straight ahead"),
        nil,
        goals(recorded)
      )

    assert_close(actions(result), expected_actions(%{"actions" => expected}))
  end

  test "a distant agent looks at a sensor module's most confident goal", %{fixture: fixture} do
    %{"goals" => recorded, "actions" => expected} =
      fixture["distant_policy_selector"]["sm_goals"]

    {result, selector} =
      DistantPolicySelector.call(
        distant(),
        Context.new(0),
        nil,
        pose(fixture, "turned thirty degrees"),
        nil,
        goals(recorded)
      )

    assert_close(actions(result), expected_actions(%{"actions" => expected}))
    assert selector.selected_policies == [LookAtGoal]
  end

  test "with no goals the distant agent falls back to its default policy", %{fixture: fixture} do
    %{"consulted_default" => 1, "actions" => []} =
      fixture["distant_policy_selector"]["no_goals"]

    {result, selector} =
      DistantPolicySelector.call(
        distant(),
        Context.new(0),
        nil,
        pose(fixture, "turned thirty degrees"),
        nil,
        []
      )

    assert selector.selected_policies == [BasePolicy]
    assert selector.selected_goals == [nil]
    assert [%MoveForward{}] = result.actions
  end

  # -- fixtures --------------------------------------------------------------

  # The pose Monty was given, rebuilt from the quaternions it was recorded with.
  defp pose(fixture, name) do
    %{
      "agent_position" => position,
      "agent_rotation_wxyz" => agent_rotation,
      "sensor_position" => sensor_position,
      "sensor_rotation_wxyz" => sensor_rotation
    } = Enum.find(fixture["poses"], &(&1["name"] == name))

    %{
      @agent => %AgentState{
        position: position,
        rotation: rotation(agent_rotation),
        sensors: %{
          @sensor => %SensorState{
            position: sensor_position,
            rotation: rotation(sensor_rotation)
          }
        }
      }
    }
  end

  defp rotation(quaternion) do
    {:ok, rotation} = Rotation.from_quaternion(List.to_tuple(quaternion))
    rotation
  end

  defp goal(location, confidence \\ 0.5, sender_type \\ :sm) do
    {:ok, goal} =
      Goal.new(
        location: location,
        confidence: confidence,
        pass_message: false,
        process_features_in_lm: false,
        sender_id: sender_id(sender_type),
        sender_type: sender_type
      )

    goal
  end

  defp sender_id(:sm), do: @sensor
  defp sender_id(:lm), do: "LM_0"

  defp goals(records),
    do: Enum.map(records, &goal(&1["location"], &1["confidence"], sender_type(&1["sender_type"])))

  defp sender_type("SM"), do: :sm
  defp sender_type("LM"), do: :lm
  defp sender_type("GSG"), do: :gsg

  defp look_at(state, goal) do
    LookAtGoal.call(
      LookAtGoal.new(agent_id: @agent, sensor_id: @sensor),
      Context.new(0),
      nil,
      state,
      nil,
      goal
    )
  end

  defp single do
    SinglePolicySelector.new(policy: LookAtGoal.new(agent_id: @agent, sensor_id: @sensor))
  end

  defp distant do
    DistantPolicySelector.new(
      jump_to_goal: JumpToGoal.new(agent_id: @agent, sensor_id: @sensor),
      look_at_goal: LookAtGoal.new(agent_id: @agent, sensor_id: @sensor),
      default:
        BasePolicy.new(
          agent_id: @agent,
          action_sampler: ConstantSampler.new(actions: [MoveForward], translation_distance: 0.05)
        )
    )
  end

  # -- comparing -------------------------------------------------------------

  defp actions(%MotorPolicyResult{actions: actions}),
    do: Enum.map(actions, &{&1.__struct__, &1.rotation_degrees})

  defp expected_actions(%{"actions" => expected}) do
    Enum.map(expected, fn %{"action" => name, "rotation_degrees" => degrees} ->
      {action(name), degrees}
    end)
  end

  defp action("TurnLeft"), do: TurnLeft
  defp action("LookUp"), do: LookUp

  # An action as the fixture records it: the struct, and the fields that tell one
  # action from another.
  defp action_from(%{"action" => name} = record) do
    module = module_of(name)
    known = struct(module)

    attributes =
      record
      |> Map.take([
        "agent_id",
        "rotation_degrees",
        "constraint_degrees",
        "distance",
        "direction",
        "left_distance",
        "forward_distance"
      ])
      |> Enum.map(fn {key, value} -> {String.to_existing_atom(key), value} end)
      |> Enum.filter(fn {key, _value} -> Map.has_key?(known, key) end)

    struct!(module, attributes)
  end

  defp action_fields(action) do
    %{
      "action" => action.__struct__ |> Module.split() |> List.last(),
      "agent_id" => action.agent_id,
      "rotation_degrees" => Map.get(action, :rotation_degrees),
      "constraint_degrees" => Map.get(action, :constraint_degrees),
      "distance" => Map.get(action, :distance),
      "direction" => Map.get(action, :direction)
    }
  end

  defp module_of(name) do
    [__MODULE__, Monty.Frameworks.Actions]
    |> Enum.map(&Module.concat(&1, name))
    |> Enum.find(&Code.ensure_loaded?/1)
    |> case do
      nil -> raise ArgumentError, "no Elixir action named #{name}"
      module -> module
    end
  end

  defp assert_close(actual, expected, label \\ "") do
    assert length(actual) == length(expected),
           "#{label}: expected #{length(expected)} actions, got #{length(actual)}"

    Enum.zip(actual, expected)
    |> Enum.each(fn {{got_action, got_degrees}, {want_action, want_degrees}} ->
      assert got_action == want_action,
             "#{label}: #{inspect(got_action)} is not #{inspect(want_action)}"

      assert_in_delta got_degrees,
                      want_degrees,
                      @degrees,
                      "#{label}: #{got_degrees} is not #{want_degrees}"
    end)
  end
end
