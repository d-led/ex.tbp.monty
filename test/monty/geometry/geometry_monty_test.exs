defmodule Monty.GeometryMontyTest do
  @moduledoc """
  Translations of `tests/unit/geometry_test.py`.

  Four of its twelve cases are here: the two quaternion order conversions, read
  on one quaternion and on a list of them. Monty's `setUp` gives both orders of
  `(0, 1, 2, 3)`, and the same numbers are used.

  ## What could not be translated

  The other eight — `ScipyRotationsApproxEqualTest` and `RotationQuaternionTest` —
  are double-ledger cases: they assert Monty's helpers against
  `scipy.spatial.transform.Rotation` itself. `scipy_rotations_approx_equal` is
  documented as a backport of scipy's `Rotation.approx_equal`, `to_scalar_last`
  is the order scipy takes, and `Rotation.from_quat`/`as_quat` are checked against
  scipy's, so `evaluate`-for-`evaluate` the two implementations are the ledger.

  There is no scipy in this port and `Monty.Geometry.Rotation` *is* the
  arithmetic: a port of those cases would compare the port with the port. That is
  a restatement of the code under test, not a translation of a case that checks
  it against a second implementation — so they are listed rather than written,
  and the port's own rotation cases stand on their own arithmetic
  (`test/monty/geometry/rotation_test.exs`).
  """

  use ExUnit.Case, async: true

  alias Monty.Geometry

  # Monty's `setUp`: `w, x, y, z = 0, 1, 2, 3`, in both orders, once and twice.
  @scalar_first [0.0, 1.0, 2.0, 3.0]
  @scalar_last [1.0, 2.0, 3.0, 0.0]

  # test_to_scalar_first_1d
  test "a scalar-last quaternion is read scalar-first" do
    assert Geometry.to_scalar_first(@scalar_last) == @scalar_first
  end

  # test_to_scalar_first_2d
  test "a list of scalar-last quaternions is read scalar-first" do
    assert Geometry.to_scalar_first([@scalar_last, @scalar_last]) ==
             [@scalar_first, @scalar_first]
  end

  # test_to_scalar_last_1d
  test "a scalar-first quaternion is read scalar-last" do
    assert Geometry.to_scalar_last(@scalar_first) == @scalar_last
  end

  # test_to_scalar_last_2d
  test "a list of scalar-first quaternions is read scalar-last" do
    assert Geometry.to_scalar_last([@scalar_first, @scalar_first]) ==
             [@scalar_last, @scalar_last]
  end
end
