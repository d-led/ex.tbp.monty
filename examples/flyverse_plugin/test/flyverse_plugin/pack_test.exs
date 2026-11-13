defmodule FlyversePlugin.PackTest do
  use ExUnit.Case, async: true

  alias FlyversePlugin.Pack

  describe "a source-major graph" do
    test "gives every neuron a row, and the last entry is the edge count" do
      {row_ptr, destinations, counts} =
        Pack.source_major(3, [{2, 0, 5}, {0, 1, -3}, {0, 2, 4}])

      assert row_ptr == [0, 2, 2, 3]
      assert destinations == [1, 2, 0]
      assert counts == [-3, 4, 5]
    end

    test "keeps a neuron's edges together, in the order they were given" do
      {_row_ptr, destinations, _counts} =
        Pack.source_major(2, [{1, 0, 1}, {0, 1, 2}, {0, 0, 3}])

      assert destinations == [1, 0, 0]
    end

    test "is empty for a pack with no edges" do
      assert {[0, 0, 0], [], []} = Pack.source_major(2, [])
    end
  end

  describe "writing a pack" do
    setup do
      directory =
        Path.join(System.tmp_dir!(), "flyverse_pack_#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(directory) end)
      {:ok, directory: directory}
    end

    test "writes the four arrays and the plan", %{directory: directory} do
      spec = %{
        neuron_ids: [11, 22],
        edges: [{0, 1, 7}],
        plan: %{"drives" => [[0]], "readouts" => [[1]], "ticks" => 30, "seed" => 3}
      }

      assert {:ok, %{neurons: 2, edges: 1}} = Pack.write(directory, spec)

      assert ["destinations.npy", "manifest.json", "neuron_ids.npy", "plan.json", "row_ptr.npy"]
             |> Enum.map(&Path.join(directory, &1))
             |> Enum.all?(&File.exists?/1)

      assert {:ok, %{"ticks" => 30}} =
               directory |> Path.join("plan.json") |> File.read!() |> Jason.decode()
    end

    test "refuses an edge that names a neuron the pack does not have", %{directory: directory} do
      spec = %{neuron_ids: [1, 2], edges: [{0, 5, 1}]}

      assert {:error, sentence} = Pack.write(directory, spec)
      assert sentence =~ "0 -> 5"
      assert sentence =~ "0..1"
    end
  end
end
