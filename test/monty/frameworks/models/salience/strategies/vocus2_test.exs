defmodule Monty.Frameworks.Models.Salience.Strategies.Vocus2Test do
  @moduledoc """
  What VOCUS2 means, in views small enough to reason about.

  The numbers are held to Monty in `vocus2/vocus2_parity_test.exs`; these say
  what the pieces are *for*: that a weighted mean renormalises and a weighted sum
  does not, that range normalisation makes maps comparable, that an empty depth
  pixel is not the most interesting thing in the view, and that an edge is
  salient whichever way it runs.
  """

  use ExUnit.Case, async: true

  alias Monty.Context

  alias Monty.Frameworks.Models.Salience.Strategies.Vocus2.{
    ColorChannelSalience,
    DepthSalience,
    NoOperatingLimits,
    OrientationSalience,
    SafeOperatingLimits,
    Vocus2SalienceConfig,
    WeightedMean,
    WeightedSum
  }

  alias Monty.Frameworks.Models.Salience.Strategies.Vocus2

  defp context, do: Context.new(0)

  describe "combining maps" do
    @two_maps %{"one" => [[1.0, 2.0]], "two" => [[3.0, 0.0]]}

    test "the plain combiners take the strongest, the sum and the mean" do
      assert Vocus2.map_max(@two_maps) == [[3.0, 2.0]]
      assert Vocus2.map_sum(@two_maps) == [[4.0, 2.0]]
      assert Vocus2.map_mean(@two_maps) == [[2.0, 1.0]]
    end

    test "a weighted mean renormalises, so scaling every weight changes nothing" do
      maps = %{"L" => [[1.0, 2.0]], "depth" => [[3.0, 0.0]]}

      even = WeightedMean.new(%{"L" => 1, "depth" => 1})
      scaled = WeightedMean.new(%{"L" => 10, "depth" => 10})

      assert WeightedMean.call(even, maps) == WeightedMean.call(scaled, maps)
      assert WeightedMean.call(even, maps) == [[2.0, 1.0]]
    end

    test "a weighted sum does not renormalise, so it sets the scale" do
      maps = %{"L" => [[1.0, 2.0]], "depth" => [[3.0, 0.0]]}

      assert WeightedSum.call(WeightedSum.new(%{"L" => 1, "depth" => 1}), maps) == [[4.0, 2.0]]

      assert WeightedSum.call(WeightedSum.new(%{"L" => 2, "depth" => 2}), maps) == [[8.0, 4.0]]
    end

    test "weights that cancel have no mean to take, and say so" do
      maps = %{"L" => [[1.0]], "a" => [[1.0]]}

      assert_raise ArgumentError, fn ->
        WeightedMean.call(WeightedMean.new(%{"L" => 0, "a" => 0}), maps)
      end
    end
  end

  describe "normalising a map" do
    test "stretches the range to exactly zero and one" do
      assert Vocus2.range_normalize([[2.0, 4.0], [6.0, 8.0]]) == [
               [0.0, 1.0 / 3.0],
               [2.0 / 3.0, 1.0]
             ]

      assert Vocus2.range_normalize([[0.0, 1.0]]) == [[0.0, 1.0]]
    end

    test "leaves a flat map flat, inside [0, 1]" do
      # A view with no structure has no range to stretch, and dividing by it
      # would answer infinities rather than a map.
      assert Vocus2.range_normalize([[0.5, 0.5]]) == [[0.5, 0.5]]
      assert Vocus2.range_normalize([[2.0, 2.0]]) == [[1.0, 1.0]]
    end
  end

  describe "the operating limits" do
    test "accepts sigmas a 64-pixel view was tried with" do
      limits = SafeOperatingLimits.new()

      assert limits.__struct__.validate(limits, 64, 2.0, 4.0) == :ok
    end

    test "refuses a surround that is not meaningfully wider than the centre" do
      limits = SafeOperatingLimits.new()

      assert {:error, message} = limits.__struct__.validate(limits, 64, 2.0, 2.1)
      assert message =~ "center_sigma + min_fractional_sigma_separation"
    end

    test "refuses a centre sigma too small for the view to show" do
      limits = SafeOperatingLimits.new()

      assert {:error, message} = limits.__struct__.validate(limits, 64, 0.5, 4.0)
      assert message =~ "Center sigma"
    end

    test "no limits means no checking" do
      assert NoOperatingLimits.new().__struct__.validate(NoOperatingLimits.new(), 4, 9.0, 9.0) ==
               :ok
    end
  end

  describe "the depth channel" do
    test "counts a near step, and treats a pixel with no depth as the nearest of all" do
      # The middle of the view is nearer than its surroundings. The corner has
      # no depth at all: `-log(0)` is infinity, which Monty replaces with zero,
      # so the corner arrives *above* its surroundings on the log scale and is
      # salient too. That is Monty's behaviour, reproduced on purpose and
      # recorded as §1.14 in `docs/monty-bugs.md`.
      depth =
        for row <- 0..15 do
          for column <- 0..15 do
            cond do
              row == 0 and column == 0 -> 0.0
              row in 6..9 and column in 6..9 -> 0.5
              true -> 2.0
            end
          end
        end

      salience =
        DepthSalience.new(
          center_sigma: 2.0,
          surround_sigma: 3.0,
          n_scales: 2,
          operating_limits: NoOperatingLimits.new()
        )

      map = DepthSalience.process(salience, context(), depth)

      assert Enum.at(Enum.at(map, 7), 7) > 0.0
      assert Enum.at(Enum.at(map, 0), 0) > 0.0
      assert Enum.at(Enum.at(map, 0), 0) < Enum.at(Enum.at(map, 7), 7)
    end
  end

  describe "the orientation channel" do
    test "its kernels are centred on zero, so a flat region answers nothing" do
      salience = OrientationSalience.new(period: 4.0)

      for {_name, kernel} <- salience.kernels do
        assert_in_delta Enum.sum(List.flatten(kernel)), 0.0, 1.0e-12
      end
    end

    test "it answers at an edge and stays quiet in the flat either side of it" do
      # A vertical edge down the middle: the whole point is a response that is
      # large where the image changes and small where it does not.
      image =
        for _row <- 0..15 do
          for column <- 0..15, do: if(column < 8, do: 0.0, else: 1.0)
        end

      salience =
        ColorChannelSalience.new(
          center_sigma: 2.0,
          surround_sigma: 3.0,
          n_scales: 2,
          operating_limits: NoOperatingLimits.new()
        )

      {_map, center} = ColorChannelSalience.process(salience, context(), image)

      orientation =
        OrientationSalience.new(period: 4.0) |> OrientationSalience.process(context(), center)

      assert Enum.at(Enum.at(orientation, 8), 8) > Enum.at(Enum.at(orientation, 8), 1)
    end
  end

  describe "the strategy" do
    test "answers one salience value per pixel, normalised" do
      # A bright blob on a plain background: something to be salient about, so
      # the normalised map really does span its range.
      image =
        for row <- 0..15 do
          for column <- 0..15 do
            if row in 4..7 and column in 4..7,
              do: [230.0, 230.0, 230.0, 255.0],
              else: [60.0, 60.0, 60.0, 255.0]
          end
        end

      depth = List.duplicate(List.duplicate(1.5, 16), 16)

      strategy =
        Vocus2.from_config(Vocus2SalienceConfig.new(center_sigma: 1.5, surround_sigma: 2.5))

      map = Vocus2.call(strategy, context(), image, depth)

      assert {length(map), map |> hd() |> length()} == {16, 16}
      assert map |> List.flatten() |> Enum.min() == 0.0
      assert map |> List.flatten() |> Enum.max() == 1.0
    end

    test "a config can leave depth and orientation out" do
      strategy =
        Vocus2.from_config(
          Vocus2SalienceConfig.new(
            center_sigma: 2.0,
            surround_sigma: 3.0,
            use_depth: false,
            use_orientation: false
          )
        )

      assert strategy.depth == nil
      assert strategy.orientation == nil
    end
  end
end
