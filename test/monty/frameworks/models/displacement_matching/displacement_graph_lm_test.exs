defmodule Monty.Frameworks.Models.DisplacementMatching.DisplacementGraphLMTest do
  @moduledoc """
  A displacement module, as the tutorial uses it: one object, one sensor, and a
  match made of nothing but how far the sensor moved.

  Monty has no unit test for `displacement_matching.py`, so every case here is
  hand-written intent rather than a translation: what this port means by a path,
  a prediction and a pose. The numbers are chosen so the arithmetic can be
  checked by reading it — three nodes a decimetre apart along x, and steps of
  exactly that decimetre.
  """

  use ExUnit.Case, async: true

  alias Monty.Context
  alias Monty.Frameworks.Models.Buffer.FeatureAtLocationBuffer
  alias Monty.Frameworks.Models.DisplacementMatching.DisplacementGraphLM
  alias Monty.Frameworks.Models.GraphMatching.GraphLM
  alias Monty.Frameworks.Models.GraphMatching.GraphMemory
  alias Monty.Frameworks.Models.ObjectModel.GraphObjectModel
  alias Monty.Test.Messages

  @pose [0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0]
  @line [[0.0, 0.0, 0.0], [0.1, 0.0, 0.0], [0.2, 0.0, 0.0]]

  # Three nodes a decimetre apart on the x axis, linked to their two nearest
  # neighbours: edges of 0.1 and 0.2, forwards and backwards.
  defp model(object_id, locations \\ @line) do
    features = %{
      "rgba" => Enum.map(locations, fn [x | _] -> [x] end),
      "pose_vectors" => List.duplicate(@pose, length(locations))
    }

    GraphObjectModel.new(object_id)
    |> GraphObjectModel.build_model(locations, features, 2, nil)
  end

  defp memory(models) do
    models
    |> Enum.reduce(GraphMemory.new(k: 2, features_to_use: %{"patch" => ["rgba"]}), fn {graph_id,
                                                                                       model},
                                                                                      memory ->
      GraphMemory.add_graph_to_memory(memory, %{"patch" => model}, graph_id)
    end)
    |> GraphMemory.initialize_feature_arrays()
  end

  # A module that has learned `models` and is ready for its first step: the
  # memory is the only thing `new/1` cannot give it.
  defp new_lm(models) do
    lm = DisplacementGraphLM.new(k: 2)

    lm
    |> Map.put(:graph_lm, %{lm.graph_lm | graph_memory: memory(models)})
    |> DisplacementGraphLM.init_from_ltm()
  end

  defp percept(location, overrides \\ %{}),
    do: Messages.percept(Map.merge(%{location: location, sender_id: "patch"}, overrides))

  defp step(lm, location, overrides \\ %{}) do
    {:ok, stepped} =
      DisplacementGraphLM.matching_step([percept(location, overrides)], Context.new(0), lm)

    stepped
  end

  defp possible(lm), do: GraphLM.get_possible_matches(lm.graph_lm) |> Enum.sort()

  describe "what a module starts from" do
    test "every node is a place to be at the first step, and every edge a path a move extends" do
      lm = new_lm(%{"mug" => model("mug")})

      # Monty starts the paths with the node ids themselves: at the first step a
      # match is on a node, and a move is what turns it into a path.
      assert lm.possible_paths["mug"] == [0, 1, 2]

      # Each node links to its two nearest neighbours, so every pair is linked
      # both ways: three nodes, six edges.
      assert length(lm.next_possible_paths["mug"]) == 6
      assert Enum.member?(lm.next_possible_paths["mug"], [0, 1])
      assert Enum.member?(lm.next_possible_paths["mug"], [2, 1])

      # The scale factor of an edge is its displacement along the model's x axis.
      assert Enum.sort(lm.scale_factors["mug"]) == [-0.2, -0.1, -0.1, 0.1, 0.1, 0.2]
    end

    test "every object in memory is possible before anything is sensed" do
      assert possible(new_lm(%{"mug" => model("mug"), "cup" => model("cup")})) == ["cup", "mug"]
    end
  end

  describe "matching a displacement" do
    test "a move the graph has an edge for keeps the object" do
      lm = new_lm(%{"mug" => model("mug")}) |> step([0.0, 0.0, 0.0]) |> step([0.1, 0.0, 0.0])

      assert possible(lm) == ["mug"]
      assert lm.possible_paths["mug"] == [[0, 1], [1, 2]]
    end

    test "a move no edge of the object has rules it out" do
      lm = new_lm(%{"mug" => model("mug")}) |> step([0.0, 0.0, 0.0]) |> step([0.5, 0.0, 0.0])

      assert possible(lm) == []
      assert lm.graph_lm.terminal_state == :no_match
    end

    # The rule is "has an edge like that", not "is the object still there": the
    # same displacement is kept from a graph whose edges it matches, and a graph
    # built of nodes a decimetre apart can only account for moves of that size.
    test "one object is kept and the other ruled out by the same move" do
      far = model("far", [[0.0, 0.0, 0.0], [0.6, 0.0, 0.0], [1.2, 0.0, 0.0]])
      lm = new_lm(%{"mug" => model("mug"), "far" => far})

      lm = lm |> step([0.0, 0.0, 0.0]) |> step([0.1, 0.0, 0.0])

      assert possible(lm) == ["mug"]
    end

    test "a sensor that has not moved narrows nothing, because there is nothing to match" do
      lm = new_lm(%{"mug" => model("mug"), "cup" => model("cup")}) |> step([0.0, 0.0, 0.0])

      assert possible(lm) == ["cup", "mug"]
      assert lm.possible_paths["mug"] == [0, 1, 2]
    end
  end

  describe "the pose a module reports" do
    test "a move along the axis it learned needs no turn and no scaling" do
      # 0.2 is the length of one edge only — node 0 to node 2 — so the path is
      # the only one left and the module can say where it is.
      lm =
        new_lm(%{"mug" => model("mug")})
        |> step([0.0, 0.0, 0.0])
        |> step([0.2, 0.0, 0.0])

      assert {:ok, pose} = DisplacementGraphLM.get_unique_pose_if_available(lm, "mug")
      assert [x, y, z | _] = pose.pose
      assert_in_delta x, 0.2, 1.0e-12
      assert_in_delta y, 0.0, 1.0e-12
      assert_in_delta z, 0.0, 1.0e-12

      assert Enum.all?(pose.rotation, &(abs(&1) < 1.0e-6))
      assert_in_delta pose.scale, 1.0, 1.0e-12
    end

    test "two paths are two places to be, so there is no pose yet" do
      lm = new_lm(%{"mug" => model("mug")}) |> step([0.0, 0.0, 0.0])

      assert DisplacementGraphLM.get_unique_pose_if_available(lm, "mug") == :not_narrowed
    end

    test "a conclusion records the pose it concluded with" do
      lm =
        new_lm(%{"mug" => model("mug")})
        |> step([0.0, 0.0, 0.0])
        |> step([0.2, 0.0, 0.0])

      {lm, terminal_state} = DisplacementGraphLM.update_terminal_condition(lm)

      assert terminal_state == :match
      assert lm.graph_lm.detected_object == "mug"
      assert [0.2, 0.0, 0.0, _, _, _, scale] = lm.graph_lm.detected_pose
      assert_in_delta scale, 1.0, 1.0e-12
      assert lm.graph_lm.buffer.stats["detected_path"] == [0, 2]
    end

    test "several possible objects are not a conclusion" do
      lm = new_lm(%{"mug" => model("mug")}) |> step([0.0, 0.0, 0.0])

      assert {_lm, nil} = DisplacementGraphLM.update_terminal_condition(lm)
    end
  end

  describe "the displacement a step carries" do
    test "is zero on the first step and the move on the next, with point pair features" do
      first = percept([0.0, 0.0, 0.0])
      lm = new_lm(%{"mug" => model("mug")})

      assert {:ok, [first_displaced]} = DisplacementGraphLM.add_displacements(lm, [first])
      assert first_displaced.displacement["displacement"] == [0.0, 0.0, 0.0]
      assert first_displaced.displacement["ppf"] == [0.0, 0.0, 0.0, 0.0]

      lm = step(lm, [0.0, 0.0, 0.0])
      assert FeatureAtLocationBuffer.current_displacement(lm.graph_lm.buffer) == [0.0, 0.0, 0.0]

      lm = step(lm, [0.1, 0.0, 0.0])
      [x | _] = FeatureAtLocationBuffer.current_displacement(lm.graph_lm.buffer)
      assert_in_delta x, 0.1, 1.0e-12
    end

    test "a step with no sensor module percept says so rather than moving by zero" do
      assert {:error, :no_sensor_module_location} =
               DisplacementGraphLM.add_displacements(new_lm(%{"mug" => model("mug")}), [])
    end
  end

  # `match_attribute: "PPF"` matches on four numbers per edge instead of the
  # displacement: the length and the angles between the line and the two nodes'
  # normals. Monty has no unit test for this either; the graph side is checked in
  # `GraphObjectModel` against the transform's own definition, and what is left
  # here is which of the four a step compares.
  describe "matching on point pair features" do
    # The same three nodes on a line, each facing `+z` unless a test says
    # otherwise, so an edge is the same length with the same three angles — the
    # shape a surface agent's steps make.
    defp ppf_model(object_id, normal \\ [0.0, 0.0, 1.0]) do
      features = %{
        "rgba" => Enum.map(@line, fn [x | _] -> [x] end),
        "pose_vectors" => List.duplicate(pose_facing(normal), length(@line))
      }

      GraphObjectModel.new(object_id, k_n: 2, has_ppf: true)
      |> GraphObjectModel.build_model(@line, features, 2, nil)
    end

    # A pose vector row: the normal, then the two directions across it.
    defp pose_facing([x, y, z]) do
      across =
        if abs(z) < 0.5, do: [0.0, 0.0, 1.0], else: [1.0, 0.0, 0.0]

      across = orthogonalise(across, [x, y, z])
      second = cross([x, y, z], across)
      [x, y, z] ++ across ++ second
    end

    defp orthogonalise([ax, ay, az], [x, y, z]) do
      dot = ax * x + ay * y + az * z
      [ax - dot * x, ay - dot * y, az - dot * z] |> normalised()
    end

    defp normalised(vector) do
      length = :math.sqrt(Enum.sum(Enum.map(vector, &(&1 * &1))))
      Enum.map(vector, &(&1 / length))
    end

    defp cross([a1, a2, a3], [b1, b2, b3]) do
      [a2 * b3 - a3 * b2, a3 * b1 - a1 * b3, a1 * b2 - a2 * b1]
    end

    defp ppf_lm(models, overrides \\ []) do
      lm =
        DisplacementGraphLM.new(Keyword.merge([k: 2, match_attribute: "PPF"], overrides))

      lm
      |> Map.put(:graph_lm, %{lm.graph_lm | graph_memory: memory(models)})
      |> DisplacementGraphLM.init_from_ltm()
    end

    test "a step of a length and angle the graph has an edge for keeps the object" do
      lm = ppf_lm(%{"mug" => ppf_model("mug")}) |> step([0.0, 0.0, 0.0]) |> step([0.1, 0.0, 0.0])

      # Every edge a decimetre long reads [0.1, 90°, 90°, 0°], and so does the
      # step: 0.1 along x under normals of +z. The four one-decimetre edges are
      # kept, in both directions — which is what the attribute buys, since a
      # point-pair feature has no sign the way a displacement has.
      assert possible(lm) == ["mug"]
      assert lm.possible_paths["mug"] == [[0, 1], [1, 0], [1, 2], [2, 1]]
    end

    test "a step no edge of the object has rules it out" do
      lm = ppf_lm(%{"mug" => ppf_model("mug")}) |> step([0.0, 0.0, 0.0]) |> step([0.3, 0.0, 0.0])

      assert possible(lm) == []
    end

    # What the attribute buys over a displacement: a length alone does not say
    # which way the surface faces, so two graphs of the same shape are told
    # apart by the three angles.
    test "the angles tell two graphs of the same length apart" do
      models = %{
        "facing_z" => ppf_model("facing_z"),
        "facing_x" => ppf_model("facing_x", [1.0, 0.0, 0.0])
      }

      # The patch's own normal is +z, so the step's four numbers are
      # [0.1, 90°, 90°, 0°] — an edge of the +z graph, and not of the +x one,
      # whose edges read [0.1, 0°, 0°, 0°].
      lm = ppf_lm(models) |> step([0.0, 0.0, 0.0]) |> step([0.1, 0.0, 0.0])

      assert possible(lm) == ["facing_z"]
    end

    # A scale-invariant module matches a step against an edge by the ratio each
    # length makes with the first one it saw: Monty divides the query's first
    # component by the buffer's first step, and an edge's by the length of the
    # *first edge of the path* being tested. So steps that are the same length as
    # each other match a graph of decimetres, which no length comparison can.
    test "a scale-invariant module compares the ratio of lengths, not the lengths" do
      # Two steps of 0.4: the query reads [1.0, angles]. Every path whose tested
      # edge is as long as its first edge reads [1.0, angles] too — the paths
      # starting on a 0.1 edge and still on one, since this graph's edges are all
      # 0.1 or 0.2.
      relative =
        ppf_lm(%{"mug" => ppf_model("mug")}, use_relative_len: true)
        |> step([0.0, 0.0, 0.0])
        |> step([0.4, 0.0, 0.0])

      assert possible(relative) == ["mug"]

      # The same two steps compared as lengths: 0.4 is not an edge of this graph,
      # so nothing can be on it.
      absolute =
        ppf_lm(%{"mug" => ppf_model("mug")})
        |> step([0.0, 0.0, 0.0])
        |> step([0.4, 0.0, 0.0])

      assert possible(absolute) == []
    end

    test "an attribute this port has no comparison for is refused rather than matched differently" do
      assert_raise ArgumentError, ~r/is not ported/, fn ->
        DisplacementGraphLM.new(match_attribute: "normals")
      end
    end

    test "a config asking for that is refused with a reason, not built" do
      assert DisplacementGraphLM.from_config(%{"match_attribute" => "normals"}) ==
               {:error, {:unsupported_match_attribute, "normals"}}
    end
  end

  describe "as a learning module" do
    # The coordinator reaches a module only through the behaviour's callbacks, so
    # a class that left one unanswered could not be stepped at all — it would
    # fail on the first episode rather than on the first line that says so.
    test "answers every callback the learning module behaviour declares" do
      # `function_exported?/3` answers for a module that is *loaded*, and a module
      # is loaded when something first calls it. A run that reaches this test
      # before anything else has asked this module anything — a different seed, a
      # different partition — got every callback reported missing, which is a
      # green suite that fails on a coin toss.
      {:module, _loaded} = Code.ensure_loaded(DisplacementGraphLM)

      missing =
        for {name, arity} <-
              Monty.Frameworks.Models.AbstractMontyClasses.LearningModule.behaviour_info(
                :callbacks
              ),
            not function_exported?(DisplacementGraphLM, name, arity),
            do: {name, arity}

      assert missing == []
    end

    test "keeps the hypothesis space the memory starts it with" do
      lm = new_lm(%{"mug" => model("mug")})

      assert GraphLM.get_possible_matches(lm.graph_lm) == ["mug"]
      assert lm.possible_paths["mug"] == [0, 1, 2]

      # One two-node path per edge, two edges per node: the order is the memory's
      # own, and what the step is matched against.
      assert Enum.sort(lm.next_possible_paths["mug"]) ==
               [[0, 1], [0, 2], [1, 0], [1, 2], [2, 0], [2, 1]]
    end

    test "states a supervised answer about the graph module underneath" do
      target = %{
        "object_name" => "mug",
        "position" => [0.0, 1.5, 0.0],
        "euler_rotation" => [0.0, 0.0, 0.0],
        "quat_rotation" => [1.0, 0.0, 0.0, 0.0],
        "scale" => [1.0, 1.0, 1.0]
      }

      supervised = DisplacementGraphLM.supervise(new_lm(%{}), target, [0.0, 1.5, 0.0])

      assert GraphLM.conclusion(supervised.graph_lm) == nil
      assert supervised.graph_lm.detected_object == "mug"
      assert supervised.graph_lm.buffer.stats["possible_matches"] == ["mug"]
    end
  end
end
