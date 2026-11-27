defmodule Monty.Frameworks.Models.Salience.Strategies.Vocus2MontyTest do
  @moduledoc """
  Monty's own cases for VOCUS2, translated.

  Each test names the case in
  `tests/unit/frameworks/models/salience/strategies/vocus2/vocus2_test.py` it
  translates. Three adaptations are made, and this is why they are the honest
  ones:

    * Monty mocks `ColorChannelSalience`, `DepthSalience`, `OrientationSalience`
      and the constructor to assert what `from_config` passes. The port's
      `from_config` *answers* the channels it built, so the coupling is read off
      the strategy instead of off a mock.
    * Monty mocks the colour space converter, the combiner and the normaliser to
      assert the call chain. Those three are functions a strategy is given, so
      here they are the captures — which proves the same wiring and runs the real
      processors underneath.
    * Monty mocks `operating_limits.validate` to return a `ValueError`. The port
      asks a limits module, so here the numbers are made to fall outside a real
      `SafeOperatingLimits` — the same refusal, arrived at the way a user would
      arrive at it.

  Monty's property cases draw images and sigmas from hypothesis; here the view
  and the numbers are fixed, chosen to sit inside the operating limits for a
  64 by 64 view, and the test says what they are.
  """

  use ExUnit.Case, async: true

  alias Monty.Frameworks.Models.Salience.Strategies.Vocus2
  alias Monty.Frameworks.Models.Salience.Strategies.Vocus2.ColorChannelSalience
  alias Monty.Frameworks.Models.Salience.Strategies.Vocus2.DepthSalience
  alias Monty.Frameworks.Models.Salience.Strategies.Vocus2.Images
  alias Monty.Frameworks.Models.Salience.Strategies.Vocus2.OrientationSalience
  alias Monty.Frameworks.Models.Salience.Strategies.Vocus2.SafeOperatingLimits
  alias Monty.Frameworks.Models.Salience.Strategies.Vocus2.Vocus2SalienceConfig
  alias Monty.Frameworks.Models.Salience.Strategies.Vocus2.WeightedMean

  # The smallest view the default limits accept, and sigmas inside them: a
  # centre at 2 and a surround at 4 are 1.28 apart at the least, and no more
  # than a tenth of the view wide.
  @view_size 64
  @center_sigma 2.0
  @surround_sigma 4.0
  @box_size 16

  # --- the views the cases are given -----------------------------------------

  defp context, do: Monty.Context.new(1)

  defp quiet_context, do: Monty.Context.new(1, suppress_runtime_errors: true)

  defp solid(size, value), do: List.duplicate(List.duplicate(value, size), size)

  defp in_box?(row, column, size, box_size) do
    low = div(size, 2) - div(box_size, 2)

    row >= low and row < low + box_size and column >= low and column < low + box_size
  end

  defp box_image(size, box_size, on_value, off_value) do
    for row <- 0..(size - 1) do
      for column <- 0..(size - 1) do
        if in_box?(row, column, size, box_size), do: on_value, else: off_value
      end
    end
  end

  defp box_mask(size, box_size) do
    for row <- 0..(size - 1) do
      for column <- 0..(size - 1), do: in_box?(row, column, size, box_size)
    end
  end

  # A sinusoidal grating inside the box and solid black outside it — the thing an
  # orientation channel exists to find.
  defp grating(size, box_size, wavelength) do
    angle = :math.pi() / 6
    phase = :math.pi() / 4
    frequency = 2 * :math.pi() / wavelength

    for row <- 0..(size - 1) do
      for column <- 0..(size - 1) do
        if in_box?(row, column, size, box_size) do
          (:math.sin(frequency * (column * :math.cos(angle) + row * :math.sin(angle)) + phase) + 1) /
            2
        else
          0.0
        end
      end
    end
  end

  defp mean_where(plane, mask, wanted?) do
    values =
      for {row, mask_row} <- Enum.zip(plane, mask),
          {value, inside?} <- Enum.zip(row, mask_row),
          inside? == wanted?,
          do: value

    Enum.sum(values) / length(values)
  end

  defp channel(plane, index) do
    Enum.map(plane, fn row -> Enum.map(row, &Enum.at(&1, index)) end)
  end

  # --- the processors -------------------------------------------------------

  defp colour_salience(overrides \\ []) do
    ColorChannelSalience.new(
      Keyword.merge(
        [center_sigma: @center_sigma, surround_sigma: @surround_sigma, n_scales: 2],
        overrides
      )
    )
  end

  defp depth_salience(overrides \\ []) do
    DepthSalience.new(
      Keyword.merge(
        [center_sigma: @center_sigma, surround_sigma: @surround_sigma, n_scales: 2],
        overrides
      )
    )
  end

  defp orientation_salience, do: OrientationSalience.new(period: 2 * @center_sigma)

  # --- the colour channel ---------------------------------------------------

  describe "the colour channel" do
    @minimum_salience 1.0e-4

    # test_solid_image_not_salient
    test "a solid image has nothing to be more salient than" do
      {salience_map, _pyramid} =
        ColorChannelSalience.process(colour_salience(), context(), solid(@view_size, 0.5))

      assert Enum.all?(List.flatten(salience_map), &(&1 < @minimum_salience))
    end

    # test_box_is_more_salient_than_surround
    test "a box stands out from the surround it is drawn on" do
      image = box_image(@view_size, @box_size, 1.0, 0.0)

      {salience_map, _pyramid} = ColorChannelSalience.process(colour_salience(), context(), image)

      mask = box_mask(@view_size, @box_size)

      assert mean_where(salience_map, mask, true) > mean_where(salience_map, mask, false)
    end

    # test_sigmas_outside_of_operating_limits_raises_value_error_if_suppress_runtime_errors_is_false
    test "sigmas too close together for the limits are refused" do
      # Monty mocks `validate` to answer a `ValueError`. Here the limits are real
      # and the numbers are real: a separation of 2 is too little for a view
      # that wants a fifth of itself between centre and surround.
      salience = colour_salience(operating_limits: wide_separation_limits())

      assert_raise ArgumentError, fn ->
        ColorChannelSalience.process(salience, context(), solid(@view_size, 0.5))
      end
    end

    # test_sigmas_outside_of_operating_limits_does_not_raise_value_error_if_suppress_runtime_errors_is_true
    @tag :capture_log
    test "the same sigmas are used anyway when the run suppresses runtime errors" do
      salience = colour_salience(operating_limits: wide_separation_limits())

      assert {salience_map, _pyramid} =
               ColorChannelSalience.process(salience, quiet_context(), solid(@view_size, 0.5))

      assert length(salience_map) == @view_size
    end

    defp wide_separation_limits do
      SafeOperatingLimits.new(min_fractional_sigma_separation: 0.5)
    end
  end

  # --- the depth channel ----------------------------------------------------

  describe "the depth channel" do
    @minimum_salience 1.0e-3

    # test_solid_image_not_salient
    test "a surface at one distance throughout has nothing to be nearer than" do
      salience_map = DepthSalience.process(depth_salience(), context(), solid(@view_size, 0.5))

      assert Enum.all?(List.flatten(salience_map), &(&1 < @minimum_salience))
    end

    # test_box_is_more_salient_than_surround
    test "a box nearer than its surround stands out" do
      # Monty draws the box at 0.5 and the background at 1.0: the box is nearer.
      image = box_image(@view_size, @box_size, 0.5, 1.0)
      salience_map = DepthSalience.process(depth_salience(), context(), image)

      mask = box_mask(@view_size, @box_size)

      assert mean_where(salience_map, mask, true) > mean_where(salience_map, mask, false)
    end

    # test_sigmas_outside_of_operating_limits_raises_value_error_if_suppress_runtime_errors_is_false
    test "sigmas too close together for the limits are refused" do
      salience =
        depth_salience(
          operating_limits: SafeOperatingLimits.new(min_fractional_sigma_separation: 0.5)
        )

      assert_raise ArgumentError, fn ->
        DepthSalience.process(salience, context(), solid(@view_size, 0.5))
      end
    end

    # test_sigmas_outside_of_operating_limits_does_not_raise_value_error_if_suppress_runtime_errors_is_true
    @tag :capture_log
    test "the same sigmas are used anyway when the run suppresses runtime errors" do
      salience =
        depth_salience(
          operating_limits: SafeOperatingLimits.new(min_fractional_sigma_separation: 0.5)
        )

      salience_map = DepthSalience.process(salience, quiet_context(), solid(@view_size, 0.5))

      assert length(salience_map) == @view_size
    end
  end

  # --- the orientation channel ---------------------------------------------

  describe "the orientation channel" do
    @minimum_salience 1.0e-4

    # test_solid_image_not_salient
    test "a solid image has no orientation to find" do
      {_map, pyramid} =
        ColorChannelSalience.process(colour_salience(), context(), solid(@view_size, 0.5))

      feature_map = OrientationSalience.process(orientation_salience(), context(), pyramid)

      assert Enum.all?(List.flatten(feature_map), &(&1 < @minimum_salience))
    end

    # test_box_is_more_salient_than_surround
    test "a grating in a box stands out from the black around it" do
      # The wavelength is twice the period's sigma at the least and twice the box
      # at the most; eight pixels sits inside both for a box of sixteen.
      image = grating(@view_size, 24, 8.0)

      {_map, pyramid} = ColorChannelSalience.process(colour_salience(), context(), image)
      feature_map = OrientationSalience.process(orientation_salience(), context(), pyramid)

      mask = box_mask(@view_size, 24)

      assert mean_where(feature_map, mask, true) > mean_where(feature_map, mask, false)
    end
  end

  # --- a strategy from a config --------------------------------------------

  describe "a strategy from a config" do
    # test_sigmas_scales_and_octaves_are_coupled_across_color_depth_and_orientation
    test "colour and depth take the config's numbers, and orientation twice its centre" do
      config = %Vocus2SalienceConfig{
        center_sigma: 1.5,
        surround_sigma: 4.0,
        n_scales: 3,
        max_octaves: 2
      }

      strategy = Vocus2.from_config(config)

      for channel <- [strategy.color, strategy.depth] do
        assert {channel.center_sigma, channel.surround_sigma, channel.n_scales,
                channel.max_octaves} ==
                 {1.5, 4.0, 3, 2}
      end

      assert strategy.orientation.period == 3.0
    end

    # test_no_depth_if_use_depth_is_false
    test "no depth channel when the config does not want one" do
      strategy = Vocus2.from_config(%Vocus2SalienceConfig{use_depth: false})

      assert strategy.depth == nil
      assert %ColorChannelSalience{} = strategy.color
      assert %OrientationSalience{} = strategy.orientation
    end

    # test_no_orientation_if_use_orientation_is_false
    test "no orientation channel when the config does not want one" do
      strategy = Vocus2.from_config(%Vocus2SalienceConfig{use_orientation: false})

      assert strategy.orientation == nil
      assert %ColorChannelSalience{} = strategy.color
      assert %DepthSalience{} = strategy.depth
    end

    # test_color_space_converter_combine_and_normalize_are_passed_to_constructor
    test "a converter, a combiner and a normaliser given to the config are the strategy's" do
      converter = fn image -> image end
      combine = fn features -> features end
      normalize = fn map -> map end

      strategy =
        Vocus2.from_config(%Vocus2SalienceConfig{},
          color_space_converter: converter,
          combine: combine,
          normalize: normalize
        )

      assert strategy.color_space_converter == converter
      assert strategy.combine == combine
      assert strategy.normalize == normalize
    end

    # ... and what a config that names none of them gets, which Monty spells out
    # in the coupling case: the opponent colour space and a range normaliser.
    test "a config that names none of them gets the opponent colour space and a range normaliser" do
      strategy = Vocus2.from_config(%Vocus2SalienceConfig{})

      assert strategy.color_space_converter == (&Images.rgb_to_opponent/1)
      assert %WeightedMean{} = strategy.combine
      assert strategy.normalize == (&Vocus2.range_normalize/1)
    end
  end

  # --- the strategy's call --------------------------------------------------

  describe "the strategy's call" do
    # A view with structure, and alpha of 255 throughout: 255 in the alpha byte is
    # what Monty's camera writes, and the channel that drops it is the one under
    # test.
    defp rgba_view do
      image = box_image(@view_size, @box_size, 200.0, 10.0)

      Enum.map(image, fn row ->
        Enum.map(row, fn value -> [value, value / 2, 200.0 - value / 2, 255] end)
      end)
    end

    defp rgb_of(rgba),
      do: Enum.map(rgba, fn row -> Enum.map(row, fn pixel -> Enum.take(pixel, 3) end) end)

    defp capturing_combine do
      test_pid = self()

      fn features ->
        send(test_pid, {:features, features})
        features["L"]
      end
    end

    # test_color_space_converts_rgba
    test "the colour space is handed the view without its alpha, once" do
      test_pid = self()
      rgba = rgba_view()

      strategy =
        Vocus2.new(
          color: colour_salience(),
          color_space_converter: fn image ->
            send(test_pid, {:converted, image})
            image
          end,
          combine: capturing_combine(),
          normalize: & &1
        )

      Vocus2.call(strategy, context(), rgba, solid(@view_size, 1.0))

      assert_received {:converted, converted}
      assert converted == rgb_of(rgba)
      refute_received {:converted, _again}
    end

    # test_creates_Lab_feature_maps
    test "each of the view's three channels is scored by the colour channel" do
      rgba = rgba_view()
      rgb = rgb_of(rgba)

      strategy =
        Vocus2.new(
          color: colour_salience(),
          color_space_converter: & &1,
          combine: capturing_combine(),
          normalize: & &1
        )

      Vocus2.call(strategy, context(), rgba, solid(@view_size, 1.0))
      assert_received {:features, features}

      assert features |> Map.keys() |> Enum.sort() == ["L", "a", "b"]

      for {name, index} <- [{"L", 0}, {"a", 1}, {"b", 2}] do
        {expected, _pyramid} =
          ColorChannelSalience.process(colour_salience(), context(), channel(rgb, index),
            pyramid?: false
          )

        assert features[name] == expected
      end
    end

    # test_creates_depth_feature_map_if_depth_processor_is_provided
    test "the depth image is scored by the depth channel when the strategy has one" do
      depth_image = box_image(@view_size, @box_size, 0.5, 1.0)

      strategy =
        Vocus2.new(
          color: colour_salience(),
          depth: depth_salience(),
          color_space_converter: & &1,
          combine: capturing_combine(),
          normalize: & &1
        )

      Vocus2.call(strategy, context(), rgba_view(), depth_image)
      assert_received {:features, features}

      assert features["depth"] == DepthSalience.process(depth_salience(), context(), depth_image)
      assert features |> Map.keys() |> Enum.sort() == ["L", "a", "b", "depth"]
    end

    # test_creates_orientation_feature_map_if_orientation_processor_is_provided
    test "the lightness pyramid is scored by the orientation channel when the strategy has one" do
      rgba = rgba_view()

      strategy =
        Vocus2.new(
          color: colour_salience(),
          orientation: orientation_salience(),
          color_space_converter: & &1,
          combine: capturing_combine(),
          normalize: & &1
        )

      Vocus2.call(strategy, context(), rgba, solid(@view_size, 1.0))
      assert_received {:features, features}

      # The orientation channel is handed the centre pyramid of the lightness
      # channel, which is what the strategy's call carried out of the colour
      # channel — recomputed here the way the call builds it.
      {_map, lightness_pyramid} =
        ColorChannelSalience.process(colour_salience(), context(), channel(rgb_of(rgba), 0),
          pyramid?: true
        )

      assert features["orientation"] ==
               OrientationSalience.process(orientation_salience(), context(), lightness_pyramid)
    end

    # test_combines_feature_maps
    test "everything scored is combined, and nothing else" do
      strategy =
        Vocus2.new(
          color: colour_salience(),
          depth: depth_salience(),
          orientation: orientation_salience(),
          color_space_converter: & &1,
          combine: capturing_combine(),
          normalize: & &1
        )

      Vocus2.call(strategy, context(), rgba_view(), box_image(@view_size, @box_size, 0.5, 1.0))
      assert_received {:features, features}

      assert features |> Map.keys() |> Enum.sort() == ["L", "a", "b", "depth", "orientation"]
    end

    # test_normalizes_salience_map
    test "the combined map is normalised, and the normalised map is the answer" do
      test_pid = self()

      strategy =
        Vocus2.new(
          color: colour_salience(),
          color_space_converter: & &1,
          combine: fn _features -> :combined end,
          normalize: fn combined ->
            send(test_pid, {:normalising, combined})
            :normalised
          end
        )

      assert Vocus2.call(strategy, context(), rgba_view(), solid(@view_size, 1.0)) == :normalised
      assert_received {:normalising, :combined}
    end
  end
end
