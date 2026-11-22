defmodule Monty.Frameworks.EnvironmentUtils.Transforms.DepthTo3DNativeParityTest do
  @moduledoc """
  The native unprojection answers what the reference answers.

  One depth image is unprojected twice — once with `native_kernels?` on and once
  with it off — and the two observations have to be the same, field for field.
  The arithmetic is a ray times a depth, into the world through a frame, so a
  difference in the last bit would be a difference in what was computed: the same
  products in the same order, with the mask's rule decided before either walk.

  The images are deliberately awkward: not square, not a power of two, a frame
  that turns as well as moves, both masks (only the pixels on the surface, and
  every pixel), the semantic sensor's own mask, a view with two surfaces to
  choose between, and a view where nothing in it is nearer than a metre.

  `async: false`, because the switch is application configuration and a
  concurrently running test would read it while this one holds it.
  """

  use ExUnit.Case, async: false

  alias ExTbpMonty.Core.MatcherNif
  alias Monty.Frameworks.EnvironmentUtils.Transforms.{DepthTo3DLocations, TransformContext}
  alias Monty.Frameworks.Models.MotorSystemState.{AgentState, SensorState}
  alias Monty.Geometry.Rotation

  setup do
    on_exit(fn -> Application.delete_env(:ex_tbp_monty, :native_kernels?) end)
    :ok
  end

  test "the kernel is loaded on this machine" do
    assert MatcherNif.loaded?()
  end

  test "a turning frame, every pixel kept, in the world" do
    observations = depth_six_by_five(0.7)
    both_ways(observations, get_all_points: true, resolutions: [{6, 5}])
  end

  test "the pixels on the surface only" do
    observations = depth_six_by_five(0.7)
    both_ways(observations, get_all_points: false, resolutions: [{6, 5}])
  end

  test "two surfaces, and the one the middle pixel is on" do
    # The middle row is a metre behind the rest, so the threshold is between the
    # two and the mask keeps the near surface's pixels.
    observations = %{"patch" => %{"depth" => two_surfaces(0.3, 1.6, {6, 5})}}
    both_ways(observations, resolutions: [{6, 5}])
  end

  test "the semantic sensor's own mask, clipped at the finger's reach" do
    observations = %{
      "patch" => %{
        "depth" => image(6, 5, 0.7),
        "semantic" => semantic_six_by_five()
      }
    }

    both_ways(observations,
      resolutions: [{6, 5}],
      use_semantic_sensor: true,
      depth_clip_sensors: [0]
    )
  end

  test "nothing in the view is nearer than a metre" do
    observations = depth_six_by_five(1.4)
    both_ways(observations, resolutions: [{6, 5}])
  end

  test "a one-pixel view has no grid to spread" do
    observations = %{"patch" => %{"depth" => [[0.4]]}}
    both_ways(observations, resolutions: [{1, 1}], get_all_points: true)
  end

  # -- the two answers -------------------------------------------------------

  defp both_ways(seen, options) do
    transform = transform(options)
    ctx = %TransformContext{state: proprioceptive_state()}

    native = DepthTo3DLocations.call(%{"agent_id_0" => seen}, transform, ctx)

    reference =
      with_reference(fn ->
        DepthTo3DLocations.call(%{"agent_id_0" => seen}, transform, ctx)
      end)

    assert native == reference
  end

  defp with_reference(fun) do
    Application.put_env(:ex_tbp_monty, :native_kernels?, false)
    answer = fun.()
    Application.delete_env(:ex_tbp_monty, :native_kernels?)
    answer
  end

  defp transform(options) do
    DepthTo3DLocations.new(
      Keyword.merge(
        [
          agent_id: "agent_id_0",
          sensor_ids: ["patch"],
          world_coord: true,
          get_all_points: true,
          hfov: 90.0,
          zooms: 1.3
        ],
        options
      )
    )
  end

  # A frame that turns as well as moves: the sensor is a quarter turn about the
  # vertical from the agent, so a point in its own frame is a different point in
  # the world.
  defp proprioceptive_state do
    %{
      "agent_id_0" => %AgentState{
        position: [0.1, 0.5, -0.2],
        rotation: rotation([0.0, 0.0, 90.0]),
        sensors: %{
          "patch" => %SensorState{
            position: [0.02, -0.01, 0.1],
            rotation: rotation([0.0, 0.0, 30.0])
          }
        }
      }
    }
  end

  defp rotation(degrees) do
    {:ok, rotation} = Rotation.from_euler_degrees(degrees)
    rotation
  end

  defp depth_six_by_five(depth) do
    %{"patch" => %{"depth" => image(6, 5, depth)}}
  end

  defp image(height, width, depth), do: List.duplicate(List.duplicate(depth, width), height)

  # The near surface's row in the middle of the view, the far one around it.
  defp two_surfaces(near, far, {height, width}) do
    for row <- 0..(height - 1) do
      List.duplicate(if(row == div(height, 2), do: near, else: far), width)
    end
  end

  defp semantic_six_by_five do
    for row <- 0..5 do
      for column <- 0..4 do
        if(rem(row + column, 3) == 0, do: 0.0, else: 1.0)
      end
    end
  end
end
