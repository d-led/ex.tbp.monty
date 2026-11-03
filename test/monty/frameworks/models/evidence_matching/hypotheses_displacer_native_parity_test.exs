defmodule Monty.Frameworks.Models.EvidenceMatching.HypothesesDisplacerNativeParityTest do
  @moduledoc """
  The native neighbour kernel answers what the reference answers.

  One evidence step is run twice over the same graph, the same features and the
  same hypotheses: once with `native_kernels?` on and once with it off, which is
  the switch `ExTbpMonty.MatcherNif.loaded?/0` reads. The two answers have to be
  the same numbers, not near enough — the kernel performs the reference's
  arithmetic in the reference's order, so a difference in the last bit is a
  difference in what was computed.

  `async: false`, because the switch is application configuration and a
  concurrently running test would read it while this one holds it.

  The graph is deliberately awkward: a node turned away from the sense, a node
  whose pose was not fully defined, a hypothesis out of range of everything, and
  a curvature direction that is not perpendicular to its normal.
  """

  use ExUnit.Case, async: false

  alias ExTbpMonty.MatcherNif
  alias Monty.Frameworks.Models.EvidenceMatching.Hypotheses
  alias Monty.Frameworks.Models.EvidenceMatching.HypothesesDisplacer
  alias Monty.Frameworks.Models.GraphMatching.GraphMemory
  alias Monty.Frameworks.Models.ObjectModel.GraphObjectModel
  alias Monty.Geometry.Rotation

  @pose [0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0]
  @identity Rotation.to_matrix(Rotation.identity())

  setup do
    on_exit(fn -> Application.delete_env(:ex_tbp_monty, :native_kernels?) end)
    :ok
  end

  test "the kernel is loaded on this machine" do
    assert MatcherNif.loaded?()
  end

  test "every hypothesis earns the same evidence either way" do
    built = displacer()

    given =
      Hypotheses.new(
        evidence: [1.0, 1.0, 1.0, 1.0, 1.0],
        locations: [
          # on the first node, on a turned node, between two nodes, off the object
          # entirely, and on the node whose pose was not fully defined.
          [0.0, 0.0, 0.0],
          [0.1, 0.0, 0.0],
          [0.05, 0.0, 0.02],
          [0.0, 0.0, 5.0],
          [0.0, 0.1, 0.0]
        ],
        poses: [@identity, turned(), @identity, @identity, turned()],
        possible: [true, true, true, true, true]
      )

    native = evidence(built, given)

    reference = with_reference(fn -> evidence(built, given) end)

    assert native == reference
    assert length(native) == 5
    assert Enum.all?(native, &is_float/1)
  end

  test "a hypothesis with no neighbour in range earns the worst evidence either way" do
    # One node, far from where the hypothesis says the sensor is: the neighbour
    # is found, judged out of range, and scores `MIN_EVIDENCE` in both paths.
    # With no weight on the past, the answer is the observation's contribution
    # itself rather than the two blended together.
    built = displacer(locations: [[0.0, 0.0, 0.0]], past_weight: 0, present_weight: 1)

    given = hypotheses([1.0], [[0.0, 0.0, 5.0]])
    native = evidence(built, given)

    assert native == with_reference(fn -> evidence(built, given) end)
    assert native == [-1.0]
  end

  test "the switch reaches the reference path, which is otherwise the same step" do
    built = displacer()
    given = hypotheses([1.0], [[0.0, 0.0, 0.0]])

    Application.put_env(:ex_tbp_monty, :native_kernels?, false)

    assert evidence(built, given) == evidence(built, given)
    assert MatcherNif.loaded?() == false
  end

  test "every hypothesis is displaced to the same place either way" do
    built = displacer()
    given = hypotheses([1.0, 1.0], [[0.0, 0.0, 0.0], [0.1, 0.0, 0.0]], [@identity, turned()])

    native = HypothesesDisplacer.displace_hypotheses(built, given, [0.2, -0.1, 0.05])

    reference =
      with_reference(fn ->
        HypothesesDisplacer.displace_hypotheses(built, given, [0.2, -0.1, 0.05])
      end)

    assert Hypotheses.locations(native) == Hypotheses.locations(reference)
    # The first hypothesis asks no rotation of the step, so it moves by it.
    assert [moved, _turned] = Hypotheses.locations(native)
    assert_in_delta Enum.at(moved, 0), 0.2, 1.0e-12
    assert_in_delta Enum.at(moved, 1), -0.1, 1.0e-12
  end

  defp evidence(displacer, hypotheses) do
    {updated, _telemetry} =
      HypothesesDisplacer.compute_evidence(
        displacer,
        %{"patch" => %{"pose_vectors" => @pose, "pose_fully_defined" => true, "rgba" => [0.2]}},
        0.0,
        "mug",
        hypotheses
      )

    Hypotheses.evidence(updated)
  end

  defp with_reference(fun) do
    Application.put_env(:ex_tbp_monty, :native_kernels?, false)
    answer = fun.()
    Application.delete_env(:ex_tbp_monty, :native_kernels?)
    answer
  end

  defp turned do
    {:ok, quarter} = Rotation.from_axis_angle([1.0, 0.0, 0.0], :math.pi() / 2)
    Rotation.to_matrix(quarter)
  end

  # Four nodes a decimetre apart, the second turned a quarter turn, the third
  # with a curvature direction that is not perpendicular to its normal, and the
  # fourth with a pose that was not fully defined.
  defp displacer(options \\ []) do
    {locations, options} =
      Keyword.pop(options, :locations, [
        [0.0, 0.0, 0.0],
        [0.1, 0.0, 0.0],
        [0.0, 0.1, 0.0],
        [0.1, 0.1, 0.0]
      ])

    count = length(locations)

    poses = [@pose, @pose, [0.0, 1.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0], @pose]

    model =
      GraphObjectModel.new("mug")
      |> GraphObjectModel.build_model(
        locations,
        %{
          "pose_vectors" => Enum.take(poses, count),
          "pose_fully_defined" =>
            Enum.map(0..(count - 1)//1, fn index -> [if(index == 3, do: 0.0, else: 1.0)] end),
          "rgba" => List.duplicate([0.2], count)
        },
        nil,
        nil
      )

    memory =
      GraphMemory.new(
        features_to_use: %{"patch" => ["pose_vectors", "pose_fully_defined", "rgba"]}
      )
      |> GraphMemory.add_graph_to_memory(%{"patch" => model}, "mug")
      |> GraphMemory.initialize_feature_arrays()

    HypothesesDisplacer.new(
      memory,
      Keyword.merge(
        [
          feature_weights: %{"patch" => %{"pose_vectors" => [1.0, 0.75, 0.0], "rgba" => 1.0}},
          max_match_distance: 0.5,
          tolerances: %{"patch" => %{"rgba" => 0.1}}
        ],
        options
      )
    )
  end

  defp hypotheses(evidence, locations, poses \\ nil) do
    Hypotheses.new(
      evidence: evidence,
      locations: locations,
      poses: poses || List.duplicate(@identity, length(evidence)),
      possible: List.duplicate(true, length(evidence))
    )
  end
end
