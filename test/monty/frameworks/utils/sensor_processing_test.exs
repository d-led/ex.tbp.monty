defmodule Monty.Frameworks.Utils.SensorProcessingTest do
  use ExUnit.Case, async: true

  alias Monty.Frameworks.Utils.SensorProcessing

  describe "the signed logarithm" do
    test "scales a value without losing which way it points" do
      assert_in_delta SensorProcessing.log_sign(9.0), :math.log(10.0), 1.0e-12
      assert_in_delta SensorProcessing.log_sign(-9.0), -:math.log(10.0), 1.0e-12
    end

    test "keeps zero at zero, where a plain logarithm would run off" do
      assert SensorProcessing.log_sign(0.0) == 0.0
    end

    test "and applies to a curvature pair as Monty's sensor applies it" do
      assert_in_delta hd(SensorProcessing.log_sign([-20.0, 20.0])), -:math.log(21.0), 1.0e-12

      assert_in_delta List.last(SensorProcessing.log_sign([-20.0, 20.0])),
                      :math.log(21.0),
                      1.0e-12
    end
  end

  describe "a pixel as hue, saturation and value" do
    test "puts the three primaries a third of the wheel apart" do
      assert SensorProcessing.rgb2hsv([1.0, 0.0, 0.0]) == [0.0, 1.0, 1.0]

      assert [green_hue, 1.0, 1.0] = SensorProcessing.rgb2hsv([0.0, 1.0, 0.0])
      assert_in_delta green_hue, 1.0 / 3.0, 1.0e-12

      assert [blue_hue, 1.0, 1.0] = SensorProcessing.rgb2hsv([0.0, 0.0, 1.0])
      assert_in_delta blue_hue, 2.0 / 3.0, 1.0e-12
    end

    test "wraps hue round the wheel instead of going negative" do
      # A red-dominant pixel just past blue: the wheel comes back to red.
      assert [hue, _saturation, _value] = SensorProcessing.rgb2hsv([1.0, 0.0, 0.5])
      assert_in_delta hue, 1.0 - 30.0 / 360.0, 1.0e-12
    end

    test "has no hue and no saturation for a grey pixel" do
      assert [0.0, 0.0, 0.5] = SensorProcessing.rgb2hsv([0.5, 0.5, 0.5])
    end

    test "and nothing at all for black" do
      assert SensorProcessing.rgb2hsv([0.0, 0.0, 0.0]) == [0.0, 0.0, 0.0]
    end
  end
end
