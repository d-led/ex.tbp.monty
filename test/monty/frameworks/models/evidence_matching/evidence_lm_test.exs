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
  alias Monty.Geometry.{Rotation, SurfacePoseVectors}

  @channel "patch"

  # The fixture's four points: a corner of space walked one axis at a time.
  @line_locations [[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [1.0, 1.0, 0.0], [1.0, 1.0, 1.0]]

  # The same three corners with the fourth moved into the plane, so the object
  # looks the same after half a turn: the fixture's "symmetric" object.
  @symmetric_locations [[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [1.0, 1.0, 0.0], [0.0, 1.0, 0.0]]

  describe "an object's identity as a feature" do
    # Monty's `test_object_id_features_are_unique_and_float32_safe`. It drives
    # the private `_object_id_to_features`; here that is the public
    # `EvidenceGraphLM.object_id_of/1`.
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
        features = Enum.map(ids, &{&1, EvidenceGraphLM.object_id_of(&1)})

        assert collisions(features) == [],
               "#{dataset}: #{inspect(collisions(features))}"

        for {name, feature} <- features do
          assert exact_in_float32?(feature),
                 "#{dataset}: #{name} is #{feature}, which a float32 cannot hold"

          assert EvidenceGraphLM.object_id_of(name) == feature,
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

      before = EvidenceGraphLM.current_mlh(lm)
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

      now = EvidenceGraphLM.current_mlh(lm)

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
          {lm, evidences ++ [EvidenceGraphLM.current_mlh(lm).evidence]}
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

            {lm, evidences ++ [EvidenceGraphLM.current_mlh(lm).evidence]}
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

          evidence = EvidenceGraphLM.most_likely_hypothesis(lm, "new_object0").evidence

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

        mlh = EvidenceGraphLM.current_mlh(lm)
        assert mlh.graph_id == "new_object0", "new_object0 should be the mlh at every step."

        {lm, [mlh.evidence | evidences]}
      end)

    {lm, Enum.reverse(evidences)}
  end

  defp rotation_of(lm), do: Rotation.to_euler_degrees(EvidenceGraphLM.current_mlh(lm).rotation)

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
  defp learned_line(locations) do
    lm = learning_module() |> EvidenceGraphLM.set_experiment_mode(:train)

    lm =
      Enum.reduce(locations, lm, fn location, lm ->
        {:ok, lm} =
          EvidenceGraphLM.exploratory_step([fixture_percept(location)], Context.new(0), lm)

        lm
      end)

    lm = %{lm | detected_object: "new_object0", detected_rotation_r: nil}

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

    assert EvidenceGraphLM.get_all_known_object_ids(lm) == ["new_object0"],
           "Learning the line should leave exactly one object in memory."

    lm
  end

  # Monty's test writes the buffer's own statistics after a training episode;
  # a step does not set the detected location, the episode's end does.
  defp put_buffer_stat(lm, key, value) do
    %{lm | buffer: %{lm.buffer | stats: Map.put(lm.buffer.stats, key, value)}}
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
end
