defmodule Monty.Studio.Cad.PreparationTest do
  @moduledoc """
  A CAD part's inputs, written from the part file the experiment names.

  The two formats are Monty's, so these cases are about the *addresses* — which
  part file is read, which library file and object directory are written — and
  about the writing being the CAD package's work rather than ours. Both writers
  are given to the module, so the suite needs no geometry to run.
  """

  use ExUnit.Case, async: false

  alias Monty.Studio.Cad.Preparation
  alias Monty.Studio.Setup
  alias Monty.Test.Tmp

  # A part the node holds: the geometry is another package's, and what these
  # cases are about is where it comes from and where the answers go.
  setup do
    data = Tmp.dir("cad-preparation")
    parts = Path.join(data, "parts")
    File.mkdir_p!(parts)
    File.write!(Path.join(parts, "plate.step"), "ISO-10303-21;")
    Tmp.system_env("MONTY_DATA", data)
    # The memory lands in the node's library root, which a test keeps to itself:
    # a suite that wrote into the checkout's `priv/monty/libraries` would be
    # writing a model where nobody asked for one.
    libraries = Path.join(data, "libraries")
    Tmp.app_env(:monty_libraries_dir, libraries)

    {:ok, data: data, objects: Path.join(data, "cad_objects"), libraries: libraries}
  end

  defp setup_struct(objects, object \\ "plate") do
    struct(Setup,
      world: :ex_mujoco,
      object_names: [object],
      model_name_or_path: "/somewhere/tbp/results/monty/projects/cad_parts_v1/plate_part",
      environment: %{data_path: objects, module: %{class: "MuJoCoSimulator"}}
    )
  end

  describe "what preparing a part would write" do
    test "is the memory and the object set the experiment names",
         %{data: data, objects: objects, libraries: libraries} do
      assert {:ok, plan} = Preparation.plan(setup_struct(objects))

      assert plan.part == "plate"
      assert plan.step == Path.join([data, "parts", "plate.step"])
      assert plan.name == "plate_part"
      assert plan.release == "cad_parts_v1"
      assert plan.memory == Path.join([libraries, "cad_parts_v1", "plate_part.jsonl.gz"])
      assert plan.objects == objects
    end

    # The parts the application ships answer for an object they are named after,
    # so a machine with an empty data directory still prepares the part it has.
    test "reads a part the application ships when the data root holds none",
         %{objects: objects, libraries: libraries} do
      assert {:ok, plan} = Preparation.plan(setup_struct(objects, "solidcraft-plate"))

      assert Path.basename(plan.step) == "solidcraft-plate.step"
      assert plan.memory == Path.join([libraries, "cad_parts_v1", "plate_part.jsonl.gz"])
    end

    test "is refused when no part file answers the object's name", %{objects: objects} do
      assert {:error, sentence} = Preparation.plan(setup_struct(objects, "bracket"))
      assert sentence =~ ~s(there is no part "bracket")
      assert sentence =~ "plate.step"
    end

    test "is refused when the experiment names no memory", %{objects: objects} do
      setup = %{setup_struct(objects) | model_name_or_path: nil}

      assert {:error, sentence} = Preparation.plan(setup)
      assert sentence =~ "model_name_or_path"
    end
  end

  describe "writing a plan" do
    test "asks the CAD package for the memory and writes the object set in Monty's shape",
         %{objects: objects} do
      {:ok, plan} = Preparation.plan(setup_struct(objects))

      assert {:ok, report} =
               Preparation.prepare(plan,
                 trainer: __MODULE__.Trainer,
                 exporter: __MODULE__.Exporter
               )

      # The memory is the training's — its path is what a config loads by.
      assert report.memory == plan.memory
      assert File.read!(plan.memory) == "plate taught as plate_part"

      # The object is a MuJoCo object directory, named for what the memory holds.
      assert report.objects == objects
      assert report.written == 1
      assert File.regular?(Path.join([objects, "plate", "textured.obj"]))
      assert File.regular?(Path.join([objects, "plate", "metadata.json"]))
    end
  end

  # The two writers, as the CAD package answers them: a memory file, and one
  # mesh of the whole part. Kept here so the cases above test the module's
  # decisions rather than a Rust build.
  defmodule Trainer do
    def write_library([{part, _step}], path, _options) do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "#{part} taught as #{Path.basename(path, ".jsonl.gz")}")
      {:ok, %{path: path, nodes: 3, objects: [%{object_id: part, nodes: 3}]}}
    end
  end

  defmodule Exporter do
    def part_mesh(_step, options) do
      {:ok,
       %{
         name: Keyword.get(options, :name, "part"),
         vertices: [[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]],
         triangles: [[0, 1, 2]],
         colour: {0.5, 0.5, 0.5}
       }}
    end
  end
end
