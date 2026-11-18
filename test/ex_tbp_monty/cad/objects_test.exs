defmodule ExTbpMonty.Cad.ObjectsTest do
  @moduledoc """
  A part's meshes as the object set a world steps.

  The geometry is not this application's, so the cases drive a named exporter: what
  is under test is the file set, the placement and the refusal a node without the
  CAD package gives.
  """

  use ExUnit.Case, async: true

  alias ExTbpMonty.Cad.Objects

  # Two meshes, one of them a record id — the shape `MontyCad.Export` answers.
  defmodule Stub do
    def feature_meshes(_part) do
      {:ok,
       [
         %{
           name: "bosses/0",
           family: "bosses",
           vertices: [[0.0, 0.0, 0.0], [0.01, 0.0, 0.0], [0.0, 0.01, 0.0]],
           triangles: [[0, 1, 2]],
           colour: {0.5, 0.5, 0.5}
         },
         %{
           name: "body",
           family: "body",
           vertices: [[-0.01, -0.01, 0.0], [0.01, -0.01, 0.0], [0.0, 0.01, 0.0]],
           triangles: [[0, 1, 2]],
           colour: {0.5, 0.5, 0.5}
         }
       ]}
    end
  end

  @tag :tmp_dir
  test "a directory per mesh, with the three files a world reads", %{tmp_dir: dir} do
    assert {:ok, rows} = Objects.write("part.step", dir, exporter: Stub)

    assert Enum.map(rows, & &1.object) == ["bosses_0", "body"]

    for row <- rows, file <- ["textured.obj", "texture_map.png", "metadata.json"] do
      assert File.regular?(Path.join([dir, row.object, file])),
             "expected #{row.object}/#{file}"
    end
  end

  @tag :tmp_dir
  test "the placement says where it sits, not how big it is", %{tmp_dir: dir} do
    {:ok, [boss | _rest]} = Objects.write("part.step", dir, exporter: Stub)

    metadata =
      Path.join([dir, boss.object, "metadata.json"])
      |> File.read!()
      |> JSON.decode!()

    assert metadata["scale"] == [1.0, 1.0, 1.0]
    assert metadata["refquat"] == [1.0, 0.0, 0.0, 0.0]
    assert metadata["refpos"] == [0.005, 0.005, 0.0]
  end

  @tag :tmp_dir
  test "a node without the CAD package is refused with a sentence", %{tmp_dir: dir} do
    assert {:error, sentence} = Objects.write("part.step", dir, exporter: NoSuchModule)
    assert sentence =~ "ex_monty_cad"
  end

  @tag :tmp_dir
  test "one mesh can be written on its own, which is what an evaluation needs", %{tmp_dir: dir} do
    plate = %{
      name: "plate",
      family: "plate",
      vertices: [[0.0, 0.0, 0.0], [0.01, 0.0, 0.0], [0.0, 0.01, 0.0]],
      triangles: [[0, 1, 2]],
      colour: {0.5, 0.5, 0.5}
    }

    row = Objects.write_mesh(plate, dir)

    assert row.object == "plate"
    assert File.regular?(Path.join([dir, "plate", "textured.obj"]))
  end

  # One rule, two writers: a feature the exporter calls `bosses/0` belongs to
  # the plate it was cut into, and a world steps one directory per object, so the
  # name is flattened and keeps the part — the same string a memory of the
  # plate's features answers with.
  test "names an object for its part and its feature, as one directory" do
    assert Objects.object_name("plate/bosses/0") == "plate_bosses_0"
    assert Objects.object_name("plate") == "plate"
  end
end
