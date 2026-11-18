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

    # A memory is a record of what a sensor perceived, so it is taught through
    # the run's own patch: the lens its camera makes and the distance its policy
    # stands off by. The CAD package's defaults are a 66° patch from five
    # millimetres, and a part memory used to be written through them while the
    # run read 11.42° from twenty-five.
    test "a part memory is taught through the run's lens and stand-off",
         %{objects: objects} do
      assert {:ok, plan} = Preparation.plan(with_optics(setup_struct(objects)))
      assert plan.labels == :part

      assert {:ok, _report} =
               Preparation.prepare(plan,
                 trainer: __MODULE__.Recorder,
                 exporter: __MODULE__.Exporter
               )

      options = recorded_options(plan.memory)
      assert_in_delta options[:fov_x] * 180 / :math.pi(), 11.42, 0.01
      assert options[:distance] == 25.0
    end

    # A run that names neither is taught with one answer rather than the CAD
    # package's silent 66°: the tutorial's `zoom: 10` on a square patch, and the
    # eight millimetres a feature experiment stands off by.
    test "a run that names no camera is taught through the tutorial's patch",
         %{objects: objects} do
      assert {:ok, plan} = Preparation.plan(setup_struct(objects))

      assert_in_delta plan.optics.fov_x * 180 / :math.pi(), 11.42, 0.01
      assert plan.optics.distance == 8.0
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

    # The compositional half: the memory holds the plate's features rather than
    # the plate, so one episode can be asked about a boss. What makes that a
    # question at all is that the object a run steps and the object the memory
    # answers with are one name — `plate_bosses_0`, not the memory's
    # `plate/bosses/0` beside the object set's `bosses_0`.
    test "a memory of features writes one object per feature, under the names it answers with",
         %{objects: objects} do
      setup = %{
        setup_struct(objects)
        | model_name_or_path: "/somewhere/projects/cad_parts_v1/plate_features"
      }

      assert {:ok, plan} = Preparation.plan(setup)
      assert plan.labels == :features
      assert plan.part == "plate"

      assert {:ok, report} =
               Preparation.prepare(plan,
                 trainer: __MODULE__.FeatureTrainer,
                 exporter: __MODULE__.FeatureExporter
               )

      assert report.written == 2

      for object <- ~w(plate_bosses_0 plate_body) do
        assert File.regular?(Path.join([objects, object, "textured.obj"]))
      end

      assert answered_with(plan.memory) == ["plate_bosses_0", "plate_body"]
    end
  end

  # The object ids a run loads, as the file holds them.
  defp answered_with(memory) do
    memory
    |> File.read!()
    |> :zlib.gunzip()
    |> String.split("\n", trim: true)
    |> Enum.map(&JSON.decode!(&1)["object_id"])
  end

  # The patch the CAD experiments step: the tutorial's 64×64 camera at `zoom: 10`
  # over a 90° base, and the policy's own stand-off. Read off a setup rather than
  # written into the module, which is what these cases are about.
  defp with_optics(setup) do
    %{
      setup
      | cameras: %{"patch" => [resolution: {64, 64}, zoom: 10.0, hfov: 90.0]},
        motor_system_config: %{
          "policy_selector" => %{"policy" => %{"desired_object_distance" => 0.025}}
        }
    }
  end

  defp recorded_options(memory) do
    memory
    |> Kernel.<>(".options")
    |> File.read!()
    |> :erlang.binary_to_term()
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

  # A trainer that writes what it was asked for and keeps the options it was
  # given, so a case can say what a memory is taught through.
  defmodule Recorder do
    def write_library([{part, _step}], path, options) do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "#{part} taught")
      File.write!(path <> ".options", :erlang.term_to_binary(options))
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

  # A trainer that answers the way the CAD package does for `labels: :features`:
  # one object per feature, named `<part>/<feature>`, and the records that go in
  # the file.
  defmodule FeatureTrainer do
    def write_library([{part, _step}], path, options) do
      # A memory of features is sampled at a millimetre with the visit cap raised
      # beside it, and read from closer than a part is: at the package's defaults
      # the body and risers spend the budget and the small features leave the
      # memory, and a sixteen-millimetre patch is as wide as a feature. Its lens
      # is the run's too — `zoom: 10` on a square patch is 11.42° — because a
      # memory photographed through a wider one is a memory of another surface.
      expected = %{
        spacing: 1.0,
        limit: 20_000,
        distance: 8.0,
        fov_x: 11.42 * :math.pi() / 180.0
      }

      unless Map.take(Map.new(options), Map.keys(expected)) == expected do
        raise "a feature memory is #{inspect(expected)}, not #{inspect(options)}"
      end

      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "#{part} taught as #{Keyword.fetch!(options, :labels)}")

      objects =
        for feature <- ["bosses/0", "body"] do
          id = "#{part}/#{feature}"
          %{object_id: id, nodes: 3, records: [record(id)]}
        end

      {:ok, %{path: path, nodes: 6, objects: objects}}
    end

    defp record(object_id) do
      %{
        "object_id" => object_id,
        "input_channel" => "patch",
        "positions" => [[0.0, 0.0, 0.0]],
        "features" => %{"on_object" => [[1.0]]},
        "lm_index" => 0
      }
    end
  end

  defmodule FeatureExporter do
    def feature_meshes(_step) do
      {:ok,
       for name <- ["bosses/0", "body"] do
         %{
           name: name,
           family: name,
           vertices: [[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]],
           triangles: [[0, 1, 2]],
           colour: {0.5, 0.5, 0.5}
         }
       end}
    end
  end
end
