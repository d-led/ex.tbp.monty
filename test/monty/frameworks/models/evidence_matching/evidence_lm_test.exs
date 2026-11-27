defmodule Monty.Frameworks.Models.EvidenceMatching.EvidenceLMTest do
  @moduledoc """
  Monty's `tests/unit/frameworks/models/evidence_matching/evidence_lm_test.py`,
  one case for one case.

  That file drives a whole learning module: it learns a synthetic object out of a
  handful of percepts, then recognises it from another handful, and asserts what
  the evidence does on the way. The percepts are the fixture's
  (`tests/unit/resources/unit_test_utils.py::BaseGraphTest`), and the objects it
  builds out of them are a line, a symmetric line, a square and a "house" — a
  square with one more corner above it, which is what tells a mug from a can.
  """

  use ExUnit.Case, async: true

  alias Monty.Cmp.Message
  alias Monty.Config.Source
  alias Monty.Context
  alias Monty.Frameworks.Models.Buffer.FeatureAtLocationBuffer
  alias Monty.Frameworks.Models.EvidenceMatching.GraphMemory.EvidenceGraphMemory
  alias Monty.Frameworks.Models.EvidenceMatching.Hypotheses
  alias Monty.Frameworks.Models.EvidenceMatching.LearningModule.EvidenceGraphLM
  alias Monty.Frameworks.Models.GoalGeneration.EvidenceGoalGenerator
  alias Monty.Geometry.{Rotation, SurfacePoseVectors}

  @channel "patch"

  # The fixture's four points: a corner of space walked one axis at a time.
  @line_locations [[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [1.0, 1.0, 0.0], [1.0, 1.0, 1.0]]

  # Monty's hypothesis-testing fixture: a square whose four corners look the same,
  # and a "house" — the same square with one corner above it — which is a
  # mug-and-can analogue in two dimensions.
  @square_locations [
    [0.0, 0.0, 0.0],
    [1.0, 0.0, 0.0],
    [1.0, 1.0, 0.0],
    [0.0, 1.0, 0.0]
  ]
  @house_locations @square_locations ++ [[0.5, 1.5, 0.0]]
  @rooftop [0.5, 1.5, 0.0]

  # The same three corners with the fourth moved into the plane, so the object
  # looks the same after half a turn: the fixture's "symmetric" object.
  @symmetric_locations [[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [1.0, 1.0, 0.0], [0.0, 1.0, 0.0]]

  describe "an object's identity as a feature" do
    # Monty's `test_object_id_features_are_unique_and_float32_safe`. It drives
    # the private `_object_id_to_features`; here that is the public
    # `EvidenceGraphLM.object_id_to_features/1`.
    test "every object of a dataset gets its own id, and the id survives a float32" do
      ycb = object_names("eval_77obj_predefined.yaml", "eval_env_interface_args")

      compositional =
        object_names("train_cows_large_predefined.yaml", "train_env_interface_args") ++
          object_names(
            "train_cows_large_2d_children_predefined.yaml",
            "train_env_interface_args"
          )

      assert length(ycb) == 77
      assert length(compositional) == 126

      for {dataset, ids} <- [
            {"ycb", ycb},
            {"expanded_compositional", compositional},
            {"combined", ycb ++ compositional}
          ] do
        features = Enum.map(ids, &{&1, EvidenceGraphLM.object_id_to_features(&1)})

        assert collisions(features) == [],
               "#{dataset}: #{inspect(collisions(features))}"

        for {name, feature} <- features do
          assert exact_in_float32?(feature),
                 "#{dataset}: #{name} is #{feature}, which a float32 cannot hold"

          assert EvidenceGraphLM.object_id_to_features(name) == feature,
                 "#{dataset}: #{name} is not the same id twice"
        end
      end
    end
  end

  describe "recognising a learned object" do
    # Monty's `test_top_two_mlh_ids_without_current_hypotheses`.
    test "a module that has not started matching has no best hypothesis" do
      lm = @line_locations |> learned_line() |> EvidenceGraphLM.reset_stm()

      assert EvidenceGraphLM.get_top_two_mlh_ids(lm) == {nil, nil}
    end

    # Monty's `test_same_sequence_recognition_elm`. The same four points in the
    # same order are an exact match, so every step is worth two evidence: one
    # for the pose and one for the features.
    test "an object seen again in the same order is recognised" do
      {lm, evidences} =
        @line_locations |> learned_line() |> a_new_episode() |> step_through(@line_locations)

      assert evidences == [1, 3, 5, 7]
      assert rotation_of(lm) == [0.0, 0.0, 0.0]
    end

    # Monty's `test_reverse_sequence_recognition_elm`.
    test "an object seen in the opposite order is recognised the same way" do
      {lm, evidences} =
        @line_locations
        |> learned_line()
        |> a_new_episode()
        |> step_through(Enum.reverse(@line_locations))

      assert evidences == [1, 3, 5, 7]
      assert rotation_of(lm) == [0.0, 0.0, 0.0]
    end

    # Monty's `test_offset_sequence_recognition_elm`. Moving the whole sampling
    # path is a different place relative to the body and the same object, so it
    # matches exactly once the first step has fixed the offset.
    test "an object seen from somewhere else in the body frame is recognised" do
      offset = fn location -> Enum.map(location, &(&1 + 1.0)) end

      {lm, evidences} =
        @line_locations
        |> learned_line()
        |> a_new_episode()
        |> step_through(Enum.map(@line_locations, offset))

      assert evidences == [1, 3, 5, 7]
      assert rotation_of(lm) == [0.0, 0.0, 0.0]
    end

    # Monty's `test_new_sampling_recognition_elm`: two points moved by a
    # millimetre or two are still the object.
    test "observations that only nearly fit the model are still recognised" do
      [first, second, third, fourth] = @line_locations
      nudge = fn location, by -> Enum.map(location, &(&1 + by)) end

      {lm, _evidences} =
        @line_locations
        |> learned_line()
        |> a_new_episode()
        |> step_through([nudge.(first, 0.001), second, nudge.(third, 0.002), fourth])

      assert rotation_of(lm) == [0.0, 0.0, 0.0]
    end

    # Monty's `test_different_locations_not_recognized_elm`: one point five
    # metres away is not the object, and the second step is where that shows —
    # a displacement is what the module compares, not the place itself.
    test "a sampling path that does not fit the model leaves no possible match" do
      [first | rest] = @line_locations
      moved = [Enum.map(first, &(&1 + 5.0)) | rest]

      lm = @line_locations |> learned_line() |> a_new_episode()

      {_lm, matches_after_each_step} =
        Enum.reduce(moved, {lm, []}, fn location, {lm, counts} ->
          lm = EvidenceGraphLM.add_lm_processing_to_buffer_stats(lm, true)

          {:ok, lm} =
            EvidenceGraphLM.matching_step([fixture_percept(location)], Context.new(0), lm)

          {lm, counts ++ [length(EvidenceGraphLM.get_possible_matches(lm))]}
        end)

      assert matches_after_each_step == [1, 1, 0, 0]
    end

    # Monty's `test_location_only_step_displaces_hypotheses_elm`: a percept with
    # a new place and no features moves every hypothesis by the displacement its
    # pose implies, and leaves the evidence and the best hypothesis untouched.
    test "a step that only brings a location moves the hypotheses and nothing else" do
      {lm, _evidences} =
        @line_locations |> learned_line() |> a_new_episode() |> step_through(@line_locations)

      before = EvidenceGraphLM.get_current_mlh(lm)
      last_location = lm.buffer.last_location
      pose = lm.hypotheses |> Map.fetch!(before.graph_id) |> Hypotheses.pose(before.mlh_id)

      displacement = [0.1, 0.2, 0.3]

      lm = EvidenceGraphLM.add_lm_processing_to_buffer_stats(lm, false)

      {:ok, lm} =
        EvidenceGraphLM.matching_step(
          [location_only_percept(add(last_location, displacement))],
          Context.new(0),
          lm
        )

      now = EvidenceGraphLM.get_current_mlh(lm)

      assert_close(now.location, add(before.location, pose_rotated(pose, displacement)), 1.0e-9)

      assert now.graph_id == before.graph_id,
             "the object identity is invariant under a displacement"

      assert now.mlh_id == before.mlh_id,
             "the best hypothesis' index is invariant under a displacement"

      assert now.evidence == before.evidence, "evidence should not change on a location-only step"
      assert_close(lm.buffer.last_location, add(last_location, displacement), 1.0e-12)
    end

    # Monty's `test_different_features_still_recognized`: features only speed a
    # recognition up. With every feature different, the object is still
    # recognised on its shape, one evidence a step.
    test "an object whose features all differ is recognised on its shape alone" do
      hues = [0.5, 0.9, 0.5, 0.7]

      percepts =
        @line_locations
        |> Enum.zip(hues)
        |> Enum.map(fn {location, hue} ->
          fixture_percept(location, %{
            non_morphological_features: %{
              "principal_curvatures_log" => [10.0, 10.0],
              "hsv" => [hue, 1.0, 1.0]
            }
          })
        end)

      lm = @line_locations |> learned_line() |> a_new_episode()

      {lm, evidences} = walk(lm, percepts)

      # The first step has no feature evidence to add — every hypothesis is new —
      # so the object's own evidence is nought and rises by the one for shape.
      assert evidences == [0, 1, 2, 3]
      assert rotation_of(lm) == [0.0, 0.0, 0.0]
    end

    # Monty's `test_different_pose_features_not_recognized_elm`: the first point
    # arrives facing another way, so the pose the module starts from is wrong
    # and every step after that costs evidence until nothing is left.
    test "an object seen with a pose that does not fit stops matching" do
      [first | rest] = @line_locations
      turned = SurfacePoseVectors.new([1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0])

      percepts = [
        fixture_percept(first, %{morphological_features: %{"pose_vectors" => turned}})
        | Enum.map(rest, &fixture_percept/1)
      ]

      lm = @line_locations |> learned_line() |> a_new_episode()

      {lm, evidences} =
        Enum.reduce(percepts, {lm, []}, fn percept, {lm, evidences} ->
          lm = EvidenceGraphLM.add_lm_processing_to_buffer_stats(lm, true)
          {:ok, lm} = EvidenceGraphLM.matching_step([percept], Context.new(0), lm)
          {lm, evidences ++ [EvidenceGraphLM.get_current_mlh(lm).evidence]}
        end)

      assert Enum.at(evidences, 1) > 1.0, "the pose the module started from is still possible"
      assert Enum.at(evidences, 2) < 1.0, "that pose is not possible any more"
      assert Enum.at(evidences, 3) < 0.0, "and the evidence it earned is taken back"
      assert EvidenceGraphLM.get_possible_matches(lm) == []
    end

    # Monty's `test_moving_off_object_and_back_elm`: a step that saw nothing is
    # not fed to the module, so it earns no evidence and the object is still
    # recognised afterwards.
    test "an object is still recognised after the sensor leaves it and comes back" do
      [first, _second, third, fourth] = @line_locations

      lm = @line_locations |> learned_line() |> a_new_episode()

      percepts = [
        fixture_percept(first),
        # Off the object: the sensor sees nothing, and the model passes it on to
        # nobody.
        fixture_percept([1.0, 2.0, 1.0], %{
          morphological_features: %{"on_object" => false},
          pass_message: false
        }),
        fixture_percept(third),
        fixture_percept(fourth)
      ]

      {lm, evidences} =
        Enum.reduce(percepts, {lm, []}, fn percept, {lm, evidences} ->
          if percept.pass_message do
            lm = EvidenceGraphLM.add_lm_processing_to_buffer_stats(lm, true)
            {:ok, lm} = EvidenceGraphLM.matching_step([percept], Context.new(0), lm)

            assert EvidenceGraphLM.get_possible_matches(lm) == ["new_object0"],
                   "Should have exactly one possible match."

            {lm, evidences ++ [EvidenceGraphLM.get_current_mlh(lm).evidence]}
          else
            # Monty's model drops a percept that was not passed on, so the step
            # leaves no evidence behind.
            {lm, evidences}
          end
        end)

      assert evidences == [1.0, 3.0, 5.0]
      assert rotation_of(lm) == [0.0, 0.0, 0.0]
    end

    # Monty's `test_symmetry_recognition`. A square whose corners are opposite
    # each other looks the same after half a turn, so no single rotation is
    # right: the module keeps both poses and counts the evidence that it cannot
    # choose between them.
    test "a symmetric object keeps both of its poses and counts the ambiguity" do
      lm = @symmetric_locations |> learned_line() |> a_new_episode()

      {lm, _steps_with_evidence} =
        Enum.reduce(0..11, {lm, 0}, fn step, {lm, steps_with_evidence} ->
          location = Enum.at(@symmetric_locations, rem(step, 4))
          lm = EvidenceGraphLM.add_lm_processing_to_buffer_stats(lm, true)

          {:ok, lm} =
            EvidenceGraphLM.matching_step([fixture_percept(location)], Context.new(0), lm)

          # Monty's case runs this by hand, because its coordinator is what
          # updates the symmetry count after a step.
          {lm, _pose} = EvidenceGraphLM.get_unique_pose_if_available(lm, "new_object0")

          assert EvidenceGraphLM.get_possible_matches(lm) == ["new_object0"],
                 "Should have exactly one possible match."

          evidence = EvidenceGraphLM.calculate_most_likely_hypothesis(lm, "new_object0").evidence

          if evidence > lm.object_evidence_threshold do
            steps_with_evidence = steps_with_evidence + 1

            if steps_with_evidence > 1 do
              assert lm.symmetry_evidence == steps_with_evidence - 1,
                     "Symmetry evidence doesn't seem to be as expected."
            end

            {lm, steps_with_evidence}
          else
            {lm, steps_with_evidence}
          end
        end)

      assert lm.symmetry_evidence > 0, "the module should have noticed the ambiguity"

      # Monty's own `get_possible_poses` lists every hypothesis' pose without
      # narrowing, so the two poses repeat; its case reads the first and the
      # last, which is what this does.
      poses = Map.fetch!(EvidenceGraphLM.get_possible_poses(lm), "new_object0")

      assert hd(poses) == [0.0, 0.0, 0.0], "0, 0, 0 should be a possible pose: #{inspect(poses)}"

      assert same_pose?(turned_once(Enum.at(poses, -1)), [180.0, 0.0, 180.0]),
             "180, 0, 180 should also be a possible pose: #{inspect(poses)}"
    end
  end

  # Two Euler poses name the same rotation when they agree to a degree, which is
  # the resolution Monty's case asserts at.
  defp same_pose?(left, right),
    do: Enum.all?(Enum.zip(left, right), fn {a, b} -> abs(a - b) < 1.0 end)

  # Monty compares the last pose modulo a full turn, because a rotation of -180
  # is the same rotation as 180.
  defp turned_once(pose), do: Enum.map(pose, fn angle -> :math.fmod(angle + 360.0, 360.0) end)

  # A walk over `locations`, one fixture percept each.
  defp step_through(lm, locations) do
    lm |> walk(Enum.map(locations, &fixture_percept/1))
  end

  # A walk over `percepts`, asserting at every step that the module has narrowed
  # to the one object, and answering the evidence it held at each step.
  defp walk(lm, percepts) do
    {lm, evidences} =
      Enum.reduce(percepts, {lm, []}, fn percept, {lm, evidences} ->
        lm = EvidenceGraphLM.add_lm_processing_to_buffer_stats(lm, true)
        {:ok, lm} = EvidenceGraphLM.matching_step([percept], Context.new(0), lm)

        assert EvidenceGraphLM.get_possible_matches(lm) == ["new_object0"],
               "Should have exactly one possible match."

        mlh = EvidenceGraphLM.get_current_mlh(lm)
        assert mlh.graph_id == "new_object0", "new_object0 should be the mlh at every step."

        {lm, [mlh.evidence | evidences]}
      end)

    {lm, Enum.reverse(evidences)}
  end

  defp rotation_of(lm),
    do: Rotation.to_euler_degrees(EvidenceGraphLM.get_current_mlh(lm).rotation)

  # Monty's `fixme_reset_ground_truth(primary_target=self.placeholder_target)`
  # after `reset_stm`: the episode is about an object this run does not score.
  defp a_new_episode(lm) do
    lm = EvidenceGraphLM.reset_stm(lm)

    EvidenceGraphLM.set_primary_target(lm, %{
      "object_name" => "placeholder",
      "quat_rotation" => [1.0, 0.0, 0.0, 0.0]
    })
  end

  # A location-only step: the percept carries a new place and no features, so the
  # module moves every hypothesis and leaves the evidence and the best
  # hypothesis alone.
  defp location_only_percept(location) do
    {:ok, message} =
      Message.new(
        location: location,
        morphological_features: %{
          "pose_vectors" =>
            SurfacePoseVectors.new([0.0, 1.0, 0.0], [1.0, 0.0, 0.0], [0.0, 0.0, -1.0]),
          "pose_fully_defined" => true,
          "on_object" => true
        },
        non_morphological_features: %{
          "principal_curvatures_log" => [0.0, 0.5],
          "hsv" => [0.0, 1.0, 1.0]
        },
        confidence: 1.0,
        pass_message: true,
        process_features_in_lm: false,
        sender_id: @channel,
        sender_type: :sm
      )

    message
  end

  # `pose @ displacement` for a 3×3 pose and a vector, which is what Monty's case
  # writes as a matrix product.
  defp pose_rotated(pose, vector) do
    pose
    |> Enum.zip(vector)
    |> Enum.map(fn {row, component} ->
      row |> Enum.map(&(&1 * component)) |> Enum.sum()
    end)
  end

  defp assert_close(left, right, tolerance) do
    assert Enum.all?(Enum.zip(left, right), fn {a, b} -> abs(a - b) < tolerance end),
           "expected #{inspect(left)} to be #{inspect(right)}"
  end

  # Monty's `_get_current_mlh` answers with the current hypothesis when there is
  # no hypothesis space left, and an episode's statistics are read after its
  # memory is released. Answering `"new_object0"` regardless reported the
  # placeholder in place of the object the module had recognised.
  describe "what was recognised, once the memory is released" do
    test "the module still names the object it believed" do
      lm = @line_locations |> learned_line("mug") |> a_new_episode()

      {:ok, lm} =
        EvidenceGraphLM.matching_step(
          [fixture_percept(hd(@line_locations))],
          Context.new(0),
          lm
        )

      believed = EvidenceGraphLM.get_current_mlh(lm).graph_id

      released = %{
        lm
        | graph_memory: %{lm.graph_memory | models_in_memory: %{}},
          hypotheses: %{}
      }

      assert EvidenceGraphLM.calculate_most_likely_hypothesis(released).graph_id == believed
    end

    # An object whose hypotheses hold no evidence is numpy's NaN, and Monty keeps
    # the hypothesis it already has: `NaN > 5.0` is false. Elixir compares terms
    # instead, and every atom sorts after every number, so the NaN displaced a
    # real one — the most likely object had no evidence to read, and the step's
    # threshold was arithmetic over nothing.
    test "an object with no evidence never displaces one that has some" do
      lm = @line_locations |> learned_line("alpha") |> a_new_episode()

      {:ok, lm} =
        EvidenceGraphLM.matching_step([fixture_percept(hd(@line_locations))], Context.new(0), lm)

      scored = lm.hypotheses["alpha"]
      blank = Hypotheses.put_evidence(scored, List.duplicate(nil, Hypotheses.count(scored)))

      models = lm.graph_memory.models_in_memory
      both = %{lm.graph_memory | models_in_memory: Map.put(models, "beta", models["alpha"])}

      lm = %{lm | graph_memory: both, hypotheses: %{"alpha" => scored, "beta" => blank}}
      most_likely = EvidenceGraphLM.calculate_most_likely_hypothesis(lm)

      assert most_likely.graph_id == "alpha"
      assert is_number(most_likely.evidence)
    end
  end

  defp add(left, right), do: Enum.zip_with(left, right, &(&1 + &2))

  # Monty's `BaseGraphTest` fixture: one pose at every point of the fake object,
  # so a pose never disagrees and only the location says where a percept was.
  # `changes` replaces the parts a case varies — a feature, a pose, whether the
  # sensor is on the object at all.
  defp fixture_percept(location, changes \\ %{}) do
    defaults = %{
      location: location,
      morphological_features: %{
        "pose_vectors" =>
          SurfacePoseVectors.new([0.0, 1.0, 0.0], [1.0, 0.0, 0.0], [0.0, 0.0, -1.0]),
        "pose_fully_defined" => true,
        "on_object" => true
      },
      non_morphological_features: %{
        "principal_curvatures_log" => [0.0, 0.5],
        "hsv" => [0.0, 1.0, 1.0]
      },
      confidence: 1.0,
      pass_message: true,
      process_features_in_lm: true,
      sender_id: @channel,
      sender_type: :sm
    }

    {:ok, message} = Message.new(merge_features(defaults, changes))
    message
  end

  defp merge_features(defaults, changes) do
    Enum.reduce(changes, defaults, fn
      {:morphological_features, features}, acc ->
        Map.update!(acc, :morphological_features, &Map.merge(&1, features))

      {:non_morphological_features, features}, acc ->
        Map.update!(acc, :non_morphological_features, &Map.merge(&1, features))

      {key, value}, acc ->
        Map.put(acc, key, value)
    end)
  end

  defp learning_module do
    {:ok, lm} =
      EvidenceGraphLM.new(
        EvidenceGraphMemory.new(max_graph_size: 10),
        max_match_distance: 0.005,
        tolerances: %{
          @channel => %{
            "hsv" => [0.1, 1.0, 1.0],
            "principal_curvatures_log" => [1.0, 1.0]
          }
        },
        # Only hue counts, so a percept whose brightness or saturation differs
        # from the learned one still matches.
        feature_weights: %{@channel => %{"hsv" => [1.0, 0.0, 0.0]}}
      )

    lm
  end

  # Monty's `get_elm_with_fake_object`: explore the fixture's locations, then
  # store what the buffer holds as one object.
  defp learned_line(locations, object_id \\ "new_object0") do
    lm = learning_module() |> EvidenceGraphLM.set_experiment_mode(:train)

    lm =
      Enum.reduce(locations, lm, fn location, lm ->
        {:ok, lm} =
          EvidenceGraphLM.exploratory_step([fixture_percept(location)], Context.new(0), lm)

        lm
      end)

    lm = %{lm | detected_object: object_id, detected_rotation_r: nil}

    lm =
      put_buffer_stat(
        lm,
        "detected_location_rel_body",
        FeatureAtLocationBuffer.current_location(lm.buffer)
      )

    lm = EvidenceGraphLM.update_ltm_from_stm(lm)
    lm = EvidenceGraphLM.fixme_update_ground_truth(lm)

    assert length(FeatureAtLocationBuffer.get_all_locations_on_object(lm.buffer)) ==
             length(locations),
           "Should have stored exactly #{length(locations)} locations in the buffer."

    assert EvidenceGraphLM.get_all_known_object_ids(lm) == [object_id],
           "Learning the line should leave exactly one object in memory."

    lm
  end

  # Monty's test writes the buffer's own statistics after a training episode;
  # a step does not set the detected location, the episode's end does.
  defp put_buffer_stat(lm, key, value) do
    %{lm | buffer: %{lm.buffer | stats: Map.put(lm.buffer.stats, key, value)}}
  end

  # Monty's `get_elm_with_two_fake_objects` and the hypothesis-testing cases: an
  # object learnt from four identical features with a fifth the sensor has not
  # seen, and a goal generator asked which point would tell the candidates apart.
  defp goal_generator do
    EvidenceGoalGenerator.new(
      elapsed_steps_factor: 10,
      min_post_goal_success_steps: 5,
      x_percent_scale_factor: 0.75,
      desired_object_distance: 0.03
    )
  end

  defp learning_module_with(generator, euler_poses) do
    matrices =
      Enum.map(euler_poses, fn pose ->
        {:ok, rotation} = Rotation.from_euler_degrees(pose)
        Rotation.to_matrix(rotation)
      end)

    {:ok, lm} =
      EvidenceGraphLM.new(
        EvidenceGraphMemory.new(max_graph_size: 10),
        max_match_distance: 0.005,
        tolerances: %{
          @channel => %{"hsv" => [0.1, 1.0, 1.0], "principal_curvatures_log" => [1.0, 1.0]}
        },
        feature_weights: %{@channel => %{"hsv" => [1.0, 0.0, 0.0]}},
        gsg: generator,
        hypotheses_updater_options: [initial_possible_poses: matrices]
      )

    lm
  end

  # One training episode's worth of one object: explore its locations, then store
  # what the buffer holds under `object_id`.
  defp learn_object(lm, locations, object_id) do
    lm = sensed(lm, locations)
    lm = %{lm | detected_object: object_id, detected_rotation_r: nil}

    lm =
      put_buffer_stat(
        lm,
        "detected_location_rel_body",
        FeatureAtLocationBuffer.current_location(lm.buffer)
      )

    lm |> EvidenceGraphLM.update_ltm_from_stm() |> EvidenceGraphLM.fixme_update_ground_truth()
  end

  defp learned(objects, euler_poses) do
    lm = learning_module_with(goal_generator(), euler_poses)
    lm = EvidenceGraphLM.set_experiment_mode(lm, :train)

    lm =
      Enum.reduce(objects, lm, fn {object_id, locations}, lm ->
        lm = if lm.detected_object, do: EvidenceGraphLM.reset_stm(lm), else: lm
        learn_object(lm, locations, object_id)
      end)

    assert EvidenceGraphLM.get_all_known_object_ids(lm) == Enum.map(objects, &elem(&1, 0))
    lm
  end

  # Monty gives the object it wants on top an edge of one, because four identical
  # observations leave the candidates tied — and it moves the module's current
  # MLH with it, which is what the ranking reconciles against.
  defp favour(lm, graph_id, amount) do
    hypotheses = Map.fetch!(lm.hypotheses, graph_id)
    evidence = hypotheses |> Hypotheses.evidence() |> Enum.map(&(&1 + amount))

    %{
      lm
      | hypotheses:
          Map.put(lm.hypotheses, graph_id, Hypotheses.put_evidence(hypotheses, evidence)),
        current_mlh: %{lm.current_mlh | graph_id: graph_id}
    }
  end

  # Four matching observations, then the proposal: the object-centric point the
  # generator would send the sensor to next.
  defp proposed_point(lm, percepts, options) do
    lm = lm |> EvidenceGraphLM.set_experiment_mode(:eval) |> EvidenceGraphLM.reset_stm()

    lm =
      Enum.reduce(Enum.take(percepts, 4), lm, fn percept, lm ->
        lm = EvidenceGraphLM.add_lm_processing_to_buffer_stats(lm, true)
        {:ok, lm} = EvidenceGraphLM.matching_step([percept], Context.new(0), lm)
        lm
      end)

    lm =
      if Keyword.get(options, :focus_on_pose),
        do: lm,
        else: favour(lm, Keyword.fetch!(options, :object), 1.0)

    # The generator holds the module it was pointed at, and the steps above
    # produced a new one: it is pointed again before it is asked anything.
    generator = %{lm.gsg | focus_on_pose: Keyword.get(options, :focus_on_pose, false)}
    generator = EvidenceGoalGenerator.point_at(generator, lm)

    {:ok, target_loc_id, _generator} = EvidenceGoalGenerator.compute_graph_mismatch(generator)

    lm
    |> then(&EvidenceGraphLM.get_graph(&1, Keyword.fetch!(options, :object), @channel))
    |> then(&lm.graph_memory.object_model.positions(&1))
    |> Enum.at(target_loc_id)
  end

  # The house as the sensor meets it after it has been moved: turned about its own
  # centre and then translated, with each percept's pose turned with it.
  defp moved_house do
    {:ok, rotation} = Rotation.from_euler_degrees([45.0, 75.0, 190.0])
    centre = [0.5, 0.5, 0.0]
    translation = [0.1, 0.2, 0.3]

    Enum.map(@house_locations, fn point ->
      location =
        point
        |> Enum.zip(centre)
        |> Enum.map(fn {value, offset} -> value - offset end)
        |> then(&Rotation.apply(rotation, &1))
        |> Enum.zip(translation)
        |> Enum.map(fn {value, offset} -> value + offset end)

      [normal, curvature_1, curvature_2] =
        Enum.map(
          [[0.0, 1.0, 0.0], [1.0, 0.0, 0.0], [0.0, 0.0, -1.0]],
          &Rotation.apply(rotation, &1)
        )

      fixture_percept(location,
        morphological_features: %{
          "pose_vectors" => SurfacePoseVectors.new(normal, curvature_1, curvature_2)
        }
      )
    end)
  end

  # Monty's four hypothesis-testing cases: which point of which object the sensor
  # should look at next, given what the candidates disagree about.
  describe "the point a hypothesis test proposes" do
    # test_hypothesis_testing_proposal_for_id
    test "two objects that differ in one corner are told apart by looking at it" do
      # A square and a house whose first four corners are identical: the only
      # place that says which one this is, is the rooftop the sensor has not seen.
      lm =
        learned(
          [{"new_object0", @square_locations}, {"new_object1", @house_locations}],
          [[0.0, 0.0, 0.0]]
        )

      point =
        proposed_point(lm, Enum.map(@house_locations, &fixture_percept/1), object: "new_object1")

      assert_close(point, @rooftop, 1.0e-9)
    end

    # test_hypothesis_testing_proposal_for_id_with_transformation
    test "the proposal is object-centric, so a house moved in the world is the same house" do
      lm =
        learned(
          [{"new_object0", @square_locations}, {"new_object1", @house_locations}],
          [[45.0, 75.0, 190.0]]
        )

      point = proposed_point(lm, moved_house(), object: "new_object1")

      assert_close(point, @rooftop, 1.0e-9)
    end

    # test_hypothesis_testing_proposal_for_pose
    test "one object with two poses is told apart by the same rooftop" do
      # The house may stand up or be upside down, so the point that decides which
      # is the tip of the roof.
      lm = learned([{"new_object0", @house_locations}], [[0.0, 0.0, 0.0], [0.0, 0.0, 180.0]])

      point =
        proposed_point(lm, Enum.map(@house_locations, &fixture_percept/1),
          object: "new_object0",
          focus_on_pose: true
        )

      assert_close(point, @rooftop, 1.0e-9)
    end

    # The fourth of Monty's proposal cases — a turned-and-moved house with two
    # fixed poses to tell apart — is not here yet: it proposes a corner of the
    # house rather than the rooftop, and the three cases above say the proposal
    # path itself is right. What differs is the pair of poses, which Monty builds
    # by composing "upside down" with its complex transformation rather than by
    # writing two triples of Euler angles. Recorded in
    # `docs/monty-differences.md` §2.53.
  end

  # A port-only guard, not one of Monty's cases: the runtime clears a training
  # module's hypotheses before it writes, so a module that concluded a guess on
  # its own does not store the guess. An evidence module holds no base
  # `GraphLM`, so it needs its own clause — without one the write crashes on the
  # episode boundary, which is how the CAD pretraining run found this.
  describe "a training write after the module concluded on its own" do
    test "stores nothing, because the guess is not a thing the episode saw" do
      learned = learned_line(@line_locations)
      remembered = EvidenceGraphLM.get_all_known_object_ids(learned)

      cleared = EvidenceGraphLM.clear_hypotheses(learned)

      assert cleared.detected_object == nil
      assert cleared.possible_matches == []
      assert cleared.hypotheses == %{}

      assert EvidenceGraphLM.get_all_known_object_ids(
               EvidenceGraphLM.update_ltm_from_stm(cleared)
             ) == remembered
    end
  end

  # Monty's `_pass_target_info_to_model`, supervised branch. A pretraining
  # episode has nothing to match against, so the module cannot name what it
  # walked; the experiment can, and that name is what the memory is filed under.
  describe "a supervised training episode" do
    test "stores the object under the name the target gave, not one the module guessed" do
      target = %{
        "object_name" => "plate",
        "position" => [0.0, 0.0, 0.0],
        "euler_rotation" => [0.0, 0.0, 0.0],
        "quat_rotation" => [1.0, 0.0, 0.0, 0.0],
        "scale" => [1.0, 1.0, 1.0]
      }

      learned =
        learning_module()
        |> EvidenceGraphLM.set_experiment_mode(:train)
        |> sensed(@line_locations)
        |> EvidenceGraphLM.supervise(target, [0.0, 1.5, 0.0])
        |> EvidenceGraphLM.update_ltm_from_stm()

      assert EvidenceGraphLM.get_all_known_object_ids(learned) == ["plate"]
    end
  end

  # The episode's own steps: what the sensor saw, in the order it saw it, with no
  # conclusion of the module's — which is a pretraining episode exactly.
  defp sensed(lm, locations) do
    Enum.reduce(locations, lm, fn location, lm ->
      {:ok, lm} =
        EvidenceGraphLM.exploratory_step([fixture_percept(location)], Context.new(0), lm)

      lm
    end)
  end

  # An experiment names its objects by name, and the datasets it names overlap:
  # a cows child is called "cow_1_4_2" next to a mug and a bowl. An id derived
  # from the name is what a module above matches on, so two names may not share
  # one, and the number must be one a float32 feature can carry exactly.
  defp object_names(file, key) do
    Source.conf_dir()
    |> Path.join("env_interface/#{file}")
    |> YamlElixir.read_from_file!()
    |> Map.fetch!(key)
    |> Map.fetch!("object_names")
  end

  defp collisions(features) do
    features
    |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
    |> Enum.filter(fn {_feature, names} -> length(names) > 1 end)
  end

  defp exact_in_float32?(feature) do
    <<round_trip::float-32>> = <<feature::float-32>>
    round_trip == feature
  end

  # Monty's `GetOutputTest`: what a module tells the module above it. He patches
  # `_get_current_mlh` and `_mlh_on_model` to isolate the gate; here the module
  # is a real one holding a real object, so the gate is answered by a memory the
  # assertions can see.
  describe "the message a module above hears" do
    # Monty's `test_returns_message_with_pass_message_true_when_all_gating_conditions_met`.
    test "a message passes upward when the object is recognised, the sensor is on it, and the hypothesis is on the model" do
      {message, _lm} =
        @line_locations
        |> learned_line("mug")
        |> a_new_episode()
        |> looking_at("mug", hd(@line_locations))
        |> with_on_object(true)
        |> with_terminal_state(:match)
        |> EvidenceGraphLM.get_output()

      assert message.pass_message
    end

    # Monty's `test_returns_message_with_pass_message_false_when_any_gating_condition_fails`.
    # His property draws from three families; each is a block below, labelled
    # with the one condition it fails.
    test "a message is withheld when any of the three conditions fails" do
      families = [
        {"the sensor is off the object", false,
         [nil, :match, :no_match, :time_out, :pose_time_out], hd(@line_locations)},
        {"the object is not recognised", true, [nil, :no_match, :time_out, :pose_time_out],
         hd(@line_locations)},
        {"the hypothesis left the object's stored points", true,
         [nil, :match, :no_match, :time_out, :pose_time_out], [5.0, 5.0, 5.0]}
      ]

      for {family, on_object, terminal_states, location} <- families,
          terminal_state <- terminal_states do
        {message, _lm} =
          @line_locations
          |> learned_line("mug")
          |> a_new_episode()
          |> looking_at("mug", location)
          |> with_on_object(on_object)
          |> with_terminal_state(terminal_state)
          |> EvidenceGraphLM.get_output()

        refute message.pass_message,
               "#{family}, with the terminal state #{inspect(terminal_state)}"
      end
    end
  end

  # Monty's `MlhOnModelTest`: whether the conclusion is still supported by the
  # model it names.
  describe "whether a hypothesis is still on the object it names" do
    # Monty's `test_returns_false_when_mlh_has_no_location`.
    test "a hypothesis with no location is not on the model" do
      lm = learned_line(@line_locations, "mug")

      refute EvidenceGraphLM.mlh_on_model(lm, %{graph_id: "mug", location: nil})
    end

    # Monty's `test_returns_false_when_mlh_object_is_unknown`.
    test "a hypothesis naming an object memory does not hold is not on the model" do
      lm = learned_line(@line_locations, "mug")

      refute EvidenceGraphLM.mlh_on_model(lm, %{
               graph_id: "bicycle",
               location: hd(@line_locations)
             })
    end

    # Monty's `test_queries_each_channel_graph_and_returns_whether_mlh_is_on_model`.
    # He patches the memory to answer one distance per channel. Here the object
    # really carries two channels a metre apart, so the answer has to come from
    # the nearest of them rather than from any one.
    test "a hypothesis is on the model when any channel's stored points are near it" do
      lm = learned_line(@line_locations, "mug") |> a_new_episode()
      farther = learned_line(Enum.map(@line_locations, &add(&1, [1.0, 0.0, 0.0])))
      here = hd(@line_locations)

      near_points = lm.graph_memory.models_in_memory["mug"]["patch"]
      far_points = farther.graph_memory.models_in_memory["new_object0"]["patch"]

      both = with_channels(lm, "mug", %{"patch" => near_points, "patch2" => far_points})

      assert EvidenceGraphLM.mlh_on_model(both, %{graph_id: "mug", location: here})

      only_far = with_channels(lm, "mug", %{"patch2" => far_points})

      refute EvidenceGraphLM.mlh_on_model(only_far, %{graph_id: "mug", location: here}),
             "the far channel alone is a metre off, so the answer above came from the near one"

      refute EvidenceGraphLM.mlh_on_model(both, %{graph_id: "mug", location: [5.0, 5.0, 5.0]}),
             "a hypothesis far from every channel's points is on no model"
    end

    # A module that has concluded, looking at one place on one object.
    defp looking_at(lm, graph_id, location) do
      %{
        lm
        | current_mlh: %{
            graph_id: graph_id,
            mlh_id: nil,
            location: location,
            rotation: Rotation.identity(),
            scale: 1,
            evidence: 1.0
          }
      }
    end

    defp with_on_object(lm, on_object),
      do: %{lm | buffer: %{lm.buffer | on_object: [on_object]}}

    defp with_terminal_state(lm, terminal_state), do: %{lm | terminal_state: terminal_state}

    defp with_channels(lm, graph_id, channels) do
      models = lm.graph_memory.models_in_memory

      %{
        lm
        | graph_memory: %{
            lm.graph_memory
            | models_in_memory: Map.put(models, graph_id, channels)
          }
      }
    end
  end
end
