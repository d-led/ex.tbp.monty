defmodule Monty.Frameworks.Utils.SensorProcessingNativeParityTest do
  @moduledoc """
  The native curvature fit answers what the reference answers.

  One patch's principal curvatures are asked for twice — once with
  `native_kernels?` on and once with it off — and the two answers have to be the
  same numbers. The fit is six unknowns solved from a few hundred points, so a
  difference in the last bit is a difference in what was computed, not noise: the
  same normal equations, summed over the same points in the same order, solved by
  the same elimination with the same tolerance.

  The patches are deliberately awkward: a curved surface, a patch that is partly
  off the object, one where the middle pixel is off it entirely, and one with too
  few pixels on the object for a fit of six unknowns.

  `async: false`, because the switch is application configuration and a
  concurrently running test would read it while this one holds it.
  """

  use ExUnit.Case, async: false

  alias ExTbpMonty.Core.MatcherNif
  alias Monty.Frameworks.Utils.SensorProcessing

  @width 16
  @centre div(@width * @width, 2) + div(@width, 2)

  setup do
    on_exit(fn -> Application.delete_env(:ex_tbp_monty, :native_kernels?) end)
    :ok
  end

  test "the kernel is loaded on this machine" do
    assert MatcherNif.loaded?()
  end

  test "a curved patch has the same curvatures either way" do
    patch = paraboloid(@width, {0.4, 1.3}, fn _row, _column -> true end)
    normal = [0.0, 0.0, 1.0]

    native = SensorProcessing.principal_curvatures(patch, @centre, normal)

    assert native ==
             with_reference(fn ->
               SensorProcessing.principal_curvatures(patch, @centre, normal)
             end)

    {k1, k2, _first, _second, valid?} = native
    assert valid?

    # The surface curves differently along x and y, so the two curvatures it is
    # fitted from are different numbers rather than one repeated.
    refute k1 == k2
  end

  test "a patch hanging off the object has the same curvatures either way" do
    # Only the lower half of the patch is on the object, so the weights are
    # normalised over pixels the fit does not use — which is what the reference
    # does and the kernel has to do too.
    patch = paraboloid(@width, {0.7, 0.7}, fn row, _column -> row >= div(@width, 2) end)
    normal = [0.1, 0.2, 0.97]

    native = SensorProcessing.principal_curvatures(patch, @centre, normal)

    assert native ==
             with_reference(fn ->
               SensorProcessing.principal_curvatures(patch, @centre, normal)
             end)
  end

  test "an unweighted, intercept-free fit answers the same either way" do
    patch = paraboloid(@width, {0.5, 0.2}, fn _row, _column -> true end)
    normal = [0.0, 0.0, 1.0]
    options = [weighted: false, fit_intercept: false]

    assert SensorProcessing.principal_curvatures(patch, @centre, normal, options) ==
             with_reference(fn ->
               SensorProcessing.principal_curvatures(patch, @centre, normal, options)
             end)
  end

  test "a middle pixel off the object has no curvatures either way" do
    patch = paraboloid(@width, {0.4, 0.4}, fn row, column -> row < 4 and column < 4 end)

    answer = SensorProcessing.principal_curvatures(patch, @centre, [0.0, 0.0, 1.0])

    assert answer == {0.0, 0.0, [0.0, 0.0, 0.0], [0.0, 0.0, 0.0], false}

    assert answer ==
             with_reference(fn ->
               SensorProcessing.principal_curvatures(patch, @centre, [0.0, 0.0, 1.0])
             end)
  end

  test "too few pixels on the object is no fit, either way" do
    # Three points cannot pin six unknowns, and a singular system is answered as
    # no curvatures rather than as a row of NaNs.
    patch = paraboloid(@width, {0.4, 0.4}, fn row, column -> row == 8 and column < 3 end)

    answer = SensorProcessing.principal_curvatures(patch, @centre, [0.0, 0.0, 1.0])

    assert answer ==
             with_reference(fn ->
               SensorProcessing.principal_curvatures(patch, @centre, [0.0, 0.0, 1.0])
             end)

    refute elem(answer, 4)
  end

  defp with_reference(fun) do
    Application.put_env(:ex_tbp_monty, :native_kernels?, false)
    answer = fun.()
    Application.delete_env(:ex_tbp_monty, :native_kernels?)
    answer
  end

  # A patch of a paraboloid, `[x, y, z, mask]` a pixel, with the background where
  # `on_object?` says it is not. Two curvatures, because a surface that curves the
  # same way in both directions has one curvature answered twice.
  defp paraboloid(width, {curvature_x, curvature_y}, on_object?) do
    centre = div(width, 2)

    for row <- 0..(width - 1), column <- 0..(width - 1) do
      x = (column - centre) * 0.002
      y = (row - centre) * 0.002
      mask = if on_object?.(row, column), do: 1.0, else: 0.0

      [x, y, 0.5 - curvature_x * x * x - curvature_y * y * y, mask]
    end
  end
end
