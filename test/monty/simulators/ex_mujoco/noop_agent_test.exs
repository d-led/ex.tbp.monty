defmodule Monty.Simulators.ExMujoco.NoopAgentTest do
  @moduledoc """
  Translations of Monty's `tests/unit/simulators/mujoco/noop_agent_test.py`.

  Monty builds a simulator with a `NoopAgent` and steps it through a `with sim:`
  block, adding an object at run time (`sim.add_object("box", position=…)`) and
  reading `sim.observations`. A scene here is built once from a config, so an
  object is part of the scene the agent starts in — "the box it was looking at"
  is the same case — and the look is `Simulator.reset/1`'s, which is the call
  that forwards the scene before the first image.

  Two things are asserted differently because of how the worlds are made:

  - Monty compares shapes of numpy arrays. An image here is rows of lists, so a
    shape is the row count and the row length, and a pass's numbers are read off
    the flattened rows.
  - Monty names MuJoCo's own geom numbers as `mjtGeom.mjGEOM_SPHERE` and
    `mjtGeom.mjGEOM_BOX`. Those are the numbers a geom with no semantic id of its
    own carries here too, and they are written as the two literals Monty's enum
    resolves to, with the enum named beside them.

  The zoom case's `Hypothesis` integers 1..10 are two: every one of them is a
  2048² render.
  """

  use ExUnit.Case, async: false

  alias Monty.Simulators.ExMujoco.Simulator

  @agent "agent_id_0"
  @patch "patch"
  @view_finder "view_finder"

  # `mjtGeom`: mjGEOM_SPHERE is 2 and mjGEOM_BOX is 6.
  @sphere 2
  @box 6

  describe "a noop agent" do
    # test_agent_state
    test "stands where the config put it, before any action" do
      half = :math.pi() / 4.0
      rotation = {:math.sin(half), :math.cos(half), 0.0, 0.0}

      state =
        %{@patch => sensor()}
        |> scene(position: [0.0, 1.5, -1.0], rotation: rotation)
        |> Simulator.state()
        |> Map.fetch!(@agent)

      assert state["position"] == [0.0, 1.5, -1.0]
      assert_same_rotation(state["rotation"], rotation)
    end

    # test_agent_observation_single_sensor
    test "sees a box as depth and colour, one sensor's worth" do
      observations =
        look(
          scene(%{@patch => sensor()},
            objects: [%{"name" => "box", "position" => [0.0, 0.0, -5.0]}]
          )
        )

      %{"depth" => depth, "rgba" => rgba} = Map.fetch!(observations, @patch)

      assert shape(depth) == {64, 64}
      # Four numbers to a pixel: the three the camera sends and an opaque alpha.
      assert shape(rgba) == {64, 64}
      assert length(flat(rgba)) == 64 * 64 * 4

      # The near face of a two-metre box five metres away is at four.
      assert_in_delta Enum.min(flat(depth)), 4.0, 1.0e-3
      # And something in the picture is farther than the box's centre.
      assert Enum.max(flat(depth)) >= 5.0

      assert Enum.min(flat(rgba)) == 0
      assert Enum.max(flat(rgba)) == 255
    end

    # test_agent_observation_semantic_default_ids
    test "sees MuJoCo's own geom numbers when the objects name no semantic id" do
      observations =
        look(
          scene(%{@patch => sensor(semantic: true)},
            objects: [
              %{"name" => "box", "position" => [-2.5, 0.0, -5.0]},
              %{"name" => "sphere", "position" => [2.5, 0.0, -5.0]}
            ]
          )
        )

      semantic = observations |> Map.fetch!(@patch) |> Map.fetch!("semantic")

      assert shape(semantic) == {64, 64}
      # The background, then one number per shape — each one the geom's own type.
      assert Enum.sort(Enum.uniq(flat(semantic))) == [0, @sphere, @box]
    end

    # test_agent_observation_semantic_custom_ids
    test "sees the semantic ids the objects were given instead" do
      observations =
        look(
          scene(%{@patch => sensor(semantic: true)},
            objects: [
              %{"name" => "box", "position" => [-2.5, 0.0, -5.0], "semantic_id" => 100},
              %{"name" => "sphere", "position" => [2.5, 0.0, -5.0], "semantic_id" => 101}
            ]
          )
        )

      semantic = observations |> Map.fetch!(@patch) |> Map.fetch!("semantic")

      assert shape(semantic) == {64, 64}
      assert Enum.sort(Enum.uniq(flat(semantic))) == [0, 100, 101]
    end

    # test_agent_observation_multiple_resolutions
    test "draws each sensor at the size it asks for, from its own renderer" do
      observations =
        look(
          scene(%{
            @patch => sensor(),
            @view_finder => sensor(width: 256, height: 256)
          })
        )

      patch = observations |> Map.fetch!(@patch) |> Map.fetch!("rgba")
      view_finder = observations |> Map.fetch!(@view_finder) |> Map.fetch!("rgba")

      assert shape(patch) == {64, 64}
      assert shape(view_finder) == {256, 256}
    end

    # test_agent_observation_zoom
    test "draws an object larger by the square of the zoom, up to filling the frame" do
      # Monty's own calibration: the pixels a one-metre cube covers, ten metres
      # away, in a 2048² image at zoom 1.
      covered_at_zoom_1 = 51_984
      side = 2048
      total = side * side

      for zoom <- [1, 2] do
        observations =
          look(
            scene(
              %{@patch => sensor(width: side, height: side, zoom: zoom * 1.0, semantic: true)},
              objects: [
                %{"name" => "box", "position" => [0.0, 0.0, -10.0], "semantic_id" => 1}
              ]
            )
          )

        semantic = observations |> Map.fetch!(@patch) |> Map.fetch!("semantic")

        # Every covered pixel carries the id 1, so the sum is the pixel count.
        covered = semantic |> flat() |> Enum.sum()
        expected = min(1.0, covered_at_zoom_1 * zoom * zoom / total)

        assert_in_delta covered / total, expected, 1.0e-2
      end
    end
  end

  # -- the world, and what a look answers ----------------------------------

  # A scene of one `NoopAgent` with `sensor_configs` as its `sensor_configs`,
  # standing where `position` and `rotation` say, over `objects`.
  defp scene(sensor_configs, options \\ []) do
    Simulator.start(%{
      "agents" => [
        %{
          "agent_id" => @agent,
          "class" => "NoopAgent",
          "position" => Keyword.get(options, :position, [0.0, 0.0, 0.0]),
          "rotation" => Keyword.get(options, :rotation, {1.0, 0.0, 0.0, 0.0}) |> Tuple.to_list(),
          "sensor_configs" => sensor_configs
        }
      ],
      "objects" => Keyword.get(options, :objects, [])
    })
  end

  defp sensor(options \\ []) do
    %{
      "width" => Keyword.get(options, :width, 64),
      "height" => Keyword.get(options, :height, 64),
      "zoom" => Keyword.get(options, :zoom, 1.0),
      "position" => [0.0, 0.0, 0.0],
      "rotation" => [1.0, 0.0, 0.0, 0.0],
      "semantic" => Keyword.get(options, :semantic, false)
    }
  end

  # A look with nothing moving: a step with no actions, which is what forwards
  # the scene — Monty's `with sim:` block does the same before the first image.
  defp look(simulator) do
    {_simulator, observations, _state} = Simulator.step(simulator, [], nil)
    Map.fetch!(observations, @agent)
  end

  # -- what a picture is here ----------------------------------------------

  defp shape(rows), do: {length(rows), rows |> hd() |> length()}

  defp flat(rows), do: List.flatten(rows)

  # Monty's `Rotation.approx_equal`, whose tolerance is 1e-6 radians: the same
  # statement as two normalised quaternions' dot product being at least
  # `cos(tol / 2)`, with a quaternion and its negative being one rotation.
  defp assert_same_rotation(actual, expected) do
    assert abs(dot(normalise(actual), normalise(expected))) >= :math.cos(1.0e-6 / 2.0)
  end

  defp dot({aw, ax, ay, az}, {bw, bx, by, bz}), do: aw * bw + ax * bx + ay * by + az * bz

  defp normalise(quaternion) do
    [w, x, y, z] =
      case quaternion do
        {a, b, c, d} -> Enum.map([a, b, c, d], &(&1 * 1.0))
        [a, b, c, d] -> Enum.map([a, b, c, d], &(&1 * 1.0))
      end

    length = :math.sqrt(w * w + x * x + y * y + z * z)

    {w / length, x / length, y / length, z / length}
  end
end
