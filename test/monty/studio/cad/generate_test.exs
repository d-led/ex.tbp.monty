defmodule Monty.Studio.Cad.GenerateTest do
  @moduledoc """
  A part a person brought becomes an experiment the studio can open.

  The cases are about the contract the rest of the pipeline reads: the
  experiment's name, the memory name it loads (a build teaches that name because
  it is what the config asks for), the object it steps, and that generating twice
  is the same experiment. None of them assert the YAML's shape — `Studio.open/2`
  and `Preparation.plan/1` are the readers, and a config they cannot read is not
  a config.
  """

  use ExUnit.Case, async: false

  alias Monty.Studio
  alias Monty.Studio.Cad.{Generate, Preparation}
  alias Monty.Studio.Setup
  alias Monty.Test.Tmp

  setup do
    data = Tmp.dir("cad-generate")
    Tmp.system_env("MONTY_DATA", data)
    Tmp.app_env(:monty_libraries_dir, Path.join(data, "libraries"))

    {:ok, data: data, sets: Tmp.dir("cad-generate-sets")}
  end

  defp open(experiment, sets) do
    Studio.open(experiment, conf_dir: Generate.conf_dirs(sets))
  end

  describe "a part becomes an experiment" do
    test "the studio can open, under a name of its own", %{sets: sets} do
      assert {:ok, generated} = Generate.generate("solidcraft-plate", sets: sets)
      assert generated.experiment == "cad/solidcraft-plate_part_eval"

      assert {:ok, opened} = open(generated.experiment, sets)
      assert opened.name == "cad/solidcraft-plate_part_eval"
    end

    test "whose memory is the one the Make click teaches", %{sets: sets} do
      assert {:ok, generated} = Generate.generate("solidcraft-plate", sets: sets)
      assert {:ok, opened} = open(generated.experiment, sets)

      assert {:ok, plan} = Preparation.plan(opened.setup)
      assert plan.name == "solidcraft-plate_part"
      assert plan.labels == :part
      assert {part, step} = hd(plan.parts)
      assert part == "solidcraft-plate"
      assert Path.basename(step) == "solidcraft-plate.step"
      assert Path.basename(plan.memory) == "solidcraft-plate_part.jsonl.gz"
    end

    test "and asks for the part's own object", %{sets: sets} do
      assert {:ok, generated} = Generate.generate("solidcraft-plate", sets: sets)
      assert {:ok, opened} = open(generated.experiment, sets)

      assert Setup.objects(opened.setup) == ["solidcraft-plate"]
    end

    # The generated run is the shipped part-level experiment with three things
    # changed; if it were built on anything else, the sentence above would be
    # true and the run would still be in another world.
    test "in the world the part-level CAD run steps", %{sets: sets} do
      assert {:ok, generated} = Generate.generate("solidcraft-plate", sets: sets)
      assert {:ok, opened} = open(generated.experiment, sets)

      assert opened.groups["environment"] == "cad_plate_objects"
      assert opened.groups["monty/motor_system_config"] == "surface_curvature_informed_goal1"
    end

    test "writing it again is the same experiment, not a second one", %{sets: sets} do
      assert {:ok, first} = Generate.generate("solidcraft-plate", sets: sets)
      text = File.read!(hd(first.files))
      assert {:ok, second} = Generate.generate("solidcraft-plate", sets: sets)

      assert second.experiment == first.experiment
      assert File.read!(hd(second.files)) == text
    end
  end

  describe "a part that is not here" do
    test "is refused, and no experiment is written", %{sets: sets} do
      assert {:error, sentence} = Generate.generate("nothing_by_that_name", sets: sets)
      assert sentence =~ "no part"
      assert Path.wildcard(Path.join(sets, "**/*.yaml")) == []
    end
  end

  # A generated set is read before the shipped ones, so a second experiment of
  # the same name would shadow a measured one with a copy of itself.
  describe "a part that already has an experiment" do
    test "is refused, and nothing is written", %{sets: sets} do
      assert {:error, sentence} = Generate.generate("plate", sets: sets)
      assert sentence =~ "already has a run"
      assert Path.wildcard(Path.join(sets, "**/*.yaml")) == []
    end

    test "answers the experiment a page links to" do
      assert Generate.experiment_for("plate") == "cad/plate_part_eval"
      assert Generate.experiment_for("bracket") == nil
    end
  end
end
