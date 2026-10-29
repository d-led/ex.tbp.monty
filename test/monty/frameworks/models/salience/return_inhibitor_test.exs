defmodule Monty.Frameworks.Models.Salience.ReturnInhibitorTest do
  @moduledoc """
  Inhibition of return: the numbers a visit leaves behind.

  The weights are half-lives — `tau_t` seconds and `tau_s` metres are where a
  weight halves — so the expected values are the closed forms of Monty's two
  exponentials, computed with numpy rather than read off the implementation:
  a kernel visits half its weight every 10 steps when `tau_t` is 10, and a point
  1 cm from a visit with `tau_s: 0.01` weighs exactly a half.
  """

  use ExUnit.Case, async: true

  alias Monty.Frameworks.Models.Salience.ReturnInhibitor
  alias Monty.Frameworks.Models.Salience.ReturnInhibitor.{DecayField, DecayKernel}

  defp origin, do: [0.0, 0.0, 0.0]

  describe "a decay kernel" do
    test "halves its weight every tau_t steps" do
      kernel = DecayKernel.new(origin(), tau_t: 10.0)

      assert_in_delta DecayKernel.time_weight(kernel), 1.0, 1.0e-12

      kernel = kernel |> step_times(10) |> elem(0)
      assert_in_delta DecayKernel.time_weight(kernel), 0.5, 1.0e-12

      kernel = kernel |> step_times(10) |> elem(0)
      assert_in_delta DecayKernel.time_weight(kernel), 0.25, 1.0e-12
    end

    test "halves its weight every tau_s metres" do
      # Half a centimetre, one centimetre, two: the weights are 1/√2, 1/2, 1/4.
      kernel = DecayKernel.new(origin(), tau_s: 0.01)

      assert [1.0, 0.7071067812, 0.5, 0.25] =
               Enum.map([0.0, 0.005, 0.01, 0.02], fn distance ->
                 [weight] = DecayKernel.space_weight(kernel, [[distance, 0.0, 0.0]])
                 Float.round(weight, 10)
               end)
    end

    test "says nothing beyond the spatial cutoff" do
      # Otherwise a visit to one side of an object would inhibit the other.
      kernel = DecayKernel.new(origin(), tau_s: 0.01, spatial_cutoff: 0.02)

      assert [weight] = DecayKernel.space_weight(kernel, [[0.03, 0.0, 0.0]])
      assert weight == 0.0
    end

    test "expires once its weight falls below the minimum" do
      # `exp(-t / 14.427) < 0.1` first holds at 34 steps: 33 steps is 0.1006,
      # 34 is 0.0948.
      kernel = DecayKernel.new(origin(), tau_t: 10.0, w_t_min: 0.1)

      {_kernel, expired?} = step_times(kernel, 33)
      refute expired?

      {_kernel, expired?} = step_times(kernel, 34)
      assert expired?
    end
  end

  describe "a decay field" do
    test "answers zero everywhere while nothing has been visited" do
      assert DecayField.weights(DecayField.new(), [origin(), [1.0, 0.0, 0.0]]) == [0.0, 0.0]
    end

    test "keeps the strongest visit, rather than their sum" do
      # Two visits to the same place do not make it twice as uninteresting: the
      # maximum is what Monty takes, so a revisited patch is inhibited as much as
      # its most recent visit says and no more.
      field = DecayField.new() |> DecayField.add(origin()) |> DecayField.add(origin())

      assert [weight] = DecayField.weights(field, [origin()])
      assert_in_delta weight, 1.0, 1.0e-12
    end

    test "forgets a visit once it has stopped mattering" do
      field = DecayField.new() |> DecayField.add(origin())

      forgotten =
        Enum.reduce(1..35, field, fn _step, field -> DecayField.step(field) end)

      assert forgotten.kernels == []
    end
  end

  describe "the inhibitor" do
    test "records where the sensor looked, and inhibits the points nearest it" do
      {weights, _inhibitor} =
        ReturnInhibitor.call(
          ReturnInhibitor.new(),
          origin(),
          [[0.0, 0.0, 0.0], [0.01, 0.0, 0.0], [0.03, 0.0, 0.0]]
        )

      [here, near, far] = weights
      assert_in_delta here, 1.0, 1.0e-12
      assert_in_delta near, 0.5, 1.0e-9
      assert far == 0.0
    end

    test "fades as the steps pass" do
      # The first call records a visit; after ten steps it weighs half as much.
      inhibitor = ReturnInhibitor.new()
      {[first], inhibitor} = ReturnInhibitor.call(inhibitor, origin(), [origin()])

      {[later], _inhibitor} =
        Enum.reduce(1..10, {[first], inhibitor}, fn _step, {_weights, inhibitor} ->
          ReturnInhibitor.call(inhibitor, nil, [origin()])
        end)

      assert_in_delta later, 0.5, 0.05
    end

    test "inhibits nothing at all on a step that saw no object" do
      # A motor-only step, or a view off the object: there is nowhere to record,
      # and the weights are whatever the earlier visits say.
      {weights, _inhibitor} = ReturnInhibitor.call(ReturnInhibitor.new(), nil, [origin()])

      assert weights == [0.0]
    end

    test "forgets every visit when the episode ends" do
      inhibitor = ReturnInhibitor.new()
      {[weight], inhibitor} = ReturnInhibitor.call(inhibitor, origin(), [origin()])
      assert weight > 0.0

      {[after_reset], _inhibitor} =
        ReturnInhibitor.call(ReturnInhibitor.reset(inhibitor), nil, [origin()])

      assert after_reset == 0.0
    end
  end

  # Steps the kernel `times` times, answering the last kernel and whether that
  # last step expired it.
  defp step_times(kernel, times) do
    Enum.reduce(1..times, {kernel, false}, fn _step, {kernel, _expired} ->
      DecayKernel.step(kernel)
    end)
  end
end
