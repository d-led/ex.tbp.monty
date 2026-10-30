defmodule Monty.Studio.TransformsTest do
  @moduledoc """
  An experiment's transforms are read from its config and applied to what the
  world renders.

  The one that matters today is `MissingToMaxDepth`: Habitat reports 0 where no
  mesh is present, a surface agent's search asks whether the middle of its view
  is nearer than a metre, and a 0 there would be read as an object at zero
  distance (`docs/monty-bugs.md` §1.7). Monty's experiments configure it; a run
  that skipped it would be a different experiment.
  """

  use ExUnit.Case, async: false

  alias Monty.Frameworks.EnvironmentUtils.Transforms
  alias Monty.Frameworks.EnvironmentUtils.Transforms.{AddNoiseToRawDepthImage, DepthTo3DLocations}
  alias Monty.Frameworks.EnvironmentUtils.Transforms.MissingToMaxDepth

  alias Monty.Studio.{Run, Setup}

  @experiment "base_config_10distinctobj_surf_agent"

  defp setup do
    {:ok, opened} = Monty.Studio.open(@experiment)
    opened.setup
  end

  test "the setup reads the transforms the experiment configures, in order" do
    assert Enum.map(setup().transforms, &get_in(&1, ["_target_"])) == [
             "tbp.monty.frameworks.environment_utils.transforms.MissingToMaxDepth",
             "tbp.monty.frameworks.environment_utils.transforms.DepthTo3DLocations"
           ]
  end

  test "and builds them, in the order they run" do
    assert [
             %MissingToMaxDepth{agent_id: "agent_id_0", max_depth: 1},
             %DepthTo3DLocations{} = point_cloud
           ] = Setup.built_transforms(setup())

    # The cameras the config declares: a patch at ten times zoom, a view finder
    # at one. What the world renders is what this unprojects.
    assert [patch, view_finder] = point_cloud.intrinsics
    assert_in_delta patch.fx, 0.1, 1.0e-12
    assert_in_delta view_finder.fx, 1.0, 1.0e-12
    assert point_cloud.depth_clip_sensors == [0]
  end

  test "a transform turns into a module here, so none is silently dropped" do
    setup = setup()

    assert length(Setup.built_transforms(setup)) == length(setup.transforms)
  end

  describe "a noisy experiment" do
    # The noise transform is what makes a noisy-camera experiment noisy; the
    # question a run has to answer is whether its noise is *its* noise, the same
    # at the same seed and step.
    defp noisy_setup do
      {:ok, opened} = Monty.Studio.open("test/evidence_lm/noisy_sensor")
      opened.setup
    end

    test "builds the noise transform its config names" do
      assert [
               %MissingToMaxDepth{},
               %AddNoiseToRawDepthImage{sigma: 0.001},
               %DepthTo3DLocations{}
             ] = Setup.built_transforms(noisy_setup())
    end

    test "draws the same noise twice for the same seed and step, and other noise at the next step" do
      # The property that makes a noisy run comparable with Monty's: the episode
      # seed decides the noise, not the wall clock (`docs/monty-bugs.md` §2.1).
      depth_and_noise = Enum.take(Setup.built_transforms(noisy_setup()), 2)
      observations = %{"agent_id_0" => %{"patch" => %{"depth" => List.duplicate([0.2, 0.2], 2)}}}

      at = fn step ->
        Transforms.run(depth_and_noise, observations, %{Monty.Context.new(4) | step: step}, nil)
      end

      assert at.(2) == at.(2)
      refute at.(2) == at.(3)
    end
  end

  test "a miss is handed on as the furthest the sensor can see" do
    # The world answers 0 where a ray missed; the transform turns that into "as
    # far as the sensor can see" before any module reads it. A patch means a
    # partial miss is normal: some pixels see the object, some see nothing.
    {patch, view_finder} = look_for(25)

    # The view finder is not a finger, so a miss is a metre away in it.
    assert Enum.any?(view_finder, fn {depth, semantic_id} ->
             semantic_id == 0.0 and depth == 1.0
           end),
           "no pixel of the view finder missed the object, so nothing was transformed"

    # The patch is a finger, which reaches five centimetres: a miss is as far as
    # the finger goes, and no pixel of it is ever at zero distance.
    refute Enum.any?(patch, fn {depth, _semantic_id} -> depth == 0.0 end)
    assert Enum.all?(patch, fn {depth, _semantic_id} -> depth <= 0.05 end)
  end

  # Every pixel every sensor saw over a run, as `{depth, semantic id}`.
  defp look_for(steps) do
    {:ok, run} = Run.start(setup(), steps: steps)

    try do
      {patch, view_finder, _run} =
        Enum.reduce(1..steps, {[], [], run}, fn _step, {patch, view_finder, run} ->
          {:ok, _info, observations, run} = Run.step(run)

          {[pixels(get_in(observations, ["agent_id_0", "patch"])) | patch],
           [pixels(get_in(observations, ["agent_id_0", "view_finder"])) | view_finder], run}
        end)

      {List.flatten(patch), List.flatten(view_finder)}
    after
      Run.stop(run)
    end
  end

  defp pixels(observation) do
    for {depth_row, semantic_row} <- Enum.zip(observation["depth"], observation["semantic"]),
        {depth, semantic_id} <- Enum.zip(depth_row, semantic_row),
        do: {depth, semantic_id}
  end
end
