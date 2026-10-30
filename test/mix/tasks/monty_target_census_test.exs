defmodule Mix.Tasks.Monty.TargetCensusTest do
  @moduledoc """
  The target census, run for real against Monty's snapshots.

  One assertion is enough to hold the seam: Hydra names a class to instantiate
  with `_target_`, so a class Monty's snapshots name is a class a run builds. If
  the walk stops finding `_target_`s — because the composed tree changed shape, or
  the key moved — this count goes to zero and nobody notices; so it is asserted.
  """

  use ExUnit.Case, async: false

  setup do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous) end)
    :ok
  end

  test "a class Monty's experiments name is reported with how many name it" do
    path =
      Path.join(System.tmp_dir!(), "target_census_#{System.unique_integer([:positive])}.json")

    on_exit(fn -> File.rm(path) end)

    Mix.Tasks.Monty.TargetCensus.run(["--json", path])
    census = path |> File.read!() |> Jason.decode!()

    assert %{
             "class" => "MontyObjectRecognitionExperiment",
             "status" => "planned",
             "snapshots" => named
           } =
             census[
               "tbp.monty.frameworks.experiments.object_recognition_experiments.MontyObjectRecognitionExperiment"
             ]

    assert named > 50

    # A class this port has written comes back implemented: the census says what
    # the map says, from the same map.
    assert %{"status" => "implemented"} =
             census[
               "tbp.monty.frameworks.models.evidence_matching.learning_module.EvidenceGraphLM"
             ]
  end
end
