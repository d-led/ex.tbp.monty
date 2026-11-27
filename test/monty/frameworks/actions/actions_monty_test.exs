defmodule Monty.Frameworks.Actions.ActionsMontyTest do
  @moduledoc """
  Monty's own cases for the actions, translated.

  Each test names the cases in `tests/unit/frameworks/actions/actions_test.py` it
  translates. The fixtures are Monty's: one action per class with the values its
  `setUp` gives it, and the dict its `test_dict` case asserts against.

  ## What could not be translated

  Twenty-eight of Monty's eighty-four cases are the `test_delegates_to_sample_*`
  and `test_delegates_to_actuate_*` pairs, one of each per class: `Action.sample/3`
  hands the call to a sampler's `sample_<action>`, and `Action.act/2` hands it to
  an actuator's `actuate_<action>`. The port has neither on an action, and the
  module map says why in the same words: sampling is the samplers' own
  `sample_<action>` functions and acting is the carried world's, reached through
  `Monty.Simulators.Port`, so `*ActionSampler` and `*Actuator` are `:excluded`
  entries. A case that asserts a delegation to an object the port does not have
  cannot be translated; asserted against the samplers and the port, it would be a
  different case about different modules, with those modules' own tests as its
  home.
  """

  # excluded test_delegates_to_sample_look_down: an action has no sampler to delegate to
  # excluded test_delegates_to_actuate_look_down: an action has no actuator to delegate to
  # excluded test_delegates_to_sample_look_up: an action has no sampler to delegate to
  # excluded test_delegates_to_actuate_look_up: an action has no actuator to delegate to
  # excluded test_delegates_to_sample_move_forward: an action has no sampler to delegate to
  # excluded test_delegates_to_actuate_move_forward: an action has no actuator to delegate to
  # excluded test_delegates_to_sample_move_tangentially: an action has no sampler to delegate to
  # excluded test_delegates_to_actuate_move_tangentially: an action has no actuator to delegate to
  # excluded test_delegates_to_sample_orient_horizontal: an action has no sampler to delegate to
  # excluded test_delegates_to_actuate_orient_horizontal: an action has no actuator to delegate to
  # excluded test_delegates_to_sample_orient_vertical: an action has no sampler to delegate to
  # excluded test_delegates_to_actuate_orient_vertical: an action has no actuator to delegate to
  # excluded test_delegates_to_sample_set_agent_pitch: an action has no sampler to delegate to
  # excluded test_delegates_to_actuate_set_agent_pitch: an action has no actuator to delegate to
  # excluded test_delegates_to_sample_set_agent_pose: an action has no sampler to delegate to
  # excluded test_delegates_to_actuate_set_agent_pose: an action has no actuator to delegate to
  # excluded test_delegates_to_sample_set_sensor_pitch: an action has no sampler to delegate to
  # excluded test_delegates_to_actuate_set_sensor_pitch: an action has no actuator to delegate to
  # excluded test_delegates_to_sample_set_sensor_pose: an action has no sampler to delegate to
  # excluded test_delegates_to_actuate_set_sensor_pose: an action has no actuator to delegate to
  # excluded test_delegates_to_sample_set_sensor_rotation: an action has no sampler to delegate to
  # excluded test_delegates_to_actuate_set_sensor_rotation: an action has no actuator to delegate to
  # excluded test_delegates_to_sample_set_yaw: an action has no sampler to delegate to
  # excluded test_delegates_to_actuate_set_yaw: an action has no actuator to delegate to
  # excluded test_delegates_to_sample_turn_left: an action has no sampler to delegate to
  # excluded test_delegates_to_actuate_turn_left: an action has no actuator to delegate to
  # excluded test_delegates_to_sample_turn_right: an action has no sampler to delegate to
  # excluded test_delegates_to_actuate_turn_right: an action has no actuator to delegate to

  use ExUnit.Case, async: true

  alias Monty.Frameworks.Actions.{
    ActionJSONDecoder,
    ActionJSONEncoder,
    LookDown,
    LookUp,
    MoveForward,
    MoveTangentially,
    OrientHorizontal,
    OrientVertical,
    SetAgentPitch,
    SetAgentPose,
    SetSensorPitch,
    SetSensorPose,
    SetSensorRotation,
    SetYaw,
    TurnLeft,
    TurnRight
  }

  @agent "test"

  # Monty's fixtures, class by class: the action its `setUp` builds and the dict
  # its `test_dict` case asserts. The dict's `"action"` is the class's name, as
  # Monty writes `self.action.name`.
  @actions [
    {LookDown, %LookDown{agent_id: @agent, rotation_degrees: 47.0, constraint_degrees: 90.0},
     %{
       "action" => "look_down",
       "agent_id" => @agent,
       "rotation_degrees" => 47.0,
       "constraint_degrees" => 90.0
     }},
    {LookUp, %LookUp{agent_id: @agent, rotation_degrees: 77.0, constraint_degrees: 90.0},
     %{
       "action" => "look_up",
       "agent_id" => @agent,
       "rotation_degrees" => 77.0,
       "constraint_degrees" => 90.0
     }},
    {MoveForward, %MoveForward{agent_id: @agent, distance: 1},
     %{"action" => "move_forward", "agent_id" => @agent, "distance" => 1}},
    {MoveTangentially,
     %MoveTangentially{agent_id: @agent, distance: 1, direction: [1.0, 2.0, 3.0]},
     %{
       "action" => "move_tangentially",
       "agent_id" => @agent,
       "distance" => 1,
       "direction" => [1.0, 2.0, 3.0]
     }},
    {OrientHorizontal,
     %OrientHorizontal{
       agent_id: @agent,
       rotation_degrees: 90.0,
       left_distance: 1,
       forward_distance: 1
     },
     %{
       "action" => "orient_horizontal",
       "agent_id" => @agent,
       "rotation_degrees" => 90.0,
       "left_distance" => 1,
       "forward_distance" => 1
     }},
    {OrientVertical,
     %OrientVertical{
       agent_id: @agent,
       rotation_degrees: 90.0,
       down_distance: 1,
       forward_distance: 1
     },
     %{
       "action" => "orient_vertical",
       "agent_id" => @agent,
       "rotation_degrees" => 90.0,
       "down_distance" => 1,
       "forward_distance" => 1
     }},
    {SetAgentPitch, %SetAgentPitch{agent_id: @agent, pitch_degrees: 90.0},
     %{"action" => "set_agent_pitch", "agent_id" => @agent, "pitch_degrees" => 90.0}},
    {SetAgentPose,
     %SetAgentPose{
       agent_id: @agent,
       location: [1.0, 2.0, 3.0],
       rotation_quat: {1.0, 2.0, 3.0, 4.0}
     },
     %{
       "action" => "set_agent_pose",
       "agent_id" => @agent,
       "location" => [1.0, 2.0, 3.0],
       "rotation_quat" => {1.0, 2.0, 3.0, 4.0}
     }},
    {SetSensorPitch, %SetSensorPitch{agent_id: @agent, pitch_degrees: 90.0},
     %{
       "action" => "set_sensor_pitch",
       "agent_id" => @agent,
       "pitch_degrees" => 90.0
     }},
    {SetSensorPose,
     %SetSensorPose{
       agent_id: @agent,
       location: [1.0, 2.0, 3.0],
       rotation_quat: {1.0, 2.0, 3.0, 4.0}
     },
     %{
       "action" => "set_sensor_pose",
       "agent_id" => @agent,
       "location" => [1.0, 2.0, 3.0],
       "rotation_quat" => {1.0, 2.0, 3.0, 4.0}
     }},
    {SetSensorRotation, %SetSensorRotation{agent_id: @agent, rotation_quat: {1.0, 2.0, 3.0, 4.0}},
     %{
       "action" => "set_sensor_rotation",
       "agent_id" => @agent,
       "rotation_quat" => {1.0, 2.0, 3.0, 4.0}
     }},
    {SetYaw, %SetYaw{agent_id: @agent, rotation_degrees: 90.0},
     %{"action" => "set_yaw", "agent_id" => @agent, "rotation_degrees" => 90.0}},
    {TurnLeft, %TurnLeft{agent_id: @agent, rotation_degrees: 90.0},
     %{"action" => "turn_left", "agent_id" => @agent, "rotation_degrees" => 90.0}},
    {TurnRight, %TurnRight{agent_id: @agent, rotation_degrees: 90.0},
     %{"action" => "turn_right", "agent_id" => @agent, "rotation_degrees" => 90.0}}
  ]

  # test_dict (one case per action class in Monty's file)
  test "the dict form is the action's name, then every parameter" do
    for {module, action, expected} <- @actions do
      assert module.to_map(action) == expected
    end
  end

  # test_json_serialization (one case per action class)
  test "an action survives the wire, field for field" do
    for {module, action, _expected} <- @actions do
      decoded = action |> ActionJSONEncoder.encode() |> ActionJSONDecoder.decode()

      assert {:ok, ^action} = decoded,
             "#{inspect(module)} did not come back: #{inspect(decoded)}"
    end
  end

  # test_action_name_is_class_name_in_snake_case
  # test_name_is_class_name_in_snake_case
  test "an action's name is its class's name in snake case" do
    for {module, _action, expected} <- @actions do
      snake = module |> Module.split() |> List.last() |> Macro.underscore()

      assert module.name() == snake
      assert expected["action"] == snake
    end
  end

  # test_rotation_degrees_returns_configured_rotation_degrees
  # test_rotation_returns_configured_rotation
  # test_pitch_degrees_returns_configured_pitch_degrees
  # test_location_returns_configured_location
  # test_direction_returns_configured_direction
  # test_distance_returns_configured_distance
  # test_left_distance_returns_configured_left_distance
  # test_down_distance_returns_configured_down_distance
  # test_forward_distance_returns_configured_forward_distance
  # test_agent_id_returns_configured_agent_id
  test "every parameter Monty's dict names is a field of the action, holding that value" do
    for {module, action, expected} <- @actions,
        {key, value} <- expected,
        key != "action" do
      field = String.to_existing_atom(key)

      assert Map.fetch!(action, field) == value,
             "#{inspect(module)} carries #{inspect(Map.get(action, field))} for #{key}, " <>
               "not #{inspect(value)}"
    end
  end

  # test_constraint_degrees_returns_90_degrees_by_default
  test "a look that was not told how far it may go stops at ninety degrees" do
    assert %LookDown{agent_id: @agent, rotation_degrees: 47.0}.constraint_degrees == 90.0
    assert %LookUp{agent_id: @agent, rotation_degrees: 77.0}.constraint_degrees == 90.0
  end

  # test_constraint_degrees_returns_configured_constraint_degrees
  test "a limit an action was given is the limit it keeps" do
    assert %LookDown{
             agent_id: @agent,
             rotation_degrees: 47.0,
             constraint_degrees: 45.0
           }.constraint_degrees == 45.0

    assert %LookUp{
             agent_id: @agent,
             rotation_degrees: 77.0,
             constraint_degrees: 45.0
           }.constraint_degrees == 45.0
  end
end
