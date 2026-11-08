defmodule Monty.Frameworks.Models.FeatureLocationMatching.FeatureGraphLMTest do
  @moduledoc """
  The feature-at-location module: recognise an object by what is sensed at each
  location, and by which poses make the moves agree.

  Monty has no unit test for `feature_location_matching.py` either — only
  integration experiments — so every case here is hand-written intent rather
  than a translation. The fixtures are deliberately small enough to check by
  reading: three nodes a decimetre apart along x, all facing `+z` unless a case
  says otherwise, and steps of exactly that decimetre.
  """

  use ExUnit.Case, async: true

  alias Monty.Context
  alias Monty.Frameworks.Models.FeatureLocationMatching.FeatureGraphLM
  alias Monty.Frameworks.Models.GraphMatching.GraphLM
  alias Monty.Frameworks.Models.GraphMatching.GraphMemory
  alias Monty.Frameworks.Models.ObjectModel.GraphObjectModel
  alias Monty.Geometry.SurfacePoseVectors
  alias Monty.Test.Messages

  @line [[0.0, 0.0, 0.0], [0.1, 0.0, 0.0], [0.2, 0.0, 0.0]]

  # A pose vector row: the normal, then the two directions across it.
  defp pose_facing([x, y, z]) do
    across = if abs(z) < 0.5, do: [0.0, 0.0, 1.0], else: [1.0, 0.0, 0.0]
    first = orthogonalise(across, [x, y, z])
    second = cross([x, y, z], first)
    [x, y, z] ++ first ++ second
  end

  defp orthogonalise([ax, ay, az], [x, y, z]) do
    dot = ax * x + ay * y + az * z
    normalised([ax - dot * x, ay - dot * y, az - dot * z])
  end

  defp normalised(vector) do
    length = :math.sqrt(Enum.sum(Enum.map(vector, &(&1 * &1))))
    Enum.map(vector, &(&1 / length))
  end

  defp cross([a1, a2, a3], [b1, b2, b3]) do
    [a2 * b3 - a3 * b2, a3 * b1 - a1 * b3, a1 * b2 - a2 * b1]
  end

  # Three nodes a decimetre apart on x, each sensing its own shade of grey, all
  # facing `+z` unless a case says otherwise.
  defp model(object_id, options \\ []) do
    normals = Keyword.get(options, :normals, List.duplicate([0.0, 0.0, 1.0], length(@line)))
    shades = Keyword.get(options, :rgba, Enum.map(0..2, fn shade -> [shade * 1.0, 0.0, 0.0] end))

    features = %{
      "rgba" => shades,
      "principal_curvatures" => List.duplicate([0.5, 0.5], length(@line)),
      "pose_vectors" => Enum.map(normals, &pose_facing/1)
    }

    GraphObjectModel.new(object_id)
    |> GraphObjectModel.build_model(@line, features, 2, nil)
  end

  defp memory(models) do
    Enum.reduce(models, GraphMemory.new(k: 2), fn {graph_id, model}, memory ->
      GraphMemory.add_graph_to_memory(memory, %{"sensor_module" => model}, graph_id)
    end)
  end

  defp new_lm(models, overrides \\ []) do
    FeatureGraphLM.new(
      Keyword.merge(
        [
          max_match_distance: 0.05,
          tolerances: %{
            "sensor_module" => %{
              "rgba" => [0.1, 0.1, 0.1],
              "principal_curvatures" => [1.0, 1.0],
              "pose_vectors" => [20, 20, 20]
            }
          },
          memory: memory(models)
        ],
        overrides
      )
    )
  end

  defp percept(location, overrides) do
    Messages.percept(Map.merge(%{location: location, sender_id: "sensor_module"}, overrides))
  end

  # What the sensor senses at a place: the shade there, and a frame facing +z.
  defp sensing(location, rgba, overrides \\ %{}) do
    morphological_features = %{
      "pose_vectors" => SurfacePoseVectors.new([0.0, 0.0, 1.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]),
      "pose_fully_defined" => true,
      "on_object" => true,
      "rgba" => rgba,
      "principal_curvatures" => [0.5, 0.5]
    }

    percept(
      location,
      Map.merge(%{morphological_features: morphological_features}, overrides)
    )
  end

  defp step(lm, perceptions) when is_list(perceptions) do
    {:ok, stepped} = FeatureGraphLM.matching_step(perceptions, Context.new(0), lm)
    stepped
  end

  defp step(lm, perception), do: step(lm, [perception])

  defp possible(lm), do: lm.graph_lm |> GraphLM.get_possible_matches() |> Enum.sort()

  describe "what a config asks for" do
    test "the module the experiment configs name, with pose tolerances in radians" do
      {:ok, lm} =
        FeatureGraphLM.from_config(%{
          "max_match_distance" => 0.01,
          "tolerances" => %{
            "patch" => %{
              "on_object" => 0,
              "rgba" => [10, 10, 10, 10],
              "principal_curvatures" => [1, 1],
              "pose_vectors" => [40, 360, 360]
            }
          }
        })

      assert lm.max_match_distance == 0.01
      assert %{"patch" => %{"pose_vectors" => [normal, _, _]}} = lm.tolerances
      assert_in_delta normal, :math.pi() * 40 / 180, 1.0e-12
      assert lm.initial_possible_poses == nil
    end

    test "a pose mode this port does not read is refused rather than guessed" do
      assert_raise ArgumentError, ~r/is not one this port reads/, fn ->
        FeatureGraphLM.new(max_match_distance: 0.01, initial_possible_poses: "sideways")
      end
    end
  end

  describe "the first observation" do
    test "narrows the object to the nodes that carry what was sensed" do
      lm =
        new_lm(%{"mug" => model("mug")})
        |> step(sensing([0.1, 0.0, 0.0], [1.0, 0.0, 0.0]))

      # Only the middle node is that shade, so it is the one place the sensor
      # can be — as a path of one location, which is what the next step extends.
      assert possible(lm) == ["mug"]
      assert lm.graph_lm.possible_paths["mug"] == [[[0.1, 0.0, 0.0]]]

      # Both rotations are consistent with a defined pose, because a surface
      # looks the same with its curvature directions flipped.
      assert [[_, _]] = lm.possible_poses["mug"]
    end

    test "a shade no node carries rules the object out, and the episode is over" do
      lm =
        new_lm(%{"mug" => model("mug")})
        |> step(sensing([0.0, 0.0, 0.0], [9.0, 0.0, 0.0]))

      assert possible(lm) == []
      assert lm.graph_lm.terminal_state == :no_match
    end

    test "an object whose nodes all carry the shade keeps every one of them" do
      lm =
        new_lm(%{"mug" => model("mug", rgba: List.duplicate([1.0, 0.0, 0.0], 3))})
        |> step(sensing([0.1, 0.0, 0.0], [1.0, 0.0, 0.0]))

      assert lm.graph_lm.possible_paths["mug"] == Enum.map(@line, &[&1])
    end
  end

  describe "a step that follows one" do
    test "lands on the neighbour the move reaches, and the object is recognised" do
      lm =
        new_lm(%{"mug" => model("mug")}, required_symmetry_evidence: 5)
        # Start on the first node, then step a decimetre onto the second.
        |> step(sensing([0.0, 0.0, 0.0], [0.0, 0.0, 0.0]))
        |> step(sensing([0.1, 0.0, 0.0], [1.0, 0.0, 0.0]))

      # One place and one rotation is left: the sensor is a decimetre along the
      # object, and the pose is the identity's inverse — nothing was turned.
      assert lm.graph_lm.possible_paths["mug"] == [[[0.0, 0.0, 0.0], [0.1, 0.0, 0.0]]]

      {lm, terminal_state} = FeatureGraphLM.update_terminal_condition(lm)

      assert terminal_state == :match
      assert lm.graph_lm.detected_pose == [0.1, 0.0, 0.0, 0.0, 0.0, 0.0, 1]
    end

    test "lands nowhere within the match distance, so the object is ruled out" do
      lm =
        new_lm(%{"mug" => model("mug")})
        |> step(sensing([0.0, 0.0, 0.0], [0.0, 0.0, 0.0]))
        # Half a metre is not an edge of this object, and its end is nowhere near
        # a node the shade allows.
        |> step(sensing([0.5, 0.0, 0.0], [1.0, 0.0, 0.0]))

      assert possible(lm) == []
    end

    test "lands on a node whose surface faces elsewhere, so the object is ruled out" do
      normals = [[0.0, 0.0, 1.0], [1.0, 0.0, 0.0], [0.0, 0.0, 1.0]]

      lm =
        new_lm(%{"mug" => model("mug", normals: normals)})
        |> step(sensing([0.0, 0.0, 0.0], [0.0, 0.0, 0.0]))
        |> step(sensing([0.1, 0.0, 0.0], [1.0, 0.0, 0.0]))

      # The shade matches the middle node and the place is right, but the sensor
      # sees a `+z` surface there and the node says `+x` — a quarter turn apart,
      # which no tolerance of this module allows.
      assert possible(lm) == []
    end
  end

  describe "an object that looks the same from several sides" do
    test "is recognised once the same handful of poses has held for long enough" do
      # Nodes that all sense the same thing and face the same way: from any of
      # them the others look identical, so nothing narrows the poses down — which
      # is what a symmetry is. The counter lives in the terminal condition, which
      # the model asks after every step, so it is asked here too.
      same_everywhere = model("mug", rgba: List.duplicate([1.0, 0.0, 0.0], 3))

      lm = new_lm(%{"mug" => same_everywhere}, required_symmetry_evidence: 1)
      lm = step(lm, sensing([0.0, 0.0, 0.0], [1.0, 0.0, 0.0]))

      {lm, terminal_state} = FeatureGraphLM.update_terminal_condition(lm)
      assert terminal_state == nil
      assert lm.symmetry_evidence == 0

      lm = step(lm, sensing([0.0, 0.0, 0.0], [1.0, 0.0, 0.0]))
      {lm, terminal_state} = FeatureGraphLM.update_terminal_condition(lm)

      assert lm.symmetry_evidence == 1
      assert terminal_state == :match
    end
  end
end
