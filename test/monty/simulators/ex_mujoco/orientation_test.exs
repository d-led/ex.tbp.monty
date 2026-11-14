defmodule Monty.Simulators.ExMujoco.OrientationTest do
  use ExUnit.Case, async: true

  alias Monty.Simulators.ExMujoco.Orientation

  describe "a turn" do
    test "about the x axis is anticlockwise and its inverse is its conjugate" do
      quarter = Orientation.about_x(90)

      # A quarter turn about x takes the body's y axis to its z axis.
      assert_close(Orientation.rotate(quarter, [0.0, 1.0, 0.0]), [0.0, 0.0, 1.0])

      round_trip =
        Orientation.multiply(quarter, Orientation.invert(quarter))
        |> Orientation.rotate([0.0, 1.0, 0.0])

      assert_close(round_trip, [0.0, 1.0, 0.0])
    end

    test "about the y axis turns the body's x axis towards its negative z" do
      quarter = Orientation.about_y(90)

      assert_close(Orientation.rotate(quarter, [1.0, 0.0, 0.0]), [0.0, 0.0, -1.0])
    end

    test "composing on the right turns the body in its own frame" do
      # A body already turned 90° about x, then yawed 90° about its own y: the
      # yaw is about what was the world's z before the first turn.
      turned = Orientation.about_x(90)

      both = Orientation.multiply(turned, Orientation.about_y(90))

      # Its own x axis now points where world x did before the yaw, so the yaw
      # moves that axis to where the first turn had taken world y.
      assert_close(Orientation.axis(both, 0), [0.0, 1.0, 0.0], 0.0001)
    end

    test "no turn leaves everything where it was" do
      assert Orientation.identity() == {1.0, 0.0, 0.0, 0.0}
      assert_close(Orientation.rotate(Orientation.identity(), [0.1, 0.2, 0.3]), [0.1, 0.2, 0.3])
    end
  end

  describe "reading an orientation back" do
    test "the x angle of a pitch is the pitch" do
      assert_in_delta Orientation.euler_x(Orientation.about_x(30)), radians(30), 1.0e-9
    end

    test "a yaw has no x angle in it" do
      assert_in_delta Orientation.euler_x(Orientation.about_y(45)), 0.0, 1.0e-12
    end

    test "a body's own axes are the columns of its rotation matrix" do
      # Turned 90° about x: local y is world z, local z is world -y.
      assert_close(Orientation.axis(Orientation.about_x(90), 1), [0.0, 0.0, 1.0])
      assert_close(Orientation.axis(Orientation.about_x(90), 2), [0.0, -1.0, 0.0])
    end
  end

  defp radians(degrees), do: degrees * :math.pi() / 180.0

  defp assert_close(actual, expected, tolerance \\ 1.0e-12) do
    Enum.zip(as_list(actual), as_list(expected))
    |> Enum.each(fn {a, b} -> assert_in_delta a, b, tolerance end)
  end

  defp as_list(values) when is_tuple(values), do: Tuple.to_list(values)
  defp as_list(values), do: values
end
