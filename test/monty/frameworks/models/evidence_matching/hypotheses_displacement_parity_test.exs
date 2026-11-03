defmodule Monty.Frameworks.Models.EvidenceMatching.HypothesesDisplacementParityTest do
  @moduledoc """
  The displacement kernel, held to the Elixir arithmetic it replaces.

  A hypothesis moves to `location + pose · displacement`, and the two sides must
  agree on the answer rather than nearly agree: the same three dot products, in
  the same order, over the same values. So the assertions are `==`, not a
  tolerance.

  The reference is `SpatialArithmetics.add(location, Geometry.apply(pose,
  displacement))` — what `HypothesesDisplacer.displace_hypotheses/3` does today —
  and the kernel is `MatcherNif.displaced_locations/3` over the bytes the step
  already builds for the evidence kernel.
  """

  use ExUnit.Case, async: true

  alias ExTbpMonty.MatcherNif
  alias Monty.Frameworks.Utils.KdTree
  alias Monty.Frameworks.Utils.SpatialArithmetics
  alias Monty.Geometry

  if not MatcherNif.loaded?() do
    @moduletag skip: "the native kernels are not loaded in this VM"
  end

  # A rotation that is only nearly orthonormal, as a stored node's frame is.
  defp pose(turn) do
    a = 0.3 + turn * 0.01
    c = :math.cos(a)
    s = :math.sin(a)

    [[c, -s, 0.002], [s, c, -0.0013], [0.001, 0.0007, 1.0]]
  end

  defp location(index) do
    [0.01 * index - 0.2, 0.005 * index + 0.35, 0.002 * index]
  end

  # The same bytes `hypothesis_poses_bytes/1` hands the evidence kernel.
  defp poses_bytes(poses) do
    for [[p, q, r], [s, t, u], [v, w, x]] <- poses, into: <<>> do
      <<p * 1.0::little-float-64, q * 1.0::little-float-64, r * 1.0::little-float-64,
        s * 1.0::little-float-64, t * 1.0::little-float-64, u * 1.0::little-float-64,
        v * 1.0::little-float-64, w * 1.0::little-float-64, x * 1.0::little-float-64>>
    end
  end

  defp locations_from(bytes) do
    for <<x::little-float-64, y::little-float-64, z::little-float-64 <- bytes>>,
      do: [x, y, z]
  end

  defp reference(poses, locations, displacement) do
    Enum.zip_with(poses, locations, fn pose, location ->
      SpatialArithmetics.add(location, Geometry.apply(pose, displacement))
    end)
  end

  describe "the displaced search locations" do
    test "are the ones the Elixir arithmetic gives, value for value" do
      poses = Enum.map(1..64, &pose/1)
      locations = Enum.map(1..64, &location/1)
      displacement = [0.0042, -0.0019, 0.031]

      moved =
        MatcherNif.displaced_locations(
          poses_bytes(poses),
          KdTree.points_bytes(locations),
          <<0.0042::little-float-64, -0.0019::little-float-64, 0.031::little-float-64>>
        )
        |> locations_from()

      assert moved == reference(poses, locations, displacement)
    end

    test "hold for a sensor that did not move" do
      poses = [pose(1)]
      locations = [location(1)]
      still = <<0.0::little-float-64, 0.0::little-float-64, 0.0::little-float-64>>

      assert MatcherNif.displaced_locations(
               poses_bytes(poses),
               KdTree.points_bytes(locations),
               still
             )
             |> locations_from() == locations
    end

    test "are the answer for a turn about the vertical, as a hand calculation says" do
      # A quarter turn about z, so `pose · (1, 0, 0)` is `(0, 1, 0)`.
      quarter = [[0.0, -1.0, 0.0], [1.0, 0.0, 0.0], [0.0, 0.0, 1.0]]
      here = [0.0, 0.0, 0.1]
      [dx, dy, dz] = [1.0, 0.0, 0.0]

      moved =
        MatcherNif.displaced_locations(
          poses_bytes([quarter]),
          KdTree.points_bytes([here]),
          <<dx::little-float-64, dy::little-float-64, dz::little-float-64>>
        )
        |> locations_from()

      assert moved == [[0.0, 1.0, 0.1]]
    end
  end
end
