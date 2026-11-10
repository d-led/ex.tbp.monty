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

  # A module that has been on the object once: what `receive_votes` and
  # `update_terminal_condition` both ask before they conclude anything.
  defp observed(%{buffer: buffer} = lm, location \\ [0.1, 0.2, 0.3]) do
    {:ok, buffer} = FeatureAtLocationBuffer.append(buffer, [percept(location)])
    %{lm | buffer: buffer}
  end

  defp percept(location, overrides \\ %{}) do
    Messages.percept(Map.merge(%{location: location, sender_id: "patch"}, overrides))
  end

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

  describe "building from a config" do
    test "is a module with the config's tolerances and id" do
      config = %{
        "tolerances" => %{"patch" => %{"hsv" => [0.1, 1.0]}},
        "learning_module_id" => "LM_3"
      }

      assert {:ok, lm} = GraphLM.from_config(config)

      assert lm.learning_module_id == "LM_3"
      assert lm.tolerances == config["tolerances"]
    end

    test "starts from the memory it is handed, which is what a pretrained run loads" do
      memory = Monty.Frameworks.Models.GraphMatching.GraphMemory.new(k: 3)

      assert {:ok, lm} = GraphLM.from_config(%{}, memory: memory)

      assert lm.graph_memory == memory
    end

    test "is buildable, and refuses only where a match would be asked for" do
      # Monty's base class raises `NotImplementedError` in
      # `_compute_possible_matches`, and every subclass answers it instead. That
      # is a matching step's problem, not a build's: a supervised pretraining run
      # hands the module the object it saw and never matches.
      assert {:ok, lm} = GraphLM.from_config(%{})

      ctx = Monty.Context.new(42)

      assert GraphLM.compute_possible_matches(lm, ctx, [], false) ==
               {:error, :not_implemented}
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

  describe "a matching step" do
    # Monty's base class raises `NotImplementedError` here and every subclass
    # answers instead; this port answers with an error, because a graph module
    # that narrowed nothing would look like one that had not decided yet.
    test "a module with no matching scheme says so instead of narrowing nothing" do
      assert_raise RuntimeError, ~r/has no matching scheme/, fn ->
        GraphLM.matching_step([percept([0.0, 0.0, 0.0])], Monty.Context.new(0), lm())
      end
    end

    test "narrows with the scheme it is given, and keeps the observation" do
      narrow = fn lm, _ctx, _features, _moved? ->
        {:ok, %{lm | possible_matches: %{"mug" => [1]}}}
      end

      {:ok, stepped} =
        GraphLM.matching_step([percept([0.0, 0.0, 0.0])], Monty.Context.new(0), lm(), narrow)

      assert Map.keys(stepped.possible_matches) == ["mug"]
      assert FeatureAtLocationBuffer.size(stepped.buffer) == 1
    end

    # A sensor that moved without looking: there is nothing to match, and a step
    # that is not a matching step is not one of the episode's converted steps.
    test "is nothing at all when the step carried only a location" do
      only_location = percept([0.0, 0.0, 0.0], %{process_features_in_lm: false})

      {:ok, stepped} = GraphLM.matching_step([only_location], Monty.Context.new(0), lm())

      assert FeatureAtLocationBuffer.size(stepped.buffer) == 0
    end
  end

  describe "an exploratory step" do
    test "keeps the observation for the training pass that follows" do
      {:ok, stepped} =
        GraphLM.exploratory_step([percept([0.5, 0.0, 0.0])], Monty.Context.new(0), lm())

      assert FeatureAtLocationBuffer.size(stepped.buffer) == 1
      assert FeatureAtLocationBuffer.current_location(stepped.buffer) == [0.5, 0.0, 0.0]
    end

    test "is nothing at all when the step carried only a location" do
      only_location = percept([0.5, 0.0, 0.0], %{process_features_in_lm: false})

      {:ok, stepped} = GraphLM.exploratory_step([only_location], Monty.Context.new(0), lm())

      assert FeatureAtLocationBuffer.size(stepped.buffer) == 0
    end
  end

  describe "a vote from another module" do
    test "rules out the objects it names, and records what it was told" do
      lm = %{observed(lm()) | possible_matches: %{"mug" => [1], "bowl" => [2]}}

      {:ok, voted} = GraphLM.receive_votes(["mug"], lm)

      assert Map.keys(voted.possible_matches) == ["bowl"]
      assert List.last(voted.buffer.stats["vote"]) == ["mug"]
    end

    # A vote against an object this module never considered joins nothing: the
    # module has been on no object yet, so it has no conclusion to revise.
    test "is ignored by a module that has not been on the object" do
      lm = %{lm() | possible_matches: %{"mug" => [1]}}

      {:ok, voted} = GraphLM.receive_votes(["mug"], lm)

      assert Map.keys(voted.possible_matches) == ["mug"]
      refute Map.has_key?(voted.buffer.stats, "vote")
    end

    test "an empty vote is nothing to answer" do
      lm = %{observed(lm()) | possible_matches: %{"mug" => [1]}}

      assert {:ok, voted} = GraphLM.receive_votes([], lm)
      assert voted == lm
    end
  end

  describe "the conclusion a module reaches" do
    test "nothing possible is a no-match, and where it last looked is recorded" do
      {lm, state} = GraphLM.update_terminal_condition(observed(lm()), fn _, _ -> nil end)

      assert state == :no_match
      assert List.last(lm.buffer.stats["detected_location_rel_body"]) == [0.1, 0.2, 0.3]
    end

    test "nothing possible before anything was seen is a no-match with no place to record" do
      {lm, state} = GraphLM.update_terminal_condition(lm(), fn _, _ -> nil end)

      assert state == :no_match
      assert lm.buffer.stats["detected_location_rel_body"] == [nil, nil, nil]
    end

    test "one object left with a pose is a match" do
      lm = %{observed(lm()) | possible_matches: %{"mug" => [1]}}

      {lm, state} = GraphLM.update_terminal_condition(lm, fn _lm, "mug" -> [:a_pose] end)

      assert state == :match
      assert lm.terminal_state == :match
    end

    test "one object left whose pose is not narrowed yet withdraws a match already made" do
      lm = %{observed(lm()) | possible_matches: %{"mug" => [1]}, terminal_state: :match}

      {lm, state} = GraphLM.update_terminal_condition(lm, fn _, _ -> nil end)

      assert state == nil
      assert lm.terminal_state == nil
    end

    test "several objects left is no conclusion, and withdraws a match already made" do
      lm = %{
        observed(lm())
        | possible_matches: %{"mug" => [1], "bowl" => [2]},
          terminal_state: :match
      }

      {lm, state} = GraphLM.update_terminal_condition(lm, fn _, _ -> [:a_pose] end)

      assert state == nil
      assert lm.terminal_state == nil
    end
  end

  describe "what a training step maps" do
    test "a detected graph stands for the target it was learned from, and the reverse" do
      lm = %{
        observed(lm())
        | mode: :train,
          detected_object: "new_object0",
          primary_target: "mug"
      }

      mapped = GraphLM.fixme_update_ground_truth(lm)

      assert mapped.graph_id_to_target == %{"new_object0" => MapSet.new(["mug"])}
      assert mapped.target_to_graph_id == %{"mug" => MapSet.new(["new_object0"])}
    end

    test "a matching step maps nothing: there is no ground truth to learn from" do
      lm = %{observed(lm()) | mode: :matching, detected_object: "mug", primary_target: "mug"}

      assert GraphLM.fixme_update_ground_truth(lm) == lm
    end
  end

  describe "supervision" do
    # Monty's `_pass_target_info_to_model`: a pretraining experiment states the
    # answer instead of matching for it, and the six numbers it states are the
    # ones a matching episode would have concluded for itself.
    defp target do
      %{
        "object_name" => "mug",
        "position" => [0.0, 1.5, 0.0],
        "euler_rotation" => [0.0, 45.0, 0.0],
        "quat_rotation" => [0.7071067811865476, 0.0, 0.7071067811865475, 0.0],
        "scale" => [1.0, 1.0, 1.0]
      }
    end

    test "names the object, the place on the model, the turn and the scale" do
      supervised = GraphLM.supervise(lm(), target(), [-0.2, 1.5, 0.0])

      assert supervised.detected_object == "mug"
      assert supervised.buffer.stats["possible_matches"] == ["mug"]
      assert supervised.buffer.stats["detected_location_on_model"] == [-0.2, 1.5, 0.0]
      assert supervised.buffer.stats["detected_location_rel_body"] == [0.0, 1.5, 0.0]
      assert supervised.buffer.stats["detected_rotation"] == [0.0, 45.0, 0.0]
      assert supervised.buffer.stats["detected_scale"] == [1.0, 1.0, 1.0]
    end

    test "records the turn as the inverse of the one the object was placed with" do
      supervised = GraphLM.supervise(lm(), target(), [0.0, 1.5, 0.0])

      {:ok, placed} =
        Monty.Geometry.Rotation.from_quaternion(
          {0.7071067811865476, 0.0, 0.7071067811865475, 0.0}
        )

      assert supervised.detected_rotation_r == Monty.Geometry.Rotation.invert(placed)
    end

    test "refuses a target that does not say which way the object was turned" do
      assert_raise ArgumentError, ~r/"mug" has none/, fn ->
        GraphLM.supervise(lm(), Map.delete(target(), "quat_rotation"), [0.0, 1.5, 0.0])
      end
    end

    test "a module the experiment does not supervise keeps nothing to learn from" do
      cleared =
        lm()
        |> GraphLM.supervise(target(), [0.0, 1.5, 0.0])
        |> GraphLM.clear_hypotheses()

      assert cleared.detected_object == nil
      assert GraphLM.get_possible_matches(cleared) == []
      assert cleared.buffer.stats["detected_location_on_model"] == nil
      assert cleared.buffer.stats["detected_location_rel_body"] == nil
    end

    test "a cleared module writes nothing into memory" do
      lm = %{lm() | mode: :train}
      {:ok, buffer} = FeatureAtLocationBuffer.append(lm.buffer, [percept([0.1, 0.2, 0.3])])
      cleared = GraphLM.clear_hypotheses(%{lm | buffer: buffer})

      assert GraphLM.update_ltm_from_stm(cleared).graph_memory == cleared.graph_memory
    end
  end
end
