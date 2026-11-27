defmodule Monty.Frameworks.Models.Salience.ReturnInhibitorMontyTest do
  @moduledoc """
  Monty's own cases for inhibition of return, translated.

  Each test names the case in
  `tests/unit/frameworks/models/salience/return_inhibitor_test.py` it translates.

  Monty's `ReturnInhibitor` mutates a `DecayField` and takes it as a constructor
  argument, so its five cases hand in a `MagicMock` and assert the field's
  methods were called, in order, with the right arguments. The port is
  functional: a call answers `{weights, inhibitor}` and a field is a value. The
  same claims are therefore read off the field the call answers — a kernel
  exists where the sensor was, none exists when there was no central location,
  and the weights come from the field as it was *before* the step — which is what
  the mock was there to say, and is stricter, because the numbers have to be
  right too.

  Monty's property cases draw locations and points from the generators in its
  setUp; here they are the fixed numbers those cases use.
  """

  use ExUnit.Case, async: true

  alias Monty.Frameworks.Models.Salience.ReturnInhibitor
  alias Monty.Frameworks.Models.Salience.ReturnInhibitor.DecayField
  alias Monty.Frameworks.Models.Salience.ReturnInhibitor.DecayKernel
  alias Monty.Frameworks.Models.Salience.ReturnInhibitor.DecayKernelFactory

  @location [1.0, 2.0, 3.0]
  @queries [[4.0, 5.0, 6.0]]

  # The numbers Monty's cases are set up with: a tenth of a second's decay
  # constant, a twenty-millimetre reach, and a floor under the time weight.
  defp field do
    DecayField.new(
      kernel_factory: DecayKernelFactory.new(tau_t: 10.0, spatial_cutoff: 0.02, w_t_min: 0.1)
    )
  end

  # Points walking away from the location, a millimetre at a time.
  defp points(indices), do: Enum.map(indices, fn index -> [1.0 + 0.001 * index, 2.0, 3.0] end)

  defp decreasing?(values) do
    values
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [before, after_it] -> after_it < before end)
  end

  describe "a decay kernel" do
    # test_kernel_spatial_weight_decays_within_spatial_cutoff
    test "the weight falls, millimetre by millimetre, inside the spatial cutoff" do
      kernel = DecayKernel.new(@location, spatial_cutoff: 0.02)

      assert kernel |> DecayKernel.weights(points(0..19)) |> decreasing?()
    end

    # test_kernel_spatial_weight_decays_to_zero_outside_spatial_cutoff
    test "the weight is zero beyond the spatial cutoff" do
      kernel = DecayKernel.new(@location, spatial_cutoff: 0.02)

      assert kernel |> DecayKernel.weights(points(20..99)) |> Enum.all?(&(&1 == 0.0))
    end

    # test_kernel_temporal_weight_decays_with_time
    test "the weight falls as the kernel ages, at the place it was made" do
      {weights, _kernel} =
        Enum.map_reduce(1..20, DecayKernel.new(@location), fn _, kernel ->
          weight = kernel |> DecayKernel.weights([@location]) |> hd()
          {weight, kernel |> DecayKernel.step() |> elem(0)}
        end)

      assert decreasing?(weights)
    end
  end

  describe "a decay field" do
    # test_single_kernel_weight_decays_within_spatial_cutoff
    test "one visit weighs less the further a point is from it" do
      weights =
        field() |> DecayField.add(@location) |> DecayField.weights(points(0..19))

      assert decreasing?(weights)
    end

    # test_single_kernel_weight_decays_to_zero_outside_spatial_cutoff
    test "one visit weighs nothing beyond its reach" do
      weights =
        field() |> DecayField.add(@location) |> DecayField.weights(points(20..99))

      assert Enum.all?(weights, &(&1 == 0.0))
    end

    # test_single_kernel_weight_decays_within_temporal_cutoff
    test "one visit weighs less at every step until it stops mattering" do
      {weights, _field} =
        Enum.map_reduce(1..34, DecayField.add(field(), @location), fn _, field ->
          {field |> DecayField.weights([@location]) |> hd(), DecayField.step(field)}
        end)

      assert decreasing?(weights)
    end

    # test_single_kernel_weight_is_zero_beyond_temporal_cutoff
    test "one visit is forgotten after its temporal cutoff" do
      {weights, _field} =
        Enum.map_reduce(0..99, DecayField.add(field(), @location), fn step, field ->
          weight = if step > 34, do: field |> DecayField.weights([@location]) |> hd()
          {weight, DecayField.step(field)}
        end)

      weights = weights |> Enum.reject(&is_nil/1)

      assert Enum.all?(weights, &(&1 == 0.0))
    end

    # test_colocated_kernels_not_additive
    test "visiting the same place again does not add to the weight there" do
      # The field keeps the strongest weight, not the sum, so a fresh kernel in
      # the same place is as strong as the first one and never stronger.
      start = DecayField.add(field(), @location)
      first = DecayField.weights(start, points(0..99))

      {weights, _field} =
        Enum.map_reduce(1..100, start, fn _, field ->
          field = field |> DecayField.step() |> DecayField.add(@location)
          {DecayField.weights(field, points(0..99)), field}
        end)

      assert Enum.all?(weights, &(&1 == first))
    end

    # test_field_selects_max_from_overlapping_kernels
    test "two overlapping visits weigh the same on the mirror image of a point" do
      field =
        field()
        |> DecayField.add([1.0, 2.0, 3.0])
        |> DecayField.add([1.02, 2.0, 3.0])

      for index <- 0..4 do
        towards_first = [[1.0 + 0.001 * index, 2.0, 3.0]]
        towards_second = [[1.02 - 0.001 * index, 2.0, 3.0]]

        assert DecayField.weights(field, towards_first) ==
                 DecayField.weights(field, towards_second)
      end
    end

    # test_field_selects_max_from_overlapping_decaying_kernels
    test "a second visit nearby lifts the weight again, and it decays from there" do
      test_point = [[1.015, 2.0, 3.0]]

      {weights, _field} =
        Enum.map_reduce(0..29, DecayField.add(field(), [1.0, 2.0, 3.0]), fn step, field ->
          field = if step == 10, do: DecayField.add(field, [1.02, 2.0, 3.0]), else: field
          {field |> DecayField.weights(test_point) |> hd(), DecayField.step(field)}
        end)

      before_second_visit = Enum.take(weights, 10)
      after_second_visit = Enum.drop(weights, 10)

      assert decreasing?(before_second_visit)
      assert decreasing?(after_second_visit)
      assert List.last(before_second_visit) < hd(after_second_visit)
    end

    # test_field_returns_empty_array_if_empty_query
    test "no query points weigh nothing" do
      assert DecayField.weights(DecayField.add(field(), @location), []) == []
    end

    # test_reset_clears_kernels
    test "resetting the field forgets every visit" do
      field = DecayField.add(field(), @location)

      assert DecayField.weights(field, [@location]) == [1.0]
      assert field |> DecayField.reset() |> DecayField.weights([@location]) == [0.0]
    end
  end

  describe "the return inhibitor" do
    # test_return_inhibitor_add_central_location_if_present_to_decay_field
    test "a visit is recorded where the sensor just was" do
      {_weights, inhibitor} =
        ReturnInhibitor.call(ReturnInhibitor.new(decay_field: field()), @location, @queries)

      assert [kernel] = inhibitor.decay_field.kernels
      assert kernel.location == @location
    end

    # test_return_inhibitor_does_not_add_central_location_if_not_present_to_decay_field
    test "nothing is recorded when the view's centre was not on an object" do
      {_weights, inhibitor} =
        ReturnInhibitor.call(ReturnInhibitor.new(decay_field: field()), nil, @queries)

      assert inhibitor.decay_field.kernels == []
    end

    # test_return_inhibitor_computes_weights_before_stepping_decay_field
    test "the weights are the field's answer before it is aged, not after" do
      queries = points(0..19)

      before_stepping = field() |> DecayField.add(@location)

      {weights, inhibitor} =
        ReturnInhibitor.call(ReturnInhibitor.new(decay_field: field()), @location, queries)

      assert weights == DecayField.weights(before_stepping, queries)

      aged = DecayField.weights(inhibitor.decay_field, queries)

      assert weights
             |> Enum.zip(aged)
             |> Enum.all?(fn {before, after_it} -> after_it < before end)
    end

    # test_return_inhibitor_returns_computed_weights
    test "the answer is one weight for every query point, unchanged" do
      queries = points(0..4)

      {weights, _inhibitor} =
        ReturnInhibitor.call(ReturnInhibitor.new(decay_field: field()), @location, queries)

      assert length(weights) == length(queries)

      assert weights ==
               field()
               |> DecayField.add(@location)
               |> DecayField.weights(queries)
    end

    # test_reset_resets_decay_field
    test "resetting the inhibitor forgets every visit" do
      {_weights, inhibitor} =
        ReturnInhibitor.call(ReturnInhibitor.new(decay_field: field()), @location, @queries)

      reset = ReturnInhibitor.reset(inhibitor)

      assert reset.decay_field.kernels == []
      assert DecayField.weights(reset.decay_field, [@location]) == [0.0]
    end
  end
end
