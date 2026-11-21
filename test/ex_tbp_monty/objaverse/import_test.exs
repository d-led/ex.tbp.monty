defmodule ExTbpMonty.Objaverse.ImportTest do
  use ExUnit.Case, async: true

  alias ExTbpMonty.Objaverse.Import
  alias ExTbpMonty.Test.Gltf
  alias Monty.Test.Tmp

  defp entry(uid, id) do
    %{
      "id" => id,
      "uid" => uid,
      "name" => "Boykin Spaniel",
      "author" => "justicar",
      "licence" => "by",
      "page" => "https://example.invalid/models/#{uid}"
    }
  end

  defp source_with(files) do
    directory = Tmp.dir("objaverse-source")

    for {uid, bytes} <- files do
      File.write!(Path.join(directory, uid <> ".glb"), bytes)
    end

    directory
  end

  describe "one object, written as the world reads it" do
    test "the OBJ holds the mesh in the world's frame, with its texture coordinates" do
      source = source_with([{"u1", Gltf.triangle_glb()}])
      into = Tmp.dir("objaverse-set")

      assert {:ok, [row]} = Import.import(source, [entry("u1", "dog_one")], into)
      assert %{id: "dog_one", faces: 1, vertices: 3} = row

      lines =
        File.read!(Path.join([into, "dog_one", "textured.obj"])) |> String.split("\n", trim: true)

      # The node translated the triangle by (1, 2, 3); the glTF frame is Y-up and
      # the world's is Z-up, so (x, y, z) becomes (x, -z, y).
      assert Enum.filter(lines, &String.starts_with?(&1, "v ")) == [
               "v 1.000000 -3.000000 2.000000",
               "v 2.000000 -3.000000 2.000000",
               "v 1.000000 -3.000000 4.000000"
             ]

      assert Enum.filter(lines, &String.starts_with?(&1, "vt ")) == [
               "vt 0.000000 1.000000",
               "vt 1.000000 1.000000",
               "vt 0.000000 0.000000"
             ]

      assert Enum.filter(lines, &String.starts_with?(&1, "f ")) == ["f 1/1/1 2/2/2 3/3/3"]
    end

    test "the placement is in metadata.json, so the vertex file stays the scan's own" do
      source = source_with([{"u1", Gltf.triangle_glb()}])
      into = Tmp.dir("objaverse-placement")

      assert {:ok, _rows} = Import.import(source, [entry("u1", "dog_one")], into)

      metadata = into |> Path.join("dog_one/metadata.json") |> File.read!() |> JSON.decode!()

      # The triangle's area is 1 in its own units (base 1, height 2), so a corpus
      # of 200 cm² an object would scale it by sqrt(0.02) — 28 cm along its
      # longest side, past the 18 cm a 2 cm patch can still be a part of. So the
      # larger of the two bounds decides: 18 / 2 = 0.09, and this object's
      # surface comes out smaller than the corpus's.
      assert metadata["refpos"] == [1.5, -3.0, 2.0]
      assert metadata["refquat"] == [1.0, 0.0, 0.0, 0.0]
      assert metadata["scale"] == [0.09, 0.09, 0.09]

      # The world refuses a metadata key it does not know, so the provenance
      # lives in ATTRIBUTION.md rather than in this file.
      assert Map.keys(metadata) |> Enum.sort() == ["refpos", "refquat", "scale"]
    end

    # The area a memory's nodes follow, reported rather than left to be
    # re-derived: a corpus is comparable by this number, not by how big the
    # objects look.
    test "the row says what surface the object will present" do
      source = source_with([{"u1", Gltf.triangle_glb()}])
      into = Tmp.dir("objaverse-surface")

      assert {:ok, [row]} = Import.import(source, [entry("u1", "dog_one")], into)
      assert row.area == 0.0081

      # Nine centimetres along x, none along y (the triangle is one plane), and
      # eighteen up z — the bound that decided the scale.
      assert row.size == {0.09, 0.0, 0.18}
    end

    test "an untextured material becomes the one-pixel PNG MuJoCo is given" do
      source =
        source_with([
          {"u1", Gltf.triangle_glb(texture: %{"baseColorFactor" => [1.0, 0.0, 0.0, 1.0]})}
        ])

      into = Tmp.dir("objaverse-colour")

      assert {:ok, _rows} = Import.import(source, [entry("u1", "dog_one")], into)

      path = Path.join([into, "dog_one", "texture_map.png"])
      assert <<0x89, "PNG\r\n", 0x1A, "\n", _::binary>> = File.read!(path)
      assert {:ok, %{shape: {1, 1, 3}}} = StbImage.read_file(path)
    end

    test "a texture the GLB carries is decoded into texture_map.png" do
      png =
        StbImage.new(<<200, 30, 20>>, {1, 1, 3})
        |> StbImage.to_binary(:png)

      source = source_with([{"u1", Gltf.triangle_glb(texture: {:image, png, "image/png"})}])
      into = Tmp.dir("objaverse-image")

      assert {:ok, _rows} = Import.import(source, [entry("u1", "dog_one")], into)

      assert {:ok, %{shape: {1, 1, 3}}} =
               StbImage.read_file(Path.join([into, "dog_one", "texture_map.png"]))
    end

    test "the set carries its attribution, per object" do
      source = source_with([{"u1", Gltf.triangle_glb()}])
      into = Tmp.dir("objaverse-attribution")

      assert {:ok, _rows} = Import.import(source, [entry("u1", "dog_one")], into)

      attribution = File.read!(Path.join(into, "ATTRIBUTION.md"))
      assert attribution =~ "Boykin Spaniel"
      assert attribution =~ "justicar"
      assert attribution =~ "https://example.invalid/models/u1"
      assert attribution =~ "by"
    end
  end

  describe "an object that cannot be imported" do
    test "names itself when its GLB is not where the manifest says" do
      into = Tmp.dir("objaverse-missing")

      assert {:error, {:cannot_import, "dog_one", {:cannot_read, path, :enoent}}} =
               Import.import(Tmp.dir("objaverse-empty"), [entry("u1", "dog_one")], into)

      assert path =~ "u1.glb"
    end

    test "names itself when the GLB has no mesh" do
      document = %{
        "asset" => %{"version" => "2.0"},
        "scene" => 0,
        "scenes" => [%{"nodes" => []}],
        "nodes" => []
      }

      source = source_with([{"u1", Gltf.glb(document, <<>>)}])

      assert {:error, {:cannot_import, "dog_one", :no_mesh_in_scene}} =
               Import.import(source, [entry("u1", "dog_one")], Tmp.dir("objaverse-empty-scene"))
    end
  end
end
