defmodule Monty.Frameworks.Models.GraphMatching.GraphLMTest do
  @moduledoc """
  The graph learning module's four shared answers, and the bookkeeping around
  them.

  The first four cases are translations of Monty's own
  `tests/unit/frameworks/models/graph_matching_test.py`, one case for one case,
  each naming the case it translates. The rest are hand-written intent: Monty
  has no unit test for what a conclusion names, and a test here says what this
  port means by it.
  """

  use ExUnit.Case, async: true

  alias Monty.Cmp.AttentionRegion
  alias Monty.Frameworks.Models.Buffer.FeatureAtLocationBuffer
  alias Monty.Frameworks.Models.GraphMatching.GraphLM
  alias Monty.Test.Messages

  defp lm(options \\ []) do
    GraphLM.new(Keyword.merge([learning_module_id: "LM_0"], options))
  end

  defp goal(location) do
    %Monty.Cmp.Goal{
      location: location,
      morphological_features: %{},
      sender_id: "learning_module",
      sender_type: :lm
    }
  end

  defp processed(%{buffer: buffer} = lm),
    do: %{
      lm
      | buffer: FeatureAtLocationBuffer.update_stats(buffer, %{"lm_processed_steps" => true})
    }

  defp not_processed(%{buffer: buffer} = lm),
    do: %{
      lm
      | buffer: FeatureAtLocationBuffer.update_stats(buffer, %{"lm_processed_steps" => false})
    }

  describe "the goals a module proposes" do
    # `test_returns_gsg_goals_when_last_obs_processed`
    test "returns its goal generator's goals when the last observation was processed" do
      lm = lm()
      goals = [goal([0.1, 0.0, 0.0]), goal([0.2, 0.0, 0.0])]
      lm = %{lm | gsg: %{lm.gsg | output_goal: hd(goals)}}

      {proposed, _lm} = GraphLM.propose_goals(processed(lm))

      # `output_goals/1` answers at most one goal at a time, which is what Monty's
      # generator does too (`GraphGoalGenerator` keeps one).
      assert proposed == [hd(goals)]
    end

    # `test_returns_no_goals_when_last_obs_not_processed`
    test "returns no goals when the last observation was not processed" do
      {proposed, _lm} = GraphLM.propose_goals(not_processed(%{lm() | gsg: nil}))

      assert proposed == []
    end
  end

  describe "the region a module attends to" do
    # `test_returns_attention_region_that_contains_goal_locations_if_has_goals`
    test "is a region over the proposed goals when it has any" do
      locations = [[0.1, 0.0, 0.0], [0.2, 0.3, 0.0]]
      lm = %{lm() | goals: Enum.map(locations, &goal/1)}

      {region, _lm} = GraphLM.propose_region(lm)

      assert region.locations == locations
      assert region.weights == List.duplicate(AttentionRegion.max_weight(), 2)
    end

    # `test_returns_empty_attention_region_if_has_no_goals`
    test "is empty when it has no goals" do
      {region, _lm} = GraphLM.propose_region(%{lm() | goals: []})

      assert AttentionRegion.empty?(region)
    end
  end

  describe "what a conclusion names" do
    test "a recognition names the possible object it settled on" do
      lm = %{lm() | possible_matches: %{"mug" => [1, 2]}}

      assert GraphLM.set_detected_object(lm, :match).detected_object == "mug"
    end

    test "nothing possible names a new object, so a training episode learns one" do
      assert GraphLM.set_detected_object(lm(), :no_match).detected_object == "new_object0"
    end

    test "no conclusion at all names nothing" do
      assert GraphLM.set_detected_object(lm(), nil).detected_object == nil
    end
  end

  describe "the displacement a step carries" do
    test "the first percept of an episode is a zero displacement" do
      percept = Messages.percept(%{location: [0.1, 0.2, 0.3], sender_id: "patch"})

      {:ok, [percept]} = GraphLM.add_displacements(lm(), [percept])

      assert percept.displacement["displacement"] == [0.0, 0.0, 0.0]
    end

    test "a later percept carries how far the sensor moved since the buffer's last one" do
      lm = %{lm() | buffer: %{lm().buffer | last_location: [0.0, 0.0, 0.0]}}

      percept = Messages.percept(%{location: [0.1, 0.0, 0.0], sender_id: "patch"})

      {:ok, [percept]} = GraphLM.add_displacements(lm, [percept])

      assert_in_delta Enum.at(percept.displacement["displacement"], 0), 0.1, 1.0e-12
    end

    test "a step with no sensor module percept says so rather than moving by zero" do
      assert {:error, :no_sensor_module_location} = GraphLM.add_displacements(lm(), [])
    end
  end

  describe "the features a module matches on" do
    test "are the ones it has a tolerance for, and always the pose's definedness" do
      lm = lm(tolerances: %{"patch" => %{"hsv" => [0.1, 0.2, 0.2]}})

      percept = Messages.percept(%{sender_id: "patch", location: [0.0, 0.0, 0.0]})

      percept = %{
        percept
        | non_morphological_features: %{"hsv" => [0.1, 0.2, 0.3], "rgba" => [1.0, 0.0, 0.0, 1.0]}
      }

      assert GraphLM.select_features_to_use(lm, [percept]) == %{
               "patch" => %{"hsv" => [0.1, 0.2, 0.3], "pose_fully_defined" => true}
             }
    end
  end
end
