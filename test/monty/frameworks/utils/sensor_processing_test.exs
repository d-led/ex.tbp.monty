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
end
