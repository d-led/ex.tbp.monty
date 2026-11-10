defmodule Monty.Frameworks.Models.EvidenceMatching.LearningModule.EvidenceGraphLMTest do
  use ExUnit.Case, async: true

  alias Monty.Cmp.{Goal, Message}
  alias Monty.Context
  alias Monty.Frameworks.Models.Buffer.FeatureAtLocationBuffer
  alias Monty.Frameworks.Models.EvidenceMatching.Hypotheses
  alias Monty.Frameworks.Models.EvidenceMatching.LearningModule.EvidenceGraphLM
  alias Monty.Frameworks.Models.EvidenceMatching.Model.MontyForEvidenceGraphMatching
  alias Monty.Frameworks.Models.GoalGeneration.EvidenceGoalGenerator
  alias Monty.Frameworks.Models.GraphMatching.GraphMemory
  alias Monty.Frameworks.Models.ObjectModel.GraphObjectModel
  alias Monty.Geometry.OrientationMatrix
  alias Monty.Geometry.{Rotation, SurfacePoseVectors}

  @pose_flat [0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0]
  @identity Rotation.to_matrix(Rotation.identity())

  # An object is a row of points along x whose `rgba` is its own x coordinate,
  # so where the sensor looked is readable from the observation alone.
  defp model(id, positions) do
    locations = Enum.map(positions, &[&1, 0.0, 0.0])

    features = %{
      "rgba" => Enum.map(positions, fn x -> [x] end),
      "pose_vectors" => List.duplicate(@pose_flat, length(positions)),
      "pose_fully_defined" => List.duplicate([1.0], length(positions))
    }

    GraphObjectModel.new(id) |> GraphObjectModel.build_model(locations, features, nil, nil)
  end

  defp memory(objects) do
    objects
    |> Enum.reduce(GraphMemory.new(features_to_use: %{"patch" => ["rgba", "pose_vectors"]}), fn
      {id, positions}, memory ->
        GraphMemory.add_graph_to_memory(memory, %{"patch" => model(id, positions)}, id)
    end)
    |> GraphMemory.initialize_feature_arrays()
  end

  defp mug, do: memory(%{"mug" => [0.0, 0.1, 0.2]})

  defp learning_module(memory, options \\ []) do
    {:ok, lm} =
      EvidenceGraphLM.new(
        memory,
        Keyword.merge(
          [
            max_match_distance: 0.05,
            tolerances: %{"patch" => %{"rgba" => 0.05}},
            feature_weights: %{"patch" => %{"rgba" => 1.0}}
          ],
          options
        )
      )

    lm
  end

  # A sensor looking at `rgba` from `location`, with a pose that matches the
  # stored one, so only the feature decides the evidence.
  defp percept(location, rgba, options \\ []) do
    features =
      if Keyword.get(options, :with_features, true) do
        %{
          "pose_vectors" => Keyword.get(options, :pose, upright_pose()),
          "pose_fully_defined" => true,
          "rgba" => rgba
        }
      else
        %{}
      end

    {:ok, message} =
      Message.new(
        location: location,
        morphological_features: features,
        non_morphological_features: %{},
        confidence: 1.0,
        pass_message: true,
        process_features_in_lm: Keyword.get(options, :with_features, true),
        sender_id: "patch",
        sender_type: :sm
      )

    message
  end

  defp upright_pose do
    SurfacePoseVectors.new([0.0, 0.0, 1.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0])
  end

  # The same surface seen from the opposite side, with the curvature direction
  # turned a quarter turn: as unlike the stored pose as a pose can be.
  defp opposite_pose do
    SurfacePoseVectors.new([0.0, 0.0, -1.0], [0.0, 1.0, 0.0], [1.0, 0.0, 0.0])
  end

  # The stored surface seen a thirtieth of a turn about its normal. Its frame is a
  # rotation of 30° and not a symmetric matrix, so the frame's transpose is a
  # different frame — which is what tells a vote that carries one from a vote that
  # carries the other.
  defp turned_pose do
    half = :math.pi() / 6

    SurfacePoseVectors.new(
      [0.0, 0.0, 1.0],
      [Float.round(:math.cos(half), 12), Float.round(:math.sin(half), 12), 0.0],
      [Float.round(-:math.sin(half), 12), Float.round(:math.cos(half), 12), 0.0]
    )
  end

  # What the model does for the learning module around every step: it records
  # whether this module was given the observation.
  defp step(lm, percepts, processed \\ true) do
    {:ok, lm} = EvidenceGraphLM.matching_step(percepts, Context.new(0), lm)
    EvidenceGraphLM.add_lm_processing_to_buffer_stats(lm, processed)
  end

  # A step followed by the terminal-condition check that the model runs after
  # every step.
  defp step_and_conclude(lm, percepts) do
    {lm, _terminal_state} =
      lm |> step(percepts) |> EvidenceGraphLM.update_terminal_condition()

    lm
  end

  defp best_evidence(lm, graph_id) do
    lm.hypotheses
    |> Map.fetch!(graph_id)
    |> Hypotheses.evidence()
    |> Enum.max()
  end

  describe "the first observation" do
    test "starts a hypothesis space for the object, none of it ruled out" do
      lm = learning_module(mug()) |> step([percept([0.2, 0.0, 0.0], [0.2])])

      assert Map.keys(lm.hypotheses) == ["mug"]
      assert Hypotheses.count(lm.hypotheses["mug"]) == 6

      # Every node starts at what its stored features are worth against this
      # observation, and the node at the sensed location is the one that fits.
      assert Hypotheses.evidence(lm.hypotheses["mug"]) == [0.0, 0.0, 1.0, 0.0, 0.0, 1.0]
    end

    test "leaves the object possible, because nothing has ruled it out" do
      lm = learning_module(mug()) |> step([percept([0.2, 0.0, 0.0], [0.2])])

      assert EvidenceGraphLM.get_possible_matches(lm) == ["mug"]
    end

    test "says nothing was observed yet when asked what is most likely" do
      lm = learning_module(mug())

      assert EvidenceGraphLM.evidence_for_each_graph(lm) == {["patch_off_object"], [0.0]}
      assert EvidenceGraphLM.current_mlh(lm).graph_id == "no_observations_yet"
    end
  end

  describe "a hypothesis space the most likely hypothesis has left" do
    # One observation, two objects in memory: the same steps, twice, so that the
    # space of one is updated while the other's index is still the one the last
    # step found.
    defp two_objects do
      memory(%{"mug" => [0.0, 0.1, 0.2], "plate" => [0.0, 0.1, 0.2]})
      |> learning_module()
    end

    # Burst sampling prunes a space between steps and keeps a subset of it, so
    # the index the most likely hypothesis was found at can be past the end of
    # the pruned space. That is what a space pruned to nothing looks like.
    defp pruned_to_first_row(lm) do
      %{graph_id: graph_id} = lm.current_mlh
      remaining = Hypotheses.take(Map.fetch!(lm.hypotheses, graph_id), [0])

      %{lm | hypotheses: Map.put(lm.hypotheses, graph_id, remaining)}
    end

    test "does not stop the step that reads its evidence" do
      lm = two_objects() |> step([percept([0.2, 0.0, 0.0], [0.2])])
      # One row is not where the most likely hypothesis was found, so the step
      # below reads an index the space no longer holds.
      assert lm.current_mlh.mlh_id > 0

      lm = lm |> pruned_to_first_row() |> step([percept([0.3, 0.0, 0.0], [0.3])])

      # The step ran to its end, and the pruned object is still one memory holds.
      assert Map.has_key?(lm.hypotheses, "mug")
      assert EvidenceGraphLM.current_mlh(lm).graph_id in ["mug", "plate"]
    end
  end

  describe "matching an observation" do
    test "earns evidence for the hypothesis that explains it" do
      lm =
        learning_module(mug())
        |> step([percept([0.2, 0.0, 0.0], [0.2])])
        |> step([percept([0.2, 0.0, 0.0], [0.2])])

      assert best_evidence(lm, "mug") > 1.0
    end

    test "prefers the object whose features the sensor is looking at" do
      two_objects = memory(%{"mug" => [0.0, 0.1, 0.2], "bowl" => [0.6, 0.7, 0.8]})

      lm =
        learning_module(two_objects)
        |> step([percept([0.2, 0.0, 0.0], [0.2])])
        |> step([percept([0.2, 0.0, 0.0], [0.2])])

      assert best_evidence(lm, "mug") > best_evidence(lm, "bowl")
      assert EvidenceGraphLM.get_possible_matches(lm) == ["mug"]
    end

    test "takes the location of its best hypothesis from the observation" do
      lm =
        learning_module(mug())
        |> step([percept([0.2, 0.0, 0.0], [0.2])])
        |> step([percept([0.2, 0.0, 0.0], [0.2])])

      assert EvidenceGraphLM.current_mlh(lm).location == [0.2, 0.0, 0.0]
    end

    test "keeps the pose open while the mirror image of the observation survives" do
      lm =
        learning_module(mug())
        |> step_and_conclude([percept([0.2, 0.0, 0.0], [0.2])])
        |> step_and_conclude([percept([0.2, 0.0, 0.0], [0.2])])

      assert lm.terminal_state == nil
      assert Enum.all?(lm.detected_pose, &is_nil/1)
    end

    test "accepts the pose of a symmetric object once its alternatives keep surviving" do
      lm =
        learning_module(mug(), required_symmetry_evidence: 1)
        |> step_and_conclude([percept([0.2, 0.0, 0.0], [0.2])])
        |> step_and_conclude([percept([0.2, 0.0, 0.0], [0.2])])
        |> step_and_conclude([percept([0.2, 0.0, 0.0], [0.2])])

      assert lm.terminal_state == :match
      assert lm.detected_object == "mug"
      # Compared rather than matched: a pose's zero can be −0.0, which a pattern
      # on `0.0` refuses even though the two are the same angle.
      assert [x, y | _rest] = lm.detected_pose
      assert_in_delta x, 0.2, 1.0e-12
      assert y == 0.0
    end
  end

  describe "a step that only moved" do
    test "moves every hypothesis by the sensor's movement and no evidence at all" do
      before =
        learning_module(mug())
        |> step([percept([0.2, 0.0, 0.0], [0.2])])

      after_move = step(before, [percept([0.25, 0.0, 0.0], [0.2], with_features: false)])

      assert Hypotheses.locations(after_move.hypotheses["mug"]) !=
               Hypotheses.locations(before.hypotheses["mug"])

      assert Hypotheses.evidence(after_move.hypotheses["mug"]) ==
               Hypotheses.evidence(before.hypotheses["mug"])

      assert after_move.buffer.last_location == [0.25, 0.0, 0.0]
    end

    test "keeps the most likely hypothesis pointing at the same hypothesis" do
      before =
        learning_module(mug())
        |> step([percept([0.2, 0.0, 0.0], [0.2])])
        |> step([percept([0.2, 0.0, 0.0], [0.2])])

      after_move = step(before, [percept([0.25, 0.0, 0.0], [0.2], with_features: false)])

      assert after_move.current_mlh.mlh_id == before.current_mlh.mlh_id
      assert after_move.current_mlh.evidence == before.current_mlh.evidence

      assert EvidenceGraphLM.current_mlh(after_move).location !=
               EvidenceGraphLM.current_mlh(before).location
    end
  end

  describe "concluding an episode" do
    test "names a new object when nothing in memory explains the observation" do
      novel =
        learning_module(mug(), hypotheses_updater_options: [initial_possible_poses: [@identity]])
        |> step_and_conclude([percept([0.2, 0.0, 0.0], [0.9], pose: opposite_pose())])
        |> step_and_conclude([percept([0.2, 0.0, 0.0], [0.9], pose: opposite_pose())])

      assert novel.possible_matches == []
      assert novel.terminal_state == :no_match
      assert novel.detected_object == "new_object1"
    end

    test "a module that has seen nothing has nothing to say" do
      lm = learning_module(mug())

      assert {nil, _lm} = EvidenceGraphLM.send_out_vote(lm)
      assert {message, _lm} = EvidenceGraphLM.get_output(lm)
      refute message.pass_message
    end
  end

  describe "voting" do
    test "offers only the hypotheses that stand out among all objects" do
      two_objects = memory(%{"mug" => [0.0, 0.1, 0.2], "bowl" => [0.6, 0.7, 0.8]})

      lm =
        learning_module(two_objects)
        |> step([percept([0.2, 0.0, 0.0], [0.2])])
        |> step([percept([0.2, 0.0, 0.0], [0.2])])

      assert {%{possible_states: possible_states, sensed_pose_rel_body: sensed_pose}, _lm} =
               EvidenceGraphLM.send_out_vote(lm)

      assert Map.keys(possible_states) == ["mug"]
      assert Enum.all?(possible_states["mug"], &(&1.confidence > lm.vote_evidence_threshold))
      assert Enum.all?(possible_states["mug"], &(&1.sender_type == :lm))
      assert [location | _rotation_rows] = sensed_pose
      assert length(location) == 3
    end

    # Monty's #1288: the vote carries the hypothesis' pose as the module stores
    # it. A receiver turns the sensor displacement by this matrix, so a transposed
    # one turns it by the inverse rotation and "if I am here, you are there"
    # arrives pointing somewhere nobody is.
    test "votes with the hypothesis' pose exactly as it is stored" do
      lm =
        learning_module(mug())
        |> step([percept([0.2, 0.0, 0.0], [0.2], pose: turned_pose())])
        |> step([percept([0.2, 0.0, 0.0], [0.2], pose: turned_pose())])

      assert {%{possible_states: %{"mug" => [vote | _]}}, _lm} =
               EvidenceGraphLM.send_out_vote(lm)

      {:ok, %OrientationMatrix{value: value}} = Message.feature(vote, "pose_vectors")

      # Membership says it is one of the poses the module holds. A transposed
      # frame would be a different one: these poses turn 30°, and their
      # transposes turn the other way.
      assert value in Hypotheses.poses(lm.hypotheses["mug"])
    end

    test "stays silent when it was not given the observation" do
      lm =
        learning_module(mug())
        |> step([percept([0.2, 0.0, 0.0], [0.2])], false)

      assert {nil, _lm} = EvidenceGraphLM.send_out_vote(lm)
    end

    test "lifts the hypotheses an agreeing vote lands near" do
      lm =
        learning_module(mug())
        |> step([percept([0.2, 0.0, 0.0], [0.2])])
        |> step([percept([0.2, 0.0, 0.0], [0.2])])

      before = Enum.max(Hypotheses.evidence(lm.hypotheses["mug"]))

      {:ok, vote} =
        Message.new(
          location: [0.2, 0.0, 0.0],
          morphological_features: %{
            "pose_vectors" => %OrientationMatrix{value: @identity},
            "pose_fully_defined" => true
          },
          non_morphological_features: %{},
          confidence: 0.9,
          pass_message: true,
          process_features_in_lm: true,
          sender_id: "LM_1",
          sender_type: :lm
        )

      {:ok, lm} = EvidenceGraphLM.receive_votes(%{"mug" => [vote]}, lm)

      assert Enum.max(Hypotheses.evidence(lm.hypotheses["mug"])) > before
    end

    test "leaves a hypothesis alone when the vote is for somewhere else" do
      lm =
        learning_module(mug())
        |> step([percept([0.2, 0.0, 0.0], [0.2])])
        |> step([percept([0.2, 0.0, 0.0], [0.2])])

      before = Hypotheses.evidence(lm.hypotheses["mug"])

      {:ok, vote} =
        Message.new(
          location: [9.0, 9.0, 9.0],
          morphological_features: %{
            "pose_vectors" => %OrientationMatrix{value: @identity},
            "pose_fully_defined" => true
          },
          non_morphological_features: %{},
          confidence: 0.9,
          pass_message: true,
          process_features_in_lm: true,
          sender_id: "LM_1",
          sender_type: :lm
        )

      {:ok, lm} = EvidenceGraphLM.receive_votes(%{"mug" => [vote]}, lm)

      assert Hypotheses.evidence(lm.hypotheses["mug"]) == before
    end

    # This is the pair the model makes: every module votes, the model moves
    test "hears an agreeing module's vote once the model has routed it" do
      # each vote into the frame of the module that receives it, and only then
      # does it arrive. A module two sensors' widths away could not use the
      # sender's own frame, which is why the vote is not delivered raw.
      sender =
        learning_module(mug())
        |> step([percept([0.2, 0.0, 0.0], [0.2])])
        |> step([percept([0.2, 0.0, 0.0], [0.2])])

      receiver =
        learning_module(mug())
        |> step([percept([0.2, 0.0, 0.0], [0.2])])
        |> step([percept([0.2, 0.0, 0.0], [0.2])])

      {sender_vote, _sender} = EvidenceGraphLM.send_out_vote(sender)
      {receiver_vote, _receiver} = EvidenceGraphLM.send_out_vote(receiver)
      before = best_evidence(receiver, "mug")

      %{receiver: heard} =
        MontyForEvidenceGraphMatching.combine_votes(
          %{sender: sender_vote, receiver: receiver_vote},
          %{receiver: [:sender]}
        )

      {:ok, lm} = EvidenceGraphLM.receive_votes(heard, receiver)

      assert best_evidence(lm, "mug") > before
    end

    test "concludes no match when a round leaves it with nothing possible" do
      # A round with no vote in reach leaves the hypotheses standing and none of
      # them possible, and Monty concludes on that: the module has seen enough to
      # say nothing in memory explains it.
      lm =
        learning_module(mug())
        |> step([percept([0.2, 0.0, 0.0], [0.2])])
        |> step([percept([0.2, 0.0, 0.0], [0.2])])

      concluded = EvidenceGraphLM.update_stats_after_vote(%{lm | possible_matches: []})

      assert concluded.terminal_state == :no_match
    end

    test "is let back out of no match when a vote brings possibilities back" do
      # Nothing else clears `no_match` — the terminal check only ever clears
      # `match` — so this is the one path by which a module that lost its
      # hypotheses recovers within the episode.
      lm =
        learning_module(mug())
        |> step([percept([0.2, 0.0, 0.0], [0.2])])
        |> step([percept([0.2, 0.0, 0.0], [0.2])])

      concluded = %{lm | possible_matches: [], terminal_state: :no_match}

      {:ok, vote} =
        Message.new(
          location: [0.2, 0.0, 0.0],
          morphological_features: %{
            "pose_vectors" => %OrientationMatrix{value: @identity},
            "pose_fully_defined" => true
          },
          non_morphological_features: %{},
          confidence: 0.9,
          pass_message: true,
          process_features_in_lm: true,
          sender_id: "LM_1",
          sender_type: :lm
        )

      {:ok, heard} = EvidenceGraphLM.receive_votes(%{"mug" => [vote]}, concluded)
      assert heard.possible_matches != []

      assert EvidenceGraphLM.update_stats_after_vote(heard).terminal_state == nil
    end
  end

  describe "symmetry" do
    defp with_hypotheses(lm, possible) do
      hypotheses =
        Hypotheses.new(
          evidence: List.duplicate(1.0, length(possible)),
          locations: List.duplicate([0.0, 0.0, 0.0], length(possible)),
          poses: List.duplicate(@identity, length(possible)),
          possible: possible
        )

      %{lm | hypotheses: %{"mug" => hypotheses}}
    end

    test "counts consecutive steps in which the same hypotheses stayed possible" do
      lm = with_hypotheses(learning_module(mug(), required_symmetry_evidence: 2), [true, true])

      assert {lm, false} = EvidenceGraphLM.check_for_symmetry(lm, [0, 1], [0, 1], true)
      assert lm.symmetry_evidence == 1

      assert {lm, true} = EvidenceGraphLM.check_for_symmetry(lm, [0, 1], [0, 1], true)
      assert lm.symmetry_evidence == 2
    end

    test "starts counting again when the possible hypotheses change" do
      lm =
        with_hypotheses(learning_module(mug(), required_symmetry_evidence: 2), [true, true, true])

      {lm, _false} = EvidenceGraphLM.check_for_symmetry(lm, [0, 1], [0, 1], true)
      assert lm.symmetry_evidence == 1

      {lm, false} = EvidenceGraphLM.check_for_symmetry(lm, [0, 1], [0, 2], true)
      assert lm.symmetry_evidence == 0
    end

    test "a step that saw nothing new does not count towards symmetry" do
      lm = with_hypotheses(learning_module(mug(), required_symmetry_evidence: 1), [true, true])

      assert {_lm, false} = EvidenceGraphLM.check_for_symmetry(lm, [0, 1], [0, 1], false)
    end
  end

  describe "two most likely objects" do
    test "are the leader and the runner-up" do
      two_objects = memory(%{"mug" => [0.0, 0.1, 0.2], "bowl" => [0.6, 0.7, 0.8]})

      lm =
        learning_module(two_objects)
        |> step([percept([0.2, 0.0, 0.0], [0.2])])
        |> step([percept([0.2, 0.0, 0.0], [0.2])])

      assert EvidenceGraphLM.get_top_two_mlh_ids(lm) == {"mug", "bowl"}
    end

    test "are the object and nothing when memory holds one object" do
      lm = learning_module(mug()) |> step([percept([0.2, 0.0, 0.0], [0.2])])

      assert EvidenceGraphLM.get_top_two_mlh_ids(lm) == {"mug", nil}
    end

    test "are nothing at all before anything has been observed" do
      assert EvidenceGraphLM.get_top_two_mlh_ids(learning_module(mug())) == {nil, nil}
    end
  end

  describe "memory" do
    test "is written only in training, and only for what was detected" do
      training =
        learning_module(mug(), hypotheses_updater_options: [initial_possible_poses: [@identity]])
        |> EvidenceGraphLM.set_experiment_mode(:train)
        |> step([percept([0.2, 0.0, 0.0], [0.9], pose: opposite_pose())])
        |> step([percept([0.2, 0.0, 0.0], [0.9], pose: opposite_pose())])
        |> EvidenceGraphLM.update_ltm_from_stm()

      assert GraphMemory.get_memory_ids(training.graph_memory) |> Enum.sort() ==
               ["mug", "new_object1"]
    end

    test "is left alone in evaluation" do
      evaluating =
        learning_module(mug(), hypotheses_updater_options: [initial_possible_poses: [@identity]])
        |> EvidenceGraphLM.set_experiment_mode(:eval)
        |> step([percept([0.2, 0.0, 0.0], [0.9], pose: opposite_pose())])
        |> step([percept([0.2, 0.0, 0.0], [0.9], pose: opposite_pose())])
        |> EvidenceGraphLM.update_ltm_from_stm()

      assert GraphMemory.get_memory_ids(evaluating.graph_memory) == ["mug"]
    end

    test "is left alone when the episode never settled on an object" do
      undecided =
        learning_module(mug())
        |> EvidenceGraphLM.set_experiment_mode(:train)
        |> step([percept([0.2, 0.0, 0.0], [0.2])])
        |> EvidenceGraphLM.update_ltm_from_stm()

      assert undecided.detected_object == nil
      assert GraphMemory.get_memory_ids(undecided.graph_memory) == ["mug"]
    end
  end

  describe "an episode boundary" do
    test "clears the hypotheses and the conclusion but keeps the memory" do
      concluded =
        learning_module(mug(), required_symmetry_evidence: 1)
        |> step_and_conclude([percept([0.2, 0.0, 0.0], [0.2])])
        |> step_and_conclude([percept([0.2, 0.0, 0.0], [0.2])])
        |> step_and_conclude([percept([0.2, 0.0, 0.0], [0.2])])

      assert concluded.terminal_state == :match

      lm = EvidenceGraphLM.reset_stm(concluded)

      assert lm.hypotheses == %{}
      assert lm.terminal_state == nil
      assert lm.detected_object == nil
      assert FeatureAtLocationBuffer.size(lm.buffer) == 0
      assert EvidenceGraphLM.current_mlh(lm).graph_id == "no_observations_yet"
      assert GraphMemory.get_memory_ids(lm.graph_memory) == ["mug"]
    end
  end

  describe "what a detailed run records" do
    test "keeps the whole hypothesis space, and the poses only once" do
      lm =
        learning_module(mug(), has_detailed_logger: true)
        |> step([percept([0.2, 0.0, 0.0], [0.2])])
        |> step([percept([0.2, 0.0, 0.0], [0.2])])

      stats = lm.buffer.stats

      assert length(stats["possible_locations"]) == 2
      assert length(stats["evidences"]) == 2
      assert hd(stats["possible_rotations"]) |> Map.keys() == ["mug"]
      assert List.last(stats["symmetry_evidence"]) == lm.symmetry_evidence
    end

    test "reports the poses as angles when asked for them" do
      lm = learning_module(mug()) |> step([percept([0.2, 0.0, 0.0], [0.2])])

      assert [pose | _more] = EvidenceGraphLM.get_possible_poses(lm)["mug"]
      assert length(pose) == 3
      assert [raw_pose | _more] = EvidenceGraphLM.get_possible_poses(lm, false)["mug"]
      assert length(raw_pose) == 3
    end
  end

  describe "proposing goals" do
    # The generator Monty's learning module owns, told to jump as soon as it is
    # allowed so that a two-step episode is enough to see it happen.
    defp asked_where_to_look do
      EvidenceGoalGenerator.new(min_post_goal_success_steps: 0)
    end

    test "proposes nothing when it owns no goal generator" do
      lm = learning_module(mug()) |> step([percept([0.2, 0.0, 0.0], [0.2])])

      assert {[], _lm} = EvidenceGraphLM.propose_goals(lm)
    end

    test "proposes where its generator asked to look" do
      lm =
        mug()
        |> learning_module(gsg: asked_where_to_look())
        |> step([percept([0.2, 0.0, 0.0], [0.2])])
        |> step([percept([0.2, 0.0, 0.0], [0.2])])

      assert {[%Goal{} = goal], _lm} = EvidenceGraphLM.propose_goals(lm)
      assert goal.sender_type == :gsg
      assert goal.sender_id == "LM_0"
    end

    test "has nothing to propose before the schedule allows a jump" do
      lm =
        mug()
        |> learning_module(gsg: EvidenceGoalGenerator.new())
        |> step([percept([0.2, 0.0, 0.0], [0.2])])
        |> step([percept([0.2, 0.0, 0.0], [0.2])])

      assert {[], _lm} = EvidenceGraphLM.propose_goals(lm)
    end

    test "stays silent on a step in which it was given nothing" do
      lm =
        mug()
        |> learning_module(gsg: asked_where_to_look())
        |> step([percept([0.2, 0.0, 0.0], [0.2])])
        |> step([percept([0.2, 0.0, 0.0], [0.2])], false)

      assert {[], _lm} = EvidenceGraphLM.propose_goals(lm)
    end

    test "forgets the goal when the episode's short-term memory is reset" do
      lm =
        mug()
        |> learning_module(gsg: asked_where_to_look())
        |> step([percept([0.2, 0.0, 0.0], [0.2])])
        |> step([percept([0.2, 0.0, 0.0], [0.2])])
        |> EvidenceGraphLM.reset_stm()

      assert {[], lm} = EvidenceGraphLM.propose_goals(lm)
      assert lm.gsg.prev_top_mlhs == nil
      assert lm.gsg.wait_factor == 1
    end
  end

  describe "the object an episode is about" do
    test "is named at the start, with the pose it was placed with" do
      lm =
        EvidenceGraphLM.set_target(learning_module(mug()), %{
          "object_name" => "mug",
          "quat_rotation" => [0.0, 0.0, 0.0, 1.0]
        })

      assert lm.primary_target == "mug"
      assert lm.primary_target_rotation_quat == [0.0, 0.0, 0.0, 1.0]
    end

    test "is kept when the caller has no target for this episode" do
      lm = %{learning_module(mug()) | primary_target: "mug"}

      assert EvidenceGraphLM.set_target(lm, nil).primary_target == "mug"
    end

    test "is forgotten when the next episode names a different one" do
      lm =
        learning_module(mug())
        |> EvidenceGraphLM.set_target(%{"object_name" => "mug"})
        |> Map.replace!(:stepwise_target_object, "bowl")
        |> EvidenceGraphLM.set_target(%{"object_name" => "bowl"})

      assert lm.primary_target == "bowl"
      assert lm.stepwise_target_object == nil
    end
  end

  describe "the object under the module's sensor, step by step" do
    test "is recorded as each step is taken, and kept as a list" do
      # The model names it from the percept's semantic id, so the module never
      # has to know where the labels come from — Monty's `_set_stepwise_targets`.
      lm =
        learning_module(mug())
        |> EvidenceGraphLM.set_stepwise_target("mug")
        |> EvidenceGraphLM.set_stepwise_target("mug")
        |> EvidenceGraphLM.set_stepwise_target("bowl")

      assert lm.stepwise_target_object == "bowl"
      assert lm.stepwise_targets_list == ["mug", "mug", "bowl"]
    end

    test "is forgotten when a new episode is told what it is about" do
      lm =
        learning_module(mug())
        |> EvidenceGraphLM.set_stepwise_target("mug")

      assert EvidenceGraphLM.set_target(lm, %{"object_name" => "mug"}).stepwise_targets_list == []
    end
  end

  describe "the ground truth a training episode records" do
    test "says which objects the graph it built came from, both ways round" do
      lm =
        mug()
        |> learning_module()
        |> EvidenceGraphLM.set_target(%{"object_name" => "mug"})
        |> Map.merge(%{mode: :train, detected_object: "mug_graph"})
        |> put_in([Access.key!(:buffer)], charged_buffer())
        |> EvidenceGraphLM.fixme_update_ground_truth()

      assert lm.graph_id_to_target == %{"mug_graph" => MapSet.new(["mug"])}
      assert lm.target_to_graph_id == %{"mug" => MapSet.new(["mug_graph"])}
    end

    test "adds to both sets when a graph is seen under a second object" do
      lm =
        mug()
        |> learning_module()
        |> Map.merge(%{
          mode: :train,
          detected_object: "mug_graph",
          graph_id_to_target: %{"mug_graph" => MapSet.new(["mug_cup"])},
          target_to_graph_id: %{"mug_cup" => MapSet.new(["mug_graph"])}
        })
        |> EvidenceGraphLM.set_target(%{"object_name" => "mug"})
        |> put_in([Access.key!(:buffer)], charged_buffer())
        |> EvidenceGraphLM.fixme_update_ground_truth()

      assert lm.graph_id_to_target["mug_graph"] == MapSet.new(["mug_cup", "mug"])
      assert lm.target_to_graph_id["mug"] == MapSet.new(["mug_graph"])
    end

    test "records nothing for a training episode that detected nothing" do
      lm =
        mug()
        |> learning_module()
        |> Map.merge(%{mode: :train, detected_object: nil})
        |> put_in([Access.key!(:buffer)], charged_buffer())
        |> EvidenceGraphLM.fixme_update_ground_truth()

      assert lm.graph_id_to_target == %{}
    end

    test "records nothing while evaluating, where memory is not being built" do
      lm =
        mug()
        |> learning_module()
        |> Map.merge(%{mode: :eval, detected_object: "mug_graph", primary_target: "mug"})
        |> put_in([Access.key!(:buffer)], charged_buffer())
        |> EvidenceGraphLM.fixme_update_ground_truth()

      assert lm.graph_id_to_target == %{}
    end
  end

  # The ground-truth record is only made for an episode whose buffer was used:
  # `size/1` is how many steps were on the object.
  defp charged_buffer do
    Monty.Frameworks.Models.Buffer.FeatureAtLocationBuffer.new()
    |> Map.replace!(:on_object, [1])
  end
end
