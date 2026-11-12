defmodule Monty.Runtime.PositioningTest do
  @moduledoc """
  The prologue steps the world until the agent is in front of the object.

  Monty's `pre_episode` is a loop, and what it decides is *which actions the world
  is stepped with*: a fresh look before each procedure, the procedure's actions
  after it, and nothing once it is finished. Here the "world" is simply the list of
  action lists it has been stepped with, so the loop's decisions are the value it
  comes back with — no process, no mock, and the procedures are Monty's own,
  running on real observations.
  """

  use ExUnit.Case, async: true

  alias Monty.Frameworks.Actions.MoveForward
  # `Environments` before `EnvironmentUtils`: credo orders these case-blind.
  alias Monty.Frameworks.Environments.PositioningProcedures.GetGoodViewFactory
  alias Monty.Frameworks.EnvironmentUtils.Transforms.{DepthTo3DLocations, MissingToMaxDepth}
  alias Monty.Frameworks.Models.MotorSystemState.{AgentState, SensorState}
  alias Monty.Geometry.Rotation
  alias Monty.Runtime.Positioning

  @agent "agent_id_0"
  @sensor "view_finder"
  @target 1
  @size 16

  test "no procedures means the world is left alone" do
    assert {:ok, [], %{steps: 0, success: false, procedures: []}} =
             Positioning.prepare([], @target, [], &look(&1, &2, far_then_near()))
  end

  test "the world is stepped with the procedure's actions, after a look" do
    assert {:ok, [[], [%MoveForward{distance: 0.01}]],
            %{steps: 2, success: true, procedures: ["view_finder@agent_id_0"]}} =
             Positioning.prepare([factory()], @target, [], &look(&1, &2, far_then_near()))
  end

  test "a single-object scene the procedure gives up on is an error" do
    assert {:error, {:target_not_visible, @target}} =
             Positioning.prepare([factory()], @target, [], &look(&1, &2, always_in_a_corner()))
  end

  test "a cluttered scene only needs the procedure to give up" do
    assert {:ok, _world, %{success: false}} =
             Positioning.prepare([factory()], @target, [], &look(&1, &2, always_in_a_corner()),
               distractors: 1
             )
  end

  test "a procedure that never finishes is stopped and reported" do
    assert {:error, {:positioning_did_not_finish, 5}} =
             Positioning.prepare(
               [factory(max_orientation_attempts: 100)],
               @target,
               [],
               &look(&1, &2, always_in_a_corner()),
               max_steps: 5
             )
  end

  # -- what the procedure is shown -------------------------------------------

  # The interface's transform computes every sensor's point cloud and a
  # procedure reads one, so the loop narrows it for the steps it takes. The
  # world here carries a transform list, as the interface does, and remembers
  # what each step was handed.
  test "a procedure computes only the cloud of the sensor it is positioning" do
    transforms = both_sensors()

    assert {:ok, world, %{steps: 2, success: true}} =
             Positioning.prepare(
               [factory()],
               @target,
               %{transforms: transforms, seen: []},
               &watch/2
             )

    # Two looks: the one before the step, and the one after it, each shown the
    # same narrowed world.
    assert [looked | [looked_again]] = world.seen
    assert looked == looked_again

    assert [%DepthTo3DLocations{} = narrowed, %MissingToMaxDepth{} = rest] = looked

    assert narrowed.sensor_ids == [@sensor],
           "the step should compute the procedure's sensor alone"

    assert narrowed.intrinsics == [:wide],
           "the camera has to be the one that sensor had, not the first in the list"

    assert narrowed.depth_clip_sensors == [],
           "and only the clipping that belonged to it"

    assert rest == List.last(transforms),
           "a transform that names no sensor is not the procedure's to narrow"

    # What lands back on the interface is the transform list it went in with:
    # the steps after positioning are the model's, and the model reads both.
    assert world.transforms == transforms
  end

  test "a world the procedure's sensor is not in is stepped as it is" do
    # A setup whose transforms do not name the procedure's sensor cannot be
    # narrowed to it, and a narrowed world would leave the procedure blind — so
    # the loop leaves the world alone rather than half a world.
    [patch_only] = [
      %DepthTo3DLocations{agent_id: @agent, sensor_ids: ["patch"], intrinsics: [:narrow]}
    ]

    transforms = [patch_only]

    assert {:ok, world, _outcome} =
             Positioning.prepare(
               [factory()],
               @target,
               %{transforms: transforms, seen: []},
               &watch/2
             )

    # The first look is the one it must not have narrowed.
    assert [^transforms | _more] = world.seen
    assert Enum.all?(world.seen, &(&1 == transforms))
  end

  # -- the scripted world ----------------------------------------------------

  # The world is the list of actions it has been stepped with; stepping it means
  # appending what was asked for, and answering what the script shows next.
  defp look(world, actions, script) do
    world = world ++ [actions]
    script.(length(world) - 1, world)
  end

  # A small object just out of reach, then the same object close enough: the
  # procedure takes one step forward, and then finds the centre on the object.
  defp far_then_near do
    fn
      0, world -> answer(centred_object(), 1.0, world)
      _look, world -> answer(centred_object(), 0.02, world)
    end
  end

  # A world that keeps the transforms it was stepped with: far to begin with,
  # close once the procedure has looked once.
  defp watch(%{transforms: transforms, seen: seen} = world, _actions) do
    depth = if seen == [], do: 1.0, else: 0.02

    {observation(centred_object(), depth), proprioceptive_state(),
     %{world | seen: [transforms | seen]}}
  end

  defp both_sensors do
    [
      %DepthTo3DLocations{
        agent_id: @agent,
        sensor_ids: [@sensor, "patch"],
        intrinsics: [:wide, :narrow],
        depth_clip_sensors: [1]
      },
      %MissingToMaxDepth{agent_id: @agent, max_depth: 20.0}
    ]
  end

  # Visible, close enough, and never under the centre pixel: the procedure turns
  # and turns and gets no closer to being on target.
  defp always_in_a_corner do
    fn _look, world -> answer(corner_object(), 0.02, world) end
  end

  defp answer(semantic, depth_on_object, world),
    do: {observation(semantic, depth_on_object), proprioceptive_state(), world}

  defp factory(options \\ []) do
    GetGoodViewFactory.new(Keyword.merge([agent_id: @agent, sensor_id: @sensor], options))
  end

  defp observation(semantic, depth_on_object) do
    step = 0.01

    pixels =
      semantic
      |> Enum.with_index()
      |> Enum.flat_map(fn {row, row_index} ->
        row
        |> Enum.with_index()
        |> Enum.map(fn {id, column_index} ->
          depth = if id == 0, do: 2.0, else: depth_on_object
          {[column_index * step, row_index * step, -1.0, id * 1.0], depth}
        end)
      end)

    %{
      @agent => %{
        @sensor => %{
          "depth" =>
            pixels |> Enum.map(fn {_point, depth} -> depth end) |> Enum.chunk_every(@size),
          "semantic_3d" => Enum.map(pixels, fn {point, _depth} -> point end)
        }
      }
    }
  end

  defp proprioceptive_state do
    %{
      @agent => %AgentState{
        position: [0.0, -0.1, 0.0],
        rotation: Rotation.identity(),
        sensors: %{
          @sensor => %SensorState{position: [0.0, 0.0, 0.0], rotation: Rotation.identity()}
        }
      }
    }
  end

  defp centred_object do
    for row <- 0..(@size - 1) do
      for column <- 0..(@size - 1) do
        if row in 6..9 and column in 6..9, do: 1, else: 0
      end
    end
  end

  defp corner_object do
    for row <- 0..(@size - 1) do
      for column <- 0..(@size - 1) do
        if row in 1..4 and column in 1..4, do: 1, else: 0
      end
    end
  end
end
