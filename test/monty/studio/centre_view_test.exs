defmodule Monty.Studio.CentreViewTest do
  @moduledoc """
  A picture of the object, with the agent in it.

  The sensor views a run streams are what one camera saw. What nothing drew is the
  thing the experiment is about — where the agent is relative to the object, and
  whether the object is in reach at all.

  So this view is specified as geometry rather than as markup: the object is in
  the middle, the agent and its sensors are inside the frame, and the note says
  the distance that decides whether a patch can touch the surface.
  """

  use ExUnit.Case, async: true

  alias Monty.Geometry.Rotation
  alias Monty.Simulators.Synthetic.{Environment, Scene}
  alias Monty.Studio.CentreView

  @centre [0.0, 1.5, 0.0]
  @radius 0.075

  test "the object is in the middle of the frame, wherever the agent is" do
    for agent <- [[0.0, 1.6, 0.0], [0.4, 1.9, 0.3], [0.0, 0.4, 0.0]] do
      view = frame(agent)

      assert view.object.x == view.width / 2
      assert view.object.y == view.height / 2
    end
  end

  test "the agent is inside the frame from a finger's width away or a room away" do
    for agent <- [[0.0, 1.525, 0.0], [0.0, 4.0, 0.0], [0.0, 0.2, 0.0]] do
      view = frame(agent)

      assert inside?(view, view.agent), "agent at #{inspect(agent)} left the frame"
    end
  end

  test "it says how far the agent is from the surface, which is what the patch can reach" do
    # The gap to the *centre* is 0.1 m; the surface is the radius nearer than that.
    assert frame([0.0, 1.6, 0.0]).note =~ "0.025 m from the surface"
  end

  test "every sensor is drawn, and two sensors at different places are not the same dot" do
    view =
      frame([0.0, 1.6, 0.0], %{"patch" => [0.0, 0.0, 0.0], "view_finder" => [0.0, 0.0, 0.03]})

    assert Enum.map(view.sensors, & &1.id) == ["patch", "view_finder"]
    assert Enum.all?(view.sensors, &inside?(view, &1))

    assert view.sensors |> Enum.map(&{&1.x, &1.y}) |> Enum.uniq() |> length() == 2
  end

  test "a sensor further from the object than the agent is still in the frame" do
    # The view finder sits three centimetres behind the patch, which on this gap
    # is further from the object than the agent is: scaling to the agent alone
    # drew it outside the picture.
    view =
      frame([0.0, 1.5, 0.1], %{"patch" => [0.0, 0.0, 0.0], "view_finder" => [0.0, 0.0, 0.03]})

    assert Enum.all?(view.sensors, &inside?(view, &1)), "a sensor left the frame"
  end

  test "a world with no scene has nothing to centre on" do
    assert CentreView.frame(Environment.new(["patch"]), 1) == nil
  end

  # The world the studio builds for a MuJoCo config: a sphere where the sampler
  # puts it, and one or two cameras on the agent.
  defp frame(agent_position, sensors \\ %{"patch" => [0.0, 0.0, 0.0]}) do
    scene = Scene.new(centre: @centre, radius: @radius)

    placed =
      Map.new(sensors, fn {id, position} ->
        {id, %{position: position, rotation: Rotation.identity()}}
      end)

    Environment.new(Map.keys(placed), scene,
      agent: %{position: agent_position, rotation: Rotation.identity()},
      sensors: placed
    )
    |> CentreView.frame(7)
  end

  defp inside?(view, point),
    do: point.x >= 0 and point.x <= view.width and point.y >= 0 and point.y <= view.height
end
