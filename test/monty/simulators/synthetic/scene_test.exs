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

    test "and the colour of the surface it hit" do
      observation =
        Scene.observe(Scene.new(radius: @radius, rgb: [0.1, 0.2, 0.3]), looking_down())

      assert [0.1, 0.2, 0.3, 1.0] = observation.rgba
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
      assert observation.rgba == nil
    end
  end

  describe "a patch of rays, as a camera answers them" do
    test "is as wide and as tall as its resolution" do
      rendered = Scene.render(scene(), looking_down(), resolution: 5, field_of_view: 10.0)

      assert length(rendered.depth) == 5
      assert Enum.all?(rendered.depth, &(length(&1) == 5))
      assert length(rendered.rgba) == 5
      assert length(rendered.semantic) == 5
    end

    test "and its middle is the ray straight down the sensor's axis" do
      rendered = Scene.render(scene(), looking_down(), resolution: 3, field_of_view: 10.0)

      # The sensor is a decimetre up and the sphere's top is at the radius, so
      # the middle sees five centimetres of it — as the single ray did.
      centre = rendered.depth |> Enum.at(1) |> Enum.at(1)
      assert_in_delta centre, 0.1 - @radius, 1.0e-12
    end

    test "and its edge pixels see the surface further away, at an angle" do
      rendered = Scene.render(scene(), looking_down(), resolution: 3, field_of_view: 20.0)

      corner = rendered.depth |> hd() |> hd()
      centre = rendered.depth |> Enum.at(1) |> Enum.at(1)

      assert corner > centre
    end

    test "a patch that hangs off the object has pixels that saw nothing" do
      # Looking at the object's edge: the middle sees it, a side does not.
      {:ok, rotation} = Rotation.from_axis_angle([0.0, 1.0, 0.0], :math.pi() / 4.0)

      rendered =
        Scene.render(
          scene(),
          %{position: [0.1, 0.0, 0.1], rotation: rotation},
          resolution: 5,
          field_of_view: 40.0
        )

      semantic = List.flatten(rendered.semantic)

      assert 0.0 in semantic
      assert 1.0 in semantic
    end
  end
end
