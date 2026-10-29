defmodule Monty.Simulators.Synthetic.SceneTest do
  @moduledoc """
  What a sensor sees of the stand-in object.

  The numbers are exact because the object is a sphere: a ray straight at it
  meets the surface at the radius, the normal is radial, and both principal
  curvatures are `-1/radius` — negative, as Monty's are for a convex surface.
  """

  use ExUnit.Case, async: true

  alias Monty.Frameworks.Utils.SpatialArithmetics
  alias Monty.Geometry.Rotation
  alias Monty.Simulators.Synthetic.Scene

  @radius 0.05

  defp scene, do: Scene.new(radius: @radius)

  # A sensor a decimetre above the object, looking down at it.
  defp looking_down, do: %{position: [0.0, 0.0, 0.1], rotation: Rotation.identity()}

  # ... and the same sensor turned to look along -x.
  defp looking_sideways do
    {:ok, rotation} = Rotation.from_axis_angle([0.0, 1.0, 0.0], :math.pi() / 2.0)
    %{position: [0.0, 0.0, 0.1], rotation: rotation}
  end

  describe "a sensor pointed at the object" do
    test "sees its surface at a distance, at the top of the sphere" do
      observation = Scene.observe(scene(), looking_down())

      assert observation.on_object
      assert_in_delta observation.depth, 0.05, 1.0e-12
    end

    test "and the surface it sees faces back at it" do
      {normal, _direction_1, _direction_2} =
        Scene.observe(scene(), looking_down()).pose_vectors

      assert_in_delta Enum.at(normal, 0), 0.0, 1.0e-12
      assert_in_delta Enum.at(normal, 1), 0.0, 1.0e-12
      assert_in_delta Enum.at(normal, 2), 1.0, 1.0e-12
    end

    test "and both curvatures are the sphere's own, negative as a convex surface is" do
      [first, second] = Scene.observe(scene(), looking_down()).principal_curvatures

      assert_in_delta first, -1.0 / @radius, 1.0e-12
      assert_in_delta second, -1.0 / @radius, 1.0e-12
    end

    test "with a right-handed pair of curvature directions, as Monty guarantees" do
      {normal, direction_1, direction_2} = Scene.observe(scene(), looking_down()).pose_vectors

      # `dir2` is the right-hand partner of `dir1` about the normal, which is
      # what makes `dir1 x dir2` point along it.
      assert SpatialArithmetics.dot(SpatialArithmetics.cross(direction_1, direction_2), normal) >
               0.0
    end
  end

  describe "a sensor pointed anywhere else" do
    test "sees nothing, and says so" do
      observation = Scene.observe(scene(), looking_sideways())

      refute observation.on_object
      assert observation.depth == nil
      assert observation.pose_vectors == nil
      assert observation.principal_curvatures == nil
    end
  end
end
