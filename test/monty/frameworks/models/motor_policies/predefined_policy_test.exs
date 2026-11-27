defmodule Monty.Frameworks.Models.MotorPolicies.PredefinedPolicyTest do
  use ExUnit.Case, async: true

  alias Monty.Context

  alias Monty.Frameworks.Actions.{
    ActionJSONEncoder,
    LookDown,
    LookUp,
    MoveForward,
    TurnLeft,
    TurnRight
  }

  alias Monty.Frameworks.Models.MotorPolicies.{MotorPolicyResult, PredefinedPolicy}
  alias Monty.Test.Tmp

  @agent "agent_id_0"

  setup do
    %{path: Tmp.file("predefined.jsonl")}
  end

  defp write(path, lines) do
    File.write!(path, Enum.join(lines, "\n") <> "\n")
  end

  defp first_line(action, extra \\ "{}") do
    Jason.encode!(Map.merge(%{"action" => action, "agent_id" => @agent}, Jason.decode!(extra)))
  end

  defp policy(path), do: PredefinedPolicy.new(agent_id: @agent, file: path)

  defp step(policy) do
    PredefinedPolicy.call(policy, Context.new(0), nil, %{}, nil, nil)
  end

  defp action_of(policy) do
    {%MotorPolicyResult{actions: [action]}, policy} = step(policy)
    {action, policy}
  end

  describe "replaying a file" do
    test "each step is the next action in the file", %{path: path} do
      write(path, [
        first_line("turn_left", ~s({"rotation_degrees": 10.0})),
        first_line("look_up", ~s({"rotation_degrees": 20.0, "constraint_degrees": 90.0})),
        first_line("move_forward", ~s({"distance": 0.05}))
      ])

      {first, policy} = action_of(policy(path))
      {second, policy} = action_of(policy)
      {third, _policy} = action_of(policy)

      assert first == %TurnLeft{agent_id: @agent, rotation_degrees: 10.0}
      assert second == %LookUp{agent_id: @agent, rotation_degrees: 20.0}
      assert third == %MoveForward{agent_id: @agent, distance: 0.05}
    end

    test "the file is cycled, not exhausted", %{path: path} do
      write(path, [first_line("turn_left", ~s({"rotation_degrees": 10.0}))])

      actions =
        Enum.map_reduce(1..5, policy(path), fn _step, policy ->
          action_of(policy)
        end)
        |> elem(0)

      assert Enum.all?(actions, &match?(%TurnLeft{rotation_degrees: 10.0}, &1))
    end

    test "blank lines are not actions", %{path: path} do
      write(path, [
        first_line("turn_left", ~s({"rotation_degrees": 10.0})),
        "",
        "   ",
        first_line("look_up", ~s({"rotation_degrees": 20.0, "constraint_degrees": 90.0}))
      ])

      {first, policy} = action_of(policy(path))
      {second, _policy} = action_of(policy)

      assert %TurnLeft{} = first
      assert %LookUp{} = second
    end

    test "the goal, the state, the observations and the percept change nothing", %{path: path} do
      write(path, [first_line("turn_left", ~s({"rotation_degrees": 10.0}))])

      {%MotorPolicyResult{actions: ignored} = _result, _policy} =
        PredefinedPolicy.call(
          policy(path),
          Context.new(0),
          %{some: :observations},
          %{
            @agent => :state
          },
          :a_percept,
          %Monty.Cmp.Goal{sender_id: "LM_0", sender_type: :gsg}
        )

      {%MotorPolicyResult{actions: bare}, _policy} = step(policy(path))

      assert ignored == bare
    end
  end

  describe "a file that is not a replay" do
    test "an empty file is refused when the policy is built", %{path: path} do
      write(path, [])

      assert_raise ArgumentError, ~r/no actions/, fn -> policy(path) end
    end

    test "a line that is not an action names its line", %{path: path} do
      write(path, [first_line("turn_left", ~s({"rotation_degrees": 10.0})), "not json"])

      assert_raise ArgumentError, ~r/line 2/, fn -> policy(path) end
    end

    test "an action this port does not have says which", %{path: path} do
      write(path, [first_line("levitate")])

      assert_raise ArgumentError, ~r/unknown_action/, fn -> policy(path) end
    end
  end

  describe "what it remembers" do
    test "how far into the file it has got", %{path: path} do
      write(path, [first_line("turn_left", ~s({"rotation_degrees": 10.0}))])

      {_action, policy} = action_of(policy(path))

      assert PredefinedPolicy.state_dict(policy) == %{episode_step: 1}
    end

    test "and starts again at the first action when reset", %{path: path} do
      write(path, [
        first_line("turn_left", ~s({"rotation_degrees": 10.0})),
        first_line("look_up", ~s({"rotation_degrees": 20.0, "constraint_degrees": 90.0}))
      ])

      {_first, policy} = action_of(policy(path))
      {_second, policy} = action_of(policy)
      {after_reset, _policy} = action_of(PredefinedPolicy.reset(policy))

      assert %TurnLeft{} = after_reset
    end
  end

  describe "Monty's own cases" do
    # test_read_action_file
    test "the lines are the actions they name, in the order they are written", %{path: path} do
      # Monty writes its own five actions rather than reading a file on disk, so
      # the case knows what it is loading; this is that list, encoded the way the
      # policy reads it.
      expected = [
        %TurnRight{agent_id: @agent, rotation_degrees: 5.0},
        %LookDown{agent_id: @agent, rotation_degrees: 10.0, constraint_degrees: 90.0},
        %TurnLeft{agent_id: @agent, rotation_degrees: 10.0},
        %LookUp{agent_id: @agent, rotation_degrees: 10.0, constraint_degrees: 90.0},
        %TurnRight{agent_id: @agent, rotation_degrees: 5.0}
      ]

      write(
        path,
        Enum.map(expected, &(&1 |> ActionJSONEncoder.encode() |> Jason.encode!()))
      )

      loaded = PredefinedPolicy.read_action_file(path)

      assert length(loaded) == length(expected)

      # Monty compares `dict(loaded) == dict(expected)`: the action as it is
      # written, not the struct whose fields happen to match.
      for {loaded_action, expected_action} <- Enum.zip(loaded, expected) do
        assert ActionJSONEncoder.encode(loaded_action) ==
                 ActionJSONEncoder.encode(expected_action)
      end
    end

    # test_cycles_continuously
    test "a file repeats itself once it is read to its end", %{path: path} do
      # Monty's `motor_policies_test_actions.jsonl`, written here: the same four
      # actions, in the same order.
      write(path, [
        ~s({"action":"turn_right","agent_id":"agent_id_0","rotation_degrees":5.0}),
        ~s({"action":"look_down","agent_id":"agent_id_0","rotation_degrees":5.0,"constraint_degrees":90.0}),
        ~s({"action":"turn_left","agent_id":"agent_id_0","rotation_degrees":5.0}),
        ~s({"action":"look_up","agent_id":"agent_id_0","rotation_degrees":5.0,"constraint_degrees":90.0})
      ])

      policy = policy(path)
      cycle_length = length(policy.action_list)

      # `action_of/1` matches one action exactly, which is Monty's
      # `len(result.actions) == 1` asserted on every step of the cycle.
      returned =
        Enum.map_reduce(1..(2 * cycle_length), policy, fn _step, policy ->
          action_of(policy)
        end)
        |> elem(0)

      assert length(returned) == 2 * cycle_length

      for i <- 0..(cycle_length - 1) do
        assert Enum.at(returned, i) == Enum.at(returned, i + cycle_length)
      end
    end
  end
end
