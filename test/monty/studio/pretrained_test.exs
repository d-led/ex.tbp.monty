defmodule Monty.Studio.PretrainedTest do
  use ExUnit.Case, async: true

  alias Monty.Studio.Memory
  alias Monty.Studio.Pretrained
  alias Monty.Studio.Pretrained.Tensor
  alias Monty.Studio.Pretrained.Torch
  alias Monty.Test.Tmp
  alias Unpickler.Object

  @name "surf_agent_1lm_10distinctobj"
  @release "pretrained_ycb_v14"
  @label @release <> "/" <> @name

  describe "what it finds under a models root" do
    test "is one entry per model, named by release and model, not by path" do
      root = Tmp.dir("models")
      pickle = write!(root, "pretrained")

      assert Pretrained.models(root) == [{@release, @name, pickle}]
    end

    test "ignores anything that is not a model's pickle" do
      root = Tmp.dir("models")
      File.mkdir_p!(Path.join([root, @release, @name]))
      File.write!(Path.join([root, @release, @name, "notes.json"]), "{}")

      assert Pretrained.models(root) == []
    end

    # An archive unpacks to a *release directory*, not to a root of releases: a
    # fetch of `pretrained_ycb_v14` has `pretrained_ycb_v14/surf_agent_1lm/
    # pretrained/model.pt` under the directory it filled. Asked about that
    # directory, this walked one level too deep, found no models, and reported a
    # memory exported by exporting nothing.
    test "is the same answer for the release directory it unpacked to" do
      root = Tmp.dir("release")
      pickle = write!(root, "pretrained")

      assert Pretrained.models(Path.join(root, @release)) == [{@release, @name, pickle}]
    end
  end

  describe "keeping the libraries current" do
    test "leaves a library that is newer than the pickle it came from" do
      root = Tmp.dir("models")
      libraries = Tmp.dir("libraries")
      # A pickle that could not be read, so the test says whether it was opened
      # at all: the library beside it is newer, so nothing needs doing.
      write!(root, "not a torch save")
      write_library!(libraries, "already exported")

      assert %{exported: [], current: [@label], failed: []} = Pretrained.sync(root, libraries)
    end

    test "exports a library that is older than the pickle it came from" do
      root = Tmp.dir("models")
      libraries = Tmp.dir("libraries")
      write!(root, "not a torch save")
      write_library!(libraries, "stale", 60)

      # It read the pickle (and could not), rather than trusting the stale file.
      assert %{exported: [], failed: [{@label, _reason}]} = Pretrained.sync(root, libraries)
    end

    test "reports a model it cannot read, and writes nothing for it" do
      root = Tmp.dir("models")
      libraries = Tmp.dir("libraries")
      # A file where a torch save should be: the archive is broken, and the
      # report names the model rather than failing the whole sync.
      write!(root, "not a torch save")

      assert %{exported: [], failed: [{@label, _reason}]} = Pretrained.sync(root, libraries)

      refute File.exists?(Memory.path_for(@name, @release, libraries))
    end

    test "does nothing at all when there are no models" do
      assert Pretrained.sync(Tmp.dir("models"), Tmp.dir("libraries")) ==
               %{exported: [], current: [], failed: []}
    end

    test "names each model as it starts reading it" do
      root = Tmp.dir("models")
      libraries = Tmp.dir("libraries")
      # Not a pickle, so the export fails — but a model that cannot be read is
      # still a model the exporter reached, which is what a page showing progress
      # needs to hear about.
      write!(root, "not a torch save")

      parent = self()

      Pretrained.sync(root, libraries, on_progress: &send(parent, {:reading, &1}))

      assert_received {:reading, %{model: @label, index: 1, total: 1}}
    end
  end

  describe "whether anything is left to read" do
    # The failure this pins: a volume came back with the pickles and without the
    # libraries, the prerequisites page said "present", and the first step said
    # there was no memory. Nothing asked the question this answers.
    test "is yes for a model whose library was never written" do
      root = Tmp.dir("models")
      libraries = Tmp.dir("libraries")
      write!(root, "not a torch save")

      assert Pretrained.pending?(root, libraries)
    end

    test "is no once the library is there and newer than its pickle" do
      root = Tmp.dir("models")
      libraries = Tmp.dir("libraries")
      write!(root, "not a torch save")
      write_library!(libraries, "already exported")

      refute Pretrained.pending?(root, libraries)
    end

    test "is no when the models directory is empty or absent" do
      refute Pretrained.pending?(Tmp.dir("models"), Tmp.dir("libraries"))
    end
  end

  describe "a graph as another torch version writes it" do
    test "is the same records whether the graph is wrapped or is the state itself" do
      graph = graph_mapping()

      # `_graph` around it is the shape this port first met. Some releases hand
      # the mapping over as the object's own state instead, which is the same
      # graph and has to be read the same way.
      assert [record] = Pretrained.records(model(%Object{state: graph}))

      assert record ==
               Pretrained.records(model(%Object{state: %{"_graph" => graph}}))
               |> then(&hd/1)
    end
  end

  describe "a real pretrained model" do
    test "is read as the objects and channels Monty trained" do
      records = pretrained_pickle() |> Torch.load!() |> Pretrained.records()

      # One record per object and input channel.
      assert length(records) == 10
      assert Enum.any?(records, &(&1["object_id"] == "mug" and &1["input_channel"] == "patch"))

      # Every node has a place and the features the learning module matches on,
      # at full precision — these numbers are Monty's, read out of its pickle.
      record = hd(records)
      assert %{"positions" => [[_x, _y, _z] | _], "features" => features} = record
      assert %{"hsv" => [[_h, _s, _v] | _]} = features

      # One row of each feature per node, and the widths Monty stores: a colour,
      # a 3×3 pose frame, a flag, and two log curvatures.
      assert Enum.all?(features, fn {_name, rows} ->
               length(rows) == length(record["positions"])
             end)

      assert %{"pose_vectors" => [[_ | _] | _], "pose_fully_defined" => [[_flag] | _]} = features
    end
  end

  # Reading Monty's data is the point of this module, so the model has to be
  # here: it arrives through `/prerequisites` (`mix monty.prerequisites.fetch`),
  # and a test that quietly skipped it would hold nothing.
  defp pretrained_pickle do
    Pretrained.models(Pretrained.models_root())
    |> Enum.find(&match?({@release, @name, _pickle}, &1))
    |> case do
      nil ->
        flunk("""
        #{@label} is not unpacked under #{Pretrained.models_root()}.
        Fetch it with `mix monty.prerequisites.fetch #{@release}`.
        """)

      {_release, _name, pickle} ->
        pickle
    end
  end

  defp write!(root, contents) do
    pickle = Path.join([root, @release, @name, "pretrained", "model.pt"])
    File.mkdir_p!(Path.dirname(pickle))
    File.write!(pickle, contents)
    pickle
  end

  describe "a model with several learning modules" do
    test "exports one memory per module, each record saying which module it belongs to" do
      # A heterarchy: the 3-D child knows a cube, the 2-D child knows a logo, and
      # the high-level module knows the composition of them. Three memories, and a
      # run asks for each by index.
      term = %{
        "lm_dict" => %{
          0 => module_memory("001_cube", "patch_0"),
          1 => module_memory("021_logo_tbp", "patch_1"),
          2 => module_memory("024_mug_tbp_horz", "patch_2")
        }
      }

      records = Pretrained.records(term)

      assert Enum.map(records, &{&1["lm_index"], &1["object_id"]}) == [
               {0, "001_cube"},
               {1, "021_logo_tbp"},
               {2, "024_mug_tbp_horz"}
             ]
    end

    test "writes the features a graph holds, not the four an evidence module matches on" do
      # A 2-D child's graph has a colour and a frame; it has no log curvatures.
      graph = %{
        "pos" => tensor([[0.0, 0.0, 0.0]]),
        "x" => tensor([[0.5, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 1.0]]),
        "feature_mapping" => %{
          "hsv" => [0, 3],
          "pose_vectors" => [3, 9],
          "pose_fully_defined" => [9, 10]
        }
      }

      assert [record] = Pretrained.records(model(%Object{state: graph}))

      assert Map.keys(record["features"]) |> Enum.sort() ==
               ["hsv", "pose_fully_defined", "pose_vectors"]
    end
  end

  # A model of one object in one channel, keeping `graph` where a run would
  # find it — under `lm_dict`, one learning module, one graph memory.
  defp model(graph) do
    %{"lm_dict" => [%{"graph_memory" => %{"mug" => %{"patch" => graph}}}]}
  end

  # Two nodes of the widths Monty stores: three coordinates of place, a colour,
  # a 3×3 pose frame, the flag, and two log curvatures.
  defp graph_mapping do
    %{
      "pos" => tensor([[0.0, 0.0, 0.0], [0.1, 0.0, 0.0]]),
      "x" => tensor([for(n <- 1..15, do: n * 1.0), for(n <- 16..30, do: n * 1.0)]),
      "feature_mapping" => %{
        "hsv" => [0, 3],
        "pose_vectors" => [3, 12],
        "pose_fully_defined" => [12, 13],
        "principal_curvatures_log" => [13, 15]
      }
    }
  end

  defp tensor(rows) do
    columns = length(hd(rows))
    storage = for row <- rows, value <- row, into: <<>>, do: <<value::float-little-32>>

    %Tensor{
      type: :f32,
      count: columns * length(rows),
      size: [length(rows), columns],
      strides: [columns, 1],
      offset: 0,
      storage: storage
    }
  end

  # One learning module's memory: one object, one channel, one graph.
  defp module_memory(object_id, channel) do
    %{"graph_memory" => %{object_id => %{channel => %Object{state: graph_mapping()}}}}
  end

  # A library as a previous export left it, `age` seconds old.
  defp write_library!(libraries, contents, age \\ 0) do
    library = Memory.path_for(@name, @release, libraries)
    File.mkdir_p!(Path.dirname(library))
    File.write!(library, contents)
    File.touch!(library, System.os_time(:second) - age)
    library
  end
end
