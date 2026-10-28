defmodule Monty.Frameworks.Models.GoalGeneration.GraphGoalGeneratorTest do
  use ExUnit.Case, async: true

  alias Monty.Cmp.{Goal, Message}
  alias Monty.Frameworks.Models.Buffer.FeatureAtLocationBuffer
  alias Monty.Frameworks.Models.GoalGeneration.{GraphGoalGenerator, ParentLMNotProvided}

  defp generator(options \\ []), do: GraphGoalGenerator.new(options)

  # A goal in the only shape this class understands: somewhere to be.
  defp goal(location), do: %Goal{sender_id: "LM_0", sender_type: :lm, location: location}

  defp percept(channel, location) do
    {:ok, message} =
      Message.new(
        location: location,
        morphological_features: %{
          "pose_vectors" =>
            Monty.Geometry.SurfacePoseVectors.new([0.0, 0.0, 1.0], [1.0, 0.0, 0.0], [
              0.0,
              1.0,
              0.0
            ]),
          "pose_fully_defined" => true,
          "on_object" => true
        },
        non_morphological_features: %{},
        confidence: 1.0,
        pass_message: true,
        process_features_in_lm: true,
        sender_id: channel,
        sender_type: :sm
      )

    message
  end

  describe "belonging to a learning module" do
    test "a generator without one says so rather than answering nil" do
      assert_raise ParentLMNotProvided, fn -> GraphGoalGenerator.parent_lm(generator()) end
    end

    test "being given one starts from no goals" do
      parent = %{buffer: FeatureAtLocationBuffer.new()}

      generator =
        generator()
        |> GraphGoalGenerator.set_driving_goal(goal([1.0, 0.0, 0.0]))
        |> GraphGoalGenerator.put_parent_lm(parent)

      assert GraphGoalGenerator.parent_lm(generator) == generator.parent_lm
      assert GraphGoalGenerator.output_goals(generator) == []
      assert generator.driving_goal == nil
    end
  end

  describe "what a generator outputs" do
    test "nothing, until it generates a goal" do
      assert GraphGoalGenerator.output_goals(generator()) == []
    end

    test "the goal it holds, once it holds one" do
      held = goal([0.1, 0.2, 0.3])

      assert GraphGoalGenerator.output_goals(%{
               generator()
               | output_goal: held
             }) == [held]
    end
  end

  describe "whether two messages are different" do
    test "an undefined message says nothing, so it is not a difference" do
      refute GraphGoalGenerator.messages_different?(nil, percept("patch", [0.0, 0.0, 0.0]), %{
               "location" => 0.015
             })

      refute GraphGoalGenerator.messages_different?(percept("patch", [0.0, 0.0, 0.0]), nil, %{
               "location" => 0.015
             })
    end

    test "a message in the same place is not a difference" do
      refute GraphGoalGenerator.messages_different?(
               percept("patch", [0.0, 0.0, 0.0]),
               percept("patch", [0.005, 0.0, 0.0]),
               %{"location" => 0.015}
             )
    end

    test "a message further away than the tolerance is" do
      assert GraphGoalGenerator.messages_different?(
               percept("patch", [0.0, 0.0, 0.0]),
               percept("patch", [0.05, 0.0, 0.0]),
               %{"location" => 0.015}
             )
    end

    test "comparing poses refuses, because symmetry is not handled yet" do
      assert_raise ArgumentError, ~r/symmetries/, fn ->
        GraphGoalGenerator.messages_different?(
          percept("patch", [0.0, 0.0, 0.0]),
          percept("patch", [0.0, 0.0, 0.0]),
          %{"pose_vectors" => 0.1}
        )
      end
    end
  end
end
