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

  test "and builds the ones this port has, leaving the rest out rather than approximating" do
    assert [%MissingToMaxDepth{agent_id: "agent_id_0", max_depth: 1}] =
             Setup.built_transforms(setup())
  end

  test "a transform the port has not written is reported, not silently dropped" do
    findings = setup().findings |> Enum.map(& &1.code)

    assert :modules_not_ported in findings
  end

  test "a miss is handed on as the furthest the sensor can see" do
    # The world answers 0 where a ray missed; the transform turns that into "as
    # far as the sensor can see" before any module reads it. A patch means a
    # partial miss is normal: some pixels see the object, some see nothing.
    {:ok, run} = Run.start(setup(), steps: 25)

    try do
      {_run, seen} =
        Enum.reduce(1..25, {run, []}, fn _step, {run, seen} ->
          {:ok, _info, observations, run} = Run.step(run)
          {run, [get_in(observations, ["agent_id_0", "patch"]) | seen]}
        end)

      pixels =
        for observation <- seen,
            {depth_row, semantic_row} <- Enum.zip(observation["depth"], observation["semantic"]),
            {depth, semantic_id} <- Enum.zip(depth_row, semantic_row),
            do: {depth, semantic_id}

      assert Enum.any?(pixels, fn {depth, semantic_id} -> semantic_id == 0.0 and depth == 1.0 end),
             "no pixel missed the object, so nothing was transformed"

      refute Enum.any?(pixels, fn {depth, _semantic_id} -> depth == 0.0 end)
    after
      Run.stop(run)
    end
  end
end
