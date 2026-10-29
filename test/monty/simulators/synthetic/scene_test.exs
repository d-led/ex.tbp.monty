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

    test "and nothing else: a camera reports an image, not a surface" do
      # The normal and the curvatures are what a sensor module estimates from the
      # patch; a world that also reported them would hide every mistake in that
      # estimate (`Monty.Frameworks.Utils.SensorProcessing`).
      observation = Scene.observe(scene(), looking_down())

      assert observation |> Map.keys() |> Enum.sort() == [:depth, :on_object, :rgba]
    end
  end

  describe "a sensor pointed anywhere else" do
    test "sees nothing, and says so" do
      observation = Scene.observe(scene(), looking_sideways())

      refute observation.on_object
      assert observation.depth == nil
      assert observation.rgba == nil
    end
  end

  describe "a patch of rays, as a camera answers them" do
    test "is as tall and as wide as its resolution" do
      rendered = Scene.render(scene(), looking_down(), resolution: {3, 5}, hfov: 10.0)

      assert length(rendered.depth) == 3
      assert Enum.all?(rendered.depth, &(length(&1) == 5))
      assert length(rendered.rgba) == 3
      assert length(rendered.semantic) == 3
    end

    test "and its middle is the ray straight down the sensor's axis" do
      rendered = Scene.render(scene(), looking_down(), resolution: 3, hfov: 10.0)

      # The sensor is a decimetre up and the sphere's top is at the radius, so
      # the middle sees five centimetres of it — as the single ray did.
      centre = rendered.depth |> Enum.at(1) |> Enum.at(1)
      assert_in_delta centre, 0.1 - @radius, 1.0e-12
    end

    test "and its edge pixels see the surface further away, at an angle" do
      rendered = Scene.render(scene(), looking_down(), resolution: 3, hfov: 20.0)

      corner = rendered.depth |> hd() |> hd()
      centre = rendered.depth |> Enum.at(1) |> Enum.at(1)

      assert corner > centre
    end

    test "narrowing the field of view brings the edge pixels in" do
      wide = Scene.render(scene(), looking_down(), resolution: 3, hfov: 20.0)
      narrow = Scene.render(scene(), looking_down(), resolution: 3, hfov: 20.0, zoom: 2.0)

      corner_of = fn rendered -> rendered.depth |> hd() |> hd() end

      # Twice the zoom is half the field across, so the corner ray meets the
      # sphere closer to where the middle ray does.
      assert corner_of.(narrow) < corner_of.(wide)
      assert corner_of.(narrow) > narrow.depth |> Enum.at(1) |> Enum.at(1)
    end

    test "and its depth runs along the sensor's axis, as a depth camera reports it" do
      # A 90-degree camera at four times zoom puts the corner of a three-by-three
      # patch a quarter of a unit out on the image plane, which is still inside
      # the horizon of a sphere five centimetres across seen from ten.
      pose = looking_down()
      rendered = Scene.render(scene(), pose, resolution: 3, hfov: 90.0, zoom: 4.0)
      plane = 0.25

      points =
        for {depths, row} <- Enum.with_index(rendered.depth),
            {depth, column} <- Enum.with_index(depths) do
          across = plane * (column - 1)
          down = plane * (1 - row)

          # Monty's unprojection, `DepthTo3DLocations`: a pixel at `(x, y)` and
          # depth `d` is the point `(x d, y d, -d)`. It reconstructs the surface
          # only if the depth is the distance along the axis rather than along
          # the ray.
          Rotation.apply(pose.rotation, [across * depth, down * depth, -depth])
          |> then(&SpatialArithmetics.add(pose.position, &1))
        end

      assert length(points) == 9
      assert Enum.all?(points, &(abs(SpatialArithmetics.magnitude(&1) - @radius) < 1.0e-12))
    end

    test "a patch that hangs off the object has pixels that saw nothing" do
      # Looking at the object's edge: the middle sees it, a side does not.
      {:ok, rotation} = Rotation.from_axis_angle([0.0, 1.0, 0.0], :math.pi() / 4.0)

      rendered =
        Scene.render(
          scene(),
          %{position: [0.1, 0.0, 0.1], rotation: rotation},
          resolution: 5,
          hfov: 40.0
        )

      semantic = List.flatten(rendered.semantic)

      assert 0.0 in semantic
      assert 1.0 in semantic
    end
  end
end
